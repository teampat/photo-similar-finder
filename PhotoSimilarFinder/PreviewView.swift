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
            // Top toolbar
            HStack(spacing: 12) {
                Spacer()

                if let group = group {
                    VStack(spacing: 2) {
                        Text(group.groupLabel)
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text("Group \(effectiveGroupIndex + 1) / \(state.groups.count)")
                            Text("·")
                            Text("Photo \(currentSlotIndex + 1) / \(displaySlots.count)")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Bulk actions for current group
                Button {
                    state.markAll(groupIndex: effectiveGroupIndex)
                } label: {
                    Label("Mark All", systemImage: "trash.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(group?.markedSlotCount == group?.displaySlots.count)

                Button {
                    state.clearAllMarks(groupIndex: effectiveGroupIndex)
                } label: {
                    Label("Clear All", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(group?.markedCount == 0)

                Divider().frame(height: 20)

                // Mark for delete button
                Button {
                    state.toggleMarkCurrentPreview()
                } label: {
                    Label(isCurrentMarked ? "Unmark (D)" : "Mark Delete (D)",
                          systemImage: isCurrentMarked ? "trash.slash.fill" : "trash.fill")
                        .foregroundColor(isCurrentMarked ? .orange : .red)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main content: image + film strip
            VStack(spacing: 0) {
                // Full-size image
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
                            .padding(8)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("Could not load image")
                                .foregroundColor(.gray)
                        }
                    }

                    // Delete indicator
                    if isCurrentMarked {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.red)
                                    .shadow(color: .black.opacity(0.5), radius: 6)
                                    .padding(16)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Film strip — one thumb per slot (JPG+RAW pair shown as one)
                if !displaySlots.isEmpty {
                    Divider()
                    FilmStripView(state: state,
                                  groupIndex: effectiveGroupIndex,
                                  currentSlotIndex: currentSlotIndex) { idx in
                        let slots = state.groups[safe: effectiveGroupIndex]?.displaySlots ?? []
                        if idx < slots.count {
                            state.previewFileIndex = slots[idx].fileIndex
                        }
                    }
                    .frame(height: 90)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }

            Divider()

            // Bottom info bar
            if let file = currentFile {
                FileInfoBar(file: file, slot: currentSlot, state: state, groupIndex: effectiveGroupIndex)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .focusable()
        .focused($isFocused)
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
            // Only reset to first slot if no valid fileIndex was pre-selected
            let validSlot = displaySlots.contains(where: { $0.fileIndex == state.previewFileIndex })
            if !validSlot, let first = displaySlots.first {
                state.previewFileIndex = first.fileIndex
            }
        }
        .task(id: "\(groupIndex)-\(state.previewFileIndex)") {
            await loadCurrentImage()
        }
        .onChange(of: state.previewGroupIndex) { _, _ in
            if let first = displaySlots.first {
                state.previewFileIndex = first.fileIndex
            }
            Task { await loadCurrentImage() }
        }
    }

    private func navigateSlot(by delta: Int) {
        let slots = displaySlots
        let next = currentSlotIndex + delta
        guard next >= 0 && next < slots.count else { return }
        state.previewFileIndex = slots[next].fileIndex
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
                        isMarked ? Color.red : (isSelected ? Color.blue : Color.clear),
                        lineWidth: (isSelected || isMarked) ? 3 : 2
                    )
            )

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

// MARK: - File Info Bar

struct FileInfoBar: View {
    let file: ImageFile
    let slot: DisplaySlot?
    @ObservedObject var state: AppState
    let groupIndex: Int

    var body: some View {
        HStack(spacing: 16) {
            // Navigation hint
            HStack(spacing: 6) {
                KeyHintView(key: "←→", label: "Files in group")
                KeyHintView(key: "↑↓", label: "Next group")
                KeyHintView(key: "D", label: "Mark/Unmark")
                KeyHintView(key: "Esc", label: "Close")
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                // Show all paired filenames joined with + (e.g. IMG_5915.JPG+IMG_5915.CR3)
                let allFiles = slot?.allFiles ?? [file]
                Text(allFiles.map(\.filename).joined(separator: "+"))
                    .font(.caption.bold())
                HStack(spacing: 8) {
                    Text(formatBytes(allFiles.reduce(0) { $0 + $1.fileSize }))
                    if let date = file.creationDate {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct KeyHintView: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Safe subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
