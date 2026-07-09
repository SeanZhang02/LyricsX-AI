# LyricsX

> [!IMPORTANT]  
> This is the version of LyricsX that I personally maintain. The original author seems to have stopped maintaining it. I will fix some remaining bugs and add some new features in my spare time.

> [!NOTE]
> 本 fork 基于 [MxIris-LyricsX-Project/LyricsX](https://github.com/MxIris-LyricsX-Project/LyricsX)，由 Claude (Anthropic) 增加了 **AI 歌词翻译**：歌词缺少翻译时自动（或从菜单栏"AI 翻译此歌词"手动）调用任意 OpenAI 兼容大模型接口（DeepSeek / OpenAI 等，在 偏好设置 → 通用 填入接口地址、API Key 与模型即可）逐行翻译，以 lrcx 原生翻译附件写回歌词文件实现双语显示，完成后有系统通知；另修复了桌面歌词超长行被截断的问题（自动缩小字号完整显示）。
>
> This fork adds **AI lyrics translation** (by Claude from Anthropic): lyrics without a translation are translated line-by-line via any OpenAI-compatible LLM API (set base URL / API key / model in Preferences → General, or trigger manually from the status menu), written back as native lrcx translation attachments for bilingual display, with a system notification on completion — plus a fix for overlong lyric lines being clipped on the desktop overlay.


<img src="docs/img/icon.png" width="128px">

Ultimate lyrics app for macOS.

[LyricsX for iOS](https://github.com/ddddxxx/LyricsX-iOS) and [lyricsx-cli for Linux](https://github.com/ddddxxx/lyricsx-cli) is in early development.

## Installation

### Homebrew

```
brew tap brewforge/extras
brew install brewforge/extras/lyricsx-mxiris
```

### Manual

Download from [releases](https://github.com/MxIris-LyricsX-Project/LyricsX/releases).

To use **Musixmatch** as lyrics source, you need to follow the steps provided [here](https://gist.github.com/TrueMyst/0461aea999e347182486934fd83a4cf9) or [here](https://spicetify.app/docs/faq#sometimes-popup-lyrics-andor-lyrics-plus-seem-to-not-work) to obtain a **usertoken** and fill it in LyricsX's preferences.

### Requirements

- macOS 11+

## Features

- Work perfectly with your favorite music players. [List of supported players](https://github.com/ddddxxx/MusicPlayer#supported-players)
- Automatically search & download live lyrics from various lyrics sources. [List of supported sources](https://github.com/ddddxxx/LyricsKit#supported-sources)
- Display lyrics on desktop and menubar. you can customize font, color and position.
- Adjust lyrics offset on status menu.
- Navigate the song with lyrics - Double click a line to jump to specific position.
- Drag & Drop to import/export lyrics file.
- Auto launch & quit with music player.
- Automatic conversion between Traditional Chinese and Simplified Chinese.

### Lyrics Editor

LyricsX use custom lyrics file format "LRCX" which support word time tag, multi-language translation and more. Currently there's no official LRCX editor. You can use [Lrcx_Creator](https://github.com/Doublefire-Chen/Lrcx_Creator) for now (see [#544](https://github.com/ddddxxx/LyricsX/issues/544), thanks to [@Doublefire-Chen](https://github.com/Doublefire-Chen)). Or use normal LRC editor, as LRCX is compatible with LRC.

## Screenshot

<img src="docs/img/desktop_lyrics.gif" width="480px">

<img src="docs/img/preview_1.jpg" width="1280px">

<img src="docs/img/preview_2.jpg" width="1280px">

<img src="docs/img/preview_3.jpg" width="1280px">

## Credit

#### Components

- [LyricsKit](https://github.com/ddddxxx/LyricsKit)
- [MusicPlayer](https://github.com/ddddxxx/MusicPlayer)

#### Open Source Libraries

- [SwiftyOpenCC](https://github.com/ddddxxx/SwiftyOpenCC)
- [GenericID](https://github.com/ddddxxx/GenericID)
- [SwiftCF](https://github.com/ddddxxx/SwiftCF)
- [Regex](https://github.com/ddddxxx/Regex)
- [Semver](https://github.com/ddddxxx/Semver)
- [TouchBarHelper](https://github.com/ddddxxx/TouchBarHelper)
- [CombineX](https://github.com/cx-org/CombineX)
- [SnapKit](https://github.com/SnapKit/SnapKit)
- [MASShortcut](https://github.com/shpakovski/MASShortcut)
- [Sparkle](https://github.com/sparkle-project/Sparkle)
- [Then](https://github.com/devxoul/Then)

#### Special Thanks

- [Lyrics Project](https://github.com/MichaelRow/Lyrics)


## ⚠️ Disclaimer

All lyrics are property and copyright of their owners.
