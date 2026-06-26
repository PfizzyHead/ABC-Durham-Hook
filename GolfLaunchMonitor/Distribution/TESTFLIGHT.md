# Shipping to TestFlight

Runbook for getting the **iOS SwingCapture** app in front of testers. (The macOS
app follows the same Archive → upload flow via the Mac App Store.) Use TestFlight
now to validate the capture app on real devices, before the detection model is
final and before any public App Store review.

## Prerequisites

- Active Apple Developer Program membership for your org (you have this).
- Xcode signed in to that account (Settings → Accounts).
- An app record in App Store Connect for the bundle ID
  `com.<yourorg>.SwingCapture` (Apps → ＋ → New App → iOS).
- Bundle-ID prefix updated from `com.example` in `SwingCaptureApp/project.yml`,
  and your Team set in **Signing & Capabilities**.

## Easiest path — Xcode Organizer (GUI)

```bash
cd SwingCaptureApp && xcodegen generate && open SwingCapture.xcodeproj
```

1. Select the **SwingCapture** scheme, destination **Any iOS Device**.
2. **Product → Archive**.
3. In the Organizer that opens: **Distribute App → App Store Connect → Upload**.
4. After processing, go to App Store Connect → your app → **TestFlight**, add
   internal testers, and they get the build.

## Scripted path (CLI)

```bash
cd SwingCaptureApp
xcodegen generate

xcodebuild -project SwingCapture.xcodeproj -scheme SwingCapture \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/SwingCapture.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/SwingCapture.xcarchive \
  -exportOptionsPlist ../Distribution/ExportOptions.plist \
  -exportPath build/export
```

Set `teamID` in `../Distribution/ExportOptions.plist` first. With
`destination = upload` the export step uploads straight to App Store Connect.
(For CI you'd authenticate with an App Store Connect API key via
`-authenticationKeyPath`; for local runs your signed-in Xcode account is used.)

## Notes

- **Internal TestFlight** (up to 100 testers on your team) needs no Beta App
  Review — ideal for trying the capture app immediately.
- **External TestFlight** and **public App Store** review require the app to be
  meaningfully functional, so hold those until the `SwingDetector` model is
  trained and the metrics work end-to-end.
- Increment `CURRENT_PROJECT_VERSION` (build number) in `project.yml` for each
  upload; App Store Connect rejects duplicate build numbers.
