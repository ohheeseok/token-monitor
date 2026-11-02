# TokenMonitor 구현 계획

Orca의 "사용량" 패널을 독립 실행형 macOS 메뉴바 앱으로 만든다. 메뉴바 아이콘을 누르면 반투명 팝오버가 열리고, 압축/상세 두 가지 보기로 서비스별 사용량을 보여 준다.

- 작성: 2026-11-01
- 검토 과정: Claude 초안 → GPT 6.1 sol(Codex, high) 비평 2회(2회차 판정 READY) → Antigravity(Gemini 3.8 Flash, high)로 기존 구현 사례 조사
- 근거 자료: 설치된 Orca.app 번들(`main/index.js`) 분석, 이 Mac에서 직접 실행해 본 결과

## 0. M0 진행 결과 (2026-11-01)

`~/Applications/TokenMonitor.app`을 ad-hoc 서명으로 빌드한 뒤, `open`으로 실행한 앱 안에서 probe를 돌려 확인했다. 결과는 `~/Library/Application Support/TokenMonitor/m0-report.json`에 비밀값 없이 저장된다.

| 항목 | 결과 |
|---|---|
| Codex app-server | ✅ `rateLimitsByLimitId`에는 `codex` 하나. Plus 플랜, 5h·주간 창 |
| Claude 계정 1 | ✅ 200 OK, Team 플랜. `five_hour`는 있고 `seven_day`는 `null`이다. 응답 최상위 키가 30개가 넘으므로(`limits`, `seven_day_sonnet`, `extra_usage` 등) M1에서 fixture로 구조를 확정한다 |
| Antigravity | ✅ agy 1.4.12, `num_turns` 0, 세 그룹 |
| 앱 전용 키체인 항목 | ⚠️→✅ SecItem API로 만든 항목은 재빌드로 cdhash가 바뀐 뒤 **앱으로 실행하면 접근 허용 창을 띄우고 멈춘다**(`interactionNotAllowed`도 효과 없음). `security -i`(비밀값은 stdin으로 전달)로 `-T /usr/bin/security` 항목을 만들고 `security`로 읽도록 바꾼 뒤에는, cdhash가 바뀐 뒤에도 팝업 없이 읽혔다 |
| Claude 키체인 이름 규칙 | ✅ Claude Code 2.1.314 바이너리에서 확인: `Claude Code-credentials` + (`CLAUDE_CONFIG_DIR`이 설정됐으면) `-` + `sha256(NFC(설정 폴더 경로)).hex` 앞 8자리, 계정 = `$USER`. `CLAUDE_CONFIG_DIR=~/.claude`처럼 기본 폴더를 명시해도 해시가 붙는다. 계정 2로 확인한 결과, 해시 입력은 `~`를 풀어 쓴 절대 경로(끝 `/` 없음)다: `/Users/…/.claude-account2` → `56dcf693`. 앱은 사용자가 `~`나 끝 `/`를 붙여 입력해도 후보를 만들어 찾는다 |
| swift-testing | ⚠️ CLT 환경에서 테스트가 컴파일되고 바이너리에 포함되지만, 러너가 아무것도 실행하지 않는다. M1에서 해결한다 |
| Claude 계정 2 | ✅ `~/.claude-account2`, Pro 플랜, 계정 1과 identity가 다르다. Pro는 session 한도를 `is_active: false`로 보내고 주간 한도의 kind가 `weekly_all`이어서, 파서가 `group` 필드로 창을 판단하도록 고쳤다 |
| OpenRouter | ⏳ 사용자가 키를 등록해야 한다 |
| 로그인 시 실행(`SMAppService`) | ⏳ 시스템 설정을 바꾸는 작업이라 사용자가 직접 실행해야 한다. 현재 상태는 `notFound` |

### M1 결과 (2026-11-01)

- `TokenMonitorCore`: 모델(`UsageWindow`, `MoneyUsage`, `UsageSnapshot`, `ProviderFailure`), 파서 4종, provider 4종, `RefreshPolicy`, `UsageStore`, `SnapshotCache`
- 테스트: CLT 환경에서는 `swift test`가 swift-testing을 실행하지 않는다. 그래서 테스트를 실행 파일 타깃으로 만들고 `make test`(= `swift run TokenMonitorTests`)로 돌린다. 54개 통과.
- fixture: 실제 응답을 비식별화한 것 4개 + 경계 사례 6개(`Tests/TokenMonitorTests/Fixtures`)
- 실제 데이터 확인: `TokenMonitor --fetch`로 네 소스 모두 정상(약 4초)
- OpenRouter 키 등록: `TokenMonitor --set-openrouter-key`(숨김 입력, 저장 후 실제 조회로 확인)
- GPT 코드 검토에서 나온 major 10건 반영: 프로세스 대기 시간 상한, JSON-RPC 응답을 id별로 분배, 이름만 바꾼 계정은 진행 중 요청 유지, 팝오버 열기가 실패 백오프를 우회하지 않음, `Retry-After`를 응답 수신 시각 기준으로 계산, OpenRouter 사용률을 `limit - limit_remaining`으로 계산, agy 안전장치 래치(한 번 걸리면 앱 재시작 전까지 비활성), RPC 오류 원문을 출력·저장하지 않음

### M2 결과 (2026-11-02)

- 메뉴바 아이콘을 왼쪽 클릭하면 `NSPopover(.transient)`가 열리고, 오른쪽 클릭하면 새로고침·계정 관리·종료 메뉴가 뜬다. 팝오버를 열 때와 잠자기에서 깨어날 때 갱신한다.
- 상세/압축 보기(선택 상태 저장), 폭 400pt. 미터는 고정 폭 두 칸(5h·wk)에 배치해서 계정끼리 열이 맞는다. 70% 이상이면 주황, 90% 이상이면 빨강.
- 아이콘: 설치된 ChatGPT·Claude·Antigravity 앱의 아이콘을 실행 중에 가져온다. OpenRouter는 SF Symbol을 쓴다.
- 계정 설정: `~/Library/Application Support/TokenMonitor/accounts.json`. "계정 관리…"를 누르면 이 파일이 열리고, 팝오버를 다시 열 때 바뀐 내용을 반영한다(설정 창은 M4).
- 화면 검수: `TokenMonitor --render-snapshots <dir>`로 데모 데이터를 PNG로 렌더링(상세/압축 × 다크/라이트)한 뒤 agy(Gemini 3.8 Flash)가 Orca 캡처와 비교했다. 반영한 것: 라이트 모드 세그먼트, 아이콘 크기 통일, 글꼴 크기, 구분선, OpenRouter 금액 강조, "종료" 보조 색. 오판 2건(막대의 최소 채움 표시를 점으로 읽음, 쉐브론 위치)은 반영하지 않았다.
- 버그 수정: `await MainActor.run { app.run() }` 구조에서는 MainActor가 계속 묶여 있어 갱신 Task가 하나도 실행되지 않았다. 진입점을 동기 코드로 바꿨다.
- 테스트 62개 통과(표시용 모델 7개 추가).

### M4 결과 (2026-11-02)

- 설정 창("계정 관리…" 또는 메뉴바 아이콘 오른쪽 클릭 → 계정 관리):
  - 계정마다 이름을 그 자리에서 고치고, 표시를 켜거나 끄고, 순서를 옮길 수 있다. Claude 계정은 삭제도 된다.
  - "Claude 계정 추가…"로 설정 폴더를 고르면, 그 폴더의 키체인 로그인 여부를 확인해 보여 준다. 로그인 정보가 없으면 `CLAUDE_CONFIG_DIR=… claude` 명령을 복사할 수 있다.
  - OpenRouter 키는 숨김 입력으로 받고, 저장한 뒤 실제 조회로 확인한다. 키 삭제도 된다.
  - 로그인 시 자동 실행(`SMAppService.mainApp`): 저장된 설정값이 아니라 실제 등록 상태를 따른다. 승인이 필요하면 시스템 설정으로 가는 링크를 보여 준다.
  - 메뉴바 표시: "아이콘만" 또는 "아이콘 + 가장 높은 사용률". 오래된 데이터는 빼고 계산하며, 70% 이상이면 주황, 90% 이상이면 빨강.
- 계정 편집은 `accounts.json`에 바로 저장되고 store에 반영된다. 이름만 바꾸면 진행 중인 요청은 그대로 유지된다(M1 수정 사항).
- 테스트 63개 통과. 설정 창도 `--render-snapshots`에 포함했다.
- 확인하지 못한 것: ad-hoc 서명 상태에서 로그인 시 자동 실행이 실제로 동작하는지(로그아웃·로그인 필요), 재빌드 후에도 유지되는지.

### M5 진행 상황 (2026-11-02 시작)

- 실제로 겪은 문제: Claude 2 토큰이 12:46Z에 만료된 뒤에도 앱이 그 토큰으로 계속 요청했고, 서버는 401이 아니라 429를 돌려줬다. 백오프가 쌓여 대기 시각이 1시간 뒤까지 밀렸다. 수정: 토큰의 `expiresAt`이 지났으면 요청을 보내지 않고 바로 "로그인 만료"로 표시한다. 15분마다 키체인만 다시 읽으므로, Claude Code가 토큰을 갱신하면 그때 다시 조회한다.
- Claude 계정 2는 그 폴더로 Claude Code를 대화형으로 실행해야만 토큰이 갱신된다. `claude auth status`로는 갱신되지 않는다. 앱은 refresh token을 쓰지 않으므로(§7) 이 제한은 그대로 둔다.
- 갱신 기록: 계정마다 요청 시작(이유 포함), 성공, 실패(실패 종류, 연속 횟수, 다음 시도 시각, 429 대기 시각)를 unified log에 남긴다. 토큰과 응답 본문은 기록하지 않는다. `make log`로 최근 하루치를 본다.
- 확인한 것:
  - 재빌드 후 재실행: Claude 1·OpenRouter 키체인 읽기 정상, 네 계정 갱신 성공.
  - 429 대기 시각이 재시작 뒤에도 유지되어 Claude 2는 실행 직후 요청하지 않았다.
- 정리: M0 키체인 시험 항목(`m0-canary`)과 `m0-report.json` 삭제, Makefile의 `probe`를 `fetch`·`log`로 교체.
- 며칠 동안 확인할 것 (`make log`로 점검):
  - 잠자기 해제 뒤 `reason=wake` 갱신이 한 번씩 일어나는지
  - 429가 다시 오는지, 오면 대기 시각을 지키는지
  - Claude 1 토큰이 Claude Code 사용으로 계속 갱신되는지
  - 로그인 시 자동 실행: 아직 등록하지 않았다(`notFound`). 설정 창에서 켠 뒤 로그아웃·로그인으로 확인한다.

## 1. 대상 서비스와 데이터 소스

| 서비스 | 데이터 소스 | 자격증명 처리 | 상태 |
|---|---|---|---|
| ChatGPT/Codex | `codex app-server`(stdio JSON-RPC) `account/rateLimits/read` | 앱이 토큰을 직접 다루지 않음. Codex가 처리 | ✅ 실행 확인 (5h·주간 %, 플랜, 무료 리셋 크레딧) |
| Claude 계정 1 | `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | `/usr/bin/security find-generic-password`로 키체인 `Claude Code-credentials`를 읽기만 함 | ✅ 키체인 ACL이 `/usr/bin/security`만 신뢰함을 확인 → 권한 팝업 없음 |
| Claude 계정 2 | 위와 같음 | `CLAUDE_CONFIG_DIR`별 키체인 항목 `Claude Code-credentials-<해시>` | ⏳ 아직 이 Mac에 두 번째 계정 로그인이 없음 |
| Antigravity | `agy -p /usage --output-format json --print-timeout 20s` | 앱이 토큰을 직접 다루지 않음 | ✅ 실행 확인 (Gemini / Claude·GPT / Gemini 4 Argon 그룹, 5h·주간) |
| OpenRouter | `GET https://openrouter.ai/api/v1/key` | 사용자가 입력한 API 키를 앱 전용 키체인 항목에 저장(`/usr/bin/security`로 저장·읽기) | ⏳ 키 필요 |

### 서비스별 세부 사항

**Codex**
- 갱신할 때마다 `codex app-server`를 띄워 `initialize` → `initialized` → `account/rateLimits/read`를 보내고 종료한다. 상주 프로세스는 v1에서 쓰지 않는다.
- 응답은 `rateLimitsByLimitId`를 우선 쓰고, 없으면 `rateLimits`를 쓴다. 창(window)이 빠질 수 있다. 라벨은 `windowDurationMins`에서 만든다(300 → 5h, 10080 → wk).
- `planType`은 문자열로 받는다. enum으로 받으면 새 플랜이 나왔을 때 파싱이 깨진다(CodexBar에서 실제로 있었던 문제).

**Claude**
- 토큰 갱신·덮어쓰기·삭제는 절대 하지 않는다. refresh token은 한 번 쓰면 바뀌므로, 앱이 갱신하면 Claude Code의 로그인이 깨진다.
- 401이 오면 키체인을 한 번 다시 읽는다. 토큰이 바뀌었을 때만 재시도하고, 그대로면 마지막 정상 값을 유지한 채 "Claude Code를 실행하면 갱신됩니다"를 표시한다.
- 계정 설정은 `{id, 라벨, configDir}`로 둔다. `GET /api/oauth/profile`로 이메일·플랜을 받아 라벨을 정하고, 두 계정이 실제로 다른지 확인한다. 같은 폴더에서 다른 계정으로 다시 로그인했으면 캐시를 버린다.
- 두 번째 계정은 다음 명령으로 한 번 로그인해 두고 앱에서 그 폴더를 지정한다.
  ```bash
  CLAUDE_CONFIG_DIR="$HOME/.claude-account2" claude
  ```
  이 계정의 토큰은 이 폴더로 Claude Code를 실행할 때만 갱신된다. 오래 쓰지 않으면 "로그인 만료"가 뜬다.
- 키체인 서비스 이름의 해시 규칙(Orca 코드상 `sha256(NFC(configDir))`의 hex 앞부분)은 계정 2를 만든 뒤 실제 항목 이름과 비교해 확정한다.
- **정책 리스크**: Anthropic 문서는 구독 OAuth를 제3자 앱이 다루는 것을 제한한다. 읽기 전용 개인 모니터에 대한 명시적 허용 조항은 없다. Orca와 CodexBar도 같은 방식이지만, 이 provider는 설정에서 끌 수 있게 둔다.

**Antigravity**
- 실행 전 `agy --version`을 확인한다. 검증한 버전(현재 1.4.12)에서만 `/usage`를 보낸다. 버전이 바뀌면 출력 형식을 한 번 확인한 뒤 허용 목록에 추가한다. 구버전은 `/usage`를 프롬프트로 처리해 쿼터를 소모하기 때문이다.
- `AGY_CLI_DISABLE_AUTO_UPDATE=true`를 설정한다. 응답의 `command.name == "usage"`와 `num_turns == 0`을 검사해, 어긋나면 이번 세션 동안 provider를 끈다.
- 화면에는 사용률로 표시한다(`1 − remaining_fraction`). Orca는 "Remaining"이라는 라벨에 사용률을 표시해 헷갈린다.

**OpenRouter**
- 일반 API 키 하나로 `/key`를 조회한다(`usage`, `limit`, `limit_remaining`, 일·주·월 사용액). `limit == null`이면 "한도 없음"으로 표시하고 0과 구분한다. 금액은 `Decimal`로 다룬다.
- 계정 전체 잔액은 `/credits`(`total_credits`, `total_usage`)로 조회한다. 처음에는 management key가 필요하다고 보고 미뤘으나, 2026-11-02에 일반 키로도 200이 오는 것을 확인했다. 잔액 = `total_credits − total_usage`. 이 호출이 실패해도 `/key` 값은 그대로 표시한다.

## 2. 앱 구조

Swift 6 + SwiftUI + AppKit, SwiftPM 패키지, 배포 대상 macOS 26. 샌드박스 없이 실행한다(`~/.codex` 읽기, `agy`/`codex`/`security` 실행에 필요).

```
TokenMonitor/
├─ Package.swift                 # Swift 6 language mode 명시
├─ Sources/TokenMonitorCore/     # UI 없는 로직 (테스트 대상)
│  ├─ Models/        UsageWindow, MoneyQuota, AccountID, ProviderFailure (Sendable 값 타입)
│  ├─ Providers/     CodexProvider, ClaudeProvider, AntigravityProvider, OpenRouterProvider
│  ├─ Services/      ProcessRunner, HTTPClient(ephemeral), KeychainStore(자체 항목), SecurityCLI
│  └─ Store/         UsageStore(@MainActor), RefreshScheduler, SnapshotCache
├─ Sources/TokenMonitor/         # 앱 셸
│  ├─ AppDelegate, StatusItemController(NSStatusItem + NSPopover.transient)
│  └─ UI/  PopoverView, CompactRow, DetailCard, SettingsView, VisualEffectBackground
├─ Resources/  provider 아이콘, AppIcon.icns, Localizable.strings(ko)
├─ Tests/TokenMonitorCoreTests/  fixture 파서, 스케줄러, 프로세스 러너
└─ scripts/bundle.sh, Makefile
```

- **provider**는 정규화된 값을 반환하거나 분류된 오류(`missingCredentials`, `expired`, `rateLimited(retryAt)`, `keychainLocked`, `schema`, `network`, `cliUnavailable`)를 던진다. 화면 상태는 store가 정한다.
- **store**는 계정마다 `lastGood`, `lastSuccessAt`, `lastAttemptAt`, `isRefreshing`, `failure`, `nextEligibleAt`을 따로 들고 있다. "오래됨"은 경과 시간에서 계산한다. 계정마다 진행 중인 요청은 하나뿐이고, 세대 번호를 붙여 계정이 바뀐 뒤 도착한 응답은 버린다.
- **ProcessRunner**는 실행 파일을 절대 경로로 실행한다(`sh -c` 사용 안 함). stdout/stderr를 동시에 읽고 크기를 제한하며, 타임아웃이 지나면 terminate 후 kill한다. 자격증명 명령의 출력은 오류 메시지나 로그에 넣지 않는다.
- **HTTPClient**는 ephemeral `URLSession`(디스크 캐시·쿠키 없음)을 쓰고 로그에서 헤더를 가린다.

### 갱신 정책 (스케줄러 하나가 모든 트리거를 처리)

| 상황 | 동작 |
|---|---|
| 백그라운드 | Claude·Codex 5분 ±20%, Antigravity·OpenRouter 10분 |
| 팝오버 열 때 | 마지막 갱신이 60초보다 오래됐고 갱신 가능한 상태면 갱신 |
| 새로고침 버튼 | 진행 중인 요청과 합치고, 서버 쿨다운은 지킨다 |
| 429 | `Retry-After`(초 또는 날짜)까지 대기하고, 그 시각을 디스크에 저장해 재시작해도 유지 |
| 타임아웃·5xx | 1·2·4·8…분, 최대 30분 |
| 잠자기 해제·네트워크 복구 | 지터를 준 1회 갱신 |
| 리셋 시각 경과 | 0%로 바꾸지 않고 "업데이트 대기" 표시 후 갱신 |

지연·타임아웃은 monotonic clock으로, 리셋 시각과 저장되는 마감 시각은 wall clock으로 계산한다. 마지막 정상 스냅샷은 `~/Library/Application Support/TokenMonitor/cache.json`(0600, 스키마 버전 포함)에 저장한다. 실행 직후 팝오버를 바로 그리기 위해서이며, 불러온 값은 항상 "오래됨"으로 시작한다.

## 3. UI (Orca 화면 기준)

- **팝오버**: `NSPopover(.transient)`에 SwiftUI를 올린다. 반투명 효과는 팝오버 배경 material에서만 내고, 창 전체 alpha는 건드리지 않는다(글자가 흐려짐). 폭은 약 350pt.
- **헤더**: "사용량", 오른쪽에 새로고침 아이콘. 그 아래 상세/압축 세그먼트(선택 상태 저장).
- **압축 행**: 아이콘 · 이름 · 부가 설명(가장 빠듯한 버킷) · 리셋까지 남은 시간(`5d 17h`) · 사용률 · `›`
- **상세 카드**: 이름 + "Resets in 4h 59m", 그 아래 창마다 `5h ▬▬ 8%   wk ▬▬ 27%`. Antigravity는 그룹·버킷별로 한 줄씩. OpenRouter는 `$사용액 / $한도`.
- **Claude**: 계정마다 한 행("Claude · 개인", "Claude · 회사").
- **상태 표시**: 로딩 스켈레톤, 오래됨(흐리게 + "n분 전"), 오류(복구 방법 안내), "로그인 만료"
- **하단**: "사용량 세부 정보 및 기록 ›"(v1에서는 각 서비스 대시보드 링크), "계정 관리… ›"(설정 창), 종료
- **메뉴바 아이콘**: 템플릿 아이콘. 옵션으로 가장 높은 사용률(%)을 옆에 표시한다.
- **설정 창**: Claude 계정 폴더 추가·삭제(폴더 선택기와 로그인 명령 복사 버튼), OpenRouter 키, provider별 켜기/끄기, 메뉴바 표시 방식, 로그인 시 실행

## 4. Xcode 없이 빌드·패키징

이 Mac에는 Command Line Tools(Swift 6.3.3, macOS 26.5 SDK)만 있고 Xcode.app은 없다. SwiftPM으로 충분하다.

- `scripts/bundle.sh`: `swift build -c release` → `TokenMonitor.app/Contents/{MacOS,Resources,Info.plist}` 조립(번들 ID `com.heeseok.tokenmonitor`, `LSUIElement`, `LSMinimumSystemVersion 26.0`) → SwiftPM 리소스 번들 복사 → `codesign --force --sign -` → `codesign --verify --strict` → `~/Applications`에 설치 → `open`
- `make dev`: 다시 빌드하고 실행 중인 앱을 재시작
- 로그인 시 실행은 `SMAppService.mainApp`을 쓰고, 토글은 저장된 Boolean이 아니라 실제 `status`를 따른다. ad-hoc 서명으로 재빌드한 뒤에도 유지되는지는 M0에서 확인한다. 안 되면 "시스템 설정 → 로그인 항목"에 직접 추가하는 방법을 안내한다.

## 5. 테스트

- `swift test`
  - 파서: 오늘 받은 실제 응답을 비식별화한 fixture와 경계 사례(창 누락, null, 100% 초과, 알 수 없는 필드, HTML 오류 본문)
  - 스케줄러: 가짜 시계로 합치기, `Retry-After` 두 형식, 재시작 후 쿨다운 유지, 취소
  - 세대 경쟁: 계정 삭제·변경 뒤 도착한 응답이 화면이나 캐시에 들어가지 않는지
  - ProcessRunner: 멈추는 실행 파일, 출력 폭주, 0이 아닌 종료 코드, 잘못된 JSON
  - agy 버전 확인: 허용 목록 밖의 버전에서는 `/usage`를 보내지 않는지
- 화면: 고정 fixture로 `NSHostingView`를 PNG로 렌더링한 뒤, agy(Gemini)에게 Orca 캡처와 비교 검수를 맡긴다.
- 수동 점검: 팝오버 닫힘(바깥 클릭, Esc, 아이콘 연속 클릭, 전체 화면 앱, 다중 모니터), 키체인 잠김 상태, 재빌드 후 키체인·로그인 항목

## 6. 마일스톤

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **M0 실현 가능성** | Claude 계정 2 로그인 및 키체인 해시 규칙 확인, OpenRouter `/key` 응답 확인, 최소 앱 번들 + `SMAppService` + 재빌드 후 키체인 접근 확인 | 다섯 개 데이터 소스 모두 실제 값 확인 |
| **M1 코어** | 모델, fixture, 파서 4종, 스케줄러, ProcessRunner + 테스트 | `swift test` 통과 |
| **M2 화면 골격** | 상태 아이콘 + 팝오버 + 압축/상세 화면(fixture 데이터) | Orca 캡처와 비교 검수 통과 |
| **M3 실제 연결** | Codex → Claude 1 → Antigravity → OpenRouter → Claude 2 순서 | 팝오버에 실제 값 표시 |
| **M4 설정·오류 처리** | 설정 창, 로그인 시 실행, 메뉴바 % 표시, 오류·복구 문구 | 수동 점검표 통과 |
| **M5 설치 검증** | 재빌드, 잠자기/해제, 429, 계정 2 만료 시나리오, 며칠간 상시 실행 | 문제 없이 며칠 실행 |

## 7. v1에서 하지 않는 것

- Claude OAuth 로그인 직접 구현 (정책 위반 소지 + refresh token 충돌)
- Codex app-server 상주 연결
- OpenRouter management key
- 사용량 기록 저장과 차트 (하단 메뉴는 대시보드 링크로 대체)
- 갱신 주기 사용자 설정
- Cursor (사용하지 않음)

## 8. 참고 구현

- [steipete/CodexBar](https://github.com/steipete/CodexBar) (Swift, MIT): 네 서비스를 모두 지원하는 메뉴바 앱. provider 추상화, 429 쿨다운 게이트, `planType` 문자열 처리를 참고한다.
- [stablyai/orca](https://github.com/stablyai/orca) (Electron, MIT): 화면 구성과 각 서비스 호출 방식(설치된 번들에서 확인)
- [hamed-elfayome/Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (Swift): Claude 다중 프로필 관리

## 9. 시작 전에 정할 것

1. **두 번째 Claude 계정**: 지금은 Claude Code에 로그인된 계정이 하나뿐이다. 위 `CLAUDE_CONFIG_DIR` 명령으로 두 번째 계정을 로그인해 두면 같은 방식으로 읽을 수 있다. 이 계정의 사용률을 갱신하려면 가끔 그 폴더로 Claude Code를 실행해야 한다.
2. **OpenRouter 키**: 앱 설정 화면에서 입력한다(일반 키로 충분하다).
3. **Claude 정책 리스크**를 감수할지 여부. 감수하지 않으면 Claude 항목을 끈 채로 시작한다.
