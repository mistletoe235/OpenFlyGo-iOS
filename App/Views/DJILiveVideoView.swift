import SwiftUI

#if canImport(DJISDK) && !targetEnvironment(simulator)
import DJISDK

/// DJI's previewer owns a hardware-decoded render surface. SwiftUI may call
/// `updateUIView` for unrelated telemetry changes, so resize the previewer only
/// when UIKit reports a real bounds change instead of on every view update.
final class DJILiveVideoHostView: UIView {
    var onBoundsSizeChanged: (() -> Void)?
    private var lastBoundsSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0, size != lastBoundsSize else { return }
        lastBoundsSize = size
        onBoundsSizeChanged?()
    }
}

struct DJILiveVideoView: UIViewRepresentable {
    var priority = 0

    final class Coordinator {
        let id = UUID()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DJILiveVideoHostView {
        let view = DJILiveVideoHostView()
        view.backgroundColor = .black
        let id = context.coordinator.id
        view.onBoundsSizeChanged = {
            DJILiveVideoHostRegistry.shared.hostBoundsDidChange(id: id)
        }
        DJILiveVideoHostRegistry.shared.register(
            view: view, id: id, priority: priority
        )
        return view
    }

    func updateUIView(_ uiView: DJILiveVideoHostView, context: Context) {
        DJILiveVideoHostRegistry.shared.register(
            view: uiView, id: context.coordinator.id, priority: priority
        )
    }

    static func dismantleUIView(_ uiView: DJILiveVideoHostView, coordinator: Coordinator) {
        uiView.onBoundsSizeChanged = nil
        DJILiveVideoHostRegistry.shared.unregister(id: coordinator.id)
    }
}

/// DJIVideoPreviewer supports one render target. Keep the normal full-screen
/// target registered while a higher-priority map/survey PIP temporarily owns it,
/// then deterministically restore the normal target when that PIP disappears.
@MainActor
private final class DJILiveVideoHostRegistry {
    private final class WeakHost {
        weak var view: UIView?
        var priority: Int
        var order: UInt64
        init(view: UIView, priority: Int, order: UInt64) {
            self.view = view; self.priority = priority; self.order = order
        }
    }

    static let shared = DJILiveVideoHostRegistry()
    private var hosts: [UUID: WeakHost] = [:]
    private var order: UInt64 = 0
    private var activeID: UUID?

    func register(view: UIView, id: UUID, priority: Int) {
        if let host = hosts[id] {
            guard host.view !== view || host.priority != priority else { return }
            order &+= 1
            host.view = view
            host.priority = priority
            host.order = order
        } else {
            order &+= 1
            hosts[id] = WeakHost(view: view, priority: priority, order: order)
        }
        activateBestHost()
    }

    func unregister(id: UUID) {
        hosts.removeValue(forKey: id)
        if activeID == id { activeID = nil }
        activateBestHost()
    }

    func hostBoundsDidChange(id: UUID) {
        guard activeID == id, hosts[id]?.view != nil else { return }
        DJIVideoPreviewer.instance()?.adjustViewSize()
    }

    private func activateBestHost() {
        hosts = hosts.filter { $0.value.view != nil }
        guard let best = hosts.max(by: {
            ($0.value.priority, $0.value.order) < ($1.value.priority, $1.value.order)
        }), let view = best.value.view else {
            activeID = nil
            DJIVideoPreviewer.instance()?.unSetView()
            return
        }
        let previewer = DJIVideoPreviewer.instance()
        if activeID != best.key {
            previewer?.enableHardwareDecode = true
            previewer?.enableFastUpload = true
            previewer?.setView(view)
            previewer?.start()
            activeID = best.key
            previewer?.adjustViewSize()
        }
    }
}
#endif
