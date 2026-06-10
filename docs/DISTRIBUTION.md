# Distribution

## Recommended Launch Path

Ship ClipStory in two tracks:

1. macOS direct download first: Developer ID signed, notarized, and shipped from
   a website as a ZIP or DMG.
2. iOS through TestFlight first, then App Store review when the beta is stable.

Do not target the Mac App Store for the first release. The current macOS app is
not sandboxed, and the product depends on menu-bar, clipboard, hotkey, paste,
and permission-heavy behavior. Direct distribution keeps that product intact.
Revisit the Mac App Store later as a separate sandboxed variant only if we want
the App Store discovery/update/payment channel enough to absorb the constraints.

## Current Project Status

- Team ID: `DY4JMWWW5S`
- macOS bundle ID: `com.vladbabic.clipstory`
- iOS bundle ID: `com.vladbabic.clipstory.ios`
- iCloud container: `iCloud.com.vladbabic.clipstory`
- Version: `1.0.0`, build `1`
- Icons: shared AppIcon asset exists for macOS and iOS.
- macOS Release hardened runtime is enabled for notarization.
- CloudKit production schema still needs to be deployed and tested.
- No StoreKit/paywall implementation exists yet.

## macOS Direct Download

Prerequisites in Apple Developer:

1. Confirm the `com.vladbabic.clipstory` App ID has iCloud/CloudKit and push
   notification capability enabled.
2. Create or confirm a Developer ID Application certificate.
3. Create a Developer ID provisioning profile for the app because CloudKit is an
   advanced capability.
4. Install the certificate and profile in Xcode.

Build, package, notarize, and verify:

```sh
./scripts/build_release.sh
ditto -c -k --keepParent build/archives/ClipStory.xcarchive/Products/Applications/ClipStory.app build/ClipStory.zip
xcrun notarytool submit build/ClipStory.zip --keychain-profile <profile> --wait
xcrun stapler staple build/archives/ClipStory.xcarchive/Products/Applications/ClipStory.app
spctl --assess --type execute --verbose build/archives/ClipStory.xcarchive/Products/Applications/ClipStory.app
```

Release artifact options:

- ZIP is fastest for v1.
- DMG looks more polished and can include a shortcut to `/Applications`.
- Add Sparkle for in-app updates before broad public launch.

## macOS Updates

Use Sparkle 2 for direct-download macOS updates. GitHub Releases should host the
DMG/ZIP artifacts, but the app should check a Sparkle appcast feed rather than
scraping GitHub's latest-release API itself.

Recommended v1 update architecture:

1. Add Sparkle 2 to the macOS target.
2. Generate a Sparkle EdDSA key pair. Store the private key only in the release
   keychain or CI secret storage; commit only the public key in app config.
3. Add `SUFeedURL` to the macOS `Info.plist`, pointing to a stable HTTPS feed:
   `https://<domain>/clipstory/appcast.xml`.
4. Host release artifacts in GitHub Releases:
   `ClipStory-1.0.1.dmg` or `ClipStory-1.0.1.zip`.
5. Host `appcast.xml` on a stable website or GitHub Pages. The appcast item
   points at the GitHub Release asset URL.
6. On release:
   - Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
   - Archive Release.
   - Sign with Developer ID.
   - Notarize.
   - Package as DMG/ZIP.
   - Generate/sign the Sparkle appcast.
   - Upload the artifact to GitHub Releases.
   - Publish the appcast update after the asset is live.

Why not just query GitHub Releases from the app:

- We would have to build our own secure update installer.
- Sparkle already verifies updates with Apple code signing plus EdDSA
  signatures, supports delta updates, handles app replacement, and gives us
  automatic/background updates.
- GitHub's latest-release API is useful for release tooling and download pages,
  but it is not a complete trusted updater.

Suggested channels:

- `appcast.xml`: stable public releases.
- `appcast-beta.xml`: opt-in beta releases for ourselves and early testers.

For v1, a manual download page is acceptable while we finish notarization and
CloudKit production testing. Before any broader public launch, Sparkle should be
in the app so users are not stranded on old builds.

## iOS TestFlight and App Store

1. Create the `ClipStory-iOS` app record in App Store Connect using
   `com.vladbabic.clipstory.ios`.
2. Archive the `ClipStory-iOS` scheme with a Release configuration.
3. Upload the archive to App Store Connect from Xcode Organizer.
4. Start with internal TestFlight, then external TestFlight after beta review.
5. Add App Store metadata before public review:
   - Name, subtitle, keywords, category, age rating, screenshots.
   - Support URL and privacy policy URL.
   - App Privacy answers for clipboard data, iCloud storage, diagnostics, and
     any analytics if added later.
   - Review notes explaining that iOS cannot capture clipboard in the
     background and that saves are user initiated.

Current Apple upload requirements should be checked before submitting. As of
June 2026, App Store Connect requires Xcode 26 or later for new uploads.

iOS updates are handled by TestFlight during beta and App Store phased release
for production. Use phased release for normal updates so a bad build can be
paused before it reaches everyone.

## CloudKit Production

Development builds use the CloudKit development environment. Before any public
release:

1. Open CloudKit Console.
2. Select `iCloud.com.vladbabic.clipstory`.
3. Deploy development schema changes to production.
4. Test production-signed macOS and iOS builds with a fresh iCloud account or a
   cleaned private database.
5. Verify both directions:
   - Mac -> iPhone and iPhone -> Mac text clips.
   - Images and screenshot-file clips.
   - Manual notes and files.
   - Pages/pinboards and renamed clips.
   - OCR text and search.
   - Deleting/clearing unsaved history does not delete Pages.

## App Review and Trust Risks

- Clipboard apps need a plain privacy story. The app should visibly say that
  clipboard data stays on-device and in the user's private iCloud database.
- iOS must not imply continuous background clipboard capture.
- Permission copy must be specific: Accessibility on macOS is only for
  auto-paste; without it, copy still works.
- Concealed/transient pasteboard data must remain ignored.
- Keep links working: support URL, privacy policy URL, terms, and contact email.
- Review on a clean Mac and a clean iPhone before submission; incomplete setup
  is a common review failure.

## Launch Checklist

- [ ] Pick the v1 business model: free, paid direct download, or paid iOS with
  free Mac companion.
- [ ] Create a small website/download page with support and privacy policy.
- [ ] Create App Store Connect records for iOS.
- [ ] Deploy CloudKit schema to production.
- [ ] Create Developer ID certificate/profile for macOS CloudKit distribution.
- [ ] Add Sparkle 2 for direct-download macOS updates.
- [ ] Create Sparkle signing keys and store the private key outside the repo.
- [ ] Publish a stable appcast URL; GitHub Releases can host DMG/ZIP assets.
- [ ] Decide ZIP vs DMG for the first public artifact.
- [ ] Produce and notarize a macOS ZIP or DMG.
- [ ] Upload iOS build to TestFlight.
- [ ] Run clean-install sync tests on Mac and iPhone.
- [ ] Capture final screenshots and short demo clips.
- [ ] Submit iOS to App Review.
- [ ] Publish the macOS download page after notarization verification passes.
