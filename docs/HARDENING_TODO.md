# 加固清单 H1-H8(对抗审查产出,按严重度排)

> 来源: 两轮多 agent 对抗审查(2026-07-22)对 `ddda309` 实现的逐行核查。每条含证据位置 + 修法。修完一条勾一条,行号漂移以符号为准。

## H1 🔴 原地 mutate 共享 Lyrics 对象 = data race

- **证据**: `AppController.swift:491-503` 在 `lyricsDisplay` 队列 `lyrics.lines[i].attachments[tag] = text` 原地写。`Lyrics` 是 class(引用语义),HUD/渲染层可能同时在别的线程读同一实例的 `lines`。
- **修法(copy-then-publish)**: 复制 `lines`(`LyricsLine` 是 struct,值拷贝)→ 译文写进副本 → 用 `Lyrics(lines:idTags:metadata:)` 构造新实例 → 重新赋值 `AppController.shared.currentLyrics` 发布(所有订阅者自动刷新)→ 旧实例只读安全。回填前守卫 `currentLyrics === captured`。
- **注意**: 重赋值 `currentLyrics` 可能触发副作用(persist 重复/写 iTunes),修时核对 `currentLyrics` 的 `didSet` 与订阅者;并先读一次 `lyrics.quality` 固化缓存,防翻译 attachment 影响搜索期择优。

## H2 🔴 覆盖率门槛 50% 就 persist 落盘

- **证据**: `:485` `guard results.count * 2 >= indices.count`,过了就回填+`persist()`(`:497`)。LRCX 缓存是永久的,半首没翻的结果占坑后 `hasTranslation` 守卫会让它永不补齐。
- **修法**: ≥90% → 回填 + persist;60-90% → 回填仅本次显示,**不 persist**(下次播放重试);<60% → 丢弃 + 通知。再给一个 `ForceRetranslate` 手动开关(`translateNow` 已部分覆盖,但它对"已有部分翻译"的歌直接跳过——`hasTranslation` guard `:389`,也要处理)。

## H3 🟠 无内容级校验(覆盖率看不见的失败模式)

- **证据**: `parseAnswer` (`:592-608`) 只做行号匹配 + 精确回显剔除。挡不住: 意译式回显、模型拒译文本("抱歉,我不能…")当译文收下、整体漂移(行号完整但内容整体错一行)。
- **修法**: 目标 zh 时非 ad-lib 行 CJK 占比 <30% → 不计入覆盖率不写 attachment;拒绝语 pattern(抱歉|无法|不能翻译|sorry|can't)→ 剔除,全文命中 → 按失败处理;首/中/尾 3 行锚点抽检长度比,异常 → 整包拒收。

## H4 🟠 无 sanitize,译文可破坏 LRCX 结构

- **证据**: 译文原样写入 attachment。LRCX 是逐行 `[tag]` 格式:译文含 `[` `]` 或 Unicode 换行(U+2028/2029/0085)会破坏落盘文件。
- **修法**: 解析层强制(不信任 prompt 承诺): 全类 Unicode 换行 → " / ";`[` `]` → `（` `）`;剥 C0+C1 控制符;trim + 空白折叠;>200 字符截断;sanitize 后为空 → 弃该行。

## H5 🟡 temperature / max_tokens 未设,截断不可见

- **证据**: `:539-563` 请求体只有 model+messages。temperature 默认 1.0(质量抖动);max_tokens 默认值下长歌可能截断,`finish_reason` 未检查 → 静默半首。
- **修法**: temperature 0.3(重试时 0);`max_tokens = min(8192, 行数×80+500)`;检查 `finish_reason == "length"` → 翻倍重试;响应含非空 `reasoning_content` → 一次性提示"当前是 thinking 模型,建议换 chat 模型"。

## H6 🟡 错误处理一刀切

- **证据**: `performRequest`(`:565`)所有失败同等对待,统一重试 + 通知"网络请求失败"。
- **修法**: 401/403 → 不重试,通知"API Key 无效";429/5xx/超时 → 现行退避重试;拒译 → 独立通知;连续失败 2 次 → session 负缓存(重启清零),防每次换曲都烧一次失败请求。

## H7 🟡 手动搜索面板选歌词无翻译 hook(路径遗漏)

- **证据**: `Search/SearchLyricsViewController.swift:78` → `lyricsReceived`(`AppController.swift:289`)→ `:306` 赋值,4 个自动触发点不覆盖此路径。用户专门手动挑的歌词反而不翻译。
- **修法**: 在 `lyricsReceived` 内(或面板调用侧)补 `translateIfNeeded`。注意 `lyricsReceived` 也被自动搜索逐候选调用(`:257`,`:267`),直接在 `:306` 后挂会在搜索中途对中间候选开翻——需和 `:278` 的完成 hook 去重(建议: 面板调用侧挂,或 hook 内判断搜索是否进行中)。

## H8 ⚪ isTranslating 跨线程读写无保护

- **证据**: `:357` 私有 queue 写,状态栏菜单在 main 读(`AppDelegate` 菜单校验)。
- **修法**: 挪到 main 写(翻译开始/结束时 `DispatchQueue.main.async`)或用锁/atomic。顺手即可,不单独开 PR。

## 建议 PR 切分

1. **PR-A(安全)**: H1 + H2 + H4 — 不碰行为语义,纯防翻车
2. **PR-B(质量)**: H3 + H5 + H6 — 校验与请求参数
3. **PR-C(覆盖)**: H7 + H8 — 路径补齐
每个 PR 都要 Allen 真机冒烟: 放一首西语歌 → 看到中译 → 重放命中缓存 → 换曲不串。
