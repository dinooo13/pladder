import Foundation
import Testing
@testable import PladderCore

@Suite struct CarbonHotkeySessionTests {
    private func session(_ generation: UInt64 = 5, roles: [HotkeyRole] = [.dictate, .toggle]) -> CarbonHotkeySession {
        CarbonHotkeySession(generation: generation, roles: roles)
    }

    private func id(_ generation: UInt64, _ role: HotkeyRole) -> UInt32 {
        CarbonHotkeySession.hotKeyID(generation: generation, role: role)
    }

    // MARK: IDs

    @Test func idsPackTheGenerationOverTheRole() {
        #expect(id(5, .dictate) == 5 << 3 | 0)
        #expect(id(5, .toggle) == 5 << 3 | 1)
        #expect(CarbonHotkeySession.cancelKeyID(generation: 5) == 5 << 3 | 7)
        #expect(session(5).cancelKeyID == 5 << 3 | 7)
    }

    @Test func idsAreDistinctWithinASessionAndAcrossNeighbours() {
        let ids: Set<UInt32> = [
            id(5, .dictate), id(5, .toggle), CarbonHotkeySession.cancelKeyID(generation: 5),
            id(6, .dictate), id(6, .toggle), CarbonHotkeySession.cancelKeyID(generation: 6),
        ]
        #expect(ids.count == 6)
    }

    @Test func onlyTheLow29BitsOfTheGenerationFit() {
        // A generation past 2^29 wraps; the documented, unreachable limit.
        #expect(id(5 + (1 << 29), .dictate) == id(5, .dictate))
    }

    // MARK: The generation filter

    @Test func anOldSessionsHotKeyMeansNothing() {
        var s = session(6)
        #expect(s.event(id: id(5, .dictate), isPress: true, cancelKeyRegistered: false) == nil)
        #expect(s.event(id: id(5, .dictate), isPress: false, cancelKeyRegistered: false) == nil)
        #expect(s.event(id: CarbonHotkeySession.cancelKeyID(generation: 5), isPress: true, cancelKeyRegistered: true) == nil)
    }

    @Test func aRoleThatWasNotRegisteredMeansNothing() {
        var s = session(roles: [.dictate])
        #expect(s.event(id: id(5, .toggle), isPress: true, cancelKeyRegistered: false) == nil)
    }

    // MARK: De-duplication

    @Test func pressAndReleaseAlternate() {
        var s = session()
        #expect(s.event(id: id(5, .dictate), isPress: true, cancelKeyRegistered: false) == .chord(.dictate, .pressed))
        // Carbon's repeat of a held key.
        #expect(s.event(id: id(5, .dictate), isPress: true, cancelKeyRegistered: false) == nil)
        #expect(s.event(id: id(5, .dictate), isPress: false, cancelKeyRegistered: false) == .chord(.dictate, .released(submit: false)))
        #expect(s.event(id: id(5, .dictate), isPress: false, cancelKeyRegistered: false) == nil)
        #expect(s.event(id: id(5, .dictate), isPress: true, cancelKeyRegistered: false) == .chord(.dictate, .pressed))
    }

    @Test func aReleaseWithNothingPressedMeansNothing() {
        var s = session()
        #expect(s.event(id: id(5, .toggle), isPress: false, cancelKeyRegistered: false) == nil)
    }

    @Test func eachRoleAlternatesOnItsOwn() {
        var s = session()
        #expect(s.event(id: id(5, .dictate), isPress: true, cancelKeyRegistered: false) == .chord(.dictate, .pressed))
        #expect(s.event(id: id(5, .toggle), isPress: true, cancelKeyRegistered: false) == .chord(.toggle, .pressed))
        #expect(s.event(id: id(5, .dictate), isPress: false, cancelKeyRegistered: false) == .chord(.dictate, .released(submit: false)))
        #expect(s.event(id: id(5, .toggle), isPress: false, cancelKeyRegistered: false) == .chord(.toggle, .released(submit: false)))
    }

    // MARK: The cancel key

    @Test func escapeCountsOnlyAsAPressWhileRegistered() {
        var s = session()
        let escape = s.cancelKeyID
        #expect(s.event(id: escape, isPress: true, cancelKeyRegistered: true) == .escape)
        #expect(s.event(id: escape, isPress: false, cancelKeyRegistered: true) == nil)
        // Let go of between the event being queued and handled.
        #expect(s.event(id: escape, isPress: true, cancelKeyRegistered: false) == nil)
    }
}
