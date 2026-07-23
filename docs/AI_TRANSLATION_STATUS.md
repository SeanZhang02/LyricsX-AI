# AI 翻译功能 — 现状与代码地图

> 本 repo = MxIris master (v1.8.9, `e84963a`) + cherry-pick `gubeifengan/LyricsX` 的 `ddda309` (本地重解冲突后为 `4e02929`) + 地基文档。
> 所有 file:line 基于 foundation/ai-translation 分支实际验证 (2026-07-22)。改代码后行号会漂,以符号名为准。

## 功能一句话

歌词加载后,若无目标语言翻译,自动把整首歌词(`编号|原文` 行协议)发给任意 OpenAI-compatible LLM API,译文逐行写入 `.translation(languageCode:)` attachment → 现有双语渲染层零改动直接显示 → `persist()` 落盘 LRCX(`[tr:<lang>]` 标签)即永久缓存,二次播放零 API 调用。

## 代码地图 (全部已验证)

核心全在一个文件:`LyricsX/Component/AppController.swift`(608 行,`AITranslationService` 在 `:352-608`)。

| 符号 | 位置 | 说明 |
|---|---|---|
| `AITranslationService` (class, singleton) | `AppController.swift:352` | 全部翻译逻辑 |
| `translateIfNeeded(_:)` | `:404` | 自动触发入口,守卫链: 开关/配置非空 → `!metadata.hasTranslation` → session 内未尝试过 (`aiTranslationAttempted` metadata flag) → `isTranslatable` |
| `translateNow(_:)` | `:381` | 手动触发(状态栏菜单「AI 翻译此歌词」),绕过开关与已尝试标记,每种跳过给系统通知 |
| `isTranslatable(_:)` | `:425` | 字符统计启发式: 非空行 ≥4 且计数字符 ≥20;目标为 zh 时——假名/谚文 ≥5 仍翻(防日语汉字歌误判),汉字占比 >0.4 跳过(中文歌不做中译中) |
| `translate(_:)` | `:451` | 主流程: 收集无翻译行 → 100 行分块请求 → 解析 → 覆盖率门控 (`:485`, 现为 ≥50%) → 回填+persist |
| `buildPrompt` | `:520` | 中文 prompt,`编号|译文` 协议,`编号|-` 占位跳过 ad-lib/制作信息行 |
| `requestTranslation` | `:539` | POST `{base}/chat/completions`,Bearer key,重试 1 次(5s 退避)。⚠️ 未设 temperature/max_tokens |
| `performRequest` | `:565` | 同步 semaphore 包 URLSession(跑在私有 utility queue,不碰 main),130s 硬超时 |
| `parseAnswer` | `:592` | 逐行 `编号|译文` 解析(兼容全角 `｜`),译文==原文跳过(防回显),`-` 跳过 |
| 回填+刷新 | `:491-503` | `DispatchQueue.lyricsDisplay.async` 内**原地 mutate** `lyrics.lines[i].attachments`(`:492-494`)+ persist(`:497`)**无条件执行**(作用于本次翻译闭包捕获的 lyrics 对象及其自身文件,换曲后落盘到旧歌文件本身无害);`currentLyrics === lyrics` 判断在 `:499`,**只守卫其后的 UI 刷新触发**(`:500-501` `currentLineIndex = nil + scheduleCurrentLineCheck()`),防止切歌后错误刷新显示 |

### 自动触发点(4 处 + 1 处遗漏)

| 路径 | Hook 位置 |
|---|---|
| 内嵌歌词 (`track.lyrics`, 播放器/文件自带) | `AppController.swift:189` (`:178-190` embedded 分支内) |
| 本地 `.lrcx`/`.lrc` 侧车/缓存文件 | `:230` (`:210-236` `candidateLyricsURL` 循环内) |
| 自动搜索完成(择优胜者) | `:278` |
| 手动导入 `importLyrics` | `:334` |
| ⚠️ **手动搜索面板选用歌词 — 无 hook (遗漏)** | `Search/SearchLyricsViewController.swift:89-110` `useLyricsAction` (双击/按钮, `Main.storyboard:811/:913` 绑定) → `:106` `AppController.shared.currentLyrics = lrc`,没挂翻译。见 HARDENING_TODO.md H7 |

### 配置 (UserDefaults, GenericID DefaultsKeys)

`Global.swift:97-101`:`AITranslationEnabled` / `AITranslationBaseURL` / `AITranslationAPIKey`(明文存储,UI 是 secureTextField 掩码)/ `AITranslationModel` / `AITranslationTargetLanguage`(默认中文系统 `zh-Hans`)。默认值注册在 `AppDelegate.swift`(`registerUserDefaults`)。UI 在 Preferences → General(storyboard 绑定,无代码)。

## 上游 base 提供的既有能力(翻译功能依赖,重构时是契约)

- **双语渲染**: `KaraokeLyricsController.swift:131-132`(桌面歌词)、`ScrollLyricsView.swift:68`(HUD 面板),都门控在 `preferBilingualLyrics`(中文系统默认开)
- **翻译数据模型**: `LyricsLine.Attachments` 的 `.translation(languageCode:)`,LRCX 序列化为 `[tr:<code>]` 标签,roundtrip 无损 → **落盘即缓存**
- **异步模型**: 歌词搜索/加载在 `DispatchQueue.lyricsDisplay` 串行队列 + Swift 结构化并发,UI 只在 main;翻译网络请求在 AITranslationService 私有 utility queue
- **歌词源择优**: 每个候选进 `lyricsReceived`(`:289-307`),`strictSearchEnabled` 严格匹配过滤(`:295`)+ 源优先级/quality 择优(`Global.swift:184-201` `lyricsHasHigherPriority`)
