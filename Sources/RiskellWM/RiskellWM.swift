// The window managers' wire formats, parsed without a window.
//
// Foundation only, on purpose: a payload recorded from a real install is replayed in a test on CI, where no window manager is running.
// Nothing in this target starts a process, opens a socket or reads a screen.
public enum RiskellWM {
    public static let ready = true
}
