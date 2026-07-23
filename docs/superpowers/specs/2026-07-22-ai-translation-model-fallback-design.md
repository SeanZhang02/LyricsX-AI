# AI 翻译生产化:默认模型 + Fallback 链 + 实测 Prompt

- **日期**: 2026-07-22
- **分支**: `feat/local-language-detection`
- **状态**: 设计已批准(2026-07-22)
- **相关**: `docs/HARDENING_TODO.md`(H1-H8)、`docs/PROMPT_DESIGN.md`、`docs/AI_TRANSLATION_STATUS.md`、`translation-eval/`(模型实测)

## 目标

把已实测选定的翻译栈接进 app:默认走 OpenRouter 上的 `opus-4.8`,**硬失败**时自动 fallback 到 `sonnet-5 → deepseek-chat-v3.1`;换用实测过的生产 prompt;请求设 `temperature=0`。

语言检测(`NLLanguageRecognizer`,`isTranslatable`)已在本分支先前 commit(`58bdedc`),不在本 spec 重复。写回文件(`persist()` → LRCX `[tr:]`)是现成能力,不动。

## 已定决策(brainstorm 2026-07-22)

1. **Fallback 触发 = 只在硬失败时**:网络错误 / 超时 / HTTP 5xx / 429 / 空响应 → 试下一个模型。**覆盖率过低 / 整段拒译** → 维持现有"放弃本次 + 通知",**不** fallback。**401/403(key 无效)** → 立即中止,通知"API Key 无效",**不** fallback(同一 OpenRouter key 换模型也会失败,白烧请求)。
2. **PR 范围 = 只做功能**:H1-H8 加固另开 PR-A/B/C。本 spec 仅额外纳入 `temperature=0`(H5 的一小部分,已获用户批准);`max_tokens` / `finish_reason` 检查仍留 PR-B。
3. **Fallback 链写死**(不做可配),成功通知**带实际模型名**(让用户知道 fallback 是否生效)。
4. **temperature = 0**:确定性输出,利于永久缓存复现。

## 详细设计

### A. 配置默认值(`AppDelegate` 的 `registerUserDefaults`)

保持 5 个 key **名不变**(红线 #5,已有用户配置不失效):

| Key | 新默认值 | 说明 |
|---|---|---|
| `AITranslationBaseURL` | `https://openrouter.ai/api/v1` | 原为空;现"填 key 即用" |
| `AITranslationModel` | `anthropic/claude-opus-4.8` | 主模型 |
| `AITranslationAPIKey` | (空) | 用户填自己的 OpenRouter key;空 → 现有守卫不触发 |
| `AITranslationTargetLanguage` | `zh-Hans` | 不变 |
| `AITranslationEnabled` | 维持现状 | 用户在 偏好设置 → 通用 里开 |

### B. Prompt 替换(`buildPrompt`,`AppController.swift:520`)

整段替换为下列内容(`target = languageName(of: targetCode)`,`title`/`numbered` 同现状):

```text
你是一位专业的歌词译者,精通多语言文学翻译。你的任务是把用户提供的歌词翻译成<target>。

## 语言规则
- 只翻译非<target>歌词,统一译为<target>。若某行本身已是<target>,按"无需翻译"处理。

## 翻译原则(按优先级排序)
1. 意象优先于字面:保留隐喻、意象和画面感,而非逐字直译;直译会丢诗意处,用<target>里效果对等的表达重构。
2. 逐行对应:与原文严格行级对齐,不合并、不拆分、不增删行。
3. 结构一致:重复段落(副歌、叠句)用完全相同的译文;原文的排比、头语反复(anaphora)在译文中保留。
4. 语域匹配:口语译口语,典雅译典雅,俚语找<target>里同等鲜活的对应,不磨平成书面语。
5. 文化负载词:不可译概念(如 saudade、ojalá)就近选最贴近的<target>表达意译;宗教/神话/地名/人名典故用通行译名,无则保留原文。
6. 忠于给定文本:只翻译用户提供的文本。即使你记忆中这首歌有不同版本歌词,也严格以输入为准,不补全、不纠正、不替换。

## 输出格式(严格遵守)
逐行输出「编号|译文」:编号照抄输入、一一对应、不改顺序;译文单行、不含换行/方括号[]/竖线|;拟声词/ad-lib、纯制作信息行、本身已是<target>的行输出「编号|-」;除这些行外不输出任何解释/前言/空行/代码块。

## 输入
歌名:<title>(仅供理解语境,不作翻译依据)
歌词:
<numbered>
```

> `<target>`/`<title>`/`<numbered>` 为 Swift 字符串插值占位。此 prompt 已在 Ojalá / La Llorona / Bésame / Águas de Março 四首上实测:三模型格式合规率 100%,幻觉探针全过。

### C. Fallback 链(核心新逻辑,收在 `requestTranslation` 内)

```
private let fallbackModels = ["anthropic/claude-sonnet-5", "deepseek/deepseek-chat-v3.1"]

// 有效链 = 主模型 + 去重后的 fallback
let primary = defaults[.aiTranslationModel].isEmpty ? "anthropic/claude-opus-4.8"
                                                    : defaults[.aiTranslationModel]
let chain = [primary] + fallbackModels.filter { $0 != primary }
```

`performRequest` 改为返回三态结果(替换现在的 `String?`):

```
private enum RequestOutcome {
    case success(String)   // HTTP 200 且 content 非空
    case authFailure       // HTTP 401 / 403
    case hardFailure       // 网络错误 / 超时 / 其它非 200 / 空 content
}
```

`requestTranslation` 遍历链:

```
for model in chain {
    switch performRequest(for: model, of: contents, title: title, targetCode: targetCode) {
    case .success(let answer):
        return (answer, model)              // 返回译文 + 实际用的模型
    case .authFailure:
        notify("AI 翻译失败", "API Key 无效, 请检查 偏好设置 → 通用")
        return nil                          // 中止, 不续链
    case .hardFailure:
        continue                            // 试下一个模型
    }
}
notify("AI 翻译失败", "《\(title)》网络请求失败, 稍后可从菜单重试")
return nil                                  // 全链硬失败
```

- 请求体新增 `"temperature": 0`(连同现有 `model`/`messages`)。
- **去掉**原来的 `for attempt in 1...2 { … Thread.sleep(5) }` 单模型退避——链本身即冗余(≈3 次尝试),也避免长歌卡太久。
- `requestTranslation` 返回类型从 `String?` 改为 `(answer: String, model: String)?`。
- **失败通知归 `requestTranslation` 独占**:authFailure → "API Key 无效";全链 hardFailure → "网络请求失败"。`translate()` 收到 `nil` **直接 `return`,不再自己弹通知**(移除现有 `translate` guard-else 里的 `notify("AI 翻译失败", …网络请求失败…)`),避免 key 错时双重/错误通知。
- **Fallback 是 chunk 粒度**:`translate()` 每个 100 行 chunk 调一次 `requestTranslation`,各自独立走链。>100 行长歌罕见,极端下前后 chunk 可能落在不同模型,质量相近可接受。

### D. 成功通知带模型名(`translate`,`AppController.swift:451`)

`translate` 收到 `(answer, usedModel)`;成功通知改为:「《歌》已用 <短名> 翻译 N 行, 歌词已实时更新」。短名映射:`opus-4.8→opus4.8`、`sonnet-5→sonnet5`、`deepseek-chat-v3.1→deepseek`,其它取 model id 末段。

### E. 不变的契约(红线)

- 仍在 `AITranslationService` 私有 utility queue —— 不阻塞播放(红线 #2)。
- `persist()` 写回链、串曲守卫(`currentLyrics === lyrics`,`:499`)、覆盖率门控现状(`:485`,≥50%)—— **不动**(H1/H2 归 PR-A)。
- 译文只经 `.translation(languageCode:)` attachment 进入 `Lyrics`(红线 #1)—— 不动。
- 5 个 UserDefaults key 名不变(红线 #5)。不碰 storyboard。

## 不在本 spec 范围

H1 copy-then-publish、H2 覆盖率分层、H3 拒译内容校验、H4 sanitize、**H5 的 max_tokens / finish_reason**、H7 手动搜索面板 hook、H8 `isTranslating` 锁、P3(剥署名/制作信息行、名曲保留自带译文优先)。

## 改动文件

- `LyricsX/Component/AppController.swift` —— `buildPrompt`、`requestTranslation`、`performRequest`、`translate`、新增 `fallbackModels` 常量 + `RequestOutcome` 枚举。
- `LyricsX/Component/AppDelegate.swift` —— `registerUserDefaults` 默认值。

## 验证(Allen 真机,Xcode)

1. Debug build 通过(本机需完整 Xcode)。
2. **主路径**:填 OpenRouter key、开开关,放西语歌 → 中译上屏 → 重放命中缓存(无 API 调用)→ 换曲不串。通知显示 `opus4.8`。
3. **Fallback**:把主模型临时改成一个不存在的 model id(强制 hardFailure)→ 应自动 fallback 到 `sonnet-5` 成功,通知显示 `sonnet5`。
4. **Key 错**:填错 key → 通知"API Key 无效",不重复烧 3 次请求。
5. **中文歌**:放一首中文/繁体歌 → `isTranslatable` 跳过,不发 API(语言检测已合入)。
