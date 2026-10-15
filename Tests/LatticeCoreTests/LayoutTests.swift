import Testing
@testable import LatticeCore

let a = WindowID("a"), b = WindowID("b"), c = WindowID("c"), d = WindowID("d")
let area = Rect(x: 0, y: 0, width: 1000, height: 600)
let noGaps = Gaps(inner: 0, outer: 0)

@Suite struct TreeTests {
    @Test func insertAfterAndRemoveNormalizes() {
        var t = LayoutTree()
        t.insert(a, after: nil)
        t.insert(b, after: a)
        t.insert(c, after: a)
        #expect(t.leaves == [a, c, b])
        t.split(c, .vertical)          // wrap c
        t.insert(d, after: c)          // d goes under c
        #expect(t.leaves == [a, c, d, b])
        let f = t.frames(in: area)
        #expect(f[c]!.height == 300 && f[d]!.minY == 300 && f[c]!.width == f[d]!.width)
        t.remove(d)                    // c's split collapses back to a leaf
        #expect(t.root.children.count == 3)
        if case .split = t.root.children[1] { Issue.record("single-child split not collapsed") }
        t.remove(a); t.remove(b); t.remove(c)
        #expect(t.leaves.isEmpty)
    }

    @Test func splitOnLoneChildReorients() {
        var t = LayoutTree(windows: [a])
        t.split(a, .vertical)
        #expect(t.root.orientation == .vertical)
        t.insert(b, after: a)
        #expect(t.frames(in: area)[b]!.minY == 300)
    }

    @Test func resizeTransfersWeightAndClamps() {
        var t = LayoutTree(windows: [a, b])
        t.resize(a, axis: .horizontal, delta: 0.1)
        let f = t.frames(in: area)
        #expect(abs(f[a]!.width - 600) < 0.001)
        t.resize(a, axis: .horizontal, delta: 5) // clamps: b keeps 10%
        #expect(abs(t.frames(in: area)[b]!.width - 100) < 0.001)
        t.resize(a, axis: .vertical, delta: 0.1)  // no vertical ancestor → no-op
        #expect(abs(t.frames(in: area)[b]!.width - 100) < 0.001)
        t.balance()
        #expect(t.frames(in: area)[a]!.width == 500)
    }

    @Test func swapKeepsStructure() {
        var t = LayoutTree(windows: [a, b, c])
        t.swap(a, c)
        #expect(t.leaves == [c, b, a])
    }
}

@Suite struct SolverTests {
    @Test func dwindleSpirals() {
        let f = Layout.frames(kind: .dwindle, tree: LayoutTree(), order: [a, b, c], focused: nil, area: area, ratio: 0.5, gaps: noGaps)
        #expect(f[a] == Rect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[b] == Rect(x: 500, y: 0, width: 500, height: 300))   // 500×600 is taller → split vertically
        #expect(f[c] == Rect(x: 500, y: 300, width: 500, height: 300))
    }

    @Test func masterStack() {
        let f = Layout.frames(kind: .master, tree: LayoutTree(), order: [a, b, c], focused: nil, area: area, ratio: 0.6, gaps: noGaps)
        #expect(f[a] == Rect(x: 0, y: 0, width: 600, height: 600))
        #expect(f[b] == Rect(x: 600, y: 0, width: 400, height: 300))
        #expect(f[c] == Rect(x: 600, y: 300, width: 400, height: 300))
    }

    @Test func monocleFillsAndSingleWindowFills() {
        let f = Layout.frames(kind: .monocle, tree: LayoutTree(), order: [a, b], focused: a, area: area, ratio: 0.5, gaps: noGaps)
        #expect(f[a] == area && f[b] == area)
        let one = Layout.frames(kind: .dwindle, tree: LayoutTree(), order: [a], focused: a, area: area, ratio: 0.5, gaps: noGaps)
        #expect(one[a] == area)
    }

    @Test func gapsAreOuterAtEdgesInnerBetween() {
        let g = Gaps(inner: 10, outer: 20)
        let f = Layout.frames(kind: .dwindle, tree: LayoutTree(), order: [a, b], focused: nil, area: area, ratio: 0.5, gaps: g)
        #expect(f[a]!.minX == 20 && f[a]!.minY == 20)
        #expect(f[b]!.maxX == 980 && f[b]!.maxY == 580)
        #expect(f[b]!.minX - f[a]!.maxX == 10)
    }

    @Test func neighbourPrefersOverlappingWindows() {
        // a | b over c
        let frames = [a: Rect(x: 0, y: 0, width: 500, height: 600),
                      b: Rect(x: 500, y: 0, width: 500, height: 300),
                      c: Rect(x: 500, y: 300, width: 500, height: 300)]
        #expect(Layout.neighbour(of: a, .right, in: frames) != nil)
        #expect(Layout.neighbour(of: b, .down, in: frames) == c)
        #expect(Layout.neighbour(of: c, .left, in: frames) == a)
        #expect(Layout.neighbour(of: a, .left, in: frames) == nil)
    }
}

@Suite struct CommandTests {
    @Test func parsesTheLanguage() throws {
        #expect(try Command.parse("focus left") == .focus(.left))
        #expect(try Command.parse("  move   Down ") == .move(.down))
        #expect(try Command.parse("workspace 3") == .workspace("3"))
        #expect(try Command.parse("workspace Mail") == .workspace("Mail"))
        #expect(try Command.parse("workspace back-and-forth") == .workspaceBackAndForth)
        #expect(try Command.parse("move-to-workspace 2 follow") == .moveToWorkspace("2", follow: true))
        #expect(try Command.parse("layout monocle") == .layout(.monocle))
        #expect(try Command.parse("split v") == .split(.vertical))
        #expect(try Command.parse("resize grow width 0.1") == .resize(grow: true, axis: .horizontal, amount: 0.1))
        #expect(try Command.parse("resize shrink") == .resize(grow: false, axis: nil, amount: 0.05))
        #expect(try Command.parse("exec open -a  Ghostty") == .exec("open -a  Ghostty"))
    }

    @Test func rejectsGarbageWithUsefulErrors() {
        #expect(throws: Command.ParseError.unknown("fly")) { try Command.parse("fly away") }
        #expect(throws: Command.ParseError.self) { try Command.parse("focus sideways") }
        #expect(throws: Command.ParseError.self) { try Command.parse("resize grow 2") }
        #expect(throws: Command.ParseError.empty) { try Command.parse("   ") }
    }

    @Test func descriptionRoundTrips() throws {
        for text in ["focus up", "move-to-workspace 4 follow", "layout dwindle", "split horizontal", "exec open -a Safari"] {
            #expect(try Command.parse(text).description == text)
        }
    }
}

@Suite struct KeyChordTests {
    let mod: KeyChord.Modifiers = [.ctrl, .alt]

    @Test func expandsModAndNormalizes() throws {
        let k = try KeyChord.parse("mod+shift+H", mod: mod)
        #expect(k.modifiers == [.ctrl, .alt, .shift] && k.key == "h")
        #expect(try KeyChord.parse("mod+enter", mod: mod).key == "return")
        #expect(try KeyChord.parse("cmd+ctrl+left", mod: mod).description == "cmd+ctrl+left")
        #expect(try KeyChord.parse("hyper+1", mod: mod).modifiers == [.cmd, .ctrl, .alt, .shift])
        #expect(try KeyChord.parse("mod+[", mod: mod).key == "leftbracket")
        #expect(try KeyChord.parse("mod+shift+left", mod: mod).symbol == "⌃⌥⇧←")
        #expect(try KeyChord.parse("return", mod: mod).symbol == "↩" && KeyChord.parse("l", mod: mod).symbol == "l")
        #expect(try KeyChord.parse("mod+-", mod: mod) == KeyChord.parse("mod+minus", mod: mod))
    }

    @Test func rejectsBadChords() {
        #expect(throws: KeyChord.ParseError.unknownModifier("meta")) { try KeyChord.parse("meta+h", mod: mod) }
        #expect(throws: KeyChord.ParseError.unknownKey("banana")) { try KeyChord.parse("ctrl+banana", mod: mod) }
        #expect(throws: KeyChord.ParseError.duplicateModifier("ctrl")) { try KeyChord.parse("ctrl+ctrl+h", mod: mod) }
        #expect(throws: KeyChord.ParseError.noKey) { try KeyChord.parse("ctrl+", mod: mod) }
    }
}
