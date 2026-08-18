# Location Albums

A native SwiftUI iPhone app that organizes existing Apple Photos assets into this structure:

```text
Organized Photos/
├── Mumbai, Maharashtra/
│   ├── 2024-01/
│   └── 2024-02/
├── Pune, Maharashtra/
│   └── 2024-03/
└── Unknown Location/
```

`Organized Photos` and each location are Photos folders. The month entries and `Unknown Location` are albums, because Apple Photos folders cannot directly contain photos.

## Location rules

- The app uses the photo's embedded GPS location, not the phone's current location.
- Apple's `locality` field represents city, town, village, or municipality. If it is missing, the app uses the county-level `subAdministrativeArea` value.
- The state (`administrativeArea`) is appended to avoid combining same-named cities.
- Neighborhoods, streets, landmarks, and tiny GPS differences do not affect the album name.
- If no suitable place is returned, the photo goes into `Unknown Location`.
- Photos are grouped into `yyyy-MM` using their creation date.

Albums reference the originals; the app does not duplicate or remove photos. Re-running it reuses the same folders and albums.

## Build locally on a Mac

1. Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate` in this folder.
3. Open `LocationAlbums.xcodeproj` in Xcode.
4. Select your Apple Developer team under **Signing & Capabilities**.
5. Connect an iPhone and press Run.

The deployment target is iOS 17.

## Build an IPA with GitHub Actions

Push the project to GitHub and run **Build IPA** from the Actions tab. Every push to `main` also runs it. Download `LocationAlbums-unsigned` from the run's **Artifacts** section.

The workflow creates an **unsigned** IPA so no signing certificate needs to be stored in GitHub. This is suitable for AltStore, which signs the IPA with your Apple ID during installation.

### Install with AltStore

1. Download `LocationAlbums-unsigned.ipa` from the GitHub Actions artifact and extract the artifact ZIP if necessary.
2. Open AltStore on the iPhone and choose **My Apps → +**.
3. Select `LocationAlbums-unsigned.ipa` from Files.
4. Keep AltServer available for the initial install and subsequent refreshes.

Free Apple Developer accounts generally require the app to be refreshed every seven days. Paid developer accounts have a longer signing period.
