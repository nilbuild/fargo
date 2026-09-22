import Foundation

enum Persistence {
    private static let defaults = UserDefaults.standard

    // MARK: - File Storage

    static func copyImageToAppSupport(_ sourcePath: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return sourcePath }
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return sourcePath }
        let imagesDir = support.appendingPathComponent("Fargo/CanvasImages", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = imagesDir.appendingPathComponent(UUID().uuidString + "-" + sourceURL.lastPathComponent)
        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            return destURL.path
        } catch {
            return sourcePath
        }
    }

    // MARK: - Destinations

    static func saveDestinations(_ destinations: [StreamDestination]) {
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        defaults.set(data, forKey: "fargo.destinations")
    }

    static func loadDestinations() -> [StreamDestination] {
        guard let data = defaults.data(forKey: "fargo.destinations"),
              let saved = try? JSONDecoder().decode([StreamDestination].self, from: data) else { return [] }
        return saved
    }

    // MARK: - Canvas Config

    static func saveCanvasConfig(_ config: CanvasConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: "fargo.canvasConfig")
    }

    static func loadCanvasConfig() -> CanvasConfig {
        guard let data = defaults.data(forKey: "fargo.canvasConfig"),
              let config = try? JSONDecoder().decode(CanvasConfig.self, from: data) else { return CanvasConfig() }
        return config
    }

    // MARK: - Selected Devices

    static func saveSelectedCamera(_ id: String) { defaults.set(id, forKey: "fargo.selectedCamera") }
    static func loadSelectedCamera() -> String? { defaults.string(forKey: "fargo.selectedCamera") }

    static func saveSelectedMic(_ id: String) { defaults.set(id, forKey: "fargo.selectedMic") }
    static func loadSelectedMic() -> String? { defaults.string(forKey: "fargo.selectedMic") }

    static func saveSelectedDisplay(_ id: UInt32) { defaults.set(id, forKey: "fargo.selectedDisplay") }
    static func loadSelectedDisplay() -> UInt32? {
        defaults.object(forKey: "fargo.selectedDisplay") as? UInt32
    }

    // MARK: - Overlays

    static func saveOverlays(_ overlays: [StreamOverlay]) {
        guard let data = try? JSONEncoder().encode(overlays) else { return }
        defaults.set(data, forKey: "fargo.overlays")
    }

    static func loadOverlays() -> [StreamOverlay] {
        guard let data = defaults.data(forKey: "fargo.overlays"),
              let saved = try? JSONDecoder().decode([StreamOverlay].self, from: data) else { return [] }
        return saved
    }

    // MARK: - Canvases

    static func saveCanvases(_ canvases: [Canvas]) {
        guard let data = try? JSONEncoder().encode(canvases) else { return }
        defaults.set(data, forKey: "fargo.canvases")
    }

    static func loadCanvases() -> [Canvas] {
        guard let data = defaults.data(forKey: "fargo.canvases"),
              let saved = try? JSONDecoder().decode([Canvas].self, from: data) else { return [] }
        return saved
    }

    static func saveActiveCanvasId(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: "fargo.activeCanvasId")
        } else {
            defaults.removeObject(forKey: "fargo.activeCanvasId")
        }
    }

    static func loadActiveCanvasId() -> UUID? {
        guard let str = defaults.string(forKey: "fargo.activeCanvasId") else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - Media Presets

    static func saveMediaPresets(_ presets: [MediaPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "fargo.mediaPresets")
    }

    static func loadMediaPresets() -> [MediaPreset] {
        guard let data = defaults.data(forKey: "fargo.mediaPresets"),
              let saved = try? JSONDecoder().decode([MediaPreset].self, from: data) else { return [] }
        return saved
    }

    static func saveActiveMediaPresetId(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: "fargo.activeMediaPresetId")
        } else {
            defaults.removeObject(forKey: "fargo.activeMediaPresetId")
        }
    }

    static func loadActiveMediaPresetId() -> UUID? {
        guard let str = defaults.string(forKey: "fargo.activeMediaPresetId") else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - Window

    static func saveWindowFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: "fargo.windowFrame")
    }

    static func loadWindowFrame() -> NSRect? {
        guard let str = defaults.string(forKey: "fargo.windowFrame") else { return nil }
        let rect = NSRectFromString(str)
        return rect.width > 0 ? rect : nil
    }

    static func savePanelVisible(_ visible: Bool) { defaults.set(visible, forKey: "fargo.panelVisible") }
    static func loadPanelVisible() -> Bool { defaults.bool(forKey: "fargo.panelVisible") == false ? true : defaults.bool(forKey: "fargo.panelVisible") }
}

import AppKit
