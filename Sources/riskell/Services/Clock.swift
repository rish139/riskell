import Foundation

/// The minute, for the cards of the app itself (the workspaces card's relative times). One wake-up a minute, on the wall clock, so it stays
/// aligned through sleep. The clock atom is a package (Packages/clock) and keeps its own time only while it is on a showing bar.
final class Clock: ObservableObject {
    static let shared = Clock()
    @Published private(set) var minute = Date()
    private var timer: DispatchSourceTimer?
    func start() {
        let next = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now() + (next - Date().timeIntervalSince1970), repeating: 60, leeway: .milliseconds(200))
        t.setEventHandler { [unowned self] in minute = Date() }
        t.resume(); timer = t
    }
}
