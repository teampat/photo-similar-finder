import SwiftUI
import CoreImage
import Metal

// MARK: - Preview View (Full-size image viewer)

struct PreviewView: View {
    @ObservedObject var state: AppState
    let groupIndex: Int
    let closeAction: () -> Void

    @State private var fullImage: NSImage? = nil
    @State private var isLoadingImage: Bool = false
    @FocusState private var isFocused: Bool

    // Zoom & pan
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var imageAreaFrame: CGRect = .zero   // screen-coords, updated by background NSView
    @State private var scrollMonitor: Any? = nil
    // Gesture accumulators (pinch & drag)
    @State private var gestureBaseScale: CGFloat = 1.0
    @State private var gestureBaseOffset: CGSize = .zero

    /// Tracks the group actually shown — follows state.previewGroupIndex so ↑↓ navigation works.
    private var effectiveGroupIndex: Int { state.previewGroupIndex ?? groupIndex }

    private var group: ImageGroup? {
        guard effectiveGroupIndex < state.groups.count else { return nil }
        return state.groups[effectiveGroupIndex]
    }

    /// One slot per unique stem; primary file is JPEG (or first non-RAW, or first file)
    private var displaySlots: [DisplaySlot] { group?.displaySlots ?? [] }

    /// Index into `displaySlots` that contains the currently selected file
    private var currentSlotIndex: Int {
        let currentID = group?.files[safe: state.previewFileIndex]?.id
        return displaySlots.firstIndex(where: { slot in
            slot.allFiles.contains(where: { $0.id == currentID })
        }) ?? 0
    }

    private var currentSlot: DisplaySlot? { displaySlots[safe: currentSlotIndex] }

    private var currentFile: ImageFile? { currentSlot?.primaryFile }

    private var isCurrentMarked: Bool { currentSlot?.isMarked ?? false }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ───────────────────────────────────────────────
            HStack(spacing: 10) {
                // Group navigation (left)
                HStack(spacing: 2) {
                    Button { state.prevGroup() } label: {
                        Image(systemName: "chevron.up").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Previous group (↑)")

                    VStack(spacing: 0) {
                        Text("GROUP")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.7))
                        Text("\(effectiveGroupIndex + 1)/\(state.groups.count)")
                            .font(.caption.monospacedDigit().bold())
                    }

                    Button { state.nextGroup() } label: {
                        Image(systemName: "chevron.down").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Next group (↓)")
                }

                Divider().frame(height: 20)

                Spacer()

                // Filename + photo counter (center)
                VStack(spacing: 2) {
                    Text(currentFile?.stem ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    if displaySlots.count > 1 {
                        Text("\(currentSlotIndex + 1) / \(displaySlots.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer()

                // Zoom controls
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { adjustZoom(by: 1 / 1.4) }
                    } label: {
                        Image(systemName: "minus").frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(zoomScale <= 1.0)
                    .keyboardShortcut("-", modifiers: .command)

                    Button {
                        withAnimation(.spring(duration: 0.2)) { resetZoom() }
                    } label: {
                        Text("\(Int(zoomScale * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 40)
                    }
                    .buttonStyle(.borderless)
                    .help("Reset zoom · Double-click image")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { adjustZoom(by: 1.4) }
                    } label: {
                        Image(systemName: "plus").frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("=", modifiers: .command)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                Divider().frame(height: 20)

                // Mark / unmark (main CTA)
                Button {
                    state.toggleMarkCurrentPreview()
                } label: {
                    Label(
                        isCurrentMarked ? "Unmark" : "Mark Delete",
                        systemImage: isCurrentMarked ? "trash.slash" : "trash"
                    )
                    .foregroundColor(isCurrentMarked ? .orange : .red)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: [])
                .help(isCurrentMarked ? "Unmark photo (D)" : "Mark for deletion (D)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Image ───────────────────────────────────────────────
            ZStack {
                Color.black

                if isLoadingImage {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                } else if let img = fullImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoomScale)
                        .offset(panOffset)
                        // Pinch to zoom (toward view center)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let raw = gestureBaseScale * value
                                    zoomScale = raw.clamped(to: 1.0...15.0)
                                }
                                .onEnded { _ in
                                    gestureBaseScale = zoomScale
                                panOffset = clampedOffset(panOffset, scale: zoomScale, viewSize: imageAreaFrame.size)
                                    gestureBaseOffset = panOffset
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    guard zoomScale > 1.01 else { return }
                                    let raw = CGSize(
                                        width:  gestureBaseOffset.width  + value.translation.width,
                                        height: gestureBaseOffset.height + value.translation.height
                                    )
                                    panOffset = clampedOffset(raw, scale: zoomScale, viewSize: imageAreaFrame.size)
                                }
                                .onEnded { _ in gestureBaseOffset = panOffset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(duration: 0.25)) {
                                if zoomScale > 1.01 { resetZoom() }
                                else {
                                    let c = CGPoint(x: imageAreaFrame.width / 2, y: imageAreaFrame.height / 2)
                                    zoomToPoint(newScale: 3.0, screenPoint: c, viewSize: imageAreaFrame.size)
                                }
                            }
                        }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo").font(.system(size: 48)).foregroundColor(.gray)
                        Text("Could not load image").foregroundColor(.gray)
                    }
                }

                // “Marked for deletion” pill overlay at top
                if isCurrentMarked {
                    VStack {
                        Label("Marked for deletion", systemImage: "trash.fill")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.9), in: Capsule())
                            .padding(.top, 14)
                        Spacer()
                    }
                }

                // Photo navigation arrows (hidden when zoomed in)
                if displaySlots.count > 1 && zoomScale <= 1.01 {
                    HStack {
                        Button { navigateSlot(by: -1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 56)
                                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .opacity(currentSlotIndex > 0 ? 1 : 0.15)
                        .padding(.leading, 12)

                        Spacer()

                        Button { navigateSlot(by: +1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 56)
                                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .opacity(currentSlotIndex < displaySlots.count - 1 ? 1 : 0.15)
                        .padding(.trailing, 12)
                    }
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(ImageAreaFrameReader { imageAreaFrame = $0 })

            // ── Film strip ───────────────────────────────────────────
            if !displaySlots.isEmpty {
                Divider()
                FilmStripView(
                    state: state,
                    groupIndex: effectiveGroupIndex,
                    currentSlotIndex: currentSlotIndex
                ) { idx in
                    let slots = state.groups[safe: effectiveGroupIndex]?.displaySlots ?? []
                    if idx < slots.count {
                        state.previewFileIndex = slots[idx].fileIndex
                    }
                }
                .frame(height: 92)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // ── Bottom info bar ──────────────────────────────────────
            if let file = currentFile {
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        let allFiles = currentSlot?.allFiles ?? [file]
                        Text(allFiles.map(\.filename).joined(separator: " + "))
                            .font(.caption.bold())
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(formatBytes(allFiles.reduce(0) { $0 + $1.fileSize }))
                            if let date = file.creationDate {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let group = group {
                        Button { state.clearAllMarks(groupIndex: effectiveGroupIndex) } label: {
                            Text("Clear All").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .disabled(group.markedCount == 0)

                        Button { state.markAll(groupIndex: effectiveGroupIndex) } label: {
                            Text("Mark All").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .disabled(group.markedSlotCount == group.displaySlots.count)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            if let win = NSApp.keyWindow, win.styleMask.contains(.fullScreen) {
                win.toggleFullScreen(nil)
            } else {
                closeAction()
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigateSlot(by: -1); return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateSlot(by: +1); return .handled
        }
        .onKeyPress(.upArrow) {
            state.prevGroup(); return .handled
        }
        .onKeyPress(.downArrow) {
            state.nextGroup(); return .handled
        }
        .onKeyPress("d") {
            state.toggleMarkCurrentPreview()
            return .handled
        }
        .onAppear {
            isFocused = true
            setupScrollMonitor()
            let validSlot = displaySlots.contains(where: { $0.fileIndex == state.previewFileIndex })
            if !validSlot, let first = displaySlots.first {
                state.previewFileIndex = first.fileIndex
            }
        }
        .onDisappear {
            teardownScrollMonitor()
        }
        .task(id: "\(groupIndex)-\(state.previewFileIndex)") {
            resetZoom()
            await loadCurrentImage()
        }
        .onChange(of: state.previewGroupIndex) { _, _ in
            if let first = displaySlots.first {
                state.previewFileIndex = first.fileIndex
            }
            resetZoom()
            Task { await loadCurrentImage() }
        }
    }

    private func navigateSlot(by delta: Int) {
        let slots = displaySlots
        let next = currentSlotIndex + delta
        guard next >= 0 && next < slots.count else { return }
        state.previewFileIndex = slots[next].fileIndex
    }

    private func resetZoom() {
        zoomScale = 1.0
        panOffset = .zero
        gestureBaseScale = 1.0
        gestureBaseOffset = .zero
    }

    private func adjustZoom(by factor: CGFloat) {
        let newScale = (zoomScale * factor).clamped(to: 1.0...15.0)
        withAnimation(.easeInOut(duration: 0.15)) {
            let center = CGPoint(x: imageAreaFrame.width / 2, y: imageAreaFrame.height / 2)
            zoomToPoint(newScale: newScale, screenPoint: center, viewSize: imageAreaFrame.size)
        }
    }

    /// Zoom to `newScale` keeping the screen point `screenPoint` stationary.
    private func zoomToPoint(newScale: CGFloat, screenPoint: CGPoint, viewSize: CGSize) {
        guard newScale != zoomScale else { return }
        let cx = viewSize.width / 2
        let cy = viewSize.height / 2
        let fx = screenPoint.x - cx
        let fy = screenPoint.y - cy
        let ratio = newScale / zoomScale
        let raw = CGSize(
            width:  fx * (1 - ratio) + panOffset.width  * ratio,
            height: fy * (1 - ratio) + panOffset.height * ratio
        )
        zoomScale = newScale
        gestureBaseScale = newScale
        panOffset = clampedOffset(raw, scale: newScale, viewSize: viewSize)
        gestureBaseOffset = panOffset
    }

    /// Clamp pan so the image stays at least partially in view.
    private func clampedOffset(_ offset: CGSize, scale: CGFloat, viewSize: CGSize) -> CGSize {
        guard scale > 1.0, viewSize != .zero else { return .zero }
        let maxX = viewSize.width  * (scale - 1) / 2
        let maxY = viewSize.height * (scale - 1) / 2
        return CGSize(
            width:  offset.width.clamped(to: -maxX...maxX),
            height: offset.height.clamped(to: -maxY...maxY)
        )
    }

    private func setupScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let mouseLoc = NSEvent.mouseLocation
            // Only handle scroll events over the image area
            guard self.imageAreaFrame.contains(mouseLoc) else { return event }

            let delta: CGFloat = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.deltaY * 8
            guard abs(delta) > 0.5 else { return event }

            // Convert screen point (bottom-left origin) to SwiftUI view coords (top-left origin)
            let relX = mouseLoc.x - self.imageAreaFrame.minX
            let relY = self.imageAreaFrame.maxY - mouseLoc.y
            let pt = CGPoint(x: relX, y: relY)

            let step: CGFloat = 0.07
            let factor: CGFloat = delta > 0
                ? 1.0 + min(abs(delta) * step, 0.4)
                : 1.0 / (1.0 + min(abs(delta) * step, 0.4))
            let newScale = (self.zoomScale * factor).clamped(to: 1.0...15.0)
            guard newScale != self.zoomScale else { return nil }

            // Direct state update — no animation, trackpad momentum gives natural easing
            self.zoomToPoint(newScale: newScale, screenPoint: pt, viewSize: self.imageAreaFrame.size)
            return nil  // consume — prevent window scroll
        }
    }

    private func teardownScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
    }

    private func loadCurrentImage() async {
        guard let file = currentFile else { return }
        isLoadingImage = true
        fullImage = nil
        // CIImage → Metal GPU pipeline: hardware RAW/HEIC decoder on Apple Silicon
        let img = await ImageProcessor.loadFullImage(url: file.url, maxDimension: 2400)
        isLoadingImage = false
        fullImage = img
    }
}

// MARK: - Film Strip

struct FilmStripView: View {
    @ObservedObject var state: AppState
    let groupIndex: Int
    let currentSlotIndex: Int
    let onSelect: (Int) -> Void

    private var slots: [DisplaySlot] {
        state.groups[safe: groupIndex]?.displaySlots ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
                        FilmStripThumb(state: state, groupIndex: groupIndex, slotIndex: idx, isSelected: currentSlotIndex == idx)
                            .id(idx)
                            .onTapGesture { onSelect(idx) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: currentSlotIndex) { _, newIdx in
                withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
            }
        }
    }
}

struct FilmStripThumb: View {
    @ObservedObject var state: AppState
    let groupIndex: Int
    let slotIndex: Int
    let isSelected: Bool

    @State private var thumb: NSImage? = nil

    private var slot: DisplaySlot? {
        state.groups[safe: groupIndex]?.displaySlots[safe: slotIndex]
    }

    private var isMarked: Bool { slot?.isMarked ?? false }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = thumb {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 70, height: 70)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 70, height: 70)
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.white : (isMarked ? Color.red : Color.clear),
                        lineWidth: (isSelected || isMarked) ? 3 : 2
                    )
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.8) : .clear, radius: 6)

            // Delete indicator
            if isMarked {
                Image(systemName: "trash.fill")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.red)
                    .cornerRadius(4)
                    .padding(3)
            }

            // Extension label — shows "JPG+CR3" for paired files
            VStack {
                HStack {
                    Spacer()
                    Text(slot?.extLabel ?? "")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(3)
                        .padding(3)
                }
                Spacer()
            }
        }
        .frame(width: 70, height: 70)
        .task(id: slot?.primaryFile.url) {
            guard let url = slot?.primaryFile.url else { return }
            thumb = await ImageProcessor.loadThumbnail(url: url, size: 140)
        }
    }
}

// MARK: - Image area frame tracker
// Placed as .background — reports the image container's screen frame to
// the scroll-wheel zoom monitor so focal-point zooming stays accurate.

private struct ImageAreaFrameReader: NSViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameNSView { FrameNSView(onFrame: onFrame) }
    func updateNSView(_ v: FrameNSView, context: Context) { v.onFrame = onFrame }

    class FrameNSView: NSView {
        var onFrame: (CGRect) -> Void
        init(onFrame: @escaping (CGRect) -> Void) {
            self.onFrame = onFrame; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        private func report() {
            guard let win = window else { return }
            let winFrame = convert(bounds, to: nil)
            let screenFrame = win.convertToScreen(winFrame)
            DispatchQueue.main.async { self.onFrame(screenFrame) }
        }

        override func layout() { super.layout(); report() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
    }
}

// MARK: - Safe subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Comparable clamped

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
