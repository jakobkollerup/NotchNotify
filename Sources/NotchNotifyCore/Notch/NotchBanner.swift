import AppKit
import SwiftUI

/// Pure screen geometry so mixed display arrangements can be tested without AX access.
struct NotchLayout: Equatable {
    let frame: CGRect
    let topInset: CGFloat
    let collapsedSize: CGSize
    let stackIndex: Int

    // Transparent space lets a small spring overshoot keep its rounded edges.
    // The actual banner still meets the same top edge and camera center.
    var panelFrame: CGRect {
        CGRect(x: frame.minX - 20, y: frame.minY - 20,
               width: frame.width + 40, height: frame.height + 20)
    }

    static func nativeOffsets(visibleFrame: CGRect, safeTopY: CGFloat, centerX: CGFloat) -> CGPoint {
        CGPoint(x: centerX - visibleFrame.midX, y: max(0, visibleFrame.maxY - safeTopY))
    }

    init(screenFrame: CGRect, safeTop: CGFloat, notchCenterX: CGFloat?, notchWidth: CGFloat,
         stackIndex: Int = 0) {
        self.stackIndex = stackIndex
        let width = min(max(420, notchWidth + 96), max(1, screenFrame.width - 24))
        let center = notchCenterX ?? screenFrame.midX
        let x = min(max(center - width / 2, screenFrame.minX + 12), screenFrame.maxX - width - 12)
        topInset = stackIndex == 0 ? max(12, safeTop) : 12
        let firstHeight = max(12, safeTop) + 106
        let height = topInset + 106
        let top = screenFrame.maxY - (stackIndex == 0 ? 0 : firstHeight + CGFloat(stackIndex - 1) * 124 + 6)
        frame = CGRect(x: x, y: top - height, width: width, height: height)
        // Meet the physical camera on a MacBook; use a small pill on other displays.
        let meetsCamera = stackIndex == 0 && safeTop > 0
        collapsedSize = CGSize(width: min(width, meetsCamera ? max(1, notchWidth) : 64),
                               height: meetsCamera ? safeTop : 6)
    }

    @MainActor init(screen: NSScreen, stackIndex: Int = 0) {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let center = left.flatMap { left in right.map { (left.maxX + $0.minX) / 2 } }
        let width = left.flatMap { left in right.map { max(0, $0.minX - left.maxX) } } ?? 180
        self.init(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                  notchCenterX: center, notchWidth: width, stackIndex: stackIndex)
    }

    static func stackCapacity(availableHeight: CGFloat, safeTop: CGFloat) -> Int {
        max(1, min(3, 1 + Int((availableHeight - max(12, safeTop) - 106 - 24) / 124)))
    }
}

@MainActor
final class NotchAnimationController: ObservableObject {
    let animation: NotchAnimationStyle
    @Published private(set) var expanded = false
    @Published private(set) var contentVisible = false
    private var reveal: Task<Void, Never>?
    private var hasPresented = false
    private var isDismissing = false
    var reduceMotion = false

    init(animation: NotchAnimationStyle = .expand) {
        self.animation = animation
    }

    func present(reduceMotion: Bool) {
        guard !hasPresented, !isDismissing else { return }
        hasPresented = true
        self.reduceMotion = reduceMotion
        let revealSeparately = animation.expandsFromNotch && !reduceMotion
        if !revealSeparately { contentVisible = true }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : animation.entrance) {
            expanded = true
        }
        guard revealSeparately else { return }
        let revealDelay = animation.contentRevealDelay
        reveal = Task { [weak self] in
            try? await Task.sleep(for: revealDelay)
            guard !Task.isCancelled, let self, !self.isDismissing else { return }
            withAnimation(self.animation.contentReveal) { self.contentVisible = true }
        }
    }

    func cancelReveal() {
        reveal?.cancel()
        reveal = nil
    }

    func dismiss(completion: @escaping () -> Void) {
        isDismissing = true
        cancelReveal()
        guard hasPresented else { completion(); return }
        withAnimation(.easeOut(duration: 0.10)) { contentVisible = false }
        // Keep the panel alive until the spring actually finishes, including interruptions.
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : animation.exit,
                      completionCriteria: .removed) {
            expanded = false
        } completion: {
            completion()
        }
    }
}

struct NotchBannerView: View {
    let content: BannerContent
    var layout: NotchLayout
    @ObservedObject var controller: NotchAnimationController
    var animated = true
    let onDismiss: () -> Void
    let onOpen: () -> Void
    var motionMode: NotchMotionMode = .system
    var onHoverChanged: () -> Void = {}
    var queuedCount = 0

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { motionMode.reducesMotion(systemEnabled: systemReduceMotion) }

    var body: some View {
        ZStack(alignment: .top) {
            surface.fill(.black)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
            bannerContent
                .mask(alignment: .top) {
                    surface.frame(width: surfaceSize.width, height: surfaceSize.height)
                }
        }
        .offset(y: slideOffset)
        .frame(width: layout.panelFrame.width, height: layout.panelFrame.height, alignment: .top)
        .clipped()
        .allowsHitTesting(contentVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notification from \(content.appName)")
        .opacity(visible ? 1 : 0)
        .onHover { _ in onHoverChanged() }
        .onAppear {
            if animated { controller.present(reduceMotion: reduceMotion) }
        }
        .onChange(of: reduceMotion) { _, value in controller.reduceMotion = value }
        .onDisappear { controller.cancelReveal() }
    }

    private var bannerContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: layout.topInset)
            HStack(alignment: .center, spacing: 13) {
                Group {
                    if let icon = content.appIcon {
                        Image(nsImage: icon)
                            .renderingMode(icon.isTemplate ? .template : .original)
                            .resizable().scaledToFit().foregroundStyle(.white)
                    } else {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(content.appName.uppercased()).tracking(1.3).lineLimit(1)
                        Spacer(minLength: 4)
                        if queuedCount > 0 { Text("\(queuedCount) waiting").fixedSize() }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    Text(content.title.isEmpty ? content.appName : content.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text([content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: "\n"))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                .help("Dismiss banner").accessibilityLabel("Dismiss notification banner")
            }
            .padding(.horizontal, 20)
            .frame(height: 94)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: contentVisible || reduceMotion || !controller.animation.expandsFromNotch ? 0 : -6)
            Color.clear.frame(height: 12)
        }
        .frame(width: layout.frame.width, height: layout.frame.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var visible: Bool { !animated || controller.expanded }
    private var contentVisible: Bool { !animated || controller.contentVisible }
    private var morphs: Bool { controller.animation.expandsFromNotch && !reduceMotion }
    private var surfaceSize: CGSize {
        visible || !morphs ? layout.frame.size : layout.collapsedSize
    }
    private var slideOffset: CGFloat {
        !visible && !reduceMotion && controller.animation == .dropDown ? -layout.frame.height : 0
    }
    private var surface: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: layout.stackIndex == 0 ? 0 : 25,
                               bottomLeadingRadius: visible || !morphs ? 25 : 8,
                               bottomTrailingRadius: visible || !morphs ? 25 : 8,
                               topTrailingRadius: layout.stackIndex == 0 ? 0 : 25,
                               style: .continuous)
    }
}

@MainActor
final class NotchBannerManager {
    private struct Presentation {
        let panel: NSPanel
        let hosting: NSHostingView<NotchBannerView>
        let controller: NotchAnimationController
    }
    private struct Entry {
        var screen: NSScreen
        let animation: NotchAnimationStyle
        var onOpen: () -> Void
        var onOpenDetached: () -> Void
        var onDismiss: (() -> Void)?
        var presentation: Presentation?
    }
    private var queue = NotchNotificationQueue()
    private var entries: [UUID: Entry] = [:]
    private var closingPanels: [UUID: NSPanel] = [:]
    private var heartbeat: Timer?
    private var motionMode: NotchMotionMode = .system
    private let pointerLocation: () -> CGPoint

    init(pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.pointerLocation = pointerLocation
    }

    var hasActive: Bool { !entries.isEmpty }
    var hasClosingPanels: Bool { !closingPanels.isEmpty }
    var activeCount: Int { entries.count }
    var visibleCount: Int { entries.values.filter { $0.presentation != nil }.count }
    var queuedCount: Int { activeCount - visibleCount }
    func isActive(key: CFHashCode) -> Bool { queue.id(for: key) != nil }

    func show(content: BannerContent, screen: NSScreen, autoDismissSeconds: Double,
              animation: NotchAnimationStyle = .expand, motionMode: NotchMotionMode = .system,
              stackLimit: Int = 3,
              onOpen: @escaping () -> Void, onOpenDetached: (() -> Void)? = nil,
              onDismiss: (() -> Void)?, key: CFHashCode) {
        self.motionMode = motionMode
        queue.configure(seconds: autoDismissSeconds, stackLimit: stackLimit)
        let id = queue.receive(content, sourceKey: key, displayID: screen.displayID,
                               at: ProcessInfo.processInfo.systemUptime)
        if var entry = entries[id] {
            entry.screen = screen
            entry.onOpen = onOpen
            entry.onOpenDetached = onOpenDetached ?? onOpen
            entry.onDismiss = onDismiss
            entries[id] = entry
        } else {
            entries[id] = Entry(screen: screen, animation: animation, onOpen: onOpen,
                                onOpenDetached: onOpenDetached ?? onOpen, onDismiss: onDismiss)
        }
        reflow()
        startHeartbeatIfNeeded()
    }

    /// The native banner can expire or its host can be reused while our card is
    /// hovered, queued, or still counting down. Detach its native actions only.
    func sourceEnded(key: CFHashCode) { queue.sourceEnded(key) }

    func configure(seconds: Double, stackLimit: Int, screen: NSScreen? = nil,
                   motionMode: NotchMotionMode? = nil) {
        if let motionMode { self.motionMode = motionMode }
        queue.configure(seconds: seconds, stackLimit: stackLimit)
        for id in queue.order {
            let target = screen ?? entries[id]?.screen
            if let target, let connected = NSScreen.screens.first(where: { $0.displayID == target.displayID })
                ?? NSScreen.screens.first {
                entries[id]?.screen = connected
                queue.move(id, to: connected.displayID)
            }
        }
        reflow()
    }

    private func makeView(id: UUID, layout: NotchLayout, controller: NotchAnimationController,
                          queuedCount: Int) -> NotchBannerView {
        NotchBannerView(content: queue.items[id]!.content, layout: layout, controller: controller,
                        onDismiss: { [weak self] in self?.dismiss(id: id, notifySource: true) },
                        onOpen: { [weak self] in self?.open(id: id) },
                        motionMode: motionMode,
                        onHoverChanged: { [weak self] in self?.refreshCountdowns() }, queuedCount: queuedCount)
    }

    private func makePresentation(id: UUID, layout: NotchLayout, queuedCount: Int) -> Presentation {
        let controller = NotchAnimationController(animation: entries[id]!.animation)
        let hosting = NSHostingView(rootView: makeView(id: id, layout: layout, controller: controller,
                                                      queuedCount: queuedCount))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        hosting.autoresizingMask = [.width, .height]
        let panel = NSPanel(contentRect: layout.panelFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        return Presentation(panel: panel, hosting: hosting, controller: controller)
    }

    private func open(id: UUID) {
        guard let entry = entries[id], let item = queue.items[id] else { return }
        if item.sourceKey != nil { entry.onOpen() } else { entry.onOpenDetached() }
        dismiss(id: id, notifySource: true)
    }

    func dismiss(key: CFHashCode) {
        guard let id = queue.id(for: key) else { return }
        dismiss(id: id)
    }

    private func dismiss(id: UUID, notifySource: Bool = false, reflowAfter: Bool = true) {
        guard let entry = entries.removeValue(forKey: id), let item = queue.remove(id) else { return }
        if notifySource, item.sourceKey != nil { entry.onDismiss?() }
        if let presentation = entry.presentation { close(presentation) }
        if entries.isEmpty { heartbeat?.invalidate(); heartbeat = nil }
        if reflowAfter { reflow() }
    }

    private func close(_ presentation: Presentation) {
        let panel = presentation.panel
        let closingID = UUID()
        closingPanels[closingID] = panel
        panel.ignoresMouseEvents = true
        presentation.controller.dismiss { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.closingPanels.removeValue(forKey: closingID)
        }
    }

    func dismissAll() {
        for id in queue.order { dismiss(id: id, reflowAfter: false) }
    }

    /// Synthetic previews replay immediately when the user tries another style.
    /// Live content updates continue to use show() and retain their controller.
    func dismissAllImmediately() {
        for entry in entries.values {
            entry.presentation?.controller.cancelReveal()
            entry.presentation?.panel.orderOut(nil)
        }
        for panel in closingPanels.values { panel.orderOut(nil) }
        heartbeat?.invalidate()
        heartbeat = nil
        entries.removeAll()
        queue = NotchNotificationQueue()
        closingPanels.removeAll()
    }

    func move(key: CFHashCode, screen: NSScreen) {
        guard let id = queue.id(for: key) else { return }
        entries[id]?.screen = screen
        queue.move(id, to: screen.displayID)
        reflow()
    }

    func resetDismissTimers(seconds: Double) {
        configure(seconds: seconds, stackLimit: queue.stackLimit)
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        // Tracking the pointer also covers the camera cutout, gaps between
        // cards, and an inactive app. No global event monitor or AX access.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func tick() {
        refreshCountdowns()
        let expired = queue.expiredIDs(at: ProcessInfo.processInfo.systemUptime)
        for id in expired { dismiss(id: id, notifySource: true, reflowAfter: false) }
        if !expired.isEmpty { reflow() }
    }

    private func refreshCountdowns() {
        var bounds: [CGDirectDisplayID: CGRect] = [:]
        var visible: Set<UUID> = []
        for (id, entry) in entries {
            guard let presentation = entry.presentation else { continue }
            visible.insert(id)
            let rect = presentation.hosting.rootView.layout.frame
            let display = entry.screen.displayID
            bounds[display] = bounds[display].map { $0.union(rect) } ?? rect
        }
        let pointer = pointerLocation()
        let hovered = Set(bounds.compactMap { $0.value.contains(pointer) ? $0.key : nil })
        queue.updateCountdowns(visibleIDs: visible, hoveredDisplays: hovered,
                               at: ProcessInfo.processInfo.systemUptime)
    }

    private func reflow() {
        var capacities: [CGDirectDisplayID: Int] = [:]
        for entry in entries.values {
            capacities[entry.screen.displayID] = NotchLayout.stackCapacity(
                availableHeight: entry.screen.frame.maxY - entry.screen.visibleFrame.minY,
                safeTop: entry.screen.safeAreaInsets.top)
        }
        let visible = queue.visibleIDs(capacities: capacities)
        for id in queue.order where !visible.contains(id) {
            if let presentation = entries[id]?.presentation {
                presentation.controller.cancelReveal()
                presentation.panel.orderOut(nil)
                entries[id]?.presentation = nil
            }
        }
        var counts: [CGDirectDisplayID: Int] = [:]
        for id in visible {
            guard let entry = entries[id] else { continue }
            let display = entry.screen.displayID
            let layout = NotchLayout(screen: entry.screen, stackIndex: counts[display, default: 0])
            counts[display, default: 0] += 1
            let isLast = visible.last(where: { queue.items[$0]?.displayID == display }) == id
            let waiting = isLast ? queue.order.filter {
                queue.items[$0]?.displayID == display && !visible.contains($0)
            }.count : 0
            if let presentation = entry.presentation {
                let changedLayout = presentation.hosting.rootView.layout != layout
                presentation.hosting.rootView = makeView(id: id, layout: layout,
                    controller: presentation.controller, queuedCount: waiting)
                if changedLayout {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = presentation.controller.reduceMotion ? 0 : 0.22
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        presentation.panel.animator().setFrame(layout.panelFrame, display: true)
                    }
                }
            } else {
                let presentation = makePresentation(id: id, layout: layout, queuedCount: waiting)
                entries[id]?.presentation = presentation
            }
        }
        refreshCountdowns()
    }
}
