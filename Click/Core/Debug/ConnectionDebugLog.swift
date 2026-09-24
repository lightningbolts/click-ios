import Foundation
import Observation
import SwiftUI

/// DEBUG-only record of every Tap to Connect / QR request and response, for comparing an iOS
/// capture with an Android one during in-person testing (round 4 §8.1). Never compiled into
/// Release; nothing leaves the device.
@Observable
@MainActor
final class ConnectionDebugLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let method: String
        let path: String
        let status: Int?
        let request: String
        let response: String
    }

    static let shared = ConnectionDebugLog()
    private(set) var entries: [Entry] = []

    nonisolated static func captures(path: String) -> Bool {
        path.hasPrefix("/api/connections/proximity") || path.hasPrefix("/api/qr") || path == "/api/connections"
    }

    func record(method: String, path: String, status: Int?, request: Data?, response: Data?) {
        entries.insert(Entry(
            date: .now, method: method, path: path, status: status,
            request: Self.pretty(request), response: Self.pretty(response)
        ), at: 0)
        if entries.count > 30 { entries.removeLast(entries.count - 30) }
    }

    func clear() { entries.removeAll() }

    private static func pretty(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "—" }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: data.prefix(4_000), as: UTF8.self)
    }
}

/// Collapsible overlay listing `ConnectionDebugLog` (launch with `-connection-log`).
struct ConnectionDebugLogView: View {
    @State private var log = ConnectionDebugLog.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Connection log (\(log.entries.count))").font(.caption.bold())
                Spacer()
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }.font(.caption)
                Button("Copy") {
                    UIPasteboard.general.string = log.entries.map { "\($0.date) \($0.method) \($0.path) → \($0.status.map(String.init) ?? "error")\n\($0.request)\n\($0.response)" }.joined(separator: "\n\n")
                }.font(.caption)
                Button("Clear") { log.clear() }.font(.caption)
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(log.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.method) \(entry.path) → \(entry.status.map(String.init) ?? "error")").font(.caption2.bold())
                                Text(entry.request).font(.system(size: 9, design: .monospaced))
                                Text(entry.response).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }
}
