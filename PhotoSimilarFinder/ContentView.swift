import SwiftUI
import AppKit

// MARK: - Singleton preview window controller

private class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private var _previewWindowController: NSWindowController?
private var _previewWindowDelegate: PreviewWindowDelegate?

func openPreviewWindow(state: AppState, groupIndex: Int) {
    // Reuse existing window if possible — PreviewView is state-driven via effectiveGroupIndex.
    // showWindow(_:) reopens a previously closed window without recreating it.
    if let wc = _previewWindowController, let win = wc.window {
        if win.isMiniaturized { win.deminiaturize(nil) }
        wc.showWindow(nil)
        win.makeKeyAndOrderFront(nil)
        return
    }

    let win = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    win.title = "Preview"
    win.minSize = NSSize(width: 700, height: 500)
    win.center()
    win.collectionBehavior = [.fullScreenPrimary]

    // Sync state when user closes via the red X button, so re-opening the same group works.
    let delegate = PreviewWindowDelegate {
        Task { @MainActor in state.previewGroupIndex = nil }
    }
    win.delegate = delegate
    _previewWindowDelegate = delegate

    // Pass a close action so Esc inside PreviewView closes the actual NSWindow
    // (which in turn fires the delegate above).
    let closeAction = { [weak win] in win?.close() as Void? ; () }
    win.contentView = NSHostingView(rootView: PreviewView(state: state, groupIndex: groupIndex, closeAction: closeAction))
    let wc = NSWindowController(window: win)
    _previewWindowController = wc
    wc.showWindow(nil)
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } detail: {
            if state.groups.isEmpty && !state.isScanning {
                EmptyStateView(state: state)
            } else if state.showAllPhotos {
                AllPhotosView(state: state)
            } else if let idx = state.selectedGroupIndex, idx < state.groups.count {
                GroupDetailView(state: state, groupIndex: idx)
            } else {
                GroupGridView(state: state)
            }
        }
        .alert("Confirm Delete", isPresented: $state.showDeleteConfirm) {
            Button("Move to Trash", role: .destructive) {
                state.deleteMarkedFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(state.totalMarked) photo(s) (\(formatBytes(state.totalMarkedSize))) to Trash")
        }
        .alert("Error", isPresented: Binding(
            get: { state.scanError != nil },
            set: { if !$0 { state.scanError = nil } }
        )) {
            Button("OK") { state.scanError = nil }
        } message: {
            Text(state.scanError ?? "")
        }
        .onChange(of: state.previewGroupIndex) { _, newIdx in
            if let idx = newIdx {
                openPreviewWindow(state: state, groupIndex: idx)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Photo Similar Finder")
                    .font(.headline)
                    .foregroundColor(.primary)

                Button(action: state.chooseFolder) {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isScanning)

                if let folder = state.scanFolder {
                    Text(folder.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            // Group list
            if !state.groups.isEmpty {
                // "All Photos" row — shows every photo in the folder
                Button {
                    state.showAllPhotos = true
                    state.selectedGroupIndex = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.fill.on.rectangle.fill")
                            .font(.system(size: 20))
                            .frame(width: 52, height: 52)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(6)
                            .foregroundColor(.purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All Photos")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(state.totalShots) photos")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(state.showAllPhotos ? Color.purple.opacity(0.2) : Color.clear)
                )
                .padding(.horizontal, 6)
                .padding(.top, 4)

                // "All Groups" row — shows the group overview grid
                Button {
                    state.selectedGroupIndex = nil
                    state.showAllPhotos = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 20))
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(6)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All Groups")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(state.groups.count) groups · \(state.totalShots) photos")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(!state.showAllPhotos && state.selectedGroupIndex == nil ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .padding(.horizontal, 6)

                // "No Similar Matches" row — shown at same level as All Groups if present
                if let ungroupedIndex = state.groups.indices.first(where: { state.groups[$0].groupLabel.hasPrefix("No Similar") }) {
                    let ungrouped = state.groups[ungroupedIndex]
                    Button {
                        state.showAllPhotos = false
                        state.selectedGroupIndex = ungroupedIndex
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.badge.checkmark")
                                .font(.system(size: 20))
                                .frame(width: 52, height: 52)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("No Similar Matches")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(ungrouped.displaySlots.count) photos")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(state.selectedGroupIndex == ungroupedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .padding(.horizontal, 6)
                }

                GroupListView(state: state)
            } else if state.isScanning {
                scanProgressView
            }

            Spacer(minLength: 0)

            // Stats + Delete
            if !state.groups.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    HStack {
                        Label("\(state.groups.count) groups", systemImage: "photo.stack")
                        Spacer()
                        Label("\(state.totalShots) photos", systemImage: "photo")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    if state.totalMarked > 0 {
                        Button(role: .destructive) {
                            state.showDeleteConfirm = true
                        } label: {
                            Label("Delete \(state.totalMarked) photo(s) (\(formatBytes(state.totalMarkedSize)))",
                                  systemImage: "trash.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 220, maxWidth: 260)
    }

    private var scanProgressView: some View {
        VStack(spacing: 10) {
            if state.scanProgress > 0 {
                ProgressView(value: state.scanProgress)
                    .padding(.horizontal)
                Text(state.progressMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Scanning...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Group List in Sidebar

struct GroupListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.selectedGroupIndex },
            set: { state.selectedGroupIndex = $0; if $0 != nil { state.showAllPhotos = false } }
        )) {
            ForEach(Array(state.groups.enumerated()), id: \.offset) { index, group in
                if !group.groupLabel.hasPrefix("No Similar") {
                    GroupListRow(group: group, index: index)
                        .tag(index)
                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                        .onTapGesture(count: 1) {
                            state.showAllPhotos = false
                            state.selectedGroupIndex = index
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                state.openPreview(groupIndex: index)
                            }
                        )
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct GroupListRow: View {
    let group: ImageGroup
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            // Cover thumbnail
            GroupRowThumb(file: group.thumbnailFile)
                .frame(width: 52, height: 52)
                .cornerRadius(6)
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(group.groupLabel.hasPrefix("No Similar") ? group.groupLabel : "Group \(index)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if group.markedSlotCount > 0 {
                    Text("🗑 \(group.markedSlotCount) / \(group.displaySlots.count) photos")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                } else {
                    Text("\(group.displaySlots.count) photos")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct GroupRowThumb: View {
    let file: ImageFile
    @State private var thumb: NSImage? = nil

    var body: some View {
        Group {
            if let img = thumb {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
                    .overlay(Image(systemName: "photo").font(.caption).foregroundColor(.secondary))
            }
        }
        .task(id: file.url) {
            thumb = await ImageProcessor.loadThumbnail(url: file.url, size: 80)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Select a Photo Folder")
                .font(.title2)
            Text("The app will group similar photos or burst shots\nso you can choose which ones to delete.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button(action: state.chooseFolder) {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Supported formats note
            VStack(alignment: .leading, spacing: 4) {
                Text("Supported: JPG, HEIC, PNG, TIFF, RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF and more)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
