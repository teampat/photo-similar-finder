import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var groups: [ImageGroup] = []
    @Published var selectedGroupIndex: Int? = nil
    @Published var selectedFileIndex: Int = 0
    @Published var isScanning: Bool = false
    @Published var scanFolder: URL? = nil
    @Published var scanError: String? = nil
    @Published var showDeleteConfirm: Bool = false

    /// Scan progress 0…1
    @Published var scanProgress: Double = 0
    @Published var progressMessage: String = ""

    // Preview panel
    @Published var previewGroupIndex: Int? = nil
    @Published var previewFileIndex: Int = 0

    // Grid thumbnail size (shared across all grid views)
    @Published var thumbnailSize: CGFloat = 200

    // Navigation state for All Photos view
    @Published var showAllPhotos: Bool = true

    /// Number of photos (unique stems) marked for deletion.
    /// 1 JPG + 1 CR3 with the same name = 1 photo
    var totalMarked: Int {
        groups.flatMap(\.displaySlots).filter(\.isMarked).count
    }

    /// Total size of all files that are marked (counts every physical file).
    var totalMarkedSize: Int64 {
        groups.flatMap(\.files).filter(\.isMarkedForDelete).reduce(0) { $0 + $1.fileSize }
    }

    /// Total number of photos (unique stems) across all groups.
    var totalShots: Int {
        groups.reduce(0) { $0 + $1.displaySlots.count }
    }

    // MARK: - Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a photo folder from your camera"
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            scanFolder = url
            startScan(url: url)
        }
    }

    func startScan(url: URL) {
        isScanning = true
        scanError = nil
        scanProgress = 0
        progressMessage = ""
        groups = []
        selectedGroupIndex = nil
        previewGroupIndex = nil

        Task {
            // Always use Vision Neural Engine for perceptual similarity
            let result = await ImageScanner.scanWithVision(folder: url) { [weak self] pct, msg in
                guard let self else { return }
                await MainActor.run {
                    self.scanProgress = pct
                    self.progressMessage = msg
                }
            }
            groups = result
            isScanning = false
            scanProgress = 0
            progressMessage = ""
            if groups.isEmpty {
                scanError = "ไม่พบไฟล์รูปภาพที่รองรับในโฟลเดอร์นี้"
            }
        }
    }

    // MARK: - Mark for Delete

    func toggleMarkForDelete(groupIndex: Int, fileIndex: Int) {
        guard groupIndex < groups.count, fileIndex < groups[groupIndex].files.count else { return }

        let tappedFile = groups[groupIndex].files[fileIndex]
        let newValue = !tappedFile.isMarkedForDelete

        // If the group contains a JPG+RAW pair with the same stem, mark both together
        let sameStemIndices = groups[groupIndex].files.indices.filter {
            groups[groupIndex].files[$0].stem == tappedFile.stem
        }

        for idx in sameStemIndices {
            groups[groupIndex].files[idx].isMarkedForDelete = newValue
        }
    }

    func toggleMarkCurrentPreview() {
        guard let gi = previewGroupIndex else { return }
        toggleMarkForDelete(groupIndex: gi, fileIndex: previewFileIndex)
    }

    /// Marks every photo in a group for deletion.
    func markAll(groupIndex: Int) {
        guard groupIndex < groups.count else { return }
        for idx in groups[groupIndex].files.indices {
            groups[groupIndex].files[idx].isMarkedForDelete = true
        }
    }

    /// Clears all delete marks in a group.
    func clearAllMarks(groupIndex: Int) {
        guard groupIndex < groups.count else { return }
        for idx in groups[groupIndex].files.indices {
            groups[groupIndex].files[idx].isMarkedForDelete = false
        }
    }

    /// Keeps the first display slot (index 0), marks all others for deletion.
    func keepFirstDeleteRest(groupIndex: Int) {
        guard groupIndex < groups.count else { return }
        let slots = groups[groupIndex].displaySlots
        guard slots.count >= 2 else { return }
        let keepStem = slots[0].primaryFile.stem
        for idx in groups[groupIndex].files.indices {
            groups[groupIndex].files[idx].isMarkedForDelete =
                (groups[groupIndex].files[idx].stem != keepStem)
        }
    }

    // MARK: - Preview Navigation

    func openPreview(groupIndex: Int, fileIndex: Int = 0) {
        previewGroupIndex = groupIndex
        previewFileIndex = fileIndex
    }

    func closePreview() {
        previewGroupIndex = nil
    }

    func previewNext() {
        guard let gi = previewGroupIndex else { return }
        let count = groups[gi].files.count
        previewFileIndex = (previewFileIndex + 1) % count
    }

    func previewPrev() {
        guard let gi = previewGroupIndex else { return }
        let count = groups[gi].files.count
        previewFileIndex = (previewFileIndex - 1 + count) % count
    }

    func nextGroup() {
        guard let gi = previewGroupIndex else { return }
        if gi + 1 < groups.count {
            previewGroupIndex = gi + 1
            previewFileIndex = 0
        }
    }

    func prevGroup() {
        guard let gi = previewGroupIndex else { return }
        if gi - 1 >= 0 {
            previewGroupIndex = gi - 1
            previewFileIndex = 0
        }
    }

    // MARK: - Delete

    func deleteMarkedFiles() {
        var newGroups: [ImageGroup] = []
        var errors: [String] = []

        for group in groups {
            var remaining: [ImageFile] = []
            for file in group.files {
                if file.isMarkedForDelete {
                    do {
                        try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    } catch {
                        errors.append(file.filename + ": " + error.localizedDescription)
                        remaining.append(file) // keep if trash failed
                    }
                } else {
                    remaining.append(file)
                }
            }
            if !remaining.isEmpty {
                var updated = group
                updated.files = remaining
                newGroups.append(updated)
            }
        }

        groups = newGroups
        if let gi = previewGroupIndex, gi >= groups.count {
            previewGroupIndex = groups.isEmpty ? nil : groups.count - 1
            previewFileIndex = 0
        }

        if !errors.isEmpty {
            scanError = "ลบไม่ได้บางไฟล์:\n" + errors.joined(separator: "\n")
        }
    }
}
