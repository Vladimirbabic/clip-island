import Foundation

/// iOS-side presentation helper for the shared sync state.
extension CloudSyncStatus.State {
    var systemImageName: String {
        switch self {
        case .syncing: return "icloud"
        case .noAccount: return "icloud.slash"
        case .localOnly: return "icloud.slash"
        case .ephemeral: return "exclamationmark.icloud"
        }
    }
}
