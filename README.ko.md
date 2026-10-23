<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Mac에 여유 공간을 더하세요.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

앱 캐시, 개발 프로젝트, 계속 커지는 폴더를 정리하는 네이티브 macOS 클리너입니다. 공간 사용량을 확인하고 정리 대상을 검토한 뒤 나만의 규칙을 재사용하세요.

## 다운로드 및 설치

Shou v0.12.0은 **macOS 14 이상**을 지원합니다. 유니버설 앱은 Apple Silicon 및 Intel Mac에서 실행됩니다. 디스크 이미지에서 **Shou.app**을 **Applications**로 옮기세요. UI는 영어와 중국어 간체를 제공합니다.

[**Shou v0.12.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.12.0/Shou-0.12.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.12.0/Shou-0.12.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.12.0/shou-0.12.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

이 버전은 ad-hoc 서명을 사용하며 Apple 공증을 받지 않았습니다. 첫 실행이 차단되면 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안**에서 실행을 허용하세요.

## Shou의 기능

| | |
| --- | --- |
| **앱 제거** | 앱과 정확히 연결된 파일을 검토한 후 제거합니다. 개인 데이터는 별도 동의가 필요하며 휴지통에서 복원할 수 있습니다. |
| **시작 항목** | 시작 정의를 확인하고 macOS 로그인 항목 설정을 엽니다. Shou는 항목을 직접 켜거나 끄지 않습니다. |
| **제외 규칙** | 전체 또는 프로젝트별로 폴더를 보호합니다. 개인 규칙 변경은 비활성 새 버전으로 저장됩니다. |
| **앱 캐시** | Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat 등의 캐시를 함께 확인합니다. |
| **개발 도구 및 프로젝트** | npm, Cargo, Xcode, Python, Go 캐시와 Rust target, Node.js 의존성, Swift 결과물을 찾습니다. |
| **공간 분석** | 트리맵과 폴더 목록으로 저장 공간을 살펴봅니다. |
| **개인 규칙** | 재생성 가능한 폴더의 규칙을 만들고 미리 본 뒤 재사용합니다. |
| **기록 및 복원** | 결과 확인, 항목 복원 또는 별도 확인 후 영구 삭제가 가능합니다. |
| **온라인 업데이트** | 설정 또는 Shou 메뉴에서 업데이트를 확인하고 설치 전 서명을 검증합니다. |

## 세 단계로 정리

1. **스캔.** 앱 정리를 선택하거나 작업 공간을 추가합니다. 스캔은 파일을 삭제하지 않습니다.
2. **검토.** 경로, 크기, 위험, 재생성 조건을 확인합니다.
3. **확인.** 선택한 항목을 휴지통으로 이동하고 필요하면 기록에서 복원합니다.

휴지통 이동은 공간을 즉시 확보하지 않습니다. 영구 삭제는 별도 확인이 필요하며 취소할 수 없습니다. 보호 항목, 제외 규칙, 실행 중인 앱이나 빌드가 정리를 차단할 수 있습니다.

## 파일은 사용자가 결정합니다

규칙은 로컬에서 동작하며 Shell 명령을 실행하지 않습니다. 계정, 모델 연결, 클라우드 스캔이 필요 없습니다. 규칙과 기록은 Mac에 저장됩니다.

## 터미널에서 사용

독립 CLI로 규칙, 스캔, 계획과 기록을 관리합니다. 정리와 복원에는 대화형 확인이 필요합니다.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## 문서 및 참여

빌드, 테스트, 규칙 예제 및 CLI는 문서를 확인하세요. 문제와 제안은 Issues로 보내주세요.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## 감사의 말

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## 라이선스

[Apache License 2.0](LICENSE).
