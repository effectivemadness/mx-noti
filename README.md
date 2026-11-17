# MX Noti

AI 도구가 응답을 끝내거나 승인을 기다릴 때 **MX Master 4의 햅틱 진동**으로 알려주는 macOS 메뉴 막대 앱입니다. Swift와 macOS 기본 프레임워크만 사용합니다. Logitech 플러그인, Python 실행 환경, 로컬 웹 서버가 필요하지 않습니다.

## 시작

```sh
git clone https://github.com/effectivemadness/mx-noti.git
cd mx-noti
./scripts/install.sh
```

`./scripts/install.sh`를 실행하면 빌드, `~/Applications/MX Noti.app` 설치, Claude Code·Codex·Kiro CLI 훅 연결과 앱 실행까지 진행합니다. 기존 설정은 백업합니다. 실행 중인 MX Noti가 있다면 먼저 종료하세요. 개별 단계는 아래와 같습니다.

1. `./scripts/build.sh`로 앱을 만듭니다. 결과: `dist/MX Noti.app`.
2. 앱을 원하는 위치로 옮긴 뒤 실행합니다. 훅에는 이 위치가 기록되므로 **위치를 정한 뒤** 연결하세요.
3. 앱의 **마우스 접근 허용** 버튼을 누르고, 시스템 설정 → 개인정보 보호 및 보안 → **입력 모니터링**에서 **MX Noti**를 켭니다. macOS가 요청하면 앱을 종료 후 다시 실행합니다.
4. **앱 연결**에서 Claude Code, Codex, Kiro CLI를 연결합니다. Kiro IDE는 **프로젝트 폴더 연결**도 한 번 실행합니다.
5. Codex는 **설정 → Hooks** 또는 CLI의 **`/hooks`**에서 새 MX Noti 훅을 검토하고 허용합니다. 기존 훅에 대한 신뢰 설정은 변경하지 않습니다.
6. 새 에이전트 세션을 열고, 앱의 ▶ 버튼으로 진동을 시험합니다.

### ChatGPT·Claude 데스크톱 앱

버전 0.2.0부터 **앱 연결 → 데스크톱 앱 알림**에서 ChatGPT 앱과 Claude 앱의 macOS 알림 배너를 감지합니다. `Claude Code` 연결과 `Claude 앱` 연결은 별도입니다.

1. MX Noti의 **알림 감지 권한 설정**을 누르고 시스템 설정 → 개인정보 보호 및 보안 → **손쉬운 사용**에서 MX Noti를 허용합니다. 마우스 제어용 **입력 모니터링**과는 별도 권한입니다.
2. ChatGPT·Claude의 앱 알림과 macOS 시스템 설정 → 알림의 **배너**를 켭니다. ChatGPT의 경우 완료 알림을 **항상** 또는 **백그라운드에서만**으로 선택하고 권한·질문 알림도 켭니다.
3. MX Noti를 실행한 상태에서 앱 알림을 받습니다. 방해금지·집중 모드 등으로 배너가 표시되지 않으면 감지할 수 없습니다. 배너를 보내지 않는 일반 채팅 응답도 자동 감지하지 않습니다.

읽는 대상은 알림 센터의 표시 중인 알림입니다. 채팅 창의 대화 내용을 스캔하거나 알림 데이터베이스를 읽지 않습니다. 알림 문구로 완료·승인·입력 대기를 추정하며, 구분할 수 없는 알림은 **앱 알림** 패턴을 사용합니다. 알림 원문은 저장하지 않습니다. macOS의 손쉬운 사용 화면 구조에 의존하므로 OS 업데이트에 따라 달라질 수 있습니다.

현재 `Codex` 연결은 `~/.codex/hooks.json`의 엔진 훅입니다. CLI 외에 훅을 지원하는 데스크톱 Codex 작업에도 적용됩니다. ChatGPT 일반 대화의 앱 알림은 위의 별도 배너 감지를 사용합니다. 훅과 배너를 같은 작업에 모두 켜면 중복 진동이 발생할 수 있습니다.

개발용 서명 앱을 다시 빌드하거나 갱신한 뒤 macOS가 접근을 거부하면 입력 모니터링·손쉬운 사용 권한을 다시 허용하고 앱을 재실행해야 할 수 있습니다.

현재 하드웨어 연결은 **MX Master 4 (`046D:B042`)의 직접 Bluetooth 연결**을 대상으로 합니다. Logi Bolt 수신기는 아직 지원하지 않습니다. 햅틱이 꺼져 있거나 세기가 0이면 Logi Options+에서 조절하세요. 앱은 마우스의 영구 설정을 변경하지 않습니다.

## 알림 방식

| 도구 | 응답 완료 | 승인 요청 | 입력 대기 / 오류 | 연결 방식 |
|---|---|---|---|---|
| Claude Code | `Stop` | `PermissionRequest` | `Notification`, `AskUserQuestion` / `StopFailure` | 사용자 설정의 훅에 추가 |
| Codex CLI·데스크톱 작업 | `Stop` | `PermissionRequest` | `request_user_input` 계열 도구 / 전용 오류 훅 미연결 | 사용자 `hooks.json`, 새 훅 검토·허용 필요 |
| ChatGPT 앱 | 알림 문구로 추정 | 알림 문구·버튼으로 추정 | 알림 문구로 추정 | macOS 알림 배너, 손쉬운 사용 권한 필요 |
| Claude 앱 | 알림 문구로 추정 | 알림 문구·버튼으로 추정 | 알림 문구로 추정 | macOS 알림 배너, 손쉬운 사용 권한 필요 |
| Kiro CLI V3 | `Stop` | 전용 승인 훅 미지원 | 도구 이름이 알려진 질문만 구분 / 오류 미연결 | `~/.kiro/hooks/mx-noti.json` |
| Kiro IDE | 프로젝트 `Stop` | 로컬 로그의 `agent.pendingInteraction` | 알려진 질문 이벤트만 / 오류 미연결 | 프로젝트 훅 + 로컬 로그 감지 |
| Kiro Crew | `turn/completed` | `approval/requested` | 별도 입력·오류 알림 미연결 | Crew Log를 읽기 전용으로 감지 |

Kiro CLI의 **승인 대기만** 알려주는 전용 이벤트는 현재 확인한 공식 훅 목록에 없습니다. 대신 **도구 실행 직전**을 선택하면 모든 Kiro 도구 호출을 알려줍니다. 이 옵션은 기본적으로 꺼져 있으며, 실제 승인 대기와 구분됩니다. Crew 안에서 실행되는 CLI의 승인은 Crew Log로 감지합니다.

Kiro IDE 로그 감지는 **Kiro 1.4.178**, Crew Log 감지는 **Kiro Crew 0.8.0**의 이벤트 형식을 기준으로 작성했습니다. 두 어댑터는 비공식 형식에 의존하므로 업데이트로 달라질 수 있습니다. IDE 로그에 해당 이벤트가 기록되지 않거나 Crew Log 기능이 꺼져 있으면 승인 감지가 작동하지 않습니다. 이 앱은 그 기능을 강제로 켜지 않습니다.

MX Noti와 같은 컴퓨터에서 실행되는 도구를 대상으로 합니다. 원격 호스트의 Kiro Crew나 Codex의 클라우드 오케스트레이션 경로는 로컬 파일 및 명령 훅을 제공하지 않을 수 있습니다. 해당 경로까지 연결하려면 별도의 이벤트 전달 기능이 필요합니다.

## 앱에서 할 수 있는 일

- 완료는 **완료 패턴**, 승인은 **노크**, 입력 대기는 **벨**, 오류는 **강한 알림**으로 구분합니다.
- 이벤트마다 패턴 선택, 테스트, 켜기·끄기를 제공합니다.
- 앱별 켜기·끄기, 전체 일시 정지, 로그인 시 실행을 설정할 수 있습니다.
- 메뉴 막대에서도 완료·승인 진동을 시험할 수 있습니다.
- 최근 알림 40건을 화면에 표시합니다. 실제 진동 전송 결과도 표시합니다.
- 짧은 간격의 중복 승인 알림을 줄이고, 30초 넘게 지난 알림과 재생된 Kiro 세션 기록은 무시합니다.
- 앱이 닫혀 있으면 훅 알림이 앱을 백그라운드로 실행합니다. 로그로만 감지하는 Kiro·Crew는 앱이 실행 중이어야 합니다.
- ChatGPT·Claude 앱 배너 감지는 MX Noti가 실행 중이고 손쉬운 사용 권한이 허용된 상태에서 동작합니다.

## 설정 보존과 해제

연결 시 기존 JSON을 병합하고, 변경 직전 원본을 같은 폴더의 `*.mx-noti-backup-<UUID>`에 백업합니다. 반복 연결은 같은 훅을 중복해서 추가하지 않습니다. 형식이 잘못된 기존 파일은 덮어쓰지 않습니다.

**앱 연결 → 연결됨 메뉴 → 연결 해제**는 `# mx-noti-managed` 표시가 붙은 MX Noti 훅만 제거합니다. 다른 알림, 권한, 에이전트 설정은 보존합니다. Kiro IDE의 프로젝트 훅은 프로젝트 `.kiro/hooks/mx-noti.json`에서 해제하거나 파일을 삭제하면 됩니다. 그 파일에 다른 훅을 직접 추가했다면 해당 항목을 보존하세요.

CLI로도 같은 작업을 할 수 있습니다.

```sh
"/path/to/MX Noti.app/Contents/MacOS/MXNoti" --install-hooks claude codex kiro
"/path/to/MX Noti.app/Contents/MacOS/MXNoti" --remove-hooks claude codex kiro
"/path/to/MX Noti.app/Contents/MacOS/MXNoti" --kiro-project /path/to/project
```

앱을 이동했다면 연결을 갱신하세요. 제거하려면 먼저 훅을 해제하고 로그인 시 실행을 끈 다음 앱을 종료·삭제합니다.

## 다른 도구 연결

```sh
"/path/to/MX Noti.app/Contents/MacOS/MXNoti" --emit custom completed
"/path/to/MX Noti.app/Contents/MacOS/MXNoti" --emit custom approval
```

지원 이벤트: `completed`, `approval`, `question`, `error`, `tool`, `notification`.

하드웨어 진단은 `--probe`, 직접 진동 재생은 `--play approval` 또는 `--play 12`를 사용합니다. GUI 앱과 다른 터미널 실행 파일로 직접 장치를 열면 macOS가 별도의 입력 모니터링 권한을 요구할 수 있습니다. 일반 사용은 GUI 앱의 테스트 버튼을 권장합니다.

## 구현

```text
Claude / Codex / Kiro 훅 ── 짧은 CLI 프로세스 ── 비공개 로컬 수신함 ─┐
Kiro IDE / Crew ─────────── 새 로그 이벤트 읽기 ─────────────────┤
ChatGPT / Claude 앱 ─────── macOS 알림 배너 읽기 ────────────────┤
                                                                ↓
                           이벤트 분류 → 중복 제거 → 선택한 진동 패턴
                                                                ↓
                           IOKit → HID++ 0x19B0 → MX Master 4
```

HID++ Feature Root로 햅틱 기능 인덱스를 조회합니다. 장치가 광고한 패턴 목록, 활성화 상태, 모터의 준비 상태를 확인한 다음 재생 요청을 전송하고 **응답까지 확인**합니다. 다른 소프트웨어의 HID 응답은 software ID로 구분합니다. 햅틱 세기나 버튼 매핑을 쓰는 명령은 사용하지 않습니다.

수신함은 `~/Library/Application Support/MX Noti/inbox`이며, 외부 네트워크 요청은 하지 않습니다. 훅 JSON과 로그의 대화·명령 내용은 분류에 필요한 동안만 메모리에서 읽고, 별도로 저장하지 않습니다. 저장되는 이벤트는 출처·종류·시간·세션의 단방향 지문입니다. `preferences.json`에는 UI 설정, `status.json`에는 최근 전송 결과 10건의 메타데이터만 남습니다. 테스트는 `MX_NOTI_DATA_DIR`로 임시 폴더를 지정할 수 있습니다.

## 빌드와 검증

필요 환경: macOS 13 이상, Xcode Command Line Tools 및 Swift 5.9 이상. Apple Silicon 빌드를 검증했으며 Intel Mac은 아직 검증하지 않았습니다. 배포용 Apple Developer 서명·공증은 포함하지 않은 로컬 개발용 앱입니다.

```sh
./scripts/test.sh
./scripts/build.sh
open "dist/MX Noti.app"
```

자동 테스트는 장치 없이 HID++ 응답 구분, 기능 비트맵, 이벤트 분류, 중복·오래된 알림 제거, 수신함, 설정 병합·백업·해제, 로그 어댑터와 파일 교체 처리를 검증합니다. 실제 진동은 입력 모니터링 권한을 허용한 MX Master 4에서 별도로 확인해야 합니다.

버전 0.2.0의 자동 테스트 14개가 통과했습니다. 앱 알림의 출처 구분, 완료·승인·입력 대기 분류, 초기 배너 및 중복 배너 제외, 원문 미저장, 기존 설정 이전을 포함합니다. 동시 훅 입력 12건, GUI의 실제 마우스 재생 응답, ChatGPT macOS 배너 수신부터 마우스 재생 명령 응답까지 확인했습니다. Claude 앱의 실제 배너 수신은 아직 별도 확인이 필요합니다.

## 조사한 프로젝트와 공식 문서

- [mx4-haptic](https://github.com/paveleu/mx4-haptic): macOS에서 Bluetooth HID++로 직접 제어. 이 앱의 기본 접근입니다.
- [mx4notifications](https://github.com/lukasfri/mx4notifications): Linux의 D-Bus 데스크톱 알림을 HID++ 진동으로 변환.
- [claude-code-logitech-haptic-plugin](https://github.com/ChefJodlak/claude-code-logitech-haptic-plugin): Claude 훅 → HapticWeb의 로컬 API → Logi Options+ 플러그인.
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)
- [ChatGPT Notifications](https://learn.chatgpt.com/docs/notifications)
- [agent-desktop 알림 스캔 구현](https://github.com/vercel-labs/agent-desktop/blob/main/crates/macos/src/notifications/scan.rs): macOS 알림의 Accessibility 역할 및 속성 확인에 참고.
- [Kiro Hooks](https://kiro.dev/docs/hooks/), [Hook triggers](https://kiro.dev/docs/hooks/types/)
- [Kiro Crew 소스](https://github.com/kirodotdev/KiroCrew)

참고한 프로토콜 구현의 라이선스 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.
