import Testing
@testable import LatticeCore

/// Wake from sleep: macOS briefly reports only the built-in display, then the external comes back.
/// Each display must get back the workspace it showed (user bug 2026-10-15: 1 ended up on the laptop, 3 on the monitor).
@Suite struct DisplayFlapTests {
    /// A desk: laptop shows 1 (a), the external shows 2 (b) and has focus. Before the fix the flap
    /// left 2 on the laptop and gave the external a fresh 3.
    func desk() -> Engine {
        var e = dual()
        _ = e.handle(.windowAdded(snap(a)), now: 0)                      // a → 1 (laptop)
        _ = e.handle(.command(.focusDisplay(.next)), now: 1)
        _ = e.handle(.windowAdded(snap(b)), now: 1)                      // b → 2 (external), focused
        return e
    }

    @Test func externalGetsItsWorkspaceBackAfterAFlap() {
        var e = desk()
        let ext = e.visible[extD.id]!, laptop = e.visible[mainD.id]!, focused = e.active
        _ = e.handle(.displaysChanged([mainD]), now: 10)                 // monitor gone for a moment
        _ = e.handle(.displaysChanged([mainD, extD]), now: 11)           // and back
        #expect(e.visible[extD.id] == ext && e.visible[mainD.id] == laptop && e.active == focused)
    }

    @Test func windowsGoBackToTheirDisplay() {
        var e = desk()
        let before = e.sent
        _ = e.handle(.displaysChanged([mainD]), now: 10)
        _ = e.handle(.displaysChanged([mainD, extD]), now: 11)
        #expect(e.sent[a] == before[a] && e.sent[b] == before[b])
    }

    @Test func repeatedFlapsAndAnEmptyMomentAreHarmless() {
        var e = desk()
        let ext = e.visible[extD.id]!, laptop = e.visible[mainD.id]!
        for t in 0..<3 {
            _ = e.handle(.displaysChanged([mainD]), now: 10 + Double(t))
            _ = e.handle(.displaysChanged([]), now: 10.3 + Double(t))      // during wake macOS can report none
            _ = e.handle(.displaysChanged([extD, mainD]), now: 10.6 + Double(t))
        }
        #expect(e.visible[extD.id] == ext && e.visible[mainD.id] == laptop)
    }

    @Test func switchingWorkspacesWhileUnpluggedIsKeptUntilReplug() {
        var e = desk()
        _ = e.handle(.displaysChanged([mainD]), now: 10)
        _ = e.handle(.command(.workspace("4")), now: 11)                  // user works on the laptop alone
        #expect(e.visible[mainD.id] == "4")
        _ = e.handle(.displaysChanged([mainD, extD]), now: 12)           // replug: back to the desk arrangement
        #expect(e.visible[extD.id] != nil && e.visible[mainD.id] != nil && e.visible[extD.id] != e.visible[mainD.id])
    }

    @Test func aNewDisplayStillGetsAFreeWorkspace() {
        var e = engine()                                                 // laptop only
        _ = e.handle(.windowAdded(snap(a)), now: 0)
        _ = e.handle(.displaysChanged([screen, extD]), now: 1)           // never seen this set
        #expect(e.visible[screen.id] == "1" && e.visible[extD.id] != nil && e.visible[extD.id] != "1")
    }

    @Test func pinsStillWin() {
        var s = Settings(gaps: noGaps)
        s.workspaceDisplays = ["2": .name("DELL U2720Q")]
        var e = dual(s)
        _ = e.handle(.displaysChanged([mainD]), now: 1)
        _ = e.handle(.displaysChanged([mainD, extD]), now: 2)
        #expect(e.visible[extD.id] == "2")
    }
}
