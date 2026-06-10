import Foundation
import MachO

/// Detects whether the running process actually carries iCloud container
/// entitlements. This must be checked BEFORE touching any CloudKit API:
/// CKContainer creation hits a fatal breakpoint trap (not a catchable
/// exception) when the entitlement is missing, so unsigned/team-less builds
/// would crash instead of degrading to local-only storage.
enum EntitlementChecker {
    private static let entitlementKey = "com.apple.developer.icloud-container-identifiers"

    static func hasICloudContainerEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil) != nil
        #elseif targetEnvironment(simulator)
        // Simulator builds embed entitlements in a Mach-O section; unsigned
        // CLI builds (CODE_SIGNING_ALLOWED=NO) have no such section.
        return embeddedEntitlementsText()?.contains(entitlementKey) ?? false
        #else
        // A physical iOS device cannot install an app whose configured
        // entitlements were stripped; trust the build configuration.
        return true
        #endif
    }

    #if targetEnvironment(simulator)
    private static func embeddedEntitlementsText() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        guard let bytes = getsectiondata(header64, "__TEXT", "__entitlements", &size), size > 0 else {
            return nil
        }
        return String(data: Data(bytes: bytes, count: Int(size)), encoding: .utf8)
    }
    #endif
}
