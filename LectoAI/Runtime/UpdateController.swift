import AppKit
import Sparkle

/// 只在用户主动检查时启动更新；录音、导入、补识别和更新彼此互斥。
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private var controller: SPUStandardUpdaterController?
    init(model: AppModel) { self.model = model; super.init() }
    func check() {
        guard let model, !model.active else { model?.message = "请结束当前课堂后再检查更新。"; return }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            model.message = "此本机测试版尚未配置正式更新源。"; return
        }
        model.updateSession = true
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            do { try controller?.updater.start() }
            catch { model.updateSession = false; model.message = error.localizedDescription; controller = nil; return }
        }
        controller?.checkForUpdates(nil)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        model?.updateSession = false
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.isRecording || model.canResume || model.busy || model.importing || model.repairing else { return false }
        Task {
            while model.isRecording || model.canResume || model.busy || model.importing || model.repairing {
                try? await Task.sleep(for: .seconds(1))
            }
            await model.flush()
            installHandler()
        }
        return true
    }
}
