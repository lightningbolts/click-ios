import Foundation
import Observation

/// Pre-checks who can join a verified group before the server does (spec §9): everyone must
/// have Clicked with everyone. Each candidate–member pair is asked once
/// (`verified_clique_edges_exist [viewer, a, b]`) and cached; unknown pairs stay selectable.
@Observable
@MainActor
final class CliqueEligibility {
    private(set) var pairs: [String: Bool] = [:]
    private var inFlight: Set<String> = []

    nonisolated static func key(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// Asks about every (candidate, selected member) pair not yet known, a few at a time.
    func check(selected: Set<String>, candidates: [String], viewerID: String,
               exists: @escaping @Sendable ([String]) async throws -> Bool) async {
        let wanted = Set(selected.flatMap { member in
            candidates.filter { $0 != member }.map { Self.key($0, member) }
        })
        .subtracting(pairs.keys)
        .subtracting(inFlight)
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        defer { inFlight.subtract(wanted) }
        let results = await withTaskGroup(of: (String, Bool?).self) { group in
            var results: [(String, Bool?)] = []
            for (index, key) in wanted.sorted().enumerated() {
                if index >= 6, let next = await group.next() { results.append(next) }
                let ids = [viewerID] + key.split(separator: "|").map(String.init)
                group.addTask { (key, try? await exists(ids)) }
            }
            for await result in group { results.append(result) }
            return results
        }
        for case let (key, known?) in results { pairs[key] = known }
    }

    func reason(for userID: String, selected: Set<String>, names: [String: String]) -> String? {
        Self.reason(for: userID, selected: selected, pairs: pairs, names: names)
    }

    /// "Hasn't Clicked with Lena" / "…with Lena and Sam"; nil when eligible or still unknown.
    nonisolated static func reason(for userID: String, selected: Set<String>, pairs: [String: Bool], names: [String: String]) -> String? {
        let missing = selected.filter { $0 != userID && pairs[key(userID, $0)] == false }
            .map { names[$0] ?? "someone you picked" }
            .sorted()
        guard let first = missing.first else { return nil }
        return missing.count == 1 ? "Hasn't Clicked with \(first)" : "Hasn't Clicked with \(first) and \(missing.count - 1) more"
    }
}
