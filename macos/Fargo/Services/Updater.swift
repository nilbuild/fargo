import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false

    private var automaticChecksEnabled: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    private init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticChecksEnabled = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
            .store(in: &cancellables)

        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.automaticChecksEnabled = value }
            }
            .store(in: &cancellables)
    }

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecksEnabled }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
