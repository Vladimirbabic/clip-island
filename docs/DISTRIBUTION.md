# Distribution

## macOS

1. Build a release archive:

```sh
./scripts/build_release.sh
```

2. Export or package the archived app.
3. Sign with a Developer ID Application certificate.
4. Notarize with Apple:

```sh
xcrun notarytool submit ClipStory.zip --keychain-profile <profile> --wait
xcrun stapler staple ClipStory.app
```

5. Verify on a clean Mac:

```sh
spctl --assess --verbose ClipStory.app
```

## iOS

1. Open the generated project in Xcode.
2. Select `ClipStory-iOS`.
3. Archive with a Release configuration.
4. Upload to App Store Connect.
5. Use TestFlight for device testing before public distribution.

## CloudKit

Personal development builds use the CloudKit development environment. Before a
real release, deploy the schema to production in CloudKit Console and verify:

- New install on macOS with an empty store.
- New install on iPhone with an empty store.
- Existing development data does not mask production schema issues.
- Mac -> iPhone and iPhone -> Mac sync for text, image, file preview, notes,
  Pages, renamed clips, and OCR text.

## Privacy Copy

Release notes and onboarding should say:

- Clipboard data stays on-device and in the user's private iCloud database.
- Concealed/transient pasteboard data is ignored.
- OCR runs locally with Apple Vision.
- Manual files are stored only when explicitly added and are currently capped.
