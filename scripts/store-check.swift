import Foundation
func mk(_ f: Int) -> Store {
    let s = Store()
    s.set(spaces: (1...5).map { SpaceInfo(id: $0, sid: UInt64($0), focused: $0 == f, visible: $0 == f, windows: 1, fullscreen: false) })
    return s
}
func pos(_ s: Store) -> Double { Double(s.focusedIndex ?? -1) + s.swipe }
var fails = 0
func check(_ name: String, _ got: Double, _ want: Double) { if abs(got - want) > 1e-9 { fails += 1; print("FAIL", name, "got", got, "want", want) } else { print("ok  ", name, got) } }

// one swipe: capsule goes to 1 on lift and stays at 1 when macOS confirms
var s = mk(1); s.swipeRelease(commit: 1); check("lift +1", pos(s), 1); s.focusNow(space: 2); check("confirmed", pos(s), 1); check("pending cleared", Double(s.pending), 0)
// back to back: second swipe lifts before the first is confirmed
s = mk(1); s.swipeRelease(commit: 1); s.swipeMove(slots: 0.5); check("2nd swipe live from heading", pos(s), 1.5)
s.swipeRelease(commit: 1); check("2 pending", pos(s), 2); s.focusNow(space: 2); check("1st confirmed, no jump", pos(s), 2); s.focusNow(space: 3); check("2nd confirmed, no jump", pos(s), 2)
// confirmation arrives while fingers are down on swipe 2
s = mk(1); s.swipeRelease(commit: 1); s.swipeMove(slots: 0.4); s.focusNow(space: 2); check("confirm mid-gesture, no jump", pos(s), 1.4)
// opposite direction back to back (+1 then -1): ends where it started
s = mk(2); s.swipeRelease(commit: 1); s.swipeRelease(commit: -1); check("net zero", pos(s), 1); s.focusNow(space: 3); check("+1 confirmed", pos(s), 1); s.focusNow(space: 2); check("-1 confirmed", pos(s), 1)
// keyboard move nobody predicted
s = mk(1); s.focusNow(space: 4); check("keyboard", pos(s), 3)
// ignored swipe: clear puts capsule on the real focus
s = mk(1); s.swipeRelease(commit: 1); s.swipeClear(); check("cleared", pos(s), 0)
print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
