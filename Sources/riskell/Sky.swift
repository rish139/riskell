import AppKit
import RiskellKit

// SkyLight (private). Looked up at run time so a missing symbol disables the feature instead of failing to link;
// no link-time dependency on the private framework.
enum Sky {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private typealias MainCID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private static var space: UInt64 = 0

    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    /// The space the system currently shows, straight from SkyLight (no fork, no window-manager query).
    static func activeSpace() -> UInt64? {
        guard let cid = sym("SLSMainConnectionID", as: MainCID.self), let f = sym("SLSGetActiveSpace", as: ActiveSpace.self) else { return nil }
        return f(cid())
    }

    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    /// True when `sid` is a native full-screen Space (SkyLight type 4).
    static func isFullscreen(_ sid: UInt64) -> Bool {
        guard let cid = sym("SLSMainConnectionID", as: MainCID.self), let f = sym("SLSSpaceGetType", as: SpaceType.self) else { return false }
        return f(cid(), sid) == 4
    }

    private typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Register = @convention(c) (Int32, NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32
    private static var traceHandler: ((UInt32) -> Void)?
    /// Diagnostics: call `handler(eventType)` for every SkyLight connection notification in `range`.
    static func trace(_ range: ClosedRange<UInt32>, _ handler: @escaping (UInt32) -> Void) {
        guard let cid = sym("SLSMainConnectionID", as: MainCID.self), let reg = sym("SLSRegisterConnectionNotifyProc", as: Register.self) else { return }
        traceHandler = handler
        for e in range { _ = reg(cid(), { t, _, _, _, _ in Sky.traceHandler?(t) }, e, nil) }
    }

    /// Puts the windows in one private space that is always shown, and takes them out of the user's Spaces. They then neither slide
    /// with a Space change nor follow into a full-screen Space (the user's Spaces are the only ones that move or get covered).
    /// Returns false if SkyLight does not offer the calls.
    @discardableResult
    static func pin(_ windows: [NSWindow]) -> Bool {
        guard let cid = sym("SLSMainConnectionID", as: MainCID.self),
              let create = sym("SLSSpaceCreate", as: SpaceCreate.self),
              let level = sym("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = sym("SLSShowSpaces", as: ShowSpaces.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self) else { return false }
        let c = cid()
        if space == 0 {
            space = create(c, 1, 0)
            level(c, space, 0)
            show(c, [NSNumber(value: space)] as CFArray)
        }
        add(c, space, windows.map { NSNumber(value: $0.windowNumber) } as CFArray, 0x7)
        return true
    }
}
