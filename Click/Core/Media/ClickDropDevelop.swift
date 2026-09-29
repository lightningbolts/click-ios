import CoreImage
import Foundation
import UIKit

/// The shared Click Drop develop state machine (spec §2), used by chat drops now and by event and
/// shared drops later. Mirrors click-web `lib/drops/developState.ts`.
///
///   pending   → before reveal: pixelated, countdown visible.
///   ready     → reveal passed, this viewer hasn't developed it. Quiet: no badge.
///   developed → the viewer tapped, or was watching when the timer hit zero. Permanent per viewer.
public enum ClickDropDevelopState: Sendable, Equatable {
    case pending(revealAt: Date)
    case ready
    case developed

    public static func resolve(revealAt: Date?, developedAt: Date?, now: Date = .now) -> ClickDropDevelopState {
        guard let revealAt, now >= revealAt else { return .pending(revealAt: revealAt ?? .distantFuture) }
        return developedAt == nil ? .ready : .developed
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

public enum ClickDropKind: String, Sendable, Codable {
    case chat, event, shared
}

public struct ClickDropRef: Sendable, Hashable, Codable {
    public let kind: ClickDropKind
    public let id: String

    public init(kind: ClickDropKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// One drop's answer from `POST /api/drops/develop`.
public struct ClickDropDevelopResult: Sendable, Equatable {
    public enum Status: String, Sendable { case developed, pending, notFound = "not_found" }

    public let ref: ClickDropRef
    public let status: Status
    public let developedAt: Date?
    /// Short-lived signed URL for a gated original (nil for legacy drops, whose media is the original).
    public let originalURL: URL?
}

/// `POST /api/drops/develop` and `GET /api/drops/views`. The server decides who may develop what
/// and never signs an original before its reveal time.
public struct ClickDropService: Sendable {
    let api: ClickAPIClient

    public init(api: ClickAPIClient) {
        self.api = api
    }

    /// Develops up to 50 drops ("Develop all" batches larger sets).
    public func develop(_ refs: [ClickDropRef]) async throws -> [ClickDropDevelopResult] {
        var results: [ClickDropDevelopResult] = []
        for start in stride(from: 0, to: refs.count, by: 50) {
            let batch = Array(refs[start..<min(start + 50, refs.count)])
            let body: [String: Any] = ["drops": batch.map { ["kind": $0.kind.rawValue, "id": $0.id] }]
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/drops/develop",
                method: .post,
                body: try JSONSerialization.data(withJSONObject: body),
                idempotent: true
            ))
            results += Self.parseDevelop(data)
        }
        return results
    }

    /// This viewer's developed-at time per drop ID (absent: not developed).
    public func developedAt(kind: ClickDropKind, ids: [String]) async throws -> [String: Date] {
        var out: [String: Date] = [:]
        let unique = Array(Set(ids)).sorted()
        for start in stride(from: 0, to: unique.count, by: 100) {
            let batch = unique[start..<min(start + 100, unique.count)]
            let (data, _) = try await api.executeRaw(APIRequest(
                path: "/api/drops/views",
                queryItems: [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "ids", value: batch.joined(separator: ","))]
            ))
            let developed = JSONFields.dictionary(try JSONFields.object(data)["developed"]) ?? [:]
            for (id, value) in developed {
                if let date = JSONFields.date(value) { out[id] = date }
            }
        }
        return out
    }

    static func parseDevelop(_ data: Data) -> [ClickDropDevelopResult] {
        guard let root = try? JSONFields.object(data), let rows = root["drops"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard
                let kind = JSONFields.string(row["kind"]).flatMap(ClickDropKind.init(rawValue:)),
                let id = JSONFields.string(row["id"]),
                let status = JSONFields.string(row["status"]).flatMap(ClickDropDevelopResult.Status.init(rawValue:))
            else { return nil }
            return ClickDropDevelopResult(
                ref: ClickDropRef(kind: kind, id: id),
                status: status,
                developedAt: JSONFields.date(row["developed_at"]),
                originalURL: JSONFields.string(row["url"]).flatMap(URL.init(string:))
            )
        }
    }
}

/// Pixelation shared by the sender (the gated drop's preview) and every drop bubble.
public enum ClickDropPixelation {
    private final class SharedContext: @unchecked Sendable {
        let value = CIContext()
    }

    private nonisolated static let context = SharedContext()

    /// Blocks per longest side for the pending/ready look (same as the original KMP drop).
    public nonisolated static let blocksPerSide: CGFloat = 12

    public nonisolated static func pixelated(_ image: UIImage, blocksPerSide: CGFloat = blocksPerSide) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(max(image.size.width, image.size.height) / blocksPerSide, forKey: kCIInputScaleKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent),
              let cg = context.value.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// The gated drop's preview: a small, heavily pixelated JPEG. It is all a viewer can download
    /// before reveal, so it must not carry more detail than the bubble shows.
    public nonisolated static func previewJPEG(from data: Data, maxDimension: CGFloat = 480) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return pixelated(small)?.jpegData(compressionQuality: 0.8)
    }

    /// Intermediate frames for the develop animation: pixels resolving toward the photo.
    public nonisolated static func developFrames(_ image: UIImage) -> [UIImage] {
        [24, 48, 96].compactMap { pixelated(image, blocksPerSide: $0) }
    }
}
