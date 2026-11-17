# 참고 프로젝트 및 라이선스

MX Noti의 Swift HID++ 구현은 다음 MIT 프로젝트에서 검증한 프로토콜 동작을 참고하여 작성했습니다.

- [paveleu/mx4-haptic](https://github.com/paveleu/mx4-haptic), 참고 커밋 `e0b87e83a543ef3af946979d30c94394f6ba4cdb`
  - Feature Root로 `0x19B0` 인덱스를 찾는 절차, 20바이트 long report, Bluetooth 장치 주소 처리, 패턴 비트맵, 상태 조회 및 재생 명령.
- [lukasfri/mx4notifications](https://github.com/lukasfri/mx4notifications): Linux 알림에서 HID++ 햅틱으로 연결하는 접근을 조사했습니다.
- [ChefJodlak/claude-code-logitech-haptic-plugin](https://github.com/ChefJodlak/claude-code-logitech-haptic-plugin): Claude Code의 완료·알림 훅을 햅틱에 연결하는 접근을 조사했습니다. 해당 프로젝트의 실행 파일이나 HapticWeb 플러그인은 포함하지 않습니다.
- [weldonfisher/HapticMaster](https://github.com/weldonfisher/HapticMaster) 및 [vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop): macOS 알림 센터의 Accessibility 접근 및 알림 역할·속성을 확인하는 데 참고했습니다. 이 프로젝트의 코드나 실행 파일은 포함하지 않습니다.

`mx4-haptic` license:

MIT License

Copyright (c) 2026 paveleu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
