import Foundation
import AppKit
import Vision

// MARK: - Supported Extensions

let rawExtensions: Set<String> = [
    "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
    "dng", "raf", "orf", "rw2", "rwl", "pef", "ptx",
    "3fr", "fff", "iiq", "cap", "erf", "mef", "mos",
    "mrw", "rwz", "x3f", "srw"
]

let jpegExtensions: Set<String> = ["jpg", "jpeg"]

let otherImageExtensions: Set<String> = ["heic", "heif", "png", "tiff", "tif", "bmp", "gif", "webp"]

var allSupportedExtensions: Set<String> {
    rawExtensions.union(jpegExtensions).union(otherImageExtensions)
}

// MARK: - Models

/// Represents one physical file on disk
struct ImageFile: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
    var isMarkedForDelete: Bool = false

    var filename: String { url.lastPathComponent }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var isRaw: Bool { rawExtensions.contains(ext) }
    var isJpeg: Bool { jpegExtensions.contains(ext) }

    var fileSize: Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    var creationDate: Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A group of related images (burst shots or same filename stem)
struct ImageGroup: Identifiable {
    let id: UUID = UUID()
    var files: [ImageFile]
    var groupLabel: String
    var bestScore: Float = 0.0   // highest pairwise similarity score in the group

    var markedCount: Int { files.filter(\.isMarkedForDelete).count }
    /// Number of display slots (shots) marked — 1 JPG+RAW pair = 1 slot
    var markedSlotCount: Int { displaySlots.filter(\.isMarked).count }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.fileSize } }
    var markedSize: Int64 { files.filter(\.isMarkedForDelete).reduce(0) { $0 + $1.fileSize } }

    /// Representative thumbnail file — prefer jpeg over raw
    var thumbnailFile: ImageFile {
        files.first(where: { $0.isJpeg }) ?? files.first(where: { !$0.isRaw }) ?? files[0]
    }

    /// One slot per unique stem — JPG+RAW pairs merged into a single entry
    var displaySlots: [DisplaySlot] {
        var stemOrder: [String] = []
        var byStem: [String: [ImageFile]] = [:]
        for file in files {
            if byStem[file.stem] == nil { stemOrder.append(file.stem) }
            byStem[file.stem, default: []].append(file)
        }
        return stemOrder.compactMap { stem -> DisplaySlot? in
            guard let stemFiles = byStem[stem], let first = stemFiles.first else { return nil }
            let primary = stemFiles.first(where: { $0.isJpeg })
                ?? stemFiles.first(where: { !$0.isRaw })
                ?? first
            let idx = files.firstIndex(where: { $0.id == primary.id }) ?? 0
            return DisplaySlot(id: primary.id, primaryFile: primary, allFiles: stemFiles, fileIndex: idx)
        }
    }
}

// MARK: - Display Slot (one entry per unique stem, merges JPG+RAW pairs)

struct DisplaySlot: Identifiable {
    let id: UUID
    let primaryFile: ImageFile   // JPEG preferred — shown in viewer
    let allFiles: [ImageFile]    // all same-stem files (for delete marking)
    let fileIndex: Int           // index of primaryFile in group.files

    var isMarked: Bool { allFiles.contains(where: \.isMarkedForDelete) }

    /// e.g. "JPG" or "JPG+CR3"
    var extLabel: String {
        let exts = Set(allFiles.map { $0.ext.uppercased() }).sorted()
        return exts.joined(separator: "+")
    }
}

// MARK: - Scanner

class ImageScanner {
    /// Cosine similarity threshold — matches Python reference project's default.
    /// cosine ≥ 0.92 means the two feature vectors point in nearly the same direction.
    static let visionSimilarityThreshold: Float = 0.92

    // MARK: Scan with Vision Neural Engine

    /// Full scan using Apple Silicon Neural Engine for perceptual similarity.
    /// Progress callback: (fraction 0-1, status message)
    static func scanWithVision(
        folder: URL,
        progress: @Sendable @escaping (Double, String) async -> Void
    ) async -> [ImageGroup] {
        await progress(0.03, "Scanning for image files...")

        let files = enumerateFiles(folder: folder)
        guard !files.isEmpty else {
            await progress(1.0, "")
            return []
        }

        await progress(0.08, "Grouping by filename (\(files.count) files)...")

        // Each “shot” = one unique stem (JPG+RAW pair counted as one unit).
        // Vision runs on the JPEG representative so we avoid running it twice per shot.
        let shots = makeStemShots(files)
        let total = shots.count

        await progress(0.14, "Analyzing \(total) photos...")

        // Compute Vision feature vectors for every representative concurrently
        var fps: [[Float]?] = Array(repeating: nil, count: total)

        await withTaskGroup(of: (Int, [Float]?).self) { taskGroup in
            let concurrency = min(total, 8)
            var nextIdx = 0

            // Adds exactly ONE task — call once per slot to keep window at `concurrency`
            func enqueueOne() {
                guard nextIdx < total else { return }
                let i = nextIdx; nextIdx += 1
                let url = shots[i].rep.url
                taskGroup.addTask {
                    let fp = try? await ImageProcessor.computeFeaturePrint(url: url)
                    return (i, fp)
                }
            }

            // Seed the initial window
            for _ in 0..<concurrency { enqueueOne() }

            var done = 0
            for await (idx, fp) in taskGroup {
                fps[idx] = fp
                done += 1
                let pct = 0.14 + 0.68 * Double(done) / Double(total)
                await progress(pct, "Analyzing: \(done)/\(total)")
                enqueueOne() // replenish window as each task finishes
            }
        }

        await progress(0.85, "Clustering similar photos...")

        // Cluster shots by visual similarity (O(n²) pairwise + Union-Find)
        let (clusterIndices, clusterScores) = clusterShotsBySimilarity(count: total, fps: fps)

        await progress(0.97, "Sorting results...")

        // Build ImageGroup for each cluster with 2+ shots, sorted by best score desc
        let groups: [ImageGroup] = clusterIndices
            .enumerated()
            .compactMap { (ci, idxs) -> ImageGroup? in
                guard idxs.count >= 2 else { return nil }
                let allFiles = idxs.flatMap { shots[$0].allFiles }
                return ImageGroup(
                    files: allFiles,
                    groupLabel: allFiles[0].stem,
                    bestScore: clusterScores[ci] ?? 0
                )
            }
            .sorted { $0.bestScore > $1.bestScore }

        await progress(1.0, "")
        return groups
    }

    // MARK: - Private helpers

    static func enumerateFiles(folder: URL) -> [ImageFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [ImageFile] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard allSupportedExtensions.contains(ext) else { continue }
            files.append(ImageFile(url: fileURL))
        }
        return files
    }

    /// Returns (multi-file stem groups, leftover single-file list)
    private static func stemGroupSplit(_ files: [ImageFile]) -> ([ImageGroup], [ImageFile]) {
        var stemMap: [String: [ImageFile]] = [:]
        for file in files {
            let key = file.url.deletingPathExtension().path
            stemMap[key, default: []].append(file)
        }
        var multi: [ImageGroup] = []
        var singles: [ImageFile] = []
        for (key, group) in stemMap {
            if group.count > 1 {
                let label = URL(fileURLWithPath: key).lastPathComponent
                multi.append(ImageGroup(files: group, groupLabel: label))
            } else {
                singles.append(group[0])
            }
        }
        return (multi, singles)
    }

    /// Builds one (representative, allFiles) pair per unique stem.
    /// The representative is the JPEG (or first non-RAW, or first file) —
    /// used as the Vision input so each shot is fingerprinted only once.
    private static func makeStemShots(_ files: [ImageFile]) -> [(rep: ImageFile, allFiles: [ImageFile])] {
        var stemOrder: [String] = []
        var byStem: [String: [ImageFile]] = [:]
        for file in files {
            let key = file.url.deletingPathExtension().path
            if byStem[key] == nil { stemOrder.append(key) }
            byStem[key, default: []].append(file)
        }
        return stemOrder.compactMap { key in
            guard let group = byStem[key] else { return nil }
            let rep = group.first(where: { $0.isJpeg })
                ?? group.first(where: { !$0.isRaw })
                ?? group[0]
            return (rep: rep, allFiles: group)
        }
    }

    /// O(n²) pairwise cosine similarity + Union-Find clustering.
    /// Exactly matches Python reference: cosine_similarity() with threshold 0.92.
    private static func clusterShotsBySimilarity(
        count: Int,
        fps: [[Float]?]
    ) -> (clusters: [[Int]], scores: [Int: Float]) {
        var parent = Array(0..<count)
        var rank   = Array(repeating: 0, count: count)
        var best   = [Int: Float]()  // root → best score seen in its cluster

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]  // path compression
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int, score: Float) {
            let ra = find(a), rb = find(b)
            if ra == rb {
                best[ra] = max(best[ra] ?? 0, score)
                return
            }
            // Union by rank
            let newRoot = rank[ra] >= rank[rb] ? ra : rb
            let oldRoot = newRoot == ra ? rb : ra
            parent[oldRoot] = newRoot
            if rank[ra] == rank[rb] { rank[newRoot] += 1 }
            best[newRoot] = max(best[ra] ?? 0, best[rb] ?? 0, score)
            best.removeValue(forKey: oldRoot)
        }

        // Pairwise cosine comparison — O(n²)
        for i in 0..<count {
            guard let fpi = fps[i] else { continue }
            for j in (i + 1)..<count {
                guard let fpj = fps[j] else { continue }
                let score = ImageProcessor.cosineSimilarity(fpi, fpj)
                if score >= visionSimilarityThreshold {
                    union(i, j, score: score)
                }
            }
        }

        // Collect groups by root
        var groupMap = [Int: [Int]]()
        for i in 0..<count { groupMap[find(i), default: []].append(i) }

        var clusters: [[Int]] = []
        var clusterScores = [Int: Float]()
        for (root, members) in groupMap {
            clusters.append(members)
            clusterScores[clusters.count - 1] = best[root] ?? 0
        }
        return (clusters, clusterScores)
    }
}

// MARK: - Size Formatting

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
