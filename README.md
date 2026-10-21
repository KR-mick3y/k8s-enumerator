# k8s enumerator

`k8s-enum.sh`는 현재 쿠버네티스 컨텍스트가 사용할 수 있는 리소스 권한들을 열거하는 도구입니다. 각 항목은 가용성과 무결성에 영향 없는 `kubectl auth can-i`를 통해 검사합니다.

## 범위와 옵션

| 옵션 | 동작 |
|---|---|
| 옵션 없음 | 네임스페이스 리소스는 현재 kubectl context의 네임스페이스에서 검사합니다. |
| `--namespace NS` | 지정한 네임스페이스에서 검사합니다. 클러스터 범위 리소스도 계속 검사합니다. |
| `--all-namespaces` | 네임스페이스를 특정하지 않은 전체 범위 권한을 검사합니다. |
| `--name NAME` | 각 리소스에 대해 일반 검사에 더해 `NAME`이라는 특정 객체의 권한을 검사합니다. 동일한 이름을 모든 리소스 종류에 적용합니다. |
| `--url PATH` | `/metrics` 같은 비리소스 경로의 `get` 권한을 추가로 검사합니다. 반복 지정할 수 있습니다. |
| `--as USER` | 지정한 사용자 또는 서비스 계정으로 가장해 권한을 검사합니다. 실행 계정에 가장 권한이 필요합니다. |
| `--as-group GROUP` | 가장할 그룹을 지정합니다. 반복 지정할 수 있습니다. |
| `--context CONTEXT` | 지정한 kubectl context를 사용합니다. |
| `-o FILE`, `--output FILE` | 사람이 읽는 텍스트 결과를 파일에도 저장합니다. |
| `--allowed-only` | 호환성 옵션입니다. 허용 항목만 표시하는 동작은 이미 기본값입니다. |
| `-h`, `--help` | 도움말을 표시합니다. |

`--namespace`와 `--all-namespaces`를 함께 지정하면 현재 스크립트에서는 `--namespace`가 우선합니다.

출력은 **현재 계정의 최종 유효 권한**입니다. 사용자가 직접 만든 Role뿐 아니라 Kubernetes 기본 역할과 그룹을 통해 받은 권한도 포함됩니다. 

## 문제 해결

`API discovery unavailable`이 나오면 스크립트의 검사 전에 API 서버에 연결하지 못한 것입니다. `kubectl cluster-info`와 `kubectl config current-context`로 연결 상태를 확인하세요.

인증이나 API Discovery 권한이 부족하면 일부 리소스를 찾지 못할 수 있습니다. `--as`를 지정했을 때 Discovery가 막히면 스크립트는 kubeconfig 계정으로 Discovery를 재시도하지만, 실제 권한 판정에는 계속 가장한 계정을 사용합니다.
