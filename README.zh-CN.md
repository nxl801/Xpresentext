# Xpresentext

[English](README.md) · 简体中文

**一款能听着你讲、跟着你翻页的 Mac 提词器。** 放映电脑照常播放 PowerPoint，在自己的 Mac 上打开同一份 PPTX 即可。观众看胶片，你看正在讲的那句话、下一页的内容，以及有人提问时用得上的备注。

[下载 Apple Silicon 版](https://github.com/nxl801/Xpresentext/releases/download/v0.6.4/Xpresentext-0.6.4-macOS-arm64-AppleSpeech.zip) · [版本说明](https://github.com/nxl801/Xpresentext/releases/tag/v0.6.4) · [从源码构建](#从源码构建)

## 拿一页讲稿，试讲两遍

1. **拖入 PPTX。** 选一页带英文备注的胶片，把其中一句改成自己习惯的说法。个人改稿保存在本机。
2. **第一遍，照着稿子读。** 点击「开始跟读」，允许麦克风和语音识别。读到本页末句时，下一页提前进入主区。上一页缩在左下角，末句还在眼前，你可以从容地把这句话讲完。
3. **第二遍，按自己的顺序讲。** 切到「自由讲解」，先讲第三点，再回头补第一点。已讲内容变灰，漏讲的要点保持亮色。什么时候翻页由你决定。完整构建还可以用本机 FineCat 模型识别英文改述。

[详细操作指南：分屏、指向框、字号与模型状态](docs/presenter-guide.zh-CN.md)

## 观众问「这个结论在哪一页」时

打开「现场问答」，输入问题。点击回答中的页码即可预览依据，查看引用时保留原来的跟读位置。想顺着被问到的那页继续讲，再点「从本页讲稿继续」。

在「更多 → 模型与显示设置」里填写自己的 DeepSeek API 密钥，或使用本机已登录的 Grok CLI。在线问答会将问题和选中的备稿依据发给配置的服务。

## 选择版本

| | AppleSpeech 下载版 | 源码完整构建 |
|---|---|---|
| 英文跟读 | Apple 语音识别 | Apple 语音识别或本机 Whisper Turbo |
| 自由讲解 | 原句匹配 | 可选 FineCat，识别换一种说法的英文要点 |
| 现场问答 | 原生问答窗口 | 增加 Murmury 浮窗和会议声音采集 |
| 运行与构建 | Apple Silicon，macOS 15 或更新版本 | 可选引擎需要 Apple Silicon、uv 和 Python 3.12 |

下载版解压后打开 **Xpresentext.app**。应用使用本地签名，未经 Apple 公证。完整构建中的 Whisper 和 FineCat 模型按需下载，分别约 1.6 GB 和 1.5 GB。

## 从源码构建

在 macOS 15 或更新版本上安装 Xcode Command Line Tools，然后在仓库根目录执行以下命令。首次完整构建会下载锁定版本的依赖。

```sh
./Textream/build-local.sh
open "Textream/build/local/current/Xpresentext.app"
```

胶片渲染可使用本机 LibreOffice，也可以从 PowerPoint 导出同版 PDF。运行 `Tests/verify-companion.sh` 可验证构建。测试用 Python 需要安装 python-pptx、Pillow 和 lxml，可通过 `DECK_PYTHON` 指定解释器。

## 许可与致谢

Xpresentext 按 [GPLv3](LICENSE) 发布。原生提词器基于 Fatih Kadir Akın 的 [Textream](https://github.com/f/textream) 开发，保留其 [MIT 声明](LICENSES/Textream-MIT.txt)。完整构建集成了 GianlucaBave 与贡献者的 [Murmury](https://github.com/GianlucaBave/murmury)，用于问答浮窗、音频采集与转写。[修改与重建说明](Textream/Murmury/NOTICE.md) · [第三方许可、素材署名与再分发说明](THIRD_PARTY_NOTICES.md)
