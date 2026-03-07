import SwiftUI
import QuickLookThumbnailing

// MARK: - Group Grid View

struct GroupGridView: View {
    @ObservedObject var state: AppState

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: state.thumbnailSize, maximum: state.thumbnailSize * 1.3), spacing: 12)]
    }

    var body: some View {
        ZStack {
            if state.isScanning {
                VStack(spacing: 16) {
                    if state.scanProgress > 0 {
                        // Vision Neural Engine progress
                        VStack(spacing: 10) {
                            Text("Analyzing images...")
                                .font(.headline)
                            ProgressView(value: state.scanProgress)
                                .frame(maxWidth: 300)
                            Text(state.progressMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.0f%%", state.scanProgress * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Scanning folder...")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                            GroupCardView(group: group, groupIndex: index, state: state, size: state.thumbnailSize)
                                .onTapGesture {
                                    state.openPreview(groupIndex: index)
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("All Groups")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ThumbnailSizeSlider(thumbnailSize: $state.thumbnailSize)
            }
        }
    }
}

// MARK: - Group Card

struct GroupCardView: View {
    let group: ImageGroup
    let groupIndex: Int
    @ObservedObject var state: AppState
    var size: CGFloat = 200

    private var thumbHeight: CGFloat { size * 0.75 }

    @State private var thumbnail: NSImage? = nil
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: thumbHeight)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: size, height: thumbHeight)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                .cornerRadius(8)

                // Badges
                VStack(alignment: .trailing, spacing: 4) {
                    // Shot count badge
                    if group.displaySlots.count > 1 {
                        Text("\(group.displaySlots.count)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.85))
                            .cornerRadius(8)
                    }
                    // Marked badge
                    if group.markedSlotCount > 0 {
                        Text("🗑 \(group.markedSlotCount)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(8)
                    }
                }
                .padding(6)
            }
            .frame(width: size, height: thumbHeight)

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(group.groupLabel.hasPrefix("No Similar") ? group.groupLabel : "Group \(groupIndex)")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack {
                    Spacer()
                    Text(formatBytes(group.totalSize))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .frame(width: size)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.15 : 0.07), radius: isHovered ? 6 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(group.markedSlotCount > 0 ? Color.red.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .task(id: group.thumbnailFile.url) {
            // QLThumbnailGenerator: hardware-accelerated via Apple Silicon media engine
            thumbnail = await ImageProcessor.loadThumbnail(url: group.thumbnailFile.url, size: 300)
        }
    }
}

// loadThumbnail is now handled by ImageProcessor.loadThumbnail (QLThumbnailGenerator + Metal)

// MARK: - Group Detail View (shown when a group is selected in sidebar)

struct GroupDetailView: View {
    @ObservedObject var state: AppState
    let groupIndex: Int

    private var group: ImageGroup { state.groups[groupIndex] }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: state.thumbnailSize, maximum: state.thumbnailSize * 1.3), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(group.displaySlots) { slot in
                    GroupDetailCard(slot: slot, size: state.thumbnailSize) {
                        state.openPreview(groupIndex: groupIndex, fileIndex: slot.fileIndex)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(group.groupLabel.hasPrefix("No Similar") ? group.groupLabel : "Group \(groupIndex)")
        .navigationSubtitle("\(group.displaySlots.count) photos  ·  \(formatBytes(group.totalSize))")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if groupIndex > 0 { state.selectedGroupIndex = groupIndex - 1 }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(groupIndex == 0)
                .help("Previous group")

                Button {
                    if groupIndex + 1 < state.groups.count { state.selectedGroupIndex = groupIndex + 1 }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(groupIndex + 1 >= state.groups.count)
                .help("Next group")
            }

            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        state.markAll(groupIndex: groupIndex)
                    } label: {
                        Label("Mark All", systemImage: "trash.fill")
                    }
                    .help("Mark all photos in this group for deletion")
                    .disabled(group.markedSlotCount == group.displaySlots.count)

                    Button {
                        state.clearAllMarks(groupIndex: groupIndex)
                    } label: {
                        Label("Clear All", systemImage: "xmark.circle")
                    }
                    .help("Clear all delete marks")
                    .disabled(group.markedCount == 0)
                }
            }

            ToolbarItem(placement: .automatic) {
                ThumbnailSizeSlider(thumbnailSize: $state.thumbnailSize)
            }
        }
    }
}

struct GroupDetailCard: View {
    let slot: DisplaySlot
    var size: CGFloat = 160
    let onTap: () -> Void

    private var thumbHeight: CGFloat { size * 0.75 }

    @State private var thumb: NSImage? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .center) {
                // Thumbnail
                Group {
                    if let img = thumb {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                            .overlay(Image(systemName: "photo").font(.title).foregroundColor(.secondary))
                    }
                }
                .frame(width: size, height: thumbHeight)
                .clipped()
                .cornerRadius(8)

                // Marked overlay
                if slot.isMarked {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                        .frame(width: size, height: thumbHeight)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.white)
                        .shadow(radius: 4)
                }

                // Extension badge (top-right)
                VStack {
                    HStack {
                        Spacer()
                        Text(slot.extLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(4)
                            .padding(5)
                    }
                    Spacer()
                }
                .frame(width: size, height: thumbHeight)
            }
            .frame(width: size, height: thumbHeight)

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.primaryFile.stem)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes(slot.allFiles.reduce(0) { $0 + $1.fileSize }))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 5 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(slot.isMarked ? Color.red.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
        .task(id: slot.primaryFile.url) {
            thumb = await ImageProcessor.loadThumbnail(url: slot.primaryFile.url, size: 320)
        }
    }
}

// MARK: - All Photos View

struct AllPhotosView: View {
    @ObservedObject var state: AppState

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: state.thumbnailSize, maximum: state.thumbnailSize * 1.3), spacing: 16)]
    }

    /// All display slots across all groups, sorted by filename
    private var allEntries: [(groupIndex: Int, slot: DisplaySlot)] {
        state.groups.enumerated().flatMap { (gi, group) in
            group.displaySlots.map { (groupIndex: gi, slot: $0) }
        }.sorted { $0.slot.primaryFile.filename.localizedStandardCompare($1.slot.primaryFile.filename) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(allEntries, id: \.slot.id) { entry in
                    GroupDetailCard(slot: entry.slot, size: state.thumbnailSize) {
                        state.openPreview(groupIndex: entry.groupIndex, fileIndex: entry.slot.fileIndex)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("All Photos")
        .navigationSubtitle("\(allEntries.count) photos")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ThumbnailSizeSlider(thumbnailSize: $state.thumbnailSize)
            }
        }
    }
}

// MARK: - Shared Thumbnail Size Slider

struct ThumbnailSizeSlider: View {
    @Binding var thumbnailSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Slider(value: $thumbnailSize, in: 120...320, step: 10)
                .frame(width: 130)
                .controlSize(.small)
                .help("Adjust thumbnail size (\(Int(thumbnailSize)) px)")
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
