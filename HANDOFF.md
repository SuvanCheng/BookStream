# BookStream 项目无缝接力备忘录 (HANDOFF.md)

> **致未来的我 / 新会话中的 Agent**：  
> 当你看到这份文档时，请立刻通读。这份文档凝聚了本项目核心的架构设计、**用户极度在意的合作默契与代码偏好**，以及多个价值千金的踩坑血泪经验。请立即进入状态，像老搭档一样与用户配合！

---

## 📌 一、项目核心身份与架构定位

- **工程名称**：`BookStream` (当前版本 1.2.0)
- **核心使命**：macOS 原生单机顶级离线/高保真 AI 有声书与双语字幕短视频生成系统。
- **技术栈**：Swift 6、SwiftUI、Metal、CoreAudio、AVFoundation、Kokoro-82M (MLX 本地离线引擎)、Edge-TTS、DeepSeek 结构化翻译。
- **关键输出形态**：
  - 高清 MP4 视频（16:9 横屏影视画幅 / 9:16 手机短视频竖屏 / 1:1 方形）
  - 广播级音频（44.1kHz / 48kHz WAV、AAC M4B 有声书分章节封装）
  - 同步字幕（双语对齐卡拉OK点亮 SRT / ASS，0 帧音画漂移）
  - 精美双语对照纯文本（`.bilingual.txt`）与游戏级断点存档（`.translation.json`）

---

## 💡 二、用户核心偏好与最高协作纪律（必须刻进骨髓）

### 1. 提交纪律（最高原则，触碰即违规）
- **未经用户亲口明确指示，绝不执行 `git commit`、`git push`、`amend`、`reset`、回滚或删除提交！**
- 完成改动后，代码必须**完整停留在工作区（未提交状态）**，向用户清晰汇报改动要点与自检结果，等待用户明确说「提交」「commit」后方可执行。

### 2. 极致自检原则（汇报前必须全绿）
- 任何涉及源码的改动，汇报前必须执行：
  ```bash
  swift build
  swift run BookStream --selftest
  ```
- 确认全套 **21 项自检 100% 通过（SELFTEST PASSED）且 0 编译警告**后，方可向用户汇报。临时验证产物一律放在 `/tmp`，严禁污染工作区。

### 3. 视觉排版与画幅敏感度极高
- **9:16 手机竖屏**：宽度狭窄，字幕必须精炼短小（6~12 词，中文 10~18 字，单屏 1~2 行），绝不可长句挤压遮挡画面！
- **16:9 影视宽屏**：横向宽阔，字幕追求电影级连贯舒展（12~22 词），**严禁过度碎片化切碎**，140 字符以下句子保持完整。

### 4. 超高精度与严谨预估
- 语速支持 **0.01 步进超高精度调节**（范围 0.20 ~ 0.80，文件名如 `rate0.44`）。
- 耗时预估公式已严格校准：
  - 英文声学语速：`15.35 chars/s`（基准 rate 0.40，严格反比例缩放）；
  - 视频渲染实时率：开启 Siri 光带声波为 `2.4×` 实时率，关闭光带为 `10.0×` 实时率。

### 5. 生产级稳定性（10+ 小时名著不宕机）
- 必须支持《奥德赛》全本（9,672 句 / 59.7 万字符 / 36,000 秒 / 10 小时）通宵一键渲染，全流程内存恒定、零截断、零漂移。

---

## 🛡️ 三、重大攻坚战役与踩坑经验（防重蹈覆辙）

### 1. 90 分钟看门狗硬编码误杀 BUG（已修复）
- **现象**：超长有声书渲染到 90 分钟时，报「音频线程任务超时（90 分钟）」。
- **根因**：`AudioEngine.swift` 中历史代码写死了 `semaphore.wait(timeout: .now() + 5400)`。
- **准则**：必须使用无硬编码时限的信号量，让 10+ 小时任务自由跑完。

### 2. 6.5GB 内存暴毙与 Siri 光带失效 BUG（已修复）
- **现象**：生成短文本正常，生成《奥德赛》10 小时长音频时光带消失不工作。
- **根因**：10 小时音频达 16.25 亿采样点，`extractAudioSpectrum` 尝试分配单个 6.5GB `AVAudioPCMBuffer` 导致 CoreAudio 分配失败返回空数组。
- **方案**：采用 **32,768 采样点（128KB 恒定极低内存）流式分块读取 + 重叠 FFT + 历史平滑**，且渲染时间必须使用 `time.truncatingRemainder(dividingBy: 3600.0)` 避免三角函数相位在 10 小时后精度溢出。

### 3. DeepSeek 翻译流水线内嵌 AI 语义意群断句（零成本、零额外 Token）
- **机制**：在原有的翻译请求中，让 DeepSeek 同步在英文与中文意群处插入「 ｜ 」，自适应横竖屏画幅。
- **守门员（Guardrail）**：`Translator.alignAndSplitSentence` 中采用 `wordsOnly` 字母/数字严格比对。一旦模型篡改单词或中英文段数不匹配，系统自动安全熔断返回原句，做到 100% 绝对保真！

### 4. macOS 文件面板 `runModal()` 导致主线程 1 秒卡顿假象（已修复）
- **现象**：点击「选择文件」或「开始生成」时，系统抓取到 1.08s 卡顿日志（`Event: hang` / Spindump），偶尔轻微转彩虹球。
- **根因**：`NSOpenPanel` / `NSSavePanel` 在现代 macOS 中是外部独立沙盒服务（Remote View Service / Powerbox）。同步调用 `panel.runModal()` 会挂起主线程 RunLoop 等待 Mach 消息 IPC 握手（`-[HIRunLoopSemaphore wait]`），耗时超过 1 秒即触发系统 `hangtracerd` 报警。
- **方案**：全工程彻底杜绝 `panel.runModal()`，统一重构为异步非阻塞 `panel.begin { response in ... }` 回调，并通过 `activeSavePanel` / `activeOpenPanel` 防抖防止重复弹出，主线程零卡顿。

### 5. LLM 翻译 45 秒超时与自适应二分批次降级（已修复）
- **现象**：测试连接单句耗时 32s 成功，但导出多句长文本时，在 45s 连续超时报错退出。
- **根因**：`request.timeoutInterval = 45` 硬编码过短；原批次（16~20 句）在 API 高峰期推理耗时超过 45s；重试依然发送超大批次陷入恶性死循环。
- **方案**：
  - 配置专属 `translationSession`，超时放宽至 120 秒（资源超时 300 秒）；
  - 目标批次容量调整为更稳妥敏捷的 8 句（结合 5~10 句自然标点边界探测与前序 3 句上下文滑动窗口）；
  - 实现**自适应二分批次降级（Adaptive Binary Splitting）**：遇超时自动拆半递归处理，输出 Token 量与耗时减半；单句极端情况备用通道安全兜底，整书导出绝不中断；测试连接使用 `isTest: true` 严格检验目标服务商。
  - **白盒级可观测调试日志**：全面打印模型名称、端点、批次编号、耗时、Prompt/Completion/Reasoning Tokens、生成速率（tok/s）与缓存命中率；校准耗时预估公式由虚假 0.22s 还原为真实的批次生成耗时。

### 6. AI 意群切分覆盖 Checkpoint 导致重载时原句丢失（已修复）
- **现象**：翻译完成后再次重载 `1.txt`，22 句中仅恢复 14 句，其余 8 句重新触发大模型翻译。
- **根因**：AI 意群切分将 8 处长句切分为了子片段（由 22 句扩充为 31 句）。旧代码在对齐后调用 `saveCheckpoint(sentences: finalSentences)`，将存档覆盖写成了子片段，导致原长句的 Key 被冲掉。重载 `1.txt` 时原始 22 句查不到长句 Key，仅未切分的 14 句能命中。
- **方案**：
  - **增量合并存档与字段分离**：`saveCheckpoint` 采用增量合并（merge），绝不删除已有 Key；新增 `splits` 字典独立保存意群切分映射（`text -> {en, zh}`），同时持久化原句与子句；
  - **向前兼容贪婪子片段恢复（`matchSubpieces`）**：若原句在存档中未直接命中，自动通过贪婪前缀匹配在字典中寻找连续子片段拼接恢复；
  - **跳过翻译极速通道**：当全书 100% 恢复时（`toTranslateIndices.isEmpty`），直接从存档复用意群切分并秒级组装 `finalSentences`，0 Token 消耗，直接进入 TTS 生成流程。

### 7. LLM 网络请求取消阻塞（已修复）
- **现象**：用户点击「取消」后，日志显示「正在取消...」，但翻译仍在后台持续运行长达 2 分钟直到该批请求完全结束。
- **根因**：`sendRequest` 底层调用 `URLSessionDataTask` 时仅在发起前检查了一次 `cancellation`，缺乏 Swift 结构化并发 `withTaskCancellationHandler` 监听，也没有轮询外部 `cancelFlag`，导致请求在等待返回期间对取消完全“脱缰无感”。
- **方案**：
  - 使用 `withTaskCancellationHandler`，一旦外部调用 `pipelineTask?.cancel()`，立即触发 `onCancel` 掐断 underlying socket 连接；
  - 启动 50ms 高频极速看门狗监听 `cancelFlag`，双保险确保在 50 毫秒内立即中止网络请求并抛出 `BookStreamError.cancelled`；
  - 批次重试 `Task.sleep` 捕获取消异常立即退出，全流程毫秒级响应清理。

### 8. 全流程任务暂停 / 继续机制（`PauseController`，支持切网与合盖待机）
- **需求场景**：用户生成过程中需要切换 Wi-Fi、合上 MacBook 盖子待会儿打开、或临时释放网络/算力。
- **架构设计与踩坑解决**：
  - 新增 [`PauseController.swift`](file:///Users/aram/project/BookStream/Sources/BookStream/PauseController.swift)：线程安全设计，提供 `waitIfPaused`（async 协程挂起，0% CPU）与 `waitIfPausedSync`（后台工作线程休眠让步，0% CPU）；
  - **切网保护**：暂停状态下完全切断新的网络请求（翻译批次之间挂起），杜绝因 Wi-Fi 切换导致网络中途断开报错；恢复后自动通过新网络无缝发出下一批；
  - **KokoroTTS 子进程级挂起（`SIGSTOP` / `SIGCONT`）**：
    - *原踩坑*：Kokoro 单次批量启动 Python worker 处理多达 64 句，外层暂停无法穿透正在执行的 Python 子进程，导致 TTS 抓轨在点击暂停后依然持续推进。
    - *修复*：在 `KokoroTTS.renderBatchInternal` 轮询循环中实时检测 `isPaused`，暂停瞬间向 Python 进程发送 `kill(pid, SIGSTOP)`，由 macOS Darwin 内核物理冻结其进程（0% CPU，0 内存读写）；用户点击继续时发送 `kill(pid, SIGCONT)` 毫秒级复苏无缝接力；取消时即刻 `SIGKILL` 强杀退出。
  - **分阶段暂停时长隔离（解决实时率虚高 8583.4× 与用时 0m 0s）**：
    - *原踩坑*：前期 TTS 阶段暂停了 6 秒，后期视频阶段仅用时 4 秒。如果简单使用全局 `totalPausedTime`，视频耗时会被减为 `4 - 6 = -2s`（被截断为 0.01s），导致视频实时率虚高暴增至 8583×。
    - *修复*：`PauseController` 维护区间列表 `pauseIntervals`，新增 `pausedTime(since: phaseStartTime)`，将暂停统计严格限制在当前执行阶段（Phase）的时间窗口内，彻底杜绝跨阶段时长污染，预估剩余时间与实时率倍数 100% 还原真实物理表现。
  - **合盖休眠安全**：挂起期间使用休眠让出线程（100ms 周期），不占 CPU，合上屏幕待机后唤醒继续执行零崩溃；
  - **多维控制入口**：顶部操作栏紧邻取消按钮新增高亮「暂停 / 继续」按钮、菜单栏新增快捷键 `⌘P`、进度条新增动态橙色「已暂停」徽标。

### 9. DeepSeek 思考模式默认开启 + 串行批处理 + 静默机翻降级（三座大山，已全面攻克）
- **现象**：采用 `deepseek-v4-flash` 做拆句/翻译时极慢（单批 20~30s+、日志出现「含思考 N tokens」），且译文质量明显变差（夹杂大量机翻腔）。
- **根因（对照 DeepSeek 官方文档）**：
  1. **思考模式默认开启**：官方文档明确 `deepseek-v4-flash/pro` 思考模式默认开启且 effort=high，每批先思维链再作答；且**思考模式下 temperature/top_p 参数无效**（静默忽略）。旧代码从未发送 `thinking` 参数，等于每批都在做高消耗深度思考；
  2. **完全串行**：`translateBook` 一次只发一批（8 句），《奥德赛》9,672 句 ≈ 1,209 个串行请求；而官方 v4-flash **账号级并发上限 2500**，并发余量巨大却完全未利用；
  3. **静默降级机翻**：模型返回 JSON 一旦缺 id / 截断 / 格式偏差，旧代码直接把该句替换成 MyMemory/Google 免费机翻（`translateSingleFree`），**日志完全不可见**，术语/人名/文风瞬间崩坏——这是「翻译质量变差」的最直接元凶；
  4. **拆句与翻译耦合**：同一请求既要信达雅翻译又要输出带「｜」的 en/zh 对齐，任务过难 → flash 轻量模型两头失守，格式出错率升高 → 触发机翻兜底的概率更高。
- **修复方案**：
  - **思考模式开关**：`TranslationSettings.disableThinking`（默认 true），请求体注入 `{"thinking": {"type": "disabled"}}`；第三方/本地端点不支持时收到 400 自动移除参数重试（`currentAttempt -= 1` 不消耗重试预算）；
  - **有界并发**：`TranslationSettings.concurrentRequests`（1~8，默认 4），`runConcurrentBatches` 用 `withThrowingTaskGroup` 动态补充任务；前情上下文改为「已完成批次译文 + 英文原文兜底」（不再强依赖前一批译文 → 打破串行依赖）；
  - **翻译/拆句两阶段解耦**：阶段一纯翻译（Prompt 无拆句指令，简单→快且稳）；阶段二仅对超长句（竖屏 >80 字 / 宽屏 >150 字）发拆句请求，且**附带阶段一译文、只插「｜」不重译**，双重守门员（英文单词全等 + 去管道符后译文与阶段一全等）不通过即不拆——译文质量 100% 由阶段一保障；
  - **消除静默降级**：缺句先走 LLM 单句补译重试（`allowMissingRetry` 防递归死循环），仍失败才显式兜底并**逐句告警 + 全程兜底计数**（`fallbackCount`），导出末尾汇总提示人工抽查；
  - `TranslationSettings` 自定义 `init(from:)` 用 `decodeIfPresent` 向前兼容旧存档（新字段缺省回默认，绝不重置用户设置）。
- **遗留注意**：并发下阶段一按批落盘（`BookTranslationState.merge` 父侧串行 + 锁保护），极端崩溃最多丢失并发窗口内（≤8 句×并发数）的译文，重跑从存档恢复。

### 10. `InputKind.book` 首关联值是「标题字符串」而非路径（书旁存档/双语导出从未生效的根因）
- **现象**：`books/` 下从来没有出现过 `<书名>.translation.json` 与 `<书名>.bilingual.txt`，只有 `~/.bookstream/translations/` 的全局备份在正常读写；日志毫无报错（`try?` 全部吞掉）。
- **根因**：`Models.swift` 中 `enum InputKind { case book(title: String, sentences: [Sentence]) }` 的**第一关联值是标题字符串**。而 `runPipeline` 的 `case (.book(let url, let rawSentences), ...)` 把标题误当 URL，执行 `URL(fileURLWithPath: url)`（如 `"1"` → `file:///1`），书旁存档/双语导出全部写向垃圾绝对路径 → 静默失败 → 只有回退通道 `~/.bookstream/translations/` 在起作用。此 bug 自双语字幕功能引入起就存在。
- **修复**：`AppModel` 已有 `@Published var inputURL: URL?`（`loadInput` 时记录真实路径），`runPipeline` 与存档管理（`currentBookArchiveURL` / `deleteTranslationArchive`）全部改用 `inputURL`，禁止用 `case .book` 的字符串值拼 URL；双语导出由 `try?` 改为 `exportBilingualWithFallback`（书旁优先，失败回退 `~/.bookstream/bilingual/`，并在日志中明示结果）。
- **准则**：凡 `InputKind.book` 需要真实路径，一律走 `inputURL`；命名上不要再把第一个关联值叫 `url`。

### 11. AI 拆句的英中「片段错位」与同序约束（拆句质量守门）
- **现象**：`Tell me, O muse, of that ingenious hero ｜ who travelled far and wide ｜ after he had sacked the famous town of Troy.` 的中文被切为 `缪斯女神啊…英雄，｜他在洗劫了著名的特洛伊城后，｜漂泊四方。`——英文片段与中文片段**错位**（模型按中文语序插「｜」，未与英文片段一一对应）。旧指令「在对应中文译文的同一位置同步插入」过于含糊。
- **修复一（Prompt）**：拆句指令强化「一一对应、顺序一致」（第 i 个英文片段的中文翻译必须恰是第 i 个中文片段），并明确「中英文语序往往不同，若无法逐段对应则输出 en="" zh="" 拒绝切分」。
- **修复二（程序化守门员，实测校准）**：全本《奥德赛》300 处拆句统计——对齐样本边界差集中于 **0~11pp**，语序颠倒型错位（如 EN「flew up ｜ sat as a swallow」/ ZH「化作燕子 ｜ 飞上椽木」）落在 **18~24pp**。`alignAndSplitSentence` 新增**相对边界位置校验**（英中第 k 个意群边界位置差 > **17pp** 即熔断不拆）+ **畸形分隔符校验**（首/尾/连续「｜」如「…，｜」尾缀空片段一律拒绝）。代价是拆句覆盖率下降约 7%（不拆 = 保持整句，正确但更长），换取 100% 杜绝错位字幕。
- **实测质量基线（全本 9672 句）**：10078 条字幕 0 残留「｜」、0 空译文、0 机翻回退、0 时间轴重叠；拆句对齐率 ~97%（约 6 处错位已在新守门员下不再产生）。

### 12. 翻译阶段进度「已用/剩余」基准错误与预估重标定
- **现象**：翻译阶段日志出现「双语翻译 6/22 句 · 已用 0m 54s · 剩余约 2m 23s」——实际才 2s。根因：`updateProgress` 以 `phaseStartTime` 为基准，而**翻译阶段从未重置 `phaseStartTime`**（沿用应用启动时间）。
- **修复**：`runPipeline` 翻译前 `phaseStartTime = Date(); lastLoggedPercent = -1`。
- **预估重标定**：思考模式关闭后实测单批仅 ~2.5s（旧估值 25s/批严重虚高，且 `loadInput` 处漏传 `translationConcurrency` 导致未按并发折算 → 奥德赛误估 8h24m）。现按 `disableThinking ? 4s/批 : 25s/批` 并除以并发数（含拆句阶段 ~25% 附加开销）。
- **并发上限**：`concurrentRequests` 钳制 1...32（官方 v4-flash 账号级并发上限 2500；旧上限 8 过于保守）。

---

## 📂 四、当前工作区状态与接力点

- **最近一次 Git 提交**：`80a2058` (`fix(visualizer): resolve Siri visualizer failure on long audiobooks via streaming chunked FFT`)
- **当前工作区修改（未提交）**：
  1. `Sources/BookStream/PauseController.swift`（新建）：全局暂停/继续控制器，支持分阶段区间精准耗时统计、协程/线程零消耗挂起、即时取消响应。
  2. `Sources/BookStream/KokoroTTS.swift`：
     - 在批处理子进程轮询中接入 `isPaused`，支持内核级 `SIGSTOP` 瞬间冻结与 `SIGCONT` 毫秒级复苏，彻底杜绝暂停失效。
  3. `Sources/BookStream/AudioEngine.swift`：
     - `renderBook` 与 `renderSubtitleAudio` 接入 `pauseCheck` 与 `isPaused`，支持 Kokoro 进程挂起与 EdgeTTS 句间安全暂停。
  4. `Sources/BookStream/Translator.swift`：
     - 画幅自适应（9:16 vs 16:9）AI 语义意群双向对齐断句、防篡改守门员；
     - 专属 `translationSession`（120s 超时、线程安全一次性续延保护）；
     - 批次调优为 8 句 + 自动二分降级重试机制 + 401/402/403 即时快速报错；
     - 全流程白盒级 Token 统计与吞吐速率（tok/s）实时日志；
     - `withTaskCancellationHandler` + 50ms 看门狗实现网络请求毫秒级即时取消；
     - 增量合并存档 + `splits` 意群切分留存 + `matchSubpieces` 贪婪子片段向前兼容恢复，重载秒级 100% 恢复直接跳入 TTS；
     - 接入 `pauseCheck: pauseCheckAsync`，批次间平滑暂停挂起；
     - **（本轮新增·攻克三座大山）** 思考模式开关 `disableThinking`（注入 `thinking:disabled`，400 自动降级重试）；有界并发 `concurrentRequests`（`withThrowingTaskGroup` 动态池 + `BookTranslationState` 锁保护共享态）；**翻译/拆句两阶段解耦**（阶段一纯翻译并发快发；阶段二仅超长句拆句、复用阶段一译文只插「｜」不重译、双重守门员）；缺句 LLM 单句补译重试 + 显式兜底计数 `fallbackCount`，彻底消除静默机翻降级；`TranslationSettings` 旧存档向前兼容解码。
  5. `Sources/BookStream/VideoSynthesizer.swift`：
     - `VideoRenderer.render` 接入 `pauseCheck: pauseCheckSync`，帧批次渲染间安全挂起并重置看门狗，避免超时误报。
  6. `Sources/BookStream/ContentView.swift`：
     - 接入 `isPaused`、`togglePause()`、`pauseController`；
     - 顶部操作栏新增「暂停 / 继续」交互按钮（支持快捷键 ⌘P）；
     - 进度条与日志提示增加「已暂停」状态标识与 `pausedTime(since: phaseStartTime)` 精确扣除逻辑；
     - 全面重构 5 处文件面板为非阻塞异步调用 `panel.begin`；
     - **（本轮新增）** 双语设置面板新增「关闭大模型思考模式」开关 + 「并发翻译批数」Stepper（1~8）；翻译耗时预估按并发数线性折算；
     - **（本轮新增·存档管理）** 双语面板新增「翻译存档管理区」：状态摘要（已存档 N/M 句）、「查看文件」（Finder 定位）、「删除存档」（删书旁 + ~/.bookstream/translations 双份并清空内存译文，带确认弹窗）、「另存副本…」（非阻塞 NSSavePanel 拷贝）；新增「忽略存档 · 强制重新翻译全部」开关（导入时跳过 restore、导出前删双份存档并清空译文，`loadInput`/`runPipeline` 双入口生效）。
  7. `Sources/BookStream/BookStreamApp.swift`：
     - 增加 `bookStreamTogglePause` 通知与 macOS 菜单快捷键 `⌘P`。
  8. `Sources/BookStream/SelfTest.swift`：
     - 新增用例 14b（子片段贪婪拼接向前兼容恢复验证）；
     - 新增用例 15（AI 意群断句全量熔断保护）；
     - 新增用例 16（PauseController 并发挂起、零消耗、分阶段时长隔离与即时取消）；
     - 新增用例 17（翻译设置旧存档向前兼容解码 + 并发批数 1~8 钳制）。
  9. `AGENTS.md` & `HANDOFF.md`：文档自驱动维护机制已同步更新。
- **历史完整上下文索引**：`conversation://d3161494-fdc8-463b-afbb-118c3d6796a8`
