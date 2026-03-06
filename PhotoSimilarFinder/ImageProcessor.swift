import Foundation
import AppKit
import CoreImage
import Metal
import Vision
import QuickLookThumbnailing

/// Centralized hardware-accelerated image operations for Apple Silicon
/// - GPU (Metal): Full-image rendering via Core Image
/// - Media Engine (QuickLook): Thumbnail generation for all formats incl. RAW
/// - Neural Engine (Vision): Image similarity feature prints
enum ImageProcessor {

    // MARK: - Metal Device & Core Image Context (GPU)

    /// Apple Silicon GPU device
    static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// CIContext backed by Metal GPU — shared singleton for efficient resource reuse
    static let ciContext: CIContext = {
        if let device = metalDevice {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .cacheIntermediates: false
            ])
        }
        // Fallback: GPU via OpenGL/OpenCL, never software
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Thumbnail (QuickLook — Apple Silicon Media Engine)

    /// Hardware-accelerated thumbnail via QLThumbnailGenerator.
    /// Uses the system-level media engine: supports JPEG, HEIC, RAW (CR2/CR3/NEF/ARW/DNG…)
    static func loadThumbnail(url: URL, size: CGFloat = 300) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )

        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep.nsImage
        } catch {
            // Fallback: CGImageSource hardware decoder
            return await Task.detached(priority: .background) {
                cgSourceThumbnail(url: url, maxDim: Int(size * 2))
            }.value
        }
    }

    // MARK: - Full Image (CIImage + Metal GPU)

    /// Decode and render full-size image using CIImage → Metal GPU pipeline.
    /// CIImage uses Apple Silicon's hardware RAW/HEIC decoders automatically.
    static func loadFullImage(url: URL, maxDimension: CGFloat = 2400) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            // CIImage creation is lazy — actual decoding happens at render time via Metal
            if let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                let ext = ci.extent
                guard ext.width > 0, ext.height > 0 else { return nil }

                let scale = min(maxDimension / ext.width, maxDimension / ext.height, 1.0)
                let processed = scale < 1.0
                    ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : ci

                // Render via Metal — offloads to GPU
                if let cg = ciContext.createCGImage(processed, from: processed.extent) {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            // Fallback: CGImageSource (still hardware-decoded for most formats)
            return cgSourceThumbnail(url: url, maxDim: Int(maxDimension))
                ?? NSImage(contentsOf: url)
        }.value
    }

    // MARK: - Vision Feature Print (Neural Engine)

    /// Compute perceptual feature print and return it as a raw float32 vector.
    /// On Apple Silicon, dispatched to the Neural Engine for maximum throughput.
    /// Equivalent to Python reference: `list(struct.unpack(f"{n}f", bytes(feature_print.data())))`
    static func computeFeaturePrint(url: URL) async throws -> [Float] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNGenerateImageFeaturePrintRequest { r, err in
                if let err { cont.resume(throwing: err); return }
                guard let obs = r.results?.first as? VNFeaturePrintObservation else {
                    cont.resume(throwing: NSError(domain: "Vision", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No feature print returned"]))
                    return
                }
                // Extract the raw float32 data from the observation — same as Python's
                // feature_print.data() which returns NSData of float32 values.
                guard let raw = obs.value(forKey: "data") as? Data, !raw.isEmpty else {
                    cont.resume(throwing: NSError(domain: "Vision", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot extract feature vector"]))
                    return
                }
                let vec: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                cont.resume(returning: vec)
            }
            req.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(url: url, options: [:])
            do {
                try handler.perform([req])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Cosine similarity in [0, 1] — matches Python reference's cosine_similarity().
    /// 1.0 = identical direction, 0.0 = orthogonal/opposite.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 0 }
        return max(0, min(1, dot / denom))
    }

    // MARK: - Private helpers

    static func cgSourceThumbnail(url: URL, maxDim: Int) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
