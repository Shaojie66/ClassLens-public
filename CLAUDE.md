# ClassLens

上课用的 macOS 应用：录音 → 实时英文转录 → 中文翻译字幕 → 识别老师提问并由 AI 作答；同时可打开课件（PDF / PPT）划词提问。课程领域为计算机专业。

**典型使用流程（设计以此为准）**：课前先导入老师的 PPT/PDF 课件 → 老师开讲后开始录音 → 学生主要看字幕和课件，通常不手动跟着翻页。因此：术语表应在开讲前就绪；“当前讲到哪一页”应由程序根据转录自动判断，不能依赖学生翻页；PPT 是主要的导入格式。

## 技术栈（已定，改动需先更新 docs/decisions.md）

- Swift 6（严格并发）+ SwiftUI，最低 macOS 26，仅 Apple silicon
- 项目由 XcodeGen 从 `project.yml` 生成；**不手改 `.xcodeproj`**，它不进 git，唯一例外是其中的 `Package.resolved`（锁定全部依赖版本，升级依赖后一起提交）
- 音频：AVAudioEngine；识别：`TranscriptionEngine` 协议；主引擎本地 Qwen3-ASR 1.7B，备用 Parakeet TDT 0.6B v3，均经 mlx-audio-swift 接入（对比依据见 decisions.md）
- 课件：PDFKit；PPT 导入时经 PowerPoint（兜底 Keynote）转成 PDF，之后只走 PDF 一条路
- LLM：`LLMClient` 协议，两个实现、三家服务商，在设置里切换：OpenAI 兼容（默认 DeepSeek，Flash：翻译/判问句；Pro：答题）、Anthropic（Claude，Haiku 5.5：翻译/判问句；Opus 5.5：答题）和 OpenAI（走 OpenAI 兼容实现，gpt-6-luna：翻译/判问句；gpt-6.1-sol：答题）。各验收线目前只在 DeepSeek 下跑过
- 第三方依赖用 SwiftPM，写进 `project.yml`；新增依赖前先说明理由

## 目录约定

```
ClassLens/            App 源码，按功能分目录，一个类型一个文件，文件名 = 类型名
  App/                入口、AppModel、全局设置
  Audio/              音频来源（麦克风、录音文件回放）、录音落盘、教室麦克风模式
  Transcription/      TranscriptionEngine 协议与各实现；LiveTranscriber 切句 + 调度识别
  Translation/        逐句翻译
  Questions/          提问识别（规则粗筛 + LLM 判定）与答题
  LLM/                LLMClient 协议与各家实现
  Documents/          课件阅读、PPT 转换、术语表
  Session/            一节课的数据模型与存储
  Export/             导出到 Obsidian：库位置推断、Markdown 渲染、AI 课后总结
  UI/                 视图；按界面区域分子目录
  Support/            钥匙串、日志等通用工具
  Resources/          Info.plist、entitlements、Assets
ClassLensTests/       单元测试，镜像 ClassLens/ 的目录
Fixtures/             测试用的小样本（转录 jsonl、短音频 < 5 MB）；大录音不进仓库
  questions/          （不在公开仓库中）提问识别评估集：课堂转录 + 人工标注 labels.json（SCEM Week 7 三段窗口与整节课、SDPA 实验课与 Lecture 1、FOAI 实验课、LSDE Lecture 2）
  slides_follow/      （不在公开仓库中）跟页评估集：整节课转录 scem_week7_full.jsonl + 人工标注的 34 个时间点（课件 PDF 不进仓库，评估时传路径）
  slides/             样例课件：PDF（Bench/make_fixture_slides.swift 生成）、同内容 PPTX（Bench/make_fixture_pptx.py 生成）、PowerPoint 导出的 PDF（带“ti”连字乱码，测修复）
Bench/                识别引擎对比等离线实验脚本（进 git）
  data/               实验用音频切片与输出（gitignore，可随时删）
  .venv/              实验用 Python 环境，uv 管理（gitignore，不装全局包）
docs/decisions.md     技术决策记录（日期 + 决定 + 理由）
docs/references.md    借鉴来源与许可证
build/                编译产物（gitignore，可随时删）
```

## 运行时数据

`~/Library/Application Support/ClassLens/sessions/<session-id>/`：`audio.m4a`、`transcript.jsonl`、`qa.json`、`meta.json`、`slides.jsonl`（老师讲到哪一页的时间线，每次换页一行）。`meta.json` 只增加可选字段（标题、结束时间、时长、课件），旧会话缺这些字段时按默认值读取，不需要迁移。`transcript.jsonl` 只追加：同一条字幕先写英文、翻译回来后再写一行，读取时同一 id 以最后一行为准（`SessionStore.loadTranscript`）。格式变更要写迁移，并记进 decisions.md。

课件术语表缓存在 `~/Library/Application Support/ClassLens/glossaries/<课件 SHA-256>.v<版本>.json`，可以随时删除，下次打开课件时会重新抽取；改了抽取逻辑（提示词、文字清洗）要把 `GlossaryCache.version` 加一。
PPT/Keynote 转出的 PDF 缓存在 `~/Library/Application Support/ClassLens/converted/<源文件 SHA-256>.pdf`，同样可以随时删除。`CLASSLENS_EXPORTER=keynote`（或 `powerPoint`）可以强制只用某一个应用转换，用于测试。

## 验证命令（改完必须跑）

```bash
make gen     # 由 project.yml 生成 ClassLens.xcodeproj
make build   # Debug 构建，产物在 build/
make release # Release 构建；性能验证只看它
make test    # 单元测试
make run     # 构建并启动 App
```

提交前至少保证 `make build` 和 `make test` 通过。涉及音频或识别的改动，要用录音回放做端到端验证，不能只靠“编译通过”：

```bash
# 无界面验证：从第 600 秒起按 1 倍速回放 600 秒，指标写到 build/replay-metrics.json，跑完自动退出
build/Build/Products/Release/ClassLens.app/Contents/MacOS/ClassLens \
  --replay <录音文件> --replay-start 600 --replay-duration 600 --replay-speed 1 \
  --metrics-out build/replay-metrics.json --quit-when-done
```

加 `CLASSLENS_TRACE=1` 环境变量可逐条打印识别任务耗时；`--bench-engine <录音>` 单独测识别引擎速度；`--asr-only` 关掉翻译和提问；`--eval-questions <transcript.jsonl>` 只跑提问识别；`--document <pdf>` 启动时先打开课件并抽取术语表；`--eval-slides <transcript.jsonl>`（配合 `--document`）离线跑跟页，`python3 -I Bench/score_slides.py <可执行文件> <课件.pdf> dev|test` 打分（只能用 dev 调参，test 是留出集），`CLASSLENS_SLIDES="temperature=… jump=…"` 覆盖参数；`CLASSLENS_SLIDES_MODE=llm|hybrid` 评估用模型判断当前页的方案（会真实调用 API，一次整节课约 190 次、不到 0.05 美元，只跑一次 `all`，别分开跑 dev/test）。

M1 验收线（看 Release 构建）：临时字幕延迟 p95 ≤ 1.5 s；停顿后出正式字幕 p95 ≤ 2 s（`finalLatency`，从老师停止说话算起，含 0.6 s 停顿判定）；内存峰值 ≤ 4 GB；无重复循环。长句被 15 s 上限切开的 `cutFinalLatency` 单独报告，其内容已先以临时字幕显示。Debug 构建下 MLX 慢数倍，不能用来判断性能。

M2 验收线：中文在英文正式字幕出现后 p95 ≤ 2.5 s（`translationLatency`），翻译错误 0；抽查译文术语正确、断句处衔接通顺。需要钥匙串里已有 DeepSeek key（在 App 设置里填写）。

M3 验收线（2026-11-03 用户收紧）：用 `python3 -I Bench/score_questions.py <Release 可执行文件>` 跑 `Fixtures/questions/` 的评估集：三段 10 分钟转录，外加 Week 7 整节课（`full_week7`，112 分钟，标注里有课间休息时段）、SDPA 实验课（`sdpa_lab1`，87 分钟，没有向全班的提问，用来测一对一对话的误报）、SDPA Lecture 1（`sdpa_lecture1`，76 分钟，另一位老师的问答式讲课）、FOAI 实验课（`foai_lab1`，16 分钟）和 LSDE Lecture 2（`lsde_lecture2`，67 分钟，录音在课间停过）。**误报 ≤ 0.5 个 / 10 分钟**，整节课约为 ≤ 5 个；已知的真提问全部识别；课间休息时段 0 个误报。只能用 `full_week7` 3000 秒以前的部分和 `sdpa_lab1` 调参（`--before 3000`）；`full_week7` 3000 秒以后的部分（包含两段留出集）、`sdpa_lecture1`、`foai_lab1`、`lsde_lecture2` 只用来最后验收，模型每次结果会波动，留出集至少跑三次；改了提问相关的提示词或逻辑，必须重跑。从问句出现到识别出来 p95 ≤ 15 s（`questionLatency`，其中大部分是故意等老师后面两句、等长句讲完，以排除自问自答；2026-11-02 由用户从 12 s 放宽）；答案开始出字 p95 ≤ 3 s，完整答案 p95 ≤ 15 s；`qa.json` 与界面一致。

M4 验收：用 `--document <课件> --asr-only --replay-speed 0` 回放，和不带课件的同一段转录逐条对比，`contextEchoes` 应为 0，且不能出现课件里有、老师没讲的术语；带翻译回放时，抽查译文是否按术语表用词；界面上课件、页码、术语数正常显示。

## 导出到 Obsidian（M6，2026-11-03 用户确认）

用户的课程库在 `~/Documents/Obsidian Libraries/AI（MSc）/`，有自己的规范（库根目录 `AI协作规则.md`）。导出必须遵守：
- 位置：`模块/<课程>/资料/课堂记录/ClassLens/`，下分 `转写/`、`录音/`、`AI总结/`（用户已同意新建）。课程和周次从课件路径推断（`模块/<课程>/…/Week7…`），导出前可改。
- 转写文件命名 `<课程>-W<周>-<日期>-课堂转写.md`；frontmatter 含 `title/course/week/type/tags/source/confidence/created/updated`，`confidence: low`；开头用 callout 标“机器转写与 AI 翻译/答案，二手，需核对”。
- 录音（m4a）一起导出（库的 `.gitignore` 已排除 `*.m4a`）；AI 课后总结单独成文件，只依据转写和课件，不编造，`confidence: low`。
- **只新建文件，不修改、不覆盖库里已有的任何文件**；不碰 `笔记/`（包括课堂记录索引）和 `.obsidian/`。同名文件已存在时让用户决定，不静默覆盖。
- 开发和测试只导出到临时目录；往用户库里真正导出前先告诉用户。

## 编码规则

- UI 状态放 `@MainActor @Observable` 模型；音频回调和识别跑在非主线程，跨线程只传 `Sendable` 值
- 密钥只存 macOS 钥匙串（`Support/Keychain`），不进 UserDefaults、代码、日志、测试样本
- 用户可见文案用中文；代码、标识符、日志用英文
- 不用注释掉报错、`try!`、强制解包来绕过问题；找根因
- 发给 LLM 的提示词集中放在各功能目录的 `*Prompts.swift`，便于对比和调参

## 借鉴与许可证

- Nomi（MIT）：可复用代码，复用处在文件头注明出处
- LectureFlow、OpenLecture（AGPL）、LectureLive（GPL）：**只借鉴思路，不复制代码**
- 新的借鉴来源记进 `docs/references.md`

## 里程碑

M0 骨架 → M1 录音 + 实时英文字幕 + 识别引擎对比 + 术语表 → M2 逐句翻译与双语字幕 → M3 提问识别与自动答题 → M4 课件阅读与划词提问 → M5 PPT 导入 → 自动跟随老师讲到的页（根据转录判断当前页，用作答题上下文并可自动翻页）→ M6 课程记录与导出（M6a：App 内历史与回放；M6b：导出到 Obsidian）。当前进度见 `docs/decisions.md` 末尾。
