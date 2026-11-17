#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
MX_NOTI_DEST="$HOME/Applications/MX Noti.app"
if pgrep -x MXNoti >/dev/null; then
    print -u2 '실행 중인 MX Noti를 메뉴 막대에서 종료한 다음 다시 설치해주세요.'
    exit 1
fi
mkdir -p "$HOME/Applications"
ditto "dist/MX Noti.app" "$MX_NOTI_DEST"
"$MX_NOTI_DEST/Contents/MacOS/MXNoti" --install-hooks claude codex kiro
open "$MX_NOTI_DEST"
print '설치 완료. 앱의 마우스 접근 허용 버튼으로 입력 모니터링 권한을 설정해주세요.'
