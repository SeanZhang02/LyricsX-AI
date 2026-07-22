# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⭐ This Fork: LyricsX-AI (READ FIRST)

本 repo = **MxIris master (v1.8.9) + AI 歌词翻译功能** (cherry-pick 自 `gubeifengan/LyricsX` 的 `ddda309`) + 地基文档。目标用户场景: 听西语歌自动生成中文翻译, 双语显示。协作: Sean (Windows, 写代码/文档, **不能本机 build**) × Allen (Mac, build+真机测试)。中文沟通, 代码标识符英文。

**冷启动按需读 (别全读, 省 token)**:
- `docs/AI_TRANSLATION_STATUS.md` — 功能现状 + 全部代码锚点 (file:line 已验证, 30 秒懂全貌)
- `docs/HARDENING_TODO.md` — 已知缺陷 H1-H8 (多 agent 对抗审查产出) + PR 切分建议 ← **改翻译代码前必读**
- `docs/PROMPT_DESIGN.md` — prompt A/B 版全文 + 输出格式契约 + 解析规则
- `docs/ROADMAP.md` — 分工/步骤/用户反馈追踪 (含 P0: "歌词对不准") + 重构红线

**30 秒版**: AI 翻译核心全在 `LyricsX/Component/AppController.swift:352-608` (`AITranslationService` singleton)。歌词加载后自动整首送 OpenAI-compatible API (`编号|译文` 行协议), 译文写 `.translation(languageCode:)` attachment → 上游双语渲染层零改动直接显示 → `persist()` 落盘 LRCX `[tr:]` 标签 = 永久缓存。配置 5 个 UserDefaults key (`Global.swift:97-101`), UI 在 Preferences → General。

**红线 (重构/改动不可破坏的契约)**:
1. 译文只能以 `.translation(languageCode:)` attachment 进入 `Lyrics` — 渲染层与 LRCX 缓存的公共契约
2. 不阻塞播放: 网络调用严禁在 main thread 或 `DispatchQueue.lyricsDisplay` 上同步等待
3. 回填前必须守卫 track 同一性 (现: `currentLyrics === lyrics`), 防换曲后串曲
4. `persist()` 前必须过覆盖率门控 — LRCX 缓存是永久的, 残缺/错位结果不能落盘
5. 保持 5 个 `AITranslation*` UserDefaults key 名不变; 尽量少动 storyboard; 定期同步上游 (`upstream` = MxIris-LyricsX-Project/LyricsX, 活跃维护中)

## Project Overview

LyricsX is a macOS menu-bar application (`LSUIElement`) that automatically searches, downloads, and displays synchronized lyrics for the currently playing song. It supports multiple music players and lyrics sources, with desktop karaoke overlay and menu-bar lyrics display. This is a personally maintained fork of `ddddxxx/LyricsX`.

- **Platform**: macOS 11+ only
- **Language**: Swift 5 (project setting), Swift 6.2 toolchain (Package.swift)
- **Bundle ID**: `com.JH.LyricsX`

## Build Commands

```bash
# Build (Debug)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build 2>&1 | xcsift

# Build (Release)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Release build 2>&1 | xcsift

# Archive (triggers post-archive export + notarization script)
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Release archive
```

There are no automated tests configured in the Xcode scheme. The `LyricsXPackage` has an empty test target `LyricsXFoundationTests`.

## Linting & Formatting

```bash
# SwiftLint (configured in .swiftlint.yml, line_length: 150)
swiftlint

# SwiftFormat (configured in .swiftformat, 4-space indent, LF line breaks)
swiftformat .
```

## Architecture

### Build System

Hybrid Xcode project + Swift Package Manager. The Xcode project (`LyricsX.xcodeproj`) is the primary build entry point. It integrates `LyricsXPackage/` as a local Swift package, and all third-party dependencies are managed via Xcode's SPM integration (no CocoaPods/Carthage).

### Targets

| Target | Purpose |
|---|---|
| `LyricsX` | Main macOS app |
| `LyricsXHelper` | LoginItem helper embedded in `Contents/Library/LoginItems/`, watches for music player launch and auto-starts the main app |
| `SwiftLint` | Aggregate target for running SwiftLint |

### Core Dependencies (via SPM)

- **LyricsKit** (`MxIris-LyricsX-Project/LyricsKit`, branch: main) — lyrics search/parsing engine
- **MusicPlayer** (`MxIris-LyricsX-Project/MusicPlayer`, branch: master) — music player abstraction layer
- **LyricsXFoundation** (local package in `LyricsXPackage/`) — thin re-export wrapper: `@_exported import LyricsKit`

### App Internal Structure (`LyricsX/`)

The app uses a **Combine-driven reactive architecture** with shared singletons:

- **`Component/`** — Core singletons: `AppController` (central lyrics search/management hub), `AppDelegate`, `SelectedPlayer` (player adapter). `AppController` listens for track changes via Combine publishers, runs async lyrics searches (`AsyncSequence`), and distributes results to display layers.
- **`Controller/`** — Display controllers: `KaraokeLyricsController` (desktop karaoke overlay), `MenuBarLyricsController` (menu bar text), `TouchBarLyricsController`
- **`LyricsHUD/`** — Floating lyrics panel (`LyricsHUDViewController`)
- **`Preferences/`** — Preference pane ViewControllers (General, Display, Filter, Shortcut, Source, Lab)
- **`View/`** — Custom views: `KaraokeLabel`, `KaraokeLyricsView`, `ScrollLyricsView`
- **`Utility/`** — Global constants (`Global.swift`), extensions, Combine utilities (`CXExtensions/`)

### Data Flow

1. `MusicPlayers.Selected.shared` publishes current track/playback state
2. `AppController.shared` subscribes, triggers async lyrics search on track change
3. Found lyrics stored as `@Published var currentLyrics`
4. Display controllers (`KaraokeLyricsController`, `MenuBarLyricsController`, etc.) subscribe to lyrics + playback position to render synchronized output

### Localization

- Managed via `.xcstrings` (Xcode String Catalogs) and legacy `.strings` files
- BartyCrouch (`.bartycrouch.toml`) syncs storyboard strings
- Crowdin (`crowdin.yml`) for collaborative translation

### Local Development with Dependencies

`LyricsXPackage/Package.swift` supports switching to local checkouts of `LyricsKit` and `MusicPlayer` via `local:` path overrides (disabled by default with `isEnabled: false`). Toggle these when developing against local forks of these libraries.
