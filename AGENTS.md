# LectoAI 协作约定

适用于人和 AI 编程助手（Claude Code、Codex 等）。

## 维护者私有笔记

如果仓库根目录存在 `.notes/`（维护者本机的私有笔记，不进版本库），开始任何实现、规划、修复、重构、验证工作前，先读 `.notes/RULES.md` 并按其执行。没有这个目录时忽略本节。

## 工程

- 工程由 `project.yml`（XcodeGen）生成，不手改 `.pbxproj`；改了 `project.yml` 后运行 `./Scripts/bootstrap.sh`。
- 业务逻辑放在 `LectoAICore` 本地包里，App target 只负责界面与系统集成。
- Swift 6 严格并发；实时音频回调里不做 IO，也不等待网络或模型。
- **新增代码的注释使用中文。**
- 识别引擎由 App 自动选择，不加让用户选择引擎的设置。
- 不做首次启动的一串设置：用到时就地问，先替用户填好再让用户改；能从使用记录里积累的就不问。
- 引入新的第三方包要说明理由、版本与许可证，并更新 `LectoAI/Resources/ThirdPartyNotices.txt`；许可证须与 GPL-3.0 兼容。

## 不进版本库的东西

模型权重、课堂录音与资料、API 密钥、签名证书或私钥、`Config/Signing.local.xcconfig`、构建产物。真实录音通过环境变量 `LECTOAI_SAMPLES_DIR` 读取，不复制进仓库。

## 验证

1. `swift test --package-path LectoAICore` 与 `xcodebuild … -scheme LectoAI build test` 通过（命令见 README）。
2. 界面测试（`LectoAI-UI`）会结束同一 bundle id 的进程：**有人正在用 LectoAI 录课时不要跑**。
3. 权限弹窗、小窗焦点与全屏、真实课堂、耗电等无法自动验证的项目，要写明“待人工验证”，不能写成“已验证”。
