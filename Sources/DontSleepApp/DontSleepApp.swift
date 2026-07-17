import SwiftUI

@main
struct Donts3pApp: App {
    @StateObject private var model: AppModel
    private let instance = SingleInstanceCoordinator()
    private let activationListener: ActivationListener
    private static var retainedStatusBarController: StatusBarController?

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        Self.retainedStatusBarController = StatusBarController(model: model)
        let recovery = RecoveryManager.isRecoveryLaunch()
        activationListener = ActivationListener {
            if model.desiredActive {
                model.handleWakeOrActivation()
                NSApp.activate(ignoringOtherApps: true)
                return .alreadyActive
            }
            model.enableAndActivate()
            NSApp.activate(ignoringOtherApps: true)
            return model.desiredActive ? .enabled : .failed(1)
        }
        switch instance.acquire(recovery: recovery) {
        case .owner:
            guard activationListener.start() else {
                NSApp.terminate(nil)
                return
            }
            model.launch(recovery: recovery)
        case .forwarded, .recoveryLoser:
            NSApp.terminate(nil)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
