import AudioToolbox
import Foundation

/// Subtle audible feedback when a clip is copied to the iOS pasteboard,
/// alongside the existing haptic.
enum CopySound {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppConstants.copySoundEnabledKey) as? Bool ?? true
    }

    static func play() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1306)
    }
}
