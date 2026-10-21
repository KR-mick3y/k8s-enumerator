#!/usr/bin/env bash
set -uo pipefail

# Read-only Kubernetes authorization matrix via kubectl auth can-i.
# Requires: kubectl, jq, sort, mktemp. Bash 4+ is recommended.

OUT=""
ALLOWED_ONLY=1
ALL_NAMESPACES=0
NAMESPACE=""
RESOURCE_NAME=""
URLS=()
AS_ARGS=()

usage() {w
  cat <<'HELP'
Usage: k8s_can_i_audit.sh [options]
  -o, --output FILE     Save human-readable output to FILE (default: screen only)
  --allowed-only        Compatibility option: allowed-only output is always enabled
  --all-namespaces      Check namespaced resources across all namespaces
  --namespace NS        Check this namespace plus cluster-scoped resources
  --name NAME           Additionally test name-scoped checks against NAME
  --url PATH             Add a non-resource URL check; repeatable (for example: /metrics)
  --as USER              Impersonate a user or service account
  --as-group GROUP       Impersonate a group; repeatable
  --context CONTEXT      Use this kubectl context
  --help                Show help

All probes issue authorization reviews only; no workload mutation is performed.
Without --namespace or --all-namespaces, namespaced checks use the current context namespace.
HELP
}

while (($#)); do
  case "$1" in
    -o|--output|--namespace|--name|--url|--as|--as-group|--context)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        -o|--output) OUT="$2" ;;
        --namespace) NAMESPACE="$2" ;;
        --name) RESOURCE_NAME="$2" ;;
        --url) URLS+=("$2") ;;
        --as) AS_ARGS+=("--as=$2") ;;
        --as-group) AS_ARGS+=("--as-group=$2") ;;
        --context) AS_ARGS+=("--context=$2") ;;
      esac
      shift 2
      ;;
    --allowed-only) ALLOWED_ONLY=1; shift ;;
    --all-namespaces) ALL_NAMESPACES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for x in kubectl jq sort mktemp; do
  command -v "$x" >/dev/null 2>&1 || { echo "Missing: $x" >&2; exit 1; }
done

TMP=$(mktemp -d 2>/dev/null) || {
  echo "ERROR: mktemp -d failed (TMPDIR=${TMPDIR:-<unset>}). Check writable temporary storage." >&2
  exit 1
}
[[ -n "$TMP" && -d "$TMP" ]] || { echo "ERROR: invalid temporary directory" >&2; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

K=(kubectl)
if ((${#AS_ARGS[@]})); then
  K+=("${AS_ARGS[@]}")
fi

# Discovery describes the API surface. When impersonation cannot read discovery,
# retry discovery with the kubeconfig identity; authorization reviews still use K.
DISC=(kubectl)
if ((${#AS_ARGS[@]})); then
  DISC+=("${AS_ARGS[@]}")
fi
DISC_FALLBACK=(kubectl)
if ((${#AS_ARGS[@]})); then
  for arg in "${AS_ARGS[@]}"; do
    [[ "$arg" == --context=* ]] && DISC_FALLBACK+=("$arg")
  done
fi

discover_root() {
  local url="$1" outfile="$2" errfile="$3"
  if "${DISC[@]}" get --raw "$url" >"$outfile" 2>"$errfile"; then
    return 0
  fi
  if ((${#AS_ARGS[@]})); then
    if "${DISC_FALLBACK[@]}" get --raw "$url" >"$outfile" 2>>"$errfile"; then
      echo "WARN: discovery $url used kubeconfig identity (impersonated identity could not access it)" >&2
      return 0
    fi
  fi
  return 1
}

: >"$TMP/paths"
discover_root /api "$TMP/api.json" "$TMP/api.err" || true
discover_root /apis "$TMP/apis.json" "$TMP/apis.err" || true

if jq -e '.versions | type == "array"' "$TMP/api.json" >/dev/null 2>&1; then
  jq -r '.versions[] | "/api/" + .' "$TMP/api.json" >>"$TMP/paths"
fi
if jq -e '.groups | type == "array"' "$TMP/apis.json" >/dev/null 2>&1; then
  jq -r '.groups[].versions[].groupVersion | "/apis/" + .' "$TMP/apis.json" >>"$TMP/paths"
fi
sort -u "$TMP/paths" -o "$TMP/paths"

if [[ ! -s "$TMP/paths" ]]; then
  echo "ERROR: API discovery unavailable. /api: $(head -c 250 "$TMP/api.err" 2>/dev/null)" >&2
  echo "ERROR: /apis: $(head -c 250 "$TMP/apis.err" 2>/dev/null)" >&2
  echo "HINT: kubectl cluster-info; kubectl get --raw /api; kubectl get --raw /apis" >&2
  exit 1
fi

: >"$TMP/resources.tsv"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  raw="$TMP/raw_$(printf '%s' "$path" | tr '/.' '__').json"
  err="$raw.err"
  if ! "${DISC[@]}" get --raw "$path" >"$raw" 2>"$err"; then
    if ((${#AS_ARGS[@]})) && "${DISC_FALLBACK[@]}" get --raw "$path" >"$raw" 2>>"$err"; then
      echo "WARN: discovery $path used kubeconfig identity" >&2
    else
      echo "WARN: skipping discovery path $path: $(head -c 200 "$err" 2>/dev/null)" >&2
      continue
    fi
  fi

  group=""
  if [[ "$path" == /apis/*/* ]]; then
    group="${path#/apis/}"
    group="${group%%/*}"
  fi
  jq -r --arg group "$group" '
    .resources[]?
    | select((.name | type) == "string" and (.verbs | type) == "array")
    | [(.name + (if $group == "" then "" else "." + $group end)),
       (.kind // ""),
       (if ((.namespaced | type) == "boolean" and .namespaced == true)
        then "namespaced" else "cluster" end),
       (.verbs | join(","))]
    | @tsv
  ' "$raw" >>"$TMP/resources.tsv" 2>/dev/null || \
    echo "WARN: malformed discovery response at $path" >&2
done <"$TMP/paths"

if [[ ! -s "$TMP/resources.tsv" ]]; then
  echo "ERROR: no API resources were discovered" >&2
  exit 1
fi

if [[ -n "$OUT" ]]; then
  : >"$OUT" || { echo "ERROR: cannot write output file: $OUT" >&2; exit 1; }
fi

TOTAL=0
ALLOWED=0
DENIED=0
ERRORS=0
HEADER_PRINTED=0
PRINTED_GROUPS=0

print_line() {
  local line="$1" colored="$2"
  [[ -n "$OUT" ]] && printf '%s\n' "$line" >>"$OUT"
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '%b\n' "$colored"
  else
    printf '%s\n' "$line"
  fi
}

print_box_header() {
  local title="$1" width=39 length left right
  title="${title:0:39}"
  length=${#title}
  left=$(( (width - length) / 2 ))
  right=$(( width - length - left ))
  if ((PRINTED_GROUPS > 0)); then
    print_line '' ''
    print_line '' ''
  fi
  print_line '###########################################' '###########################################'
  print_line "# $(printf '%*s%s%*s' "$left" '' "$title" "$right" '') #" "# $(printf '%*s%s%*s' "$left" '' "$title" "$right" '') #"
  print_line '###########################################' '###########################################'
  ((PRINTED_GROUPS++))
}

append_result() {
  local result="$1" verb="$2" resource="$3" kind="$4" scope="$5" ns="$6" name="$7" url="$8" err="$9"
  ((TOTAL++))
  case "$result" in
    allowed) ((ALLOWED++)); label='[+]'; color='\033[32m' ;;
    denied) ((DENIED++)); label='[-]'; color='\033[31m' ;;
    *) ((ERRORS++)); label='[!] ERROR'; color='\033[33m' ;;
  esac
  if [[ "$result" != allowed ]]; then
    return 0
  fi
  # Defer the heading until the first allowance so empty resources stay hidden.
  if ((HEADER_PRINTED == 0)); then
    print_box_header "$title"
    HEADER_PRINTED=1
  fi
  local detail line colored
  detail="$label $verb"
  line="$detail"
  [[ -n "$err" ]] && line="$line | ${err//$'\n'/ }"
  colored="${color}${detail}\\033[0m"
  [[ -n "$err" ]] && colored="$colored | ${err//$'\n'/ }"
  print_line "$line" "$colored"
}

 # Classify stdout as well as exit status: kubectl returns 1 for a valid denial.
classify_check() {
  local answer
  answer=$(<"$out")
  ((rc == 130 || rc == 143)) && exit "$rc"
  if ((rc == 0)) && [[ "$answer" == yes ]]; then
    result=allowed
  elif ((rc == 1)) && [[ "$answer" == no || "$answer" == 'no - '* ]]; then
    result=denied
  else
    result=error
    echo "ERROR: auth check failed (exit $rc): $(<"$err") ${answer}" >&2
  fi
}

check_resource() {
  local verb="$1" resource="$2" kind="$3" scope="$4" ns="$5" name="$6"
  local out err rc result stderr_text
  out="$TMP/check.out"; err="$TMP/check.err"
  local target="$resource" subresource="" tail
  # Discovery uses resource/subresource.group; can-i requires a separate flag.
  if [[ "$resource" == */* ]]; then
    tail=${resource#*/}
    subresource=${tail%%.*}
    target=${resource%%/*}
    [[ "$tail" == *.* ]] && target="$target.${tail#*.}"
  fi
  [[ -n "$name" ]] && target="$target/$name"
  local args=("${K[@]}" auth can-i "$verb" "$target")
  [[ -n "$subresource" ]] && args+=(--subresource="$subresource")
  if [[ "$scope" == namespaced ]]; then
    if [[ -n "$ns" ]]; then
      args+=(--namespace="$ns")
    elif ((ALL_NAMESPACES)); then
      args+=(--all-namespaces)
    fi
  else
    # can-i clears the review namespace with -A, including for cluster resources.
    args+=(--all-namespaces)
  fi
  if "${args[@]}" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  classify_check
  append_result "$result" "$verb" "$resource" "$kind" "$scope" "$ns" "$name" "" "$(cat "$err" 2>/dev/null)"
}

while IFS=$'\t' read -r resource kind scope discovered_verbs; do
  [[ -n "$resource" ]] || continue
  title="${kind:-$resource}"
  if [[ "$resource" == */* ]]; then
    suffix=${resource#*/}
    title="$title / ${suffix%%.*}"
  fi
  HEADER_PRINTED=0
  IFS=',' read -r -a resource_verbs <<< "$discovered_verbs"
  for verb in "${resource_verbs[@]}"; do
    [[ -n "$verb" ]] || continue
    check_resource "$verb" "$resource" "$kind" "$scope" "$NAMESPACE" ""
  done
  if [[ -n "$RESOURCE_NAME" ]]; then
    title="$title / $RESOURCE_NAME"
    HEADER_PRINTED=0
    for verb in "${resource_verbs[@]}"; do
      [[ -n "$verb" ]] || continue
      check_resource "$verb" "$resource" "$kind" "$scope" "$NAMESPACE" "$RESOURCE_NAME"
    done
  fi
done < <(sort -u "$TMP/resources.tsv")

for url in ${URLS[@]+"${URLS[@]}"}; do
  [[ -n "$url" ]] || continue
  title="Non-resource URL: $url"
  HEADER_PRINTED=0
  out="$TMP/url.out"; err="$TMP/url.err"
  args=("${K[@]}" auth can-i get "$url")
  if "${args[@]}" >"$out" 2>"$err"; then rc=0; else rc=$?; fi
  classify_check
  append_result "$result" get "" "" non-resource "" "" "$url" "$(cat "$err" 2>/dev/null)"
done

print_line '' ''
print_line "Summary: $TOTAL checks | $ALLOWED allowed | $DENIED denied | $ERRORS errors" "Summary: $TOTAL checks | $ALLOWED allowed | $DENIED denied | $ERRORS errors"
[[ -n "$OUT" ]] && echo "Saved human-readable report to $OUT" >&2
((ERRORS == 0))
