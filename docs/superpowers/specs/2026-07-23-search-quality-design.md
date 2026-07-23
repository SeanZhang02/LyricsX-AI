# 搜索质量改进(全 app 侧,不 fork LyricsKit)

- **日期**: 2026-07-23
- **状态**: 设计中(Fable5 已决策 3 个开放问题 + 审查算法,基于 **LyricsKit 1.8.3**)
- **关联 memory**: [[lyricsx-ai-search-quality-todo]]

## ⚠️ 版本基准(关键)

app 编译的 LyricsKit **钉在 1.8.3(`6f071990`,见 `Package.resolved`)**,不是 main HEAD。本 spec 全部对照 1.8.3 源。**若将来升级 LyricsKit,以下三处必须重审**:`AuthenticationManagerStore`(新版消失)、quality 公式(新版换成加权平均、NaN bug 消失)、`Group` 引入 plugin 派生 request(会让 `lyricsReceived:293` 的 `request ==` 判定失效,须改按 `request.id`)。

## 顺带挖出的根因:1.8.3 quality NaN bug

1.8.3 的 `Lyrics.quality = 1 - pow((1.05-a)(1.05-t)(1.05-d), 1/3)`,其中 exact match 时 `artistQuality=1.3` / `titleQuality=1.5`(>1)。于是**标题或歌手恰好精确匹配**时三项乘积为负 → `pow(负,1/3)=NaN` → `quality=NaN` 被缓存。后果:`Global.swift:200` 的 `new.quality > existing.quality` 对 NaN 恒 false → **好候选换不掉现任 / NaN 候选永久粘住**——这很可能就是"错歌粘住"的根因之一。**本 PR 的 ④ 用 app 侧打分绕开它。**

## 目标

app 侧修四件事(不 fork):① 查询清洗(治长标题搜不到)② 匹配门(治西语→日语错配)③ Musixmatch 自动 token(治 token 反复失效)④ 专辑排序 + app 侧打分(治版本对不准 + 绕开 NaN bug)。

## 详细设计

### ① 查询标题清洗(`AppController` 构造 request 前,约 :244-245)

- **白名单去括号**(不是删所有括号,保护 "(I Can't Get No) Satisfaction" 这类):括号类 `()[]（）【】`,组内**含噪声词 token 即删**(如 "(MA. Live In Tokio)" 含 `Live` 也删;不含噪声的括号保留),循环到稳定处理连续/嵌套后新露出的组。噪声词:`feat/ft/featuring/with/prod/remaster/deluxe/anniversary/edition/version/ver/radio/single/album/bonus/live/acoustic/unplugged/demo/mono/stereo/explicit/clean/remix/cover/instrumental/karaoke/vocal/from/伴奏/现场/翻自/纯音乐/无损/翻唱`。⚠️ `with` 会删掉 "(With You)" 这类合法括号,已接受的权衡。artist 同样先去噪声括号(治 "Artist (feat. X)")。
- 同规则处理尾部 ` - Xxx` 破折号后缀(" - Remastered 2011")。
- 清洗后 trim + 折叠空格;**结果为空则回退原始 title**。
- **artist 只在 feat 标记(` feat`/` feat.`/` ft `/` ft.`/`featuring`)和 CJK 顿号 `、` 处截断**。⚠️ **绝不**按 ` & `/`,`/`/` 截(会切碎 Simon & Garfunkel、Earth, Wind & Fire、AC/DC、Tyler, The Creator)。
- 单次搜索用清洗后 query;版本歧义交给 ④ 专辑 + duration。清洗只改查询串、不缩候选池(provider 搜 "Song" 仍会返回 "Song (Live)")。

### ② 匹配门 C(+ D 兜底 + 时长豁免)

- 新增 `LyricsX/Utility/MatchSimilarity.swift`:折叠(`caseInsensitive+diacriticInsensitive+widthInsensitive`)后的 min-length 归一编辑距离(**抄 1.8.3 `Lyrics+Quality.swift:171-191`,逐行一致**)。
- 位置:`lyricsReceived` 中紧跟 strict 块(:297-299)之后、**`:300` priority 比较之前**——被拒候选不参与择优、不落 `:304-308`(associateWithTrack/persist/publish)、不触发自动写 iTunes(:276-279)。
- **C 主门**:`titleSim < 0.3 且 artistSim < 0.3` 才拒。
  - `sim = max(sim(tag, 原始 track 值), sim(tag, 清洗后 query 值))`(防清洗本身误杀);比较对象取 `req.searchTerm` 里的值(确定性),**不要**在此再读 `selectedPlayer.currentTrack`。
  - **空串即缺失**:tag 为 nil 或 `""` → 该侧不参与判定(fail-open);QQ 的 `singers.joined` 可为 ""、NetEase artist 可 nil,必须按非空判。
- **D 兜底**(双 tag 都缺时):查询无 CJK && 歌词正文 `dominantLanguage ∈ {ja,zh,ko}`(`hasPrefix("zh")`)则拒;正文空跳过。⚠️ **1.8.3 所有 provider 都设 title+artist,D 现网不可达**——保留当未来保险,别花功夫。
- **时长豁免**:`|候选.length - track.duration| < 3s` 一律放行(救罗马字 tag/CJK 歌词的正确歌)。注意 QQ 候选无 `length`、豁免对 QQ 不生效,只剩 C。
- 显式在 `AppDelegate.registerUserDefaults` 注册 `StrictSearchEnabled=false`(纯文档化,语义不变);新门与 strict 正交。

### ③ Musixmatch 自动 token(用 1.8.3 内置 `AuthenticationManagerStore`)

- 新 helper 拉 `GET https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0&format=json`(带 `cookie: x-mxm-token-guid=` 头,URLSession);校验 `message.header.status_code==200` 且 `user_token` 非空非 "UpgradeOnly" 占位;hint=captcha 时保留旧缓存不覆盖。**需真机验证。**
- `updateLyricsManager`(`:73-89`):
  - **删掉 `:82-86` 的 append**——1.8.3 `noAuthenticationRequiredServices` **已含 .musixmatch**,再 append 带 token 的一个 = Musixmatch 顺序跑**两遍**(现网 bug,一并修)。
  - 改为:`await AuthenticationManagerStore.shared.setMusixmatchToken(手填 ?? 自动)`——已建 provider 下次请求即生效,零 rebuild。
  - **先注入缓存 token(本地、快)再发网络刷新**,压首曲竞态(init 里 `currentTrackChanged():66` 早于 `Task{updateLyricsManager}:68`)。token 请求 10s 超时,失败不得 throw(别弄丢 Lab 路径 :31-33 的 provider 重建)。
- 优先级:`defaults[.musixmatchToken] 非空 ? 手填 : 自动`。自动 token 缓存到 **UserDefaults 新 key `MusixmatchAutoToken`**(与手填分开;内存缓存会让离线启动挂)。
- **on-401 当次重试不做**:1.8.3 `Group` 对 provider 错误 `catch{log}` 全吞,app 层看不到 401。失效检测只能**每次启动重拉一次**(成功覆盖缓存/失败回退)。

### ④ 专辑 bonus + app 侧打分(替换 quality 比较,绕开 NaN)

- `Global.swift:184` 改签名:`lyricsHasHigherPriority(_ new:, over existing:, trackAlbum: String? = nil)`;`AppController:300` 传 `track.album`;`SearchLyricsViewController:121` 靠默认值零改动。**不要**在 Global 里读 `selectedPlayer.currentTrack`(隐式全局 + 竞态 + 不可测)。
- `:200` 的 `new.quality > existing.quality` 换成 **`appScore(new) > appScore(existing)`**,其中 `appScore = 加权相似度(artist .45/title .40/duration .15 + translation/timetag bonus 各 .05,复用 ② 的折叠 similarity)+ albumBonus`。这一步同时**修掉 NaN 粘滞**(不再用库 quality 排序)。
- **albumBonus**:候选 album 与 trackAlbum 折叠相似度 ≥ **0.8** 或互为包含("X (Deluxe Edition)" vs "X" min-len 归一 =1.0)→ **+0.08**(> 双 bonus 差 0.05,< 一档相似度差);**任一方 album 未知 → 0,绝不为负**(QQ/Kugou 从不设 album)。
- 附:app 侧打分让我们**无需 fork 就能**顺手去掉 translationBonus(我们自己翻、不需偏向带翻译歌)——可选,默认先保留与库一致。

### 附带优化(可选,纯 app 侧)

1.8.3 `Group` **顺序**执行、服务序为 `qq→netease→kugou→musixmatch→lrclib`,对西语最有用的 Musixmatch/LRCLIB 排最后、常被 5s 优先窗口(`:252-273`)切掉。可在 `updateLyricsManager` 里**重排服务顺序**(一行)把这两家提前。

## 改动文件

- `LyricsX/Component/AppController.swift`:查询清洗、匹配门、auto-token(setMusixmatchToken + 删双 Musixmatch)、(可选)服务重排、priority 调用传 trackAlbum。
- `LyricsX/Utility/Global.swift`:app 侧打分 + albumBonus。
- 新增 `LyricsX/Utility/MatchSimilarity.swift`:折叠 similarity + appScore + album helper。
- `LyricsX/Component/AppDelegate.swift`:注册 `StrictSearchEnabled=false`、`MusixmatchAutoToken` 默认空。
- **不碰 LyricsKit、不碰 storyboard。**

## 不在范围 / 已知边界

- translationBonus 去除、duration 权重深调:app 侧打分里可选做,不 fork。
- **历史已落盘的错歌**:`:211-238` 本地 lrcx 加载**绕过 lyricsReceived**,门管不到;只能用菜单「Wrong Lyrics」(`AppDelegate:253+`)删。
- 简繁盲区:folding 不桥接 简/繁("愛"vs"爱");0.3 低阈值 + 双低才拒让常见案例擦边过;要加固可用已 import 的 OpenCC t2s 归一(可选)。
- LRCLIB URL 未 percent-encode(1.8.3 侧 bug,含空格标题在旧 macOS 抛错),清洗顺带减少特殊字符但根治需上游。

## 验证(CI 编译 + Allen 真机)

1. Sun Showers / Pequeño Vals(去 `(Live)[feat…]` 后)搜得到、有同步歌词。
2. 西语歌不再放出日语歌(错配被 C 拒 → 无歌词优于错歌)。
3. Musixmatch token:重启后自动可用;Lab 手填仍优先。
4. 同名多版本:优先专辑匹配的;NaN 粘滞不再(精确匹配的正确歌能换掉错的)。
5. 有 token 时 Musixmatch 不再跑两遍(看日志/请求数)。
