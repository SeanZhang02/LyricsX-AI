# Roadmap + 分工 + 用户反馈追踪

> 协作: Sean (Windows, 写代码+文档, 不能 build) × Allen (Mac, build+真机测试, 主用户)。两边都用 Claude Code。

## 当前状态 (2026-07-22)

- ✅ 代码基定型: MxIris master v1.8.9 (`e84963a`) — 活跃维护 (891★, 上周还在发版), 全 SPM, 系统 Combine, 歌词源自己修
- ✅ AI 翻译初版已合入: cherry-pick `gubeifengan ddda309` → `4e02929` (仅 Info.plist 版本号冲突, 已解)
- ✅ Allen 已实测 base: **渠道多成立, 西语歌很多自带翻译**; 但反馈 ↓
- ⏳ 加固 H1-H8 未做 (见 HARDENING_TODO.md)

## 🔥 P0 用户反馈: "歌词对不准, 版本问题太多" (Allen, 2026-07-22)

现象: 搜到的歌词和实际播放的歌版本不一致 (live/remix/专辑版时长不同), 时间轴对不上。

已知的现成旋钮 (Allen 可先试, 不用改代码):
1. **歌词源优先级**: Preferences → Source 面板, `lyricsHasHigherPriority` (`Global.swift:184-201`) 先按 source 排序再按 quality — 把质量好的源排前面
2. **严格匹配**: `strictSearchEnabled` 开关 (`AppController.swift:295` 门控 `isMatched()`) — 标题/艺人不匹配的候选直接丢
3. **手动搜索面板**: 歌词错了手动搜, 双击换正确版本 (注意 H7: 手动选的暂不触发 AI 翻译)
4. **全局 offset 微调**: 菜单里的延迟调整 (整体偏移, 治标)

代码级方向 (排障 workflow 结论后定):
- (a) quality 权重里 duration-delta 的占比 — LyricsKit 侧 `Lyrics.quality` 怎么算的, 能不能让"时长最接近"权重更高
- (b) 候选池里根本没有对的版本 → 无解, 只能手动 + offset
- (c) AI 对轴 (用 LLM 把正确文本对到实际时长) — 大工程, 后置, 先别做

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

CI 出包 (Sean 侧备用): 上游 `release.yml` 支持 `workflow_dispatch` + `dry_run`, 但 Setup keychain 步骤依赖 Apple 证书 secrets — fork 上无 secrets 是否能跑通 dry_run 未验证 (排障 workflow 在查)。能跑通的话 Sean 可远程出 unsigned zip 给 Allen (`xattr -cr` 后打开)。

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
