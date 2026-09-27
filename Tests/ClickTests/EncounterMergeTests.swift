import Testing
import Foundation
@testable import Click

@Suite("Encounter merge")
struct EncounterMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ id: String, _ reporter: String?, minutes: Double = 0, tags: [String] = [],
                     compass: Double? = nil, noise: String? = nil, celsius: Double? = nil) -> Encounter {
        var encounter = Encounter(id: id, date: t0.addingTimeInterval(minutes * 60), place: nil, eventTitle: nil,
                                  eventBeaconID: nil, contextTags: tags, noiseLevel: noise, elevation: nil)
        encounter.reportingUserID = reporter
        encounter.compassAzimuth = compass
        encounter.temperatureCelsius = celsius
        return encounter
    }

    @Test("A mutual tap is one entry: the viewer's values win, the peer's only fill gaps")
    func mutualTap() {
        let mine = row("a", "me", compass: 67, noise: "MODERATE")
        let theirs = row("b", "peer", tags: [ContextTagTaxonomy.extendedHangout], compass: 336, celsius: 16)
        let merged = Encounter.merged([theirs, mine], viewerID: "me")
        #expect(merged.count == 1)
        #expect(merged[0].id == "a")
        #expect(merged[0].compassAzimuth == 67)
        #expect(merged[0].noiseLevel == "MODERATE")
        #expect(merged[0].temperatureCelsius == 16)
        #expect(merged[0].rowIDs == ["a", "b"])
        // Only one row carries it: the double tap's artifact, not a longer hangout.
        #expect(merged[0].contextTags.isEmpty)
        // The peer sees their own row with the same gaps filled from mine.
        let peerView = Encounter.merged([theirs, mine], viewerID: "peer")
        #expect(peerView[0].id == "b")
        #expect(peerView[0].compassAzimuth == 336)
        #expect(peerView[0].noiseLevel == "MODERATE")
    }

    @Test("A group of three reporters is one entry, led by the viewer's or the most detailed row")
    func groupOfThree() {
        let rows = [row("a", "u1", celsius: 16), row("b", "u2", minutes: 1, compass: 10, noise: "LOUD"), row("c", "u3", minutes: 2)]
        let mine = Encounter.merged(rows, viewerID: "u3")
        #expect(mine.count == 1)
        #expect(mine[0].id == "c")
        #expect(mine[0].compassAzimuth == 10 && mine[0].temperatureCelsius == 16)
        #expect(Set(mine[0].rowIDs) == ["a", "b", "c"])
        #expect(Encounter.merged(rows, viewerID: "outsider")[0].id == "b")
    }

    @Test("Separate moments and same-reporter rows stay separate; a real extended hangout stays")
    func separate() {
        let tag = ContextTagTaxonomy.extendedHangout
        #expect(Encounter.merged([row("a", "me"), row("b", "peer", minutes: 180)], viewerID: "me").count == 2)
        #expect(Encounter.merged([row("a", "me"), row("b", "me", minutes: 1)], viewerID: "me").count == 2)
        #expect(Encounter.merged([row("a", nil), row("b", nil)], viewerID: "me").count == 2)
        let real = Encounter.merged([row("a", "me", tags: [tag]), row("b", "peer", tags: [tag])], viewerID: "me")
        #expect(real.count == 1 && real[0].contextTags == [tag])
        #expect(Encounter.merged([row("a", "me", minutes: 0), row("b", "peer", minutes: 300)], viewerID: "me").map(\.id) == ["b", "a"])
    }
}
