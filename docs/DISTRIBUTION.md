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
- Version: `1.0.5`, build `6`
- Icons: shared AppIcon asset exists for macOS and iOS.
- macOS Release hardened runtime is enabled for notarization.
- Sparkle 2 is wired into the macOS app.
- Sparkle appcast URL:
  `https://github.com/Vladimirbabic/clip-island/releases/latest/download/appcast.xml`
- Sparkle signing account: `com.vladbabic.clipstory`
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
5. Run `./scripts/build_release.sh`; it now preflights the expected Vladimir
   Babic Developer ID certificate and notarization credentials before archiving.

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
- ZIPs must be generated without AppleDouble `._` metadata. Those files can be
  extracted into nested frameworks and invalidate the app signature.
- DMG looks more polished and can include a shortcut to `/Applications`.
- Sparkle is wired; keep the appcast reachable before broad public launch.

## macOS Updates

Use Sparkle 2 for direct-download macOS updates. GitHub Releases should host the
DMG/ZIP artifacts, but the app should check a Sparkle appcast feed rather than
scraping GitHub's latest-release API itself.

Implemented update architecture:

1. Sparkle 2 is added to the macOS target through XcodeGen.
2. The Sparkle EdDSA public key is committed in app config; the private key is
   stored in the local login Keychain under account `com.vladbabic.clipstory`.
3. `SUFeedURL` points at the latest GitHub Release appcast asset:
   `https://github.com/Vladimirbabic/clip-island/releases/latest/download/appcast.xml`.
4. Host release artifacts in GitHub Releases:
   `ClipStory-1.0.1.dmg` or `ClipStory-1.0.1.zip`.
5. Upload `appcast.xml` as a GitHub Release asset. The appcast item points at
   the GitHub Release asset URL.
6. On release:
   - Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
   - Archive Release.
   - Sign with Developer ID.
   - Notarize.
   - Package as DMG/ZIP.
   - Move the ZIP/DMG into `build/sparkle/`.
   - Generate/sign the Sparkle appcast with `./scripts/generate_appcast.sh`.
   - Upload the artifact to GitHub Releases.
   - Publish the appcast update after the asset is live.

Back up the private Sparkle key once and store it in 1Password or CI secrets:

```sh
SPARKLE_GENERATE_KEYS="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys' \
  -type f \
  -print \
  -quit)"
"$SPARKLE_GENERATE_KEYS" \
  --account com.vladbabic.clipstory \
  -x ~/Desktop/sparkle_private_key_clipstory.txt
```

Do not commit the exported private key. Only `SUPublicEDKey` belongs in git.

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
2. Create the `com.vladbabic.clipstory.ios.ShareExtension` App ID and enable
   CloudKit for the same `iCloud.com.vladbabic.clipstory` container.
3. Create or refresh provisioning profiles for the iOS app and Share Extension.
4. Archive the `ClipStory-iOS` scheme with a Release configuration.
5. Upload the archive to App Store Connect from Xcode Organizer.
6. Start with internal TestFlight, then external TestFlight after beta review.
7. Add App Store metadata before public review:
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
- [x] Add Sparkle 2 for direct-download macOS updates.
- [x] Generate initial Sparkle signing key and commit only the public key.
- [x] Add initial `docs/appcast.xml`.
- [x] Add appcast generation script for GitHub Release assets.
- [ ] Move the appcast to public hosting before public distribution if the
      GitHub repository stays private.
- [ ] Export/back up the Sparkle private key into secure secret storage.
- [x] Decide ZIP vs DMG for the first public artifact.
- [x] Produce and notarize a macOS ZIP.
- [ ] Upload iOS build to TestFlight.
- [ ] Run clean-install sync tests on Mac and iPhone.
- [ ] Capture final screenshots and short demo clips.
- [ ] Submit iOS to App Review.
- [ ] Publish the macOS download page after notarization verification passes.
