# Xpresentext 英文自由讲解验证

测试演讲者乱序讲解、换一种说法或在一次发言中讲两个要点时，能否只把讲过的要点标灰。每次独立核对该页全部四个要点。测试数字按「一段发言 × 一个要点」计数，同一要点在不同发言中可以多次出现。全程只使用为验证编写的英文材料。

## 0.6.2 跟读回归

Apple 和 Whisper 两个输入入口均通过部分转写、跳过未讲句、连续原稿问句、重复朗读和停止收音的控制器回归。另用打包的 FineCat 在一页 18 句的讲稿上验证了讲解顺序。先改述一个要点，再读下一道原稿问句，即使第一条的语义结果较晚返回，两条都会标灰，光标仍停在最新一句。

在应用窗口点 **Whisper Turbo → 用样音测试**，本机 MLX Whisper 完成了英文录音转写，跟读器定位到示例讲稿第 2 句。

另在发行包的工作区打开 orchard-fixture 第 1 页、选择「自由讲解」并开始跟读。界面先显示等待 macOS 麦克风授权，授权后显示输入音量和「Whisper Turbo · 已加载」。用系统播放器播放合成英文，先讲第 3 句 “The blue marker shows our first stop.”，再讲第 1 句 “We start at the orchard gate.”。通过 Mac 扬声器和麦克风，在窗口内观察到计数从 0/10 到 1/10 再到 2/10，第 2 句仍是待讲。停止后已讲记录保留，麦克风关闭，Whisper 恢复「已下载 · 未加载」。该回放验证了实际收音路径；真人口音与会场噪声下的表现仍需实测。

## 0.6.1 本机产品验收

2026-11-23，从 Xpresentext 工作区首次下载 FineCat，校验并试算成功，界面显示「语义匹配」。冻结原判定规则后，为三个新主题预先编写 18 段口播及标签，用 macOS Daniel 以 165/180 词每分钟合成。每页先讲第三个要点，再回头补讲，也包含一次讲两项、撤回、否定和相近数字。两种 Whisper 配置使用同一组录音，须分别计分。[冻结样例和标签](integration-trial.json)

| 同组英语音频，逐段 ASR | 已讲命中 | 本页未讲误灰 | 邻页误灰 | 转写定稿至语义组件返回 P50 / P95 |
| --- | ---: | ---: | ---: | ---: |
| Whisper Base | 14/15（93.3%） | 0/39 | 0/36 | 0.51 / 0.86 秒 |
| Whisper large-v3-turbo | 15/15（100%） | 0/39 | 0/36 | 0.56 / 0.93 秒 |

语义推断直接调用本机签名应用内的助手。每段提交本页及相邻页所有要点。邻页分母为 12 段 × 3 项。ASR 使用 OpenAI Whisper 在 CPU 上解码，包括从应用已安装的 Turbo 权重还原后运行，未使用 MLX 实时麦克风管线。Base 把 “the engineers checked” 听作 “the engine is checked”，使对应要点低于阈值；Turbo 保留了主体。语义计算耗时不含听写等候、用户讲话、冷启动及屏幕绘制。每页三个要点，不能外推到一页几十句的讲稿。[Base 逐段实测](integration-base-results.json) · [Turbo 逐段实测](integration-turbo-results.json)

Swift 工作区控制器另用同一个助手与真实本机权重验证了乱序说 C 再说 A、B 保持白色、问答后丢弃迟到结果、邻页单次改述只标记、第二个要点触发翻页，以及点击和回看保持已讲集合。Apple 与 Whisper 两个输入入口都通过了定稿、部分转写和点击隔离回归。此次测试进程未取得 Apple 英文端侧识别资源和 Metal 设备。真人口音、现场麦克风、Apple 的召回率，以及整场连续讲话的端到端延迟仍待实测。

0.6.1 的跟读回归、月景渲染、浮窗和问答文本路径通过。此次全量回归未走完：测试环境拒绝创建额外的网络隔离进程，胶片转换无法连接桌面图形会话，Vision 图表用例返回系统错误。这些项目保留为未验证。

额外校对了这批 Base 转写对应的 54 个原始模型概率。本机 NumPy 推断相对作者公开演示（三位小数）的最大绝对差为 0.000499。旧的 30 段验收转写在打包助手上复测仍为 22/24，误灰 0/96。[参考概率](reference-scores.json) · [本机概率校对](verify_model.py)

签名应用准备好模型后，可从项目外层目录运行以下命令，重新测量本机数值。

```sh
python3 textream/Tests/CompanionTracking/EnglishCoverage/evaluate_app.py Xpresentext.app --set integration-audio --adjacent
python3 textream/Tests/CompanionTracking/EnglishCoverage/evaluate_app.py Xpresentext.app --set integration-turbo-audio --adjacent
textream/Tests/CompanionTracking/verify.sh --english-coverage-helper "$PWD/Xpresentext.app/Contents/Helpers/MurmuryPresenter.app/Contents/MacOS/MurmuryPresenter"
```

## 11 月 22 日原型结果

11 月 22 日，在四组合计 90 段英语合成语音中，当前原型通过 Whisper Base 的实际转写识别出 69/72 个已讲要点，误灰 0/288 个未讲要点。录音均来自同一合成音色，转写按段提交，各组中的部分例子参与过调试。这组结果衡量已知胶片内的要点判断。

| 验证材料 | 原型识别已讲 | 原型误灰 / 未讲 | 结果用途 |
| --- | ---: | ---: | --- |
| 第一轮，5 页、45 段人工转写 | 39/40 | 0/140 | 固定原模型最初盲测为 39/40、误灰 1/140。发现误灰后开发了事实与计划的复核 |
| 图书馆、维修，20 段 Whisper 转写 | 16/16 | 0/64 | 计划、撤回以及同一句中提到两个要点的开发回归 |
| 博物馆、配送，20 段 Whisper 转写 | 16/16 | 0/64 | 页标题帮助解析省略的主语。人工原文另有一次提前入场的误灰 |
| 轮渡、水质实验室，20 段 Whisper 转写 | 15/16 | 0/64 | 短句、数字改写、转写引入的逗号长句 |
| 测试台、工作坊、电力监测，最后 30 段人工转写 | 23/24 | 0/96 | 修正计划语法及事件开场时间后的同组复测 |
| 同样的 30 段经 Whisper 转写 | 22/24 | 0/96 | 修正计划语法及事件开场时间后的同组复测 |

原型在最后三页**首次冻结规则的盲测**中，人工转写命中 22/24（91.7%），语音命中 21/24（87.5%），两种输入各有一次误灰。盲测之后修正了“plan a follow-up session”这类「plan + 名词」被当成事实的问题，分别补回一个命中。再逐项核对两个具名事件的开始时间，消除了签到与开场混淆造成的误灰。忽略额外规则直接用 FineCat，同组语音命中 23/24、误灰 1/96。四组语音合计，直接用 FineCat 命中 64/72、误灰 2/288。正式验收仍需用独立真人录音重测，不能把调试过的样本并入独立盲测。

## 模型与样本

采用公开的英文 FineCat-NLI Ultra L 模型。先将发言作为前提、各讲稿要点作为待验证主张，以 0.50 为蕴涵概率阈值。再检查哪些内容是已经发生的事、哪些是计划，以及同页另一个要点是否藏在后半句。必要时用页标题补出短句的主语。每个要点独立评分，不要求上一点先完成。相同的原始 75 对英文输入上，Laya 通用推断命中 10/18（55.6%），FineCat 单独运行命中 17/18（94.4%），两者均误灰 0/57。[Laya 对照](../Laya/README.md) · [FineCat 模型、用法与 Apache-2.0 许可](https://huggingface.co/dleemiller/finecat-nli-ultra-l)

本次实际的语义概率由作者公开演示服务的 Ultra L 返回，仅提交自编的虚构转写和要点。表格显示三位小数。按页提交全部要点，添加唯一观测编号防止读到前一次异步结果，评分时排除编号。模型权重未打进 Xpresentext。离线复核入口读取调用者指定的本地权重，11 月 22 日这批原型样本使用公开演示，后续本机实测见上表。Whisper 使用本机已有 Base 多语言权重，依官方 v20250625 的 CPU 解码执行。macOS Samantha 以每分钟 165、180 词交替生成音频，经 16 kHz 单声道输入，固定英语、无时间戳、贪心解码。本轮运行中 Apple 测试进程无法使用 en-US 端侧识别。[Whisper 源码](https://github.com/openai/whisper/tree/v20250625)

## 仍会出现的错误

- 「会员可在闭馆时多留半小时，入场时间和公众一样」在人工转写中仍会被误判成「会员提前半小时入场」。目前能区分签到与正式开场的明确时刻，相对时间仍需验证。
- “You can break down energy consumption by line on the dashboard.” 在同时讲到保留天数时，可能漏掉「按生产线展示能耗」。
- 「四组，每组十名技术员」和「四十名技术员」没有稳定对上。Whisper 也可能将计划和已完成的事实并入同一个长句。
- 真实麦克风、口音、环境噪声、连续无人工断句的输入、整场累积误差和 UI 绘制延迟仍待评估。

## 复测

在本目录用系统 Python 即可重算。第一条覆盖全部数据，第二条列出最后三页音频的具体误判。每一行同时显示原始模型和优化后的成绩。

```sh
python3 evaluate.py
python3 evaluate.py --set acceptance-audio --errors
```

原文与预先标注的要点见各个 JSON，Whisper 实际输出见对应的 `*-audio.jsonl`。原始整段分数在 [observations.json](observations.json)，按上下文追加的分数在 [additional-scores.jsonl](additional-scores.jsonl)。最终三页标签文件为 [acceptance.json](acceptance.json)，其 SHA-256 为 `a19637ee7f1adee303e9db4a4f8aea7e8cc9d510d8f0f251a1c9239ddc319c05`。首次盲测规则文件的 SHA-256 为 `946089c002674407f86ec853ae337af8a6e67f75040b96f2b432d90aa942fdd3`。后续修复包括识别“plan + a/an/the/another”，以及核对具名事件的开始时间。

安装上游模型卡说明的 sentence-transformers 与 transformers 并备好本地模型目录后，以下命令可重新预测或输入自己的发言。语义推断只读取本地权重及其随附的 UltraBERT 实现。`speech.json` 包含字符串 `slide`、字符串数组 `points` 和字符串 `transcript`。

```sh
python3 evaluate.py --model /path/to/finecat-nli-ultra-l --set acceptance-audio --errors
python3 evaluate.py --model /path/to/finecat-nli-ultra-l --input speech.json
```

macOS 上备好 OpenAI Whisper v20250625、其官方 Base 多语言权重、ffmpeg、Samantha 音色后，可重新合成并转写最后三页，输出到新的 JSONL 供对照。当前保存的复测使用同一架构已有权重从 MLX 排列还原后在 PyTorch CPU 上运行。

```sh
python3 transcribe_samples.py acceptance /path/to/base.pt /tmp/acceptance-new.jsonl
```
