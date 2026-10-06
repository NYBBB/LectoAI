# LectoAI

[English](README.md) | 简体中文

给在英语授课环境里上课的中文母语学生用的 Mac 应用：上课时看英文字幕和中文译文，走神或没听懂时一键标记、看看现在讲到哪了、问一句；下课后把转写、译文、纪要和笔记交到你自己的课程文件夹，供你和你的学习工具（比如 Claude、Codex）复习。

- **在本机识别与翻译**：默认用 Apple SpeechAnalyzer 识别英语、Apple Translation 翻译；系统识别不可用时可下载 WhisperKit 离线模型。录音不上传。
- **AI 助手可选，自带密钥（BYOK）**：连接任意兼容 OpenAI Chat Completions 的服务后，可以生成课堂纪要、总结、整段润色译文，也能问答。只发送有限的课堂文字，密钥存在钥匙串里。
- **课程文件夹**：不需要提前设置。第一次下课时选一个文件夹就建好一门课，之后按上课时间自动认课并交接文件。

> **状态**：0.5.0，早期测试版。界面目前只有中文。还没有经过完整的真实课堂验证，也没有正式签名的发行包。

## 系统要求

- Apple Silicon（arm64）
- macOS 26 或更高
- 构建需要 Xcode 27（Swift 6）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44 或更高

## 构建与运行

```bash
brew install xcodegen
./Scripts/bootstrap.sh          # 由 project.yml 生成 LectoAI.xcodeproj，并恢复锁定的依赖版本
swift test --package-path LectoAICore
xcodebuild -project LectoAI.xcodeproj -scheme LectoAI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/LectoAI.app
```

Debug 构建使用临时签名（ad-hoc），不需要 Apple 开发者账号。`./Scripts/package.sh` 会生成一个本机测试用的 DMG。

界面测试（`LectoAI-UI` scheme）会启动、结束与 App 同一个 bundle id 的进程。**正在用 LectoAI 录课时不要跑界面测试**，否则会结束正在进行的录音。

## 使用

打开后进入开始页：正中是“开始听课”和音源（麦克风＝现场上课，电脑声音＝网课），下面是准备清单（英语识别、中文翻译、AI 助手、课程），缺什么就在那一行点一下。识别资源缺失时，直接点“开始听课”也会先自动准备。

1. **上课**：字幕按段落显示，原文 / 双语 / 中文 / 总结在工具栏切换（⌥⌘1–4），字号 ⌘+ / ⌘−。每段中文先逐句出现，段落结束后在原位换成更通顺的整段译文。
2. **记录**：底部“没听懂”（⌘⇧U）和“重点”（⌘⇧I）一键标记当前时刻；“记一笔”（⌘⇧N）边看字幕边写，记在你开始输入的那一刻。
3. **小窗**（⌘⇧F）：深色字幕面板，可以叠在课件或全屏 App 上，鼠标移上去才出现控件。
4. **AI 助手**（右侧，⌥⌘0）：顶部“此刻”显示当前话题，下面是按话题分节的课堂纪要（点时间跳回原文），你的提问按时间插在其中。
5. **下课**：横幅显示这堂课交到了哪里。第一次下课时可以“放进课程文件夹…”，选好文件夹、确认一张已经填好的卡片，课程就建好了。之后同一门课的星期几和时刻对得上，就会自动归课。交出去的文件如果被你改过，App 不会覆盖，而是另存一份“(LectoAI 更新 …)”。
6. **回看**：侧栏按日期列出所有课堂，可以搜索；点任意句子就从那里播放；识别缺口可以“补识别”。导出面板（⇧⌘E）可以交到某门课，或者一次性导出到其他位置。

资料保存在 App 沙盒的 `Library/Application Support/LectoAI/Recordings/`。导出只写有内容的文件：课堂总结.md、课堂纪要.md、双语.md、课堂转录.txt/.vtt、我的笔记.md、课堂问答.md 等，引用都显示为课堂时间。

## 代码结构

| 目录 | 内容 |
|---|---|
| `LectoAI/` | App：`Runtime/`（采集、识别管线、AppModel、交接编排）、`UI/`（SwiftUI 界面）、`Diagnostics/` |
| `LectoAICore/` | Swift 包：课堂数据与事件日志、分句分段、翻译与纪要提示词、课程与交接逻辑，以及单元测试 |
| `LectoAIBench/` | 命令行基准工具（Apple 文件识别、WhisperKit 切片模拟） |
| `LectoAIUITests/` | 界面测试（使用 `--demo*` 隔离资料库） |
| `Config/`、`Scripts/` | 工程配置、依赖锁、构建/打包/签名核验脚本 |
| `docs/` | 部分设计文档 |

`project.yml` 是工程的唯一来源，不要直接改 `.pbxproj`。Debug 参数 `--demo`、`--demo-review`、`--demo-start`、`--test-workspace` 等都使用隔离的临时资料库，不会碰到真实课堂记录；完整列表见 `LectoAI/Runtime/AppModel.swift` 与 `LectoAI/Runtime/DemoClassroom.swift`。

## 隐私

- 录音、转写和笔记都只保存在本机；App 没有账号，也没有统计或遥测。
- 只有在你连接 AI 服务、并开启相应功能时，才会把有限的课堂文字（不含录音）发给**你自己配置的**服务。
- 第一次使用识别或翻译时，系统可能会下载 Apple 的语言资源；离线语音模型从 Hugging Face 下载，并按固定版本和摘要校验。

## 关于录音

录课之前，请先确认学校、课程和授课老师对录音的规定，必要时先征得同意。录音和转写只用于自己学习，不要传播。

## 已知限制

- 还没有完成 75 分钟整堂真实课、合盖/拔设备/磁盘满等情况的全面验证；离线后备模型需要更多真实录音测试。
- 界面文案还没有英文版。
- 导入音频按 1 倍速处理。
- 没有正式签名、公证的发行包，也没有更新服务器（Sparkle 已经集成，配置示例见 `Config/Update.example.xcconfig`）。

## 许可证

LectoAI 以 [GNU General Public License v3.0](LICENSE) 发布。第三方组件（WhisperKit、Sparkle、swift-argument-parser 等）的许可证见 [`ThirdPartyNotices.txt`](LectoAI/Resources/ThirdPartyNotices.txt) 与 [`Sparkle-LICENSE.txt`](LectoAI/Resources/Sparkle-LICENSE.txt)。
