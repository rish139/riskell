import Foundation
import RiskellKit

/// Applies config.json and the drop-in pill files live. Kernel file events only (no polling): the config folder, the pills folder, and each file
/// in them, because an editor may rewrite a file in place or replace it. A burst of events becomes one reload 0.3 s later; a reload whose result
/// equals the settings in force does nothing (the theme folder is watched too: a scheme file dropped in or edited applies at once). A file that is not valid JSON (half-typed) is ignored until it is. `wm` is the one setting that
/// needs `risk restart` (`wmCommand` applies live to a running command backend).
final class ConfigWatcher {
    static let shared = ConfigWatcher()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?

    func start() { arm() }

    private func arm() {
        sources.forEach { $0.cancel() }; sources = []
        let fm = FileManager.default
        watch(AppConfig.directory.path)
        watch(AppConfig.url.path)
        if fm.fileExists(atPath: Theme.userDirectory.path) {
            watch(Theme.userDirectory.path)
            for f in (try? fm.contentsOfDirectory(atPath: Theme.userDirectory.path)) ?? [] where f.hasSuffix(".yaml") || f.hasSuffix(".yml") {
                watch(Theme.userDirectory.appendingPathComponent(f).path)
            }
        }
        if fm.fileExists(atPath: AppConfig.pillsDirectory.path) {
            watch(AppConfig.pillsDirectory.path)
            for f in (try? fm.contentsOfDirectory(atPath: AppConfig.pillsDirectory.path)) ?? [] where f.hasSuffix(".json") {
                watch(AppConfig.pillsDirectory.appendingPathComponent(f).path)
            }
        }
    }

    private func watch(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.changed() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        sources.append(src)
    }

    private func changed() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload(); self?.arm() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func reload() {
        guard let new = AppConfig.read() else { return }      // not valid: keep what is in force
        let old = AppConfig.shared
        let themed = Theme.apply(new.theme)      // also picks up an edited scheme file in themes/
        guard new != old || themed else { return }
        AppConfig.shared = new
        Extensions.apply(new)      // starts or stops the optional extensions (Extensions/Extension.swift); idempotent
        var did: [String] = themed ? ["theme"] : []
        if new.spacing != old.spacing { ThemeState.shared.epoch += 1; Config.shared.onGeometry?(); did.append("spacing") }      // the spacing settings rebuild the views and re-fit the windows
        if Pills.update(new.pills ?? []) {
            Registry.rebuild(); Config.shared.pruneUnknown(); Config.shared.objectWillChange.send(); did.append("pills: " + Pills.all.map(\.spec.id).joined(separator: " "))
        }
        if new.wm != old.wm { did.append("wm: run `risk restart` to apply") }
        else if new.wmCommand != old.wmCommand { (WM.shared as? CommandWM)?.reconfigure(); did.append("wmCommand") }
        print("config: reloaded (\(did.joined(separator: ", ")))"); fflush(stdout)
    }
}
