import AppKit

/// Subtle audible feedback when something lands on the clipboard — either a
/// capture from another app or a copy made from the ClipStory panel.
@MainActor
enum CopySound {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppConstants.copySoundEnabledKey) as? Bool ?? true
    }

    static func play() {
        guard isEnabled else { return }
        NSSound(named: "Pop")?.play()
    }
}
