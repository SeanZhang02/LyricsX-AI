# LyricsX AI 自动翻译 — 需求对齐文档

> 给 Sean 和朋友的开工前对齐稿 · 2026-07-22 · 基于源码实读 + 前人方案调研 + 两轮对抗审查

---

## 1. TL;DR

- **可行, 且比预想的容易得多**: 这个功能已经有人在 2026-07-09 完整做过一遍 (`gubeifengan/LyricsX`, 单 commit ~460 行), 而且是做在**仍在活跃维护的 LyricsX 续作** (`MxIris-LyricsX-Project/LyricsX`, 891★, v1.8.9 2026-07-19 刚发) 上。
- **最大决策**: 手头这份 2022 年旧代码基 (原作者 ddddxxx 已实质弃维护, 306 个 issue 无人理) **强烈建议废弃**, 改为 fork MxIris + cherry-pick 前人的 AI 翻译 commit + 按本文档的审查结论加固。
- **工作量**: 主路线 = 移植 + 调 prompt + 打包, 约 1-2 天; 旧代码基自建 = 1-2 周且踩 Carthage/AppCenter/CombineX 三重坑。
- **成本**: 每首歌一次 API 调用约 $0.001-0.002 (DeepSeek/gpt-4o-mini 级), 译文落盘缓存后二次播放零成本, 月支出大概率 <$1。
- **最大技术风险**: (a) 线程安全 — 原地改已发布的 `Lyrics` 对象是真 data race, 必须 copy-then-publish (本文档 §3.1); (b) 模型输出错位/拒译污染缓存文件 — 必须内容级校验 + 覆盖率门控 persist (§3.4)。

---

## 2. 朋友需求逐条对齐表

| # | 需求原话 | 现状 (源码实证) | 方案 | 剩余风险 |
|---|---|---|---|---|
| 1 | "一首歌 load 进来的时候要立马发整首歌给 AI, 然后歌不中断, 等 response" | 换曲入口 `currentTrackChanged` → 多源搜索 10s 窗口内按 quality 渐进择优, `currentLyrics` 是 `@Published`。**注意**: 搜索期间歌词对象可能被更优候选替换多次, "立马发"会翻到中途被淘汰的版本 | 订阅 `$currentLyrics` + **debounce ~2s** 触发 (覆盖全部 7 处赋值路径: 本地缓存/搜索胜出/手动选用/导入等); 翻译全程异步, 歌照播, 译文到达后双语上屏 (通常第一遍副歌前后补上)。换曲 cancel 在途请求 + 对象同一性守卫 (`===`) 防串曲 | deepseek-chat 高峰期 80 行长歌可能 60-100s; 已翻译中切歌需 cancel 机制 (前人实现无 cancel, 需补) |
| 2 | "优化 prompt 看能不能提高翻译质量和保证输出格式我们能转换成歌词展示" | LyricsX 数据模型**原生支持逐行翻译** (`line.attachments[.translation(languageCode:)]`, LRCX `tr:<code>` tag), 双语渲染已存在 (桌面 Karaoke + HUD 歌词窗), **零渲染层改动** | 行号协议 `编号|译文` (非 JSON — 错位可检测可逐行恢复, 免疫模型废话); 双版本 prompt (质量优先 A / 格式稳定 B, B 兼作重试); **内容级校验** (CJK 占比 + 回显检测 + 拒译检测) + 覆盖率分层门控, 只有 ≥90% 才落盘。全文见 §3.3 | 模型"保号漂移" (行号完整但内容整体错一行) 靠锚点抽检兜底, 非 100% 可防; 用户可自由改 prompt 可能删掉格式约束 (解析层白名单已兜底) |
| 3 | "可以配置 apikey 进去, prompt 自己写一下" | 偏好体系现成 (`UserDefaults` + `DefaultsKeys`), Preferences 5 个 tab 可扩展 | OpenAI-compatible `/chat/completions` 客户端: Base URL / Model / API Key / 目标语言 / 自定义 system prompt 共 5 项配置。一个客户端通吃 DeepSeek/OpenAI/OpenRouter/本地 Ollama。前人实现已含此 UI (Preferences → General 5 项) | API key 前人实现存 UserDefaults 明文 (自用可接受); 讲究就迁 Keychain (~30 行, 无依赖) |
| 4 | "我实在是想找个办法看看西班牙语" (目标语言中文) | HUD 歌词窗双语显示**硬编码只认 zh 前缀语言** (`ScrollLyricsView` 中 `languageCode?.hasPrefix("zh")`); 中文系统 `preferBilingualLyrics` 默认开 | 目标=中文正好完全兼容: 直接写 `tr:zh-Hans` tag, 两个显示面全通。prompt 针对西语语境可加"通读全篇/俚语意译/人称一致"要求 | 若将来想翻成非中文, HUD 不显示 (需改一行); 菜单栏歌词模式**不显示翻译** (需预期管理) |
| 5 | "因为他查歌词的渠道比较多" (选 LyricsX 的原因) | 5 个源 (网易/QQ/酷狗/Gecimi/Syair)。**但原版 2022 年停更, 歌词源无人修**; MxIris 续作自己维护 LyricsKit fork (2026-06 仍在修), QQ/网易实测能用 (有质量 bug 但活着) | 走 MxIris 代码基 → "渠道多"卖点保住且有人持续修; 网易/QQ 自带中译的歌**自动跳过 AI** (省钱), 西语歌它们没有中译, AI 正好补位 | 歌词源长期靠 MxIris 单人维护; 旧代码基上此卖点会持续腐烂 |

---

## 3. 技术方案定稿 (已吸收两轮对抗审查修正)

> 以下契约独立于代码基选择: 走主路线 (MxIris + cherry-pick) 时作为**加固清单**用来改前人实现; 走旧代码基自建时作为**实现规格**。file:line 引用基于旧代码基, MxIris 上结构基本一致。

### 3.1 集成点 (审查修正后)

**触发**: 新增 `AITranslationController` singleton, 订阅 `AppController.shared.$currentLyrics` + debounce 2s (scheduler = `DispatchQueue.lyricsDisplay`)。一个 hook 覆盖全部 **7 处**赋值路径 (含 2 处置 nil, 靠守卫过滤)。不 hook 搜索流 `receiveCompletion` — 它漏掉本地 .lrcx 命中路径 (`AppController.swift:183` 赋值后 `:187` 直接 return)。
⚠️ 实现第一步先写 debounce 编译探针 — 项目用 CombineX 0.4 非系统 Combine, 若缺 `debounce` 用 `schedule(after:)` 手写 2s 静默 (有现成先例)。**新代码严禁 `import Combine`**, 只用 CXShim 或纯 callback。

**守卫链** (按序检查, 任一命中即零成本跳过):
1. `aiTranslationEnabled == false` 或 API key 空
2. `lyrics == nil` (覆盖置 nil 的 3 处赋值)
3. `metadata.language` 是 zh 前缀 → 中文歌不做中译中 【审查补充: 但源文本含大量假名时仍触发 — 防日语汉字歌被误判为中文后永不翻译】
4. `metadata.translationLanguages` 已含 zh 前缀 → 网易/QQ 自带中译、我们自己的缓存、刚合并完的自触发, 三者都被挡住 (**这条同时是防无限自触发循环的硬性守卫**)
5. 预过滤后行数 <3 → 纯音乐
6. Session 负缓存命中 (本 session 已失败 2 次的歌)
7. `aiTranslationForceRetranslate` 开关可绕过 3/4 【审查升级: 从 open question 升为 v1 必做 — 它同时兜住 ja→zh 误判、劣质源翻译、部分落盘缺行永不补齐三个洞】

**回填 — copy-then-publish, 严禁原地 mutate** 【P0 审查修正】:
原方案"在 lyricsDisplay 队列原地改 lines 即安全"**是错的**: HUD 订阅者跑在 main 线程读同一个 `Lyrics` class 实例 (Karaoke/MenuBar/TouchBar 才在 lyricsDisplay), 原地写 = 真 data race。正确做法, 在 lyricsDisplay 队列上:
1. 验 `AppController.shared.currentLyrics === captured` (发请求时捕获的引用), 不等则静默丢弃
2. **强制读一次 `_ = lyrics.quality`** 【P1 修正: 把不含翻译加成的 quality 先固化进缓存, 否则 AI 译文的 `hasTranslation +0.1` 会在搜索 10s 窗口内扭曲源择优, 击退本应胜出的更优候选】
3. 复制 `lines` (`LyricsLine` 是 struct 数组, 值拷贝), 把 **`tr:zh-Hans`** 逐行写进副本 (跳过已有翻译的行; 顺手清掉裸 `tr` attachment)
4. 用 public init `Lyrics(lines:idTags:metadata:)` 构造**新实例** — init 自动重算 `attachmentTags` + 补反向引用, metadata 值拷贝保留全部状态
5. `AppController.shared.currentLyrics = newInstance` 发布 → 4 个订阅者全刷新; 旧实例不再被写, HUD 读旧对象永远安全
6. 覆盖率 ≥90% 时 `persist()` 落盘

【P3 修正】**直接写 `tr:zh-Hans`, 放弃"裸 tr + `recognizeLanguage()` 自动检测"路径** — ad-lib 密集歌译文照抄原文多, 自动检测可能判成 `tr:es`, 落盘后守卫 4 永不命中 → 每次播放重新烧钱的死循环。

### 3.2 AI 客户端契约

- `POST {baseURL}/chat/completions`, `Authorization: Bearer <key>`, 裸 URLSession, 非流式, temperature 0.3 (重试 0), request 超时 90s。
- `max_tokens = min(8192, max(2048, 行数×80+500))` 【审查修正: 原 ×40 对长行说唱系统性低估】; `finish_reason == "length"` 重试时**翻倍** max_tokens 而非同参重发; 响应含非空 `reasoning_content` → 一次性提示用户"当前配置为 thinking 模型, 建议换 chat 模型"。
- 错误分类: 401/403 → 不重试, 禁用 + 提示"key 无效"; 429/5xx/超时 → 2s 退避重试 1 次; **refusal (拒译) → 与 401 同级给一次性用户提示, 不静默** 【审查补充】; 格式失败 → 版本 B + temperature 0 重试 1 次。两轮后进 session 负缓存 (重启清零)。
- 请求 payload: `行号|原文` (1..N 连续发送序号, 维护 → 原始下标映射), 带 title/artist 上下文, **不带时间戳** (省 ~30% token 且防模型复述); 发送侧预过滤空行/纯符号/`[Instrumental]` 类。重复副歌原样发不去重 (同一调用内译法天然一致, 是质量加分)。

### 3.3 Prompt v1 全文 (设置里可编辑, 出厂默认版本 B)

**版本 A — 质量优先** (temperature 0.3):

```
你是一位专业歌词译者，负责把外语歌词翻译成简体中文。歌词来自用户本地播放器中已有的歌词文件，仅为个人查看生成翻译。译文会直接显示在歌词软件里，随音乐逐行滚动。

先通读整首歌，理解主题、情绪和叙事视角，再逐行翻译，保证全篇人称和语气一致。

翻译要求：
1. 逐行对应：不合并、不拆分、不跳过任何一行。输入多少行，输出就多少行。
2. 用口语化、有歌词感的中文，像能唱出来的话，不要书面翻译腔。
3. 俚语、双关、文化梗按意思和情绪意译，宁可传神，不要直译生硬。
4. 语气词和 ad-lib（oh yeah、la la la、eh 等）原文照抄，不翻译。
5. 人名、地名用通行译名，没有通行译名就保留原文。
6. 每行译文必须是单行，不含换行，不使用方括号 [ ]。

输出格式（严格遵守）：
- 每行输出「行号|译文」，行号与输入完全一致。
- 除这些行外不输出任何内容：不要解释、不要空行、不要 markdown 代码块。
```

**版本 B — 格式稳定优先** (temperature 0, 兼作重试专用 prompt):

```
你是歌词翻译引擎。输入是用户本地歌词文件中带行号的外语歌词，仅为个人查看生成翻译。输出必须且只能是逐行对应的简体中文译文。

规则：
1. 每一行输入对应恰好一行输出，格式为「行号|译文」。行号照抄输入，一个不能少、一个不能多、不能改变顺序。
2. 译文是单行文本：不含换行、不含方括号 [ ]、不含竖线 |。
3. 无需翻译的行（oh yeah、la la la 等拟声词、专有名词行）把原文照抄到译文位置。
4. 输出的第一行就是第一个行号，最后一行就是最后一个行号。绝不输出解释、标题、空行、代码块标记或任何其他文字。

翻译风格：中文口语，意译优先，简短自然，贴近歌词语感。
```

(两版首句的"本地歌词文件/个人查看" framing 是审查要求的降低版权拒译概率措施。将来支持多目标语言: "简体中文"换 `{TARGET_LANG}` 占位符, v1 硬编码中文。)

### 3.4 输出格式契约 (审查加固版)

解析器:
1. 逐行匹配 `^\s*(\d+)\s*\|(.*)$`, 不匹配的行 (解释/```/`<think>` 泄漏) 直接忽略
2. 重复行号**末个生效** 【审查修正: 原"首个生效"方向反了 — 模型先 echo 输入再给译文时, 首个生效会把原文当译文收下】
3. **内容级校验** 【审查补充, 覆盖率看不见的维度】:
   - 每行 CJK 占比检测, 非 ad-lib 行 CJK <30% → 不计覆盖率不写 attachment (杀死"输入回显"假 100%)
   - 首/中/尾 3 行锚点做长度比 + 语言 spot check, 异常 → 判整包漂移, 拒收 (杀死"保号漂移"假 100% — 整首错一行永久落盘是最糟结局)
   - 拒绝语/占位语 pattern (抱歉|无法|不适宜|sorry|can't 等) → 该行剔除; 全文命中 → refusal 错误档
   - 译文 == 原文 (忽略大小写/空白) 且非 ad-lib 白名单 → 不写 attachment (防双语显示同一行原文两遍)
4. Sanitize (解析层强制, 不信任 prompt 承诺):
   - **Unicode 级换行整类** (含 U+2028/U+2029/U+0085, 不只 `\n\r`) → ` / ` 【审查修正: LRCX 逐行格式, 漏网换行 = 落盘文件结构破坏】
   - `[` `]` → 全角 `（）` (方括号是 LRCX tag 定界符)
   - 剥 U+0000–001F **及 C1 区 U+0080–009F** 控制符; trim; 空白折叠; 剥残留 markdown; >200 字符截断; sanitize 后为空 → 不写该行

覆盖率门控 (**只有 ≥90% 才 persist** — 落盘即永久缓存, 残缺结果不能占坑):

| 覆盖率 (内容校验后) | 行为 |
|---|---|
| ≥90% | 回填 + persist 落盘 (缺的行显示层自动只显原文, 零改动兼容) |
| <90% | 版本 B + temp 0 重试 1 次 → ≥60% 回填**不落盘** (下次播放还有机会); <60% 丢弃 + 负缓存 |

### 3.5 缓存

译文写 `tr:zh-Hans` attachment → `persist()` 序列化 LRCX 落盘 → 二次播放本地命中直接 return, 零 API 零延迟 — **这条链路一行不用新写**。
⚠️ 已知限制 【审查修正】: `loadLyricsBesideTrack` 开启时 (默认关), track 旁的歌词文件优先命中, 而 persist 永远写用户目录 → 该场景 AI 缓存永不被读取, 每次播放重新付费。v1 接受此限制并在 Preferences 注明; 或 merge 后同步写回 `metadata.localURL` 原路径。

### 3.6 配置 UI

Preferences 加配置项 (前人实现放 General tab, 5 项; 自建方案建议新 tab 放下 prompt 多行编辑器):
`aiTranslationEnabled` (默认 false) / `aiTranslationBaseURL` (默认 `https://api.deepseek.com/v1`) / `aiTranslationModel` (默认 `deepseek-chat`) / API key (NSSecureTextField; 存储见 §5 问题 4) / `aiTranslationCustomPrompt` (空=内置默认, 配"恢复默认"按钮) / `aiTranslationForceRetranslate` (v1 必做, 见 §3.1) / 目标语言 (v1 固定 `zh-Hans`)。
加分项: "Test API" 冒烟按钮; 手动菜单项"AI 翻译此歌词" (前人已实现)。

---

## 4. 风险与现实约束 (按严重度)

1. **【战略】代码基选择错误 = 全部白干**。手头旧代码基: 原作者 2022-05 起弃维护 (306 open issues), Carthage 残留**不是**误报 — Sparkle/AppCenter 已迁 SPM, 但 **SnapKit + MASShortcut 仍是 Carthage 框架引用** (pbxproj 实证), 首次编译无 `carthage bootstrap` 直接失败; AppCenter SDK 2025-03 已 retired; 2026 年 Xcode 上能否 build **无人验证过**。MxIris 代码基: CI 每月出签名+公证 release = "新 macOS + 新 Xcode 可 build" 被持续证明。
2. **【P0】线程安全**: 4 个显示订阅者不全在同一队列 (HUD 在 main), `Lyrics` 是无锁 class — 任何"原地改已发布对象"的实现都是 data race。copy-then-publish 是硬性要求 (§3.1)。前人实现是否有此问题, cherry-pick 时需审。
3. **【P1】错位/拒译污染永久缓存**: 覆盖率只数行号防不住"保号漂移"和"输入回显"; 部分拒译 (`（此处内容不适宜）`) 会以高覆盖率永久落盘。内容级校验 (§3.4) 是必做不是可选。explicit 西语歌 (reggaeton) 是高危场景。
4. **【P1】quality 择优扭曲**: 译文的 `hasTranslation +0.1` 加成若在搜索窗口内生效, 会击退更优候选 (含自带人工翻译的)。一行 `_ = lyrics.quality` 预固化解决。
5. **分发摩擦**: 无 Apple Developer 账号则 build 无签名, 朋友需 `xattr -cr` 放行或本机 Xcode 自签 (个人免费签名自用够)。
6. **Sean 无 Mac**: 每轮迭代反馈延迟 = GitHub Actions macOS runner (~10-15 min, public repo 免费) 或朋友响应时间; storyboard XML 手改易错无预览。
7. **歌词源长期风险**: QQ/网易 API 随时可能变, "渠道多"卖点依赖 MxIris 维护者持续在线。
8. **显示面覆盖**: 菜单栏歌词不显示翻译; HUD 只显示 zh 前缀翻译 — 目标=中文时都不是问题, 但要预期管理。
9. **前人实现的工程瑕疵** (cherry-pick 后按需修): semaphore 同步阻塞 + `Thread.sleep` 重试; 快速切歌无 cancel; key 明文 UserDefaults; 覆盖率阈值仅 50% (本方案 90%)。

---

## 5. 要和朋友确认的问题清单 (开工前必须对齐)

1. **【决定一切】代码基路线**: 同意废弃手头 2022 旧代码基, 改 fork MxIris + cherry-pick `gubeifengan ddda309`? (本文档强烈建议, 但需两人拍板)
2. **播放器**: 朋友用 Spotify / Apple Music / 本地播放器? (影响 MxIris 全适配 vs 备选 LyricFever 仅前两者)
3. **构建方式**: 朋友愿装 Xcode 本机 build (最快, 当天能用) 还是 Sean fork + GitHub Actions 出 artifact (Sean 可控但每轮 ~15min)? macOS 版本? (MxIris 要求 11+)
4. **API 供应商 + key 谁出**: DeepSeek (最便宜, 前人实现默认适配, 国内直连) / OpenAI / 其他? 人在国内则 OpenAI 直连不可达, 默认值选错第一次体验就是失败。key 明文 UserDefaults 可接受, 还是要 Keychain?
5. **目标语言**: v1 锁死简体中文确认? (HUD 只显示 zh 前缀翻译, 非中文目标需额外改渲染层)
6. **源自带中译的处理**: 默认跳过 AI (省钱) + `ForceRetranslate` 开关兜底 — 默认值确认?
7. **失败提示**: 401/拒译至少提示一次, 其余静默只留 log — 可接受? 还是要系统通知 (前人实现有完成/失败通知)?
8. **第 0 步验证**: 朋友先 `brew install brewforge/extras/lyricsx-mxiris` 装 v1.8.9 跑两天, 确认歌词源/他的播放器/桌面歌词基础体验 OK — 这步不写一行代码, 地基不牢一切免谈。

---

## 6. 实施 Roadmap (主路线, PR 粒度)

| 步 | 内容 | 谁 build / 谁测 | 预估 |
|---|---|---|---|
| 0 | 朋友 brew 装 MxIris v1.8.9, 验证基础体验 (歌词源/播放器适配/双语显示) | 朋友, 5 分钟 | Day 0 |
| 1 | Sean fork MxIris master → cherry-pick `ddda309` (ahead_by:1, 预计小冲突在 KaraokeLyricsView / Preferences.storyboard) → CI 出 unsigned build | Sean 移植, CI 编译, 朋友装 (`xattr -cr`) + 冒烟: 配 key → 放西语歌 → 看到中译 | Day 1 |
| 2 | **PR: 加固包** — 按 §3 审查结论修前人实现: copy-then-publish 线程修正 / quality 预固化 / 内容级校验 + 90% 门控 / sanitize Unicode 换行 / 重复行号末个生效 / 拒译检测 / max_tokens 公式 / 换曲 cancel / 中文歌跳过 + ForceRetranslate 开关 | Sean 写, CI 编译, 朋友日常听歌验收 | Day 1-2 |
| 3 | **PR: prompt 调优** — 朋友用真实西语歌单反馈质量, 迭代版本 A 措辞 (西语俚语/reggaeton 语境); 纯 prompt 改动, 设置界面直接改无需重新 build | 朋友主导反馈, Sean 调 | 持续 |
| 4 | (可选) **PR: 打磨** — Keychain 迁移 / Test API 按钮 / beside-track 写回 / 自建 Sparkle appcast 自动更新 | 按需 | 用得爽再说 |

**备选路线** (仅当朋友坚持用手头旧代码基): 先 `carthage bootstrap --platform macOS` + 验证 2026 Xcode 可编译 (第一优先级前置, 大概率要先迁 SnapKit/MASShortcut 到 SPM), 再按 §3 从零实现 (新增 `AITranslationService` + `AITranslationController` + Preferences tab, 4 文件小改, `AppController` 零改动)。预估 1-2 周, 不推荐。

**一句话收尾**: 你们的工作已从"实现功能"降级为"移植 + 加固 + 调 prompt" — 前人把路铺了 80%, 本文档的审查结论负责剩下 20% 不翻车。