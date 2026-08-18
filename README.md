# Location Albums

A native SwiftUI iPhone app that organizes existing Apple Photos assets into this structure:

```text
Organized Media/
├── 2026/
│   └── India/
│       ├── Ladakh/
│       │   └── Leh/
│       │       ├── January/
│       │       └── February/
│       └── Maharashtra/
│           └── Pune/
├── 2025/
│   └── India/
│       └── Delhi/
│           └── New Delhi/
└── Needs Review/
    ├── Unknown Location/
    └── Location Lookup Pending/
```

`Organized Media`, each year, country, state, multi-month city, and `Needs Review` are Photos folders. A single-month city is one album directly inside its state. Multi-month cities contain clearly named month albums such as `January` and `February`.

## Location rules

- The app processes every Photos-library asset type, including photos, Live Photos, videos, and other media returned by PhotoKit.
- It uses each asset's saved GPS location, not the phone's current location.
- Apple's `locality` field represents city, town, village, or municipality. If it is missing, the app uses the county-level `subAdministrativeArea` value.
- Country and state are retained as separate hierarchy levels so same-named cities are never combined accidentally.
- Neighborhoods, streets, landmarks, and tiny GPS differences do not affect the album name.
- Only assets with no valid GPS coordinate go into `Unknown Location`.
- GPS-bearing assets whose lookup temporarily fails go into `Location Lookup Pending`, never `Unknown Location`.
- Apple's worldwide fallback is retried up to four times; running the organizer again retries pending locations.
- Located media is grouped as `Year → Country → State → City`.
- A city represented in only one month remains a single city album inside its state.
- A city represented in multiple months becomes a city folder containing named month albums.
- Re-running the organizer reuses the year folders and albums and repairs the current hierarchy's review albums.

Albums reference the originals; the app does not duplicate or remove photos. Re-running it reuses the same folders and albums.

## Offline location lookup

- Indian coordinates use the bundled indexed GeoNames database containing 557,995 populated places and all 36 state/UT mappings.
- Major cities use wider catchment areas: up to 40 km for million-plus metros and 30 km for other major or administrative cities. This folds nearby smaller localities into the major city while retaining distinct major cities.
- A simplified India boundary prevents coordinates in neighboring countries from being treated as Indian.
- Coordinates outside India, or Indian coordinates without a sensible nearby match, use Apple's reverse geocoder.
- Both offline and Apple results are saved in a persistent on-device cache.
- The bundled source data is © GeoNames and licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Build locally on a Mac

1. Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate` in this folder.
3. Open `LocationAlbums.xcodeproj` in Xcode.
4. Select your Apple Developer team under **Signing & Capabilities**.
5. Connect an iPhone and press Run.

The deployment target is iOS 17.

## Build an IPA with GitHub Actions

Push the project to GitHub and run **Build iPhone IPA** from the Actions tab. Every push to `main` also runs it. Download `LocationAlbums-v1.9-unsigned-ipa` from the run's **Artifacts** section.

The workflow creates an **unsigned** IPA so no signing certificate needs to be stored in GitHub. This is suitable for AltStore, which signs the IPA with your Apple ID during installation.

### Install with AltStore

1. Download the Actions artifact, extract it, and locate `LocationAlbums-v1.9-unsigned.ipa`.
2. Open AltStore on the iPhone and choose **My Apps → +**.
3. Select `LocationAlbums-v1.9-unsigned.ipa` from Files.
4. Keep AltServer available for the initial install and subsequent refreshes.

Free Apple Developer accounts generally require the app to be refreshed every seven days. Paid developer accounts have a longer signing period.

## Version 1.9 country hierarchy and wider city grouping

- Declares both Photos privacy descriptions in `project.yml`, so XcodeGen preserves them when regenerating `Info.plist`.
- Verifies the privacy keys in the compiled app before GitHub Actions packages the IPA.
- Uses the proven two-step Photos authorization flow from PhotoUSBBackup: grant access first, then organize.
- Prevents the organizer from scanning until Photos authorization is confirmed.
- Includes every PhotoKit media type instead of filtering for images.
- Retries and paces reverse geocoding instead of treating transient failures as unknown GPS.
- Uses `Organized Media → Year → Country → State → City`.
- Adds month albums inside a city only when that city contains media from multiple months.
- Groups nearby smaller Indian localities under a major city using wider population-aware catchment areas.
- Migrates app-created `Year → City, State` albums and folders after their replacement hierarchy is populated; original media is never deleted.
- Places location problems together under `Needs Review`.
- Resolves Indian GPS coordinates locally without API pacing or network access.
- Uses Apple geocoding only as the worldwide fallback.
- Checks that existing Photos folders and albums allow changes before modifying them.
- Adds photos in batches to avoid oversized Photos library transactions.

If a second month appears on a later run, the app fills the new month albums first and then deletes its old direct location album. Deleting that album does not delete any original media.
