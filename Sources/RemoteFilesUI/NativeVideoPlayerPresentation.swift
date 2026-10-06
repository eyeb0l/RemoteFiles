#if os(iOS)
import SwiftUI
import AVKit

/// Present AVKit directly as the modal controller, so iOS owns fullscreen chrome,
/// transport controls and dismissal. The same player retains its position and rate.
struct NativeVideoPlayerPresentation: UIViewControllerRepresentable {
    let player: AVPlayer?
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> PresentationHost {
        let host = PresentationHost()
        host.onAppear = { [weak host, weak coordinator = context.coordinator] in
            guard let host else { return }
            coordinator?.hostAppeared(host)
        }
        return host
    }
    func updateUIViewController(_ host: PresentationHost, context: Context) {
        context.coordinator.update(player: player, presentation: $isPresented, host: host)
    }
    static func dismantleUIViewController(_ host: PresentationHost, coordinator: Coordinator) {
        host.onAppear = nil
        coordinator.remove(from: host)
    }

    final class PresentationHost: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    @MainActor final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        private var presentation: Binding<Bool>?
        private var player: AVPlayer?
        private var controller: AVPlayerViewController?
        private var presenting = false
        private var dismissing = false

        func update(player: AVPlayer?, presentation: Binding<Bool>, host: UIViewController) {
            self.player = player
            self.presentation = presentation
            synchronize(host)
        }

        func hostAppeared(_ host: UIViewController) {
            // Native AVKit's Close action returns to this presenter. Do not reopen it
            // while SwiftUI still has the previous presentation binding set to true.
            if let controller, !presenting, controller.presentingViewController == nil {
                finished()
            } else {
                synchronize(host)
            }
        }

        private func synchronize(_ host: UIViewController) {
            guard !presenting, !dismissing else { return }
            guard presentation?.wrappedValue == true, let player else {
                if controller != nil {
                    dismissing = true
                    host.dismiss(animated: false) { [weak self] in self?.finished() }
                }
                return
            }
            if let controller {
                if controller.player !== player { controller.player = player }
                return
            }
            guard host.view.window != nil, host.presentedViewController == nil else { return }
            let native = AVPlayerViewController()
            native.player = player
            native.showsPlaybackControls = true
            native.allowsPictureInPicturePlayback = false
            native.updatesNowPlayingInfoCenter = false
            native.modalPresentationStyle = .fullScreen
            controller = native
            presenting = true
            host.present(native, animated: true) { [weak self, weak host] in
                guard let self, let host else { return }
                self.presenting = false
                native.presentationController?.delegate = self
                self.synchronize(host)
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finished() }

        private func finished() {
            controller?.player = nil
            controller = nil
            presenting = false; dismissing = false
            if presentation?.wrappedValue == true { presentation?.wrappedValue = false }
        }

        func remove(from host: UIViewController) {
            presentation = nil
            controller?.player = nil
            controller = nil
            player = nil
            host.dismiss(animated: false)
        }
    }
}
#endif
