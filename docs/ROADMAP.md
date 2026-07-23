# Roadmap + 分工 + 用户反馈追踪

> 协作: Sean (Windows, 写代码+文档, 不能 build) × Allen (Mac, build+真机测试, 主用户)。两边都用 Claude Code。

## 当前状态 (2026-07-22)

- ✅ 代码基定型: MxIris master v1.8.9 (`e84963a`) — 活跃维护 (891★, 上周还在发版), 全 SPM, 系统 Combine, 歌词源自己修
- ✅ AI 翻译初版已合入: cherry-pick `gubeifengan ddda309` → `4e02929` (仅 Info.plist 版本号冲突, 已解)
- ✅ Allen 已实测 base: **渠道多成立, 西语歌很多自带翻译**; 但反馈 ↓
- ⏳ 加固 H1-H8 未做 (见 HARDENING_TODO.md)

## 🔥 P0 用户反馈: "歌词对不准, 版本问题太多" (Allen, 2026-07-22) — 深挖结论 (2026-07-22)

现象: 搜到的歌词和实际播放的歌版本不一致 (live/remix/专辑版时长不同), 时间轴对不上。

> 本节基于实际读代码 (`LyricsKit-MxIris` upstream shallow clone + 主 repo `Global.swift`/`AppController.swift`/`Extension.swift`/`Preferences.storyboard`) 的结论, 全部带 file:line, 不是猜测。之前的草稿版本有几处**不准**, 已在下面订正并标注。

### 根因分类 (三选一, 按可能性排序)

**(c) 时间轴整体偏移的真正根因: 本地缓存文件命名不带版本信息, 一次选错终身污染** — 这是我认为最可能是 P0 主因的一条, 优先级最高:

- 缓存文件命名 = `"\(title) - \(artist).lrcx"`, **完全不含时长/版本信息**。写路径 `Lyrics.fileName` (`LyricsX/Utility/Extension.swift:131-137`), 读路径 `AppController.loadLyrics` 的 `candidateLyricsURL` 构造 (`LyricsX/Component/AppController.swift:200-208`) — 两处用的是同一套裸 "标题 - 艺人" 命名, 谁都没把 duration 编进文件名。
- 后果: 只要某首歌的**任意一个版本**曾经被搜到并写入缓存 (自动 `persist()` 或 `writeToiTunesAutomatically`), 之后无论 Allen 播放这首歌的哪个版本 (专辑版/Live/Remix, 时长完全不同), App 只看 title+artist 就直接命中这份缓存文件并 `return` (`AppController.swift:222-236`), **完全不会重新搜索, 也不会检查时长**。一次选错, 后面每次播放任何版本都对不上, 会被 Allen 感知成"版本问题太多"甚至"时间轴对不上"(实际是拿了另一版本的时间轴)。
- 更深一层: `metadata.request` (记录了当次搜索用的 `duration`) 是内存里的 Swift struct, **不会序列化进 `.lrcx` 文件**。所以重开 App 后从磁盘加载的缓存歌词, 其 `metadata.request` 是 `nil` → `Lyrics+Quality.swift:131-141` 的 `durationQuality` 直接退化成中性分 0.6, `isMatched()` (`Lyrics+Quality.swift:98-100`) 直接返回 `false`。也就是说 **`strictSearchEnabled` 这个"严格匹配"开关对已经落盘的缓存完全不生效**, 只在当次网络搜索时起作用。

**(b) 择优选错了 — quality() 公式里 duration 权重结构性太弱, 是次要但真实的根因**:

- `Lyrics.quality` 公式 (`LyricsKit-MxIris/Sources/LyricsService/Utilities/Lyrics+Quality.swift:8-10, 43-62`): `artist*0.45 + title*0.40 + duration*0.15`, 外加翻译 +0.05 / 内嵌时间轴 +0.05 的加分, 以及"疑似伴奏/纯音乐/karaoke"关键词 -0.3 的减分。
- duration 那一项还带了个下限 (`minimalDurationQuality = 0.5`, 行 22): 时长差 ≥10 秒时 `durationQuality` 就封顶在 0.5, 不会再往下掉。算下来, **无论时长差多离谱 (10 秒还是 5 分钟), duration 这一项能拉低的总分最多只有 `0.15 * 0.5 = 0.075`**。而 title 项权重 0.40 — 候选标题多带一个 "(Live)"/"(Remix)" 后缀, 光是这几个字符造成的编辑距离差就可能吃掉超过 0.075 的 titleQuality * 0.40。
- 结果就是: **duration 在这个公式里实质上只是个极弱的 tie-breaker, 压根扛不住"标题干净但版本错"vs"标题带版本标注但真的是那个版本"的对抗** — 一个 title/artist 字面更干净的错误版本, 很容易在总分上压过标题带 "(Live)" 但时长真正吻合的正确版本。
- 另外: `isUnwantedAlternateVersion` (`Lyrics+Quality.swift:64-84`) 只识别伴奏/纯人声消音/karaoke 类关键词 (`伴奏`/`instrumental`/`karaoke`/`off vocal`/`acapella` 等, 行 35-40), **不识别 "live"/"remix"/"acoustic"/"unplugged" 这类版本标注** — 这些版本不会被这个惩罚项拦下来, 完全靠 title/duration 硬打分, 印证了上一条。

**(a) 候选池里没有对的版本 — 可能存在, 但没法从代码本身验证, 只能靠 Allen 实测确认**:

- 全部候选源只有 5 个 (`LyricsKit-MxIris/Sources/LyricsService/Provider/Service.swift:12-17`): NetEase / QQMusic / Kugou / Musixmatch / LRCLIB — 前三个是中文市场歌词源, 覆盖非华语曲目的 live/remix 冷门版本的深度未知; 全球曲库主要靠 Musixmatch + LRCLIB 两家兜底。
- 我没有办法离线判断"某首具体的歌, 候选池里到底有没有对的版本"——这需要 Allen 拿手动搜索面板 (下面 §零代码缓解 第2条) 实际搜一下, 看结果列表里有没有 duration 吻合的候选。如果**手动搜也搜不出对的版本**, 才能坐实这条根因, 此时 (b)(c) 的代码改动都没用, 只能考虑扩源 (见「不建议现在做」)。

### 现成旋钮订正 (Allen 可先试, 不用改代码)

之前草稿写的 4 条里, 第 1 条位置说错了, 第 4 条"全局 offset"其实是空的 — 逐条订正:

1. **~~Preferences → Source 面板~~ 订正**: Source 面板 (`PreferenceSourceViewController.swift`) 只有「歌词源优先级」这一组功能: 一个总开关 `lyricsSourcePriorityEnabled` + 一个可拖拽排序的源列表 (`lyricsSourcePriorityOrder`), **没有** Strict Search 开关, 也没有 priority window 设置。
   - `lyricsHasHigherPriority` (`Global.swift:184-201`): 打开这个总开关后, 只要两个候选来自**不同 source**, 直接按 Allen 拖的顺序定胜负, **完全不看 quality/duration**, 只有同 source 才退回到 `new.quality > existing.quality` 比较。默认是**关闭**的 (`UserDefaults.plist:66-67` 显式注册 `false`)。**不建议 Allen 现在打开** — 除非已经确认"某个源的版本匹配总是比另一个源准", 否则打开后反而可能让一个来自"优先源"的错版本盖掉本来 quality 分更高的正确版本。
2. **严格匹配**在 **Preferences → General 面板**, 不在 Source 面板 (storyboard 里 "Strict Search" 复选框绑定 `values.StrictSearchEnabled`, 出现在 `Preferences.storyboard:515` 附近, 属于 General tab)。`strictSearchEnabled` 开关门控 `isMatched()` (`AppController.swift:295`) — **但只对当次网络搜索结果生效, 对已经落盘的缓存文件完全无效**(见上面根因 c)。另外这个开关在 `UserDefaults.plist` 里**没有注册默认值** (只有 storyboard 画布上显示是勾选状态, 那只是设计时外观, 不代表运行时默认值) — 实际出厂状态大概率是**关闭**的, 建议 Allen 打开 Preferences → General 亲眼确认一下当前是勾选还是没勾选, 没勾就勾上。
3. **手动搜索面板**(`SearchLyricsViewController.swift`): 歌词错了, 打开菜单 "Search Lyrics…" (可在 Preferences → Shortcut 配快捷键, key 是 `shortcutSearchLyrics`), 结果列表按 `lyricsHasHigherPriority` 排序, 选中一行点 Use (`useLyricsAction`, 行 89-110) —— 这一步会把选中的候选**重新写入同名缓存文件**, 覆盖掉之前缓存的错误版本, 并把这首歌从"以后不再自动搜索"名单里移除。**这是目前唯一能真正修好某首具体歌"缓存里卡了错版本"的零代码办法**。
   - ⚠️ 局限: 这个面板只有 Title / Artist / Source 三列 (`SearchLyricsViewController.swift:142-151`), **没有 duration 列**, Allen 只能靠听感/预览文本框里的歌词内容去猜哪个是对的版本, 选不准还是会选错。
   - ⚠️ 菜单栏另有一个 "Wrong Lyrics" 菜单项 (`Main.storyboard` tag 203 → `AppDelegate.wrongLyrics`, `AppDelegate.swift:240-253`) —— **这个不是"重新搜索"按钮**, 它做的是「删掉当前缓存文件 + 把这首歌的 track id 拉黑进 `noSearchingTrackIds`, 以后再也不自动搜这首歌的歌词」。点了之后这首歌会**永久没有歌词**, 除非再去手动搜索面板 Use 一次(会自动解除拉黑)。别指望点它能让 App 自动换一个对的版本。
4. **~~全局 offset 微调~~ 订正: 目前没有真正的"全局"偏移功能**。菜单/快捷键里的 Increase/Decrease Offset (Preferences → Shortcut 面板可配快捷键, `shortcutOffsetIncrease`/`Decrease`) 调的其实是 `AppController.lyricsOffset` → 落到 `currentLyrics.offset`, **这是这首歌自己的 per-track offset, 会存进这首歌的缓存文件里, 不影响其他歌**(`AppController.swift:32-38`)。UserDefaults 里确实有个 `GlobalLyricsOffset` key (`Global.swift:163`, 参与 `adjustedOffset = offset + defaults[.globalLyricsOffset]` 计算, `Extension.swift:210-212`), 但**全代码库搜索确认没有任何地方会写入这个 key**(只有这一处读) —— 它是个从上游继承下来的死键, 出厂注册值是 0 (`UserDefaults.plist:64-65`), **没有任何 UI 能改它**。如果 Allen 观察到的是"每首歌开头都固定慢/快一截"这种系统性偏移(比如蓝牙耳机/音箱的输出延迟), 目前没有一键全局补偿, 只能一首一首用 per-track offset 调。

### 最小代码改动方向 Top-2 (按建议优先级排序)

**#1 优先做 — 加载缓存前做 duration 校验守卫 (低风险, 渐进式)**
- 位置: `LyricsX/Component/AppController.swift` 的 `loadLyrics`, `candidateLyricsURL` 命中后到 `return`/`break` 之间那段 (约 210-237 行)。
- 做法: 读入 `.lrcx`/`.lrc` 后, 如果这份歌词自带的 `lyrics.length` (来自 LRC 的 `[length:]` 标签, `LyricsKit-MxIris/Sources/LyricsCore/Lyrics.swift:142-`) 存在, 且和 `track.duration` 的差值超过一个阈值 (比如复用 quality 公式里已有的 10 秒), 就不要直接采信缓存, 继续往下走正常搜索流程, 而不是 `return`。
- 预估行数: ~15-25 行 (一个 duration 比较 helper + 改读缓存循环的分支)。
- 风险与前提: 这个方案能不能生效, 取决于 5 个 provider (NetEase/QQ/Kugou/Musixmatch/LRCLIB) 搜出来的结果**是否真的回填了 `[length:]` 标签** — 这一点我还没有逐个 provider 验证, 需要先抓几个真实响应确认, 不然这条守卫可能形同虚设 (`length` 拿不到时直接维持现状, 不会让情况变坏, 属于安全的渐进加固, 但也可能没什么用)。

**#2 更根治但改动面更大 — 缓存文件名里加 duration 指纹, 从根上避免多版本撞同一个文件**
- 位置: `LyricsX/Utility/Extension.swift:131-137` (`Lyrics.fileName`, 写路径) + `LyricsX/Component/AppController.swift:200-237` (`candidateLyricsURL` 构造, 读路径)。
- 做法: 文件名从 `"Title - Artist.lrcx"` 改成带 duration 桶的形式 (比如取整到 5 秒: `"Title - Artist [215s].lrcx"`); 读取端不能再假设"只有 2 个精确候选 URL", 得改成扫描目录里 title-artist 前缀匹配的所有 `.lrcx`/`.lrc`, 挑 duration 桶离 `track.duration` 最近的一个。
- 预估行数: ~40-70 行 (两处改 + 一个目录扫描 helper + 处理"没有 duration 信息时怎么办"的 fallback), 且要把 duration 写进 `.lrcx` 的 `[length:]` 标签里做持久化 (否则重开 App 后 `metadata.request` 丢了, 桶算不出来) — 这部分工作量已经算进上面的行数估计里。
- 风险: 老缓存文件命名对不上新规则, 相当于让所有人第一次升级后缓存全部失效要重新搜一遍(一次性成本, 可接受, 但要在发布说明里提一句); `loadLyricsBesideTrack` 那条分支 (读 track 同目录的 lrcx, `AppController.swift:193-198`) 走的是另一套命名, 不受这个改动影响, 需要在实现时明确写清楚。
- 建议: **先做 #1, 观察 Allen 反馈是否明显好转, 再决定要不要上 #2**——如果 #1 (读缓存前的 duration 守卫) 已经能把大部分"卡住的错误缓存"问题解决掉, #2 这种改动面更大、要动缓存文件命名规则的活就没必要立刻做。

### 明确不建议现在做的方向

- **调 `Lyrics.quality` 里的权重数字** (比如把 duration weight 从 0.15 提到 0.3): 治标, 而且没有回归测试集去验证调权重会不会把"同名翻唱""不同艺人撞标题"这类别的场景带崩, 属于"没测过不敢动"。而且如果 (c) 缓存撞车才是真正主因, 单调权重救不了已经被污染、根本不会重新触发 quality 打分的缓存文件。如果之后真要调, 建议先让 Allen 收集几个"明确选错"的具体案例 (歌名+选中的错误候选+对应 quality 分), 有数据再调, 不要盲调。
- **AI 对轴** (用 LLM 把已有歌词文本强行拉伸/压缩对齐到当前播放时长): 大工程, 而且是治标不治本 — 真正的问题是选错了版本 (歌词内容本身可能都对不上, 不只是时间轴数字要缩放), 硬拉伸只会做出"看起来同步但内容驴唇不对马嘴"的结果。维持 ROADMAP 原判断, 先别做。
- **接入新歌词源** (比如 Genius/网易云官方 API/其他海外源) 来扩大候选池: 有可能是解决根因 (a) 的正解, 但涉及新依赖 + 新 provider 协议实现 + 可能的 auth/rate-limit, 工作量和当前 P0 的紧迫度不对称。而且我没有证据证明"候选池缺版本"是主因(更像是根因 c 缓存撞车更致命且更容易踩中)——建议等 Allen 用手动搜索面板实测确认"5 个源真的搜不出那个版本"之后, 再评估要不要扩源。

## 实施步骤

| 步 | 内容 | 谁 | 状态 |
|---|---|---|---|
| 0 | Allen 装 base 验证渠道/播放器/双语显示 | Allen | ✅ 已完成 (见 P0 反馈) |
| 1 | **build 本分支** (foundation/ai-translation): Xcode 打开 `LyricsX.xcodeproj`, scheme `LyricsX`, Debug build → 配 API key → 放西语歌 → 中译上屏 → 重放命中缓存 | Allen (本机 Xcode) | ⏳ |
| 2 | 加固 PR-A/B/C (HARDENING_TODO 切分) | Allen 的 Claude 写 + Allen build 测; Sean 侧 review | ⏳ |
| 3 | Prompt 迭代: 真实西语歌单反馈 → 改 PROMPT_DESIGN A/B 版 → (可选) prompt 暴露成偏好项 | Allen 主导反馈 | ⏳ |
| 4 | "对不准"专项: 先试现成旋钮 → 排障结论 → 决定是否动 quality 权重 | 两人对齐后 | ⏳ |
| 5 | (可选打磨) Keychain 迁移 / Test API 按钮 / 通知开关 / prompt 编辑 UI | 按需 | — |

## Build 说明 (Allen 侧)

```bash
git clone https://github.com/SeanZhang02/LyricsX-AI && cd LyricsX-AI
git checkout foundation/ai-translation
xcodebuild -project LyricsX.xcodeproj -scheme LyricsX -configuration Debug build
# 或直接 Xcode GUI 打开跑。首次会解析 SPM 依赖 (需要网络)。
# 本地跑不需要签名/公证; Debug build 直接运行即可。
```

### CI 出包 (Sean 侧, 已验证结论 2026-07-22)

- ❌ **上游 `release.yml` 在本 fork 上不可用** (无论 dry_run 与否): `Setup keychain` 步骤无 `if:` 门控, 内部 `require_env` 三个 Apple 签名 secret (`setup-keychain.sh:44`), fork 无 secrets → 必死在该步, 零 artifact。不要动 release.yml (留给将来真拿到证书时用)。
- ✅ **改用本 repo 新增的 `.github/workflows/build-unsigned.yml`**: 手动 `workflow_dispatch` 或 push 自动触发, `xcodebuild Debug` + `CODE_SIGNING_ALLOWED=NO` 全家桶出 unsigned `LyricsX.app`, artifact 保留 14 天。
- **Allen 安装 unsigned build (必须走终端, 每个新 build 都要重做)**:
  ```bash
  cd ~/Downloads && unzip LyricsX-unsigned-<sha>.zip
  xattr -cr LyricsX.app        # 清 quarantine, 必须
  open LyricsX.app
  # Apple Silicon 若报「已损坏」(不是"未知开发者"): 补 ad-hoc 自签再开
  codesign --force --deep --sign - LyricsX.app && open LyricsX.app
  ```
  注意: 「右键 → 打开」对彻底 unsigned 的 arm64 二进制**无效**, 别在这上面卡住。

## 待两人对齐的决策

1. **API 供应商**: DeepSeek (便宜/国内直连) vs OpenAI vs OpenRouter?key 谁的账号?
2. **重构范围**: Allen 想重构 — 建议第一步只做「把 `AITranslationService` 从 `AppController.swift` 抽成独立文件」+ H1-H4, 别一上来大动 (base 是活跃上游, 改动面越大, 以后 merge 上游越痛)
3. **上游跟进策略**: 定期 `git fetch upstream && git rebase/merge` — AI 功能文件独立度越高越好
4. **要不要给上游提 PR**: MxIris 是活跃 repo, AI 翻译加固好之后可以考虑贡献回去 (讨论后定)

## 重构红线 (Allen 的 Claude 注意)

见 CLAUDE.md「红线」段: `tr:` attachment 契约 / 不阻塞播放 / 串曲守卫 / persist 前门控。另外:
- 保持 UserDefaults key 名不变 (`AITranslationEnabled` 等 5 个) — 已有用户配置不失效
- 别把系统 Combine 换成第三方响应式库; 别引入大依赖
- Storyboard 绑定的 Preferences UI 动之前先确认 Xcode 能打开编辑 (storyboard 冲突是 merge 地狱, 尽量少动)
