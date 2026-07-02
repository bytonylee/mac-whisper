<p align="center">
  <img src="./public/assets/readme/hero.png" alt="Mac Whisper 히어로" width="720">
</p>

<h1 align="center">Mac Whisper</h1>

<p align="center">
  <em>Fn을 누른 채 말하면, 지금 쓰는 앱에 받아쓴 문장이 붙여넣어집니다.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.0.1-111111?style=flat-square" alt="Version 0.0.1">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5.9-111111?style=flat-square" alt="Swift 5.9">
</p>

<p align="center">
  <sub><a href="./README.md">English</a> &middot; <a href="./README.ko.md">한국어</a></sub>
</p>

<p align="center">
  <a href="https://github.com/bytonylee/mac-whisper/releases/latest/download/MacWhisper.dmg"><img src="./public/assets/readme/download-macos.png" alt="Mac OS용 MacWhisper.dmg 다운로드" width="270"></a>
</p>

---

<p align="center">
  <img src="./public/assets/readme/mac-whisper-demo.gif" alt="Mac Whisper 푸시 투 톡 받아쓰기 데모" width="100%">
</p>

Mac Whisper은 푸시 투 톡 받아쓰기를 위한 macOS 메뉴 막대 앱입니다. Fn을
누른 채 말하고 손을 떼면, 포커스가 있는 입력란에 전사문이 붙여넣어집니다.

붙여넣기 전에 보수적인 LLM 정리 단계를 거칠 수도 있습니다. 이 기능은
선택 사항이며, LLM 요청이 실패하면 원본 전사문을 그대로 사용합니다.

> 창을 바꾸거나 녹음기를 열지 않고, 지금 쓰는 앱에서 바로 글을 넣기 위해
> 만들었습니다.

**앱은 HID로 Fn 키를 읽고, Speech framework로 음성을 인식하고, 말하는 동안
플로팅 HUD를 보여줍니다. 붙여넣기는 클립보드와 Cmd+V 시뮬레이션으로 처리합니다.
받아쓰는 동안에는 내장 마이크를 우선 사용해 Bluetooth 헤드폰이 고품질 재생
모드를 유지하도록 합니다.**

## 왜 만들었나

macOS 받아쓰기는 쓸 만하지만, 모든 앱에서 짧게 눌러 말하고 바로 붙여넣는
흐름에는 맞지 않습니다. Mac Whisper의 흐름은 단순합니다.

- Fn을 누르면 시작
- Fn에서 손을 떼면 종료
- 말하는 동안 실시간 전사 확인
- 포커스된 입력란에 붙여넣기
- 필요하면 LLM으로 인식 오류 정리

메시지, 메모, 프롬프트, 검색창, 이슈 댓글처럼 커서가 이미 놓인 곳에 짧게
글을 넣는 용도에 맞췄습니다.

## 상태

| 영역 | 동작 | 메모 |
|---|---|---|
| 트리거 | Fn 또는 Globe 길게 누르기 | 전역 단축키가 아니라 키보드 HID에서 읽음 |
| 음성 | 실시간 스트리밍 인식 | 영어, 한국어, 중국어, 일본어 지원 |
| HUD | 플로팅 전사 패널 | macOS 26에서 Liquid Glass 사용 |
| 오디오 | 내장 마이크 우선 | Bluetooth 헤드셋이 통화 모드로 바뀌는 상황을 줄임 |
| 붙여넣기 | 클립보드와 Cmd+V | 입력 뒤 이전 클립보드를 복원 |
| LLM | 선택적 정리 | OpenAI 호환, Anthropic 호환 엔드포인트 지원 |

메뉴에서 할 수 있는 일:

- `Language`로 인식 언어를 바꿉니다.
- `LLM Refinement`로 정리 기능을 켜고 설정을 엽니다.
- `Auto-stop on Silence`로 조용한 구간 뒤 녹음을 끝냅니다.
- `Permissions...`에서 마이크, 음성 인식, 입력 모니터링, 접근성 상태를 봅니다.

## 설치

[Releases](https://github.com/bytonylee/mac-whisper/releases/latest)에서 최신
`MacWhisper.dmg`를 내려받아 열고, **Mac Whisper**를 Applications로 옮기세요.

로컬에서 빌드할 수도 있습니다.

```bash
git clone https://github.com/bytonylee/mac-whisper.git
cd mac-whisper
make app
open "build/Mac Whisper.app"
```

요구 사항:

- macOS 26+
- Xcode command-line tools
- 마이크 권한
- 음성 인식 권한
- 입력 모니터링 권한
- 접근성 권한

로컬 리빌드 후에도 권한을 유지하려면 자체 서명 인증서를 한 번 만드세요.

```bash
make cert
make app
```

이 인증서가 없으면 임시 서명 때문에 macOS가 리빌드할 때마다 입력 모니터링과
접근성 권한을 다시 요구할 수 있습니다.

## 작동 방식

Fn을 누르면 앱이 새 음성 세션을 만듭니다.

```text
Fn key down -> start audio engine -> stream recognition -> update HUD
Fn key up   -> stop recognition -> optionally refine -> paste text
```

LLM 정리에 쓰는 API 키는 환경 변수에서 읽습니다.

```bash
cp .env.example .env
# .env 편집:
#   MACWHISPER_LLM_API_KEY=sk-...
make run
```

Finder에서 실행하는 설치 앱은 아래 명령을 사용할 수 있습니다.

```bash
launchctl setenv MACWHISPER_LLM_API_KEY sk-...
```

같은 내용을 `~/.config/macwhisper/.env`에 넣어도 됩니다.

## 빌드

컴파일:

```bash
make build
```

빌드 후 실행:

```bash
make run
```

DMG 생성:

```bash
make dmg
```

## 에이전트용

한 번 빌드하고 실행하려면:

```bash
cd /path/to/mac-whisper
make app
open "build/Mac Whisper.app"
```

빠른 컴파일 확인:

```bash
swift build
```

## 보안

- 앱은 음성을 전사하려고 마이크와 음성 인식 권한을 요청합니다.
- 입력 모니터링은 Fn 또는 Globe 키를 읽는 데만 씁니다.
- 접근성 권한은 포커스된 앱에 텍스트를 붙여넣는 데 씁니다.
- 진단 로그에는 전사문을 쓰지 않습니다.
- LLM API 키는 UserDefaults가 아니라 환경 변수에서 읽습니다.
- LLM 정리가 실패하면 원본 전사문을 붙여넣습니다.

## 테스트

```bash
swift build
```

macOS 권한, HID 입력, 붙여넣기, 오디오 라우팅은 시스템 상태의 영향을 받으므로
수동 확인도 필요합니다.

## 릴리스

현재 태그: [`0.0.1`](https://github.com/bytonylee/mac-whisper/releases/tag/0.0.1)

`0.0.1` 릴리스에는 푸시 투 톡 받아쓰기, 플로팅 전사 HUD, 언어 선택, 선택적
LLM 정리, 로컬 빌드 스크립트, DMG 패키징이 포함되어 있습니다.

## 라이선스

MIT
