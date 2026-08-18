import CoreLocation
import Combine
import Foundation
import Photos

@MainActor
final class PhotoAlbumOrganizer: ObservableObject {
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusText = ""
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published var photoAccessGranted = false

    private let rootFolderName = "Organized Media"
    private let reviewFolderName = "Needs Review"
    private let unknownLocationName = "Unknown Location"
    private let pendingLocationName = "Location Lookup Pending"
    private let locationResolver = HybridLocationResolver()
    private let groupingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
    private let monthNames: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.monthSymbols
    }()

    init() {
        refreshPermission()
    }

    func refreshPermission() {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited
    }

    func requestPhotoPermission() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited

        switch authorization {
        case .authorized:
            statusText = "Full Photos access granted"
        case .limited:
            statusText = "Limited Photos access granted"
        case .denied, .restricted:
            presentError("Photo access was not granted. Enable it in Settings → Privacy & Security → Photos.")
        case .notDetermined:
            presentError("Photos permission is still undetermined. Please try again.")
        @unknown default:
            presentError("The Photos permission state could not be determined.")
        }
    }

    func organize() async {
        guard !isRunning else { return }
        refreshPermission()
        guard photoAccessGranted else {
            presentError("Allow Photos access before organizing your library.")
            return
        }
        isRunning = true
        progress = 0
        statusText = "Reading Photos library…"
        defer { isRunning = false }

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAllBurstAssets = true
        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        guard fetchResult.count > 0 else {
            statusText = "No media found"
            return
        }

        var locatedGroups: [YearLocation: [MonthGroup: [PHAsset]]] = [:]
        var unknownAssets: [PHAsset] = []
        var pendingAssets: [PHAsset] = []
        var gpsAssets: [PHAsset] = []
        var resolvedAssets: [PHAsset] = []
        var locationCache: [CoordinateKey: LocationResolution] = [:]
        var legacyFlatCollections: Set<LegacyFlatCollection> = []
        var legacyStateFolders: Set<LegacyStateFolder> = []
        let totalAssets = fetchResult.count

        for index in 0..<totalAssets {
            let asset = fetchResult.object(at: index)
            statusText = "Reading locations \(index + 1) of \(totalAssets)…"
            progress = Double(index) / Double(totalAssets) * 0.72

            guard let location = asset.location,
                  CLLocationCoordinate2DIsValid(location.coordinate) else {
                unknownAssets.append(asset)
                continue
            }
            gpsAssets.append(asset)

            let cacheKey = CoordinateKey(location.coordinate)
            let resolution: LocationResolution
            if let cached = locationCache[cacheKey] {
                resolution = cached
            } else {
                if let resolvedLocation = await locationResolver.resolve(location) {
                    resolution = .resolved(resolvedLocation)
                } else {
                    resolution = .unresolved
                }
                locationCache[cacheKey] = resolution
            }

            guard case .resolved(let resolvedLocation) = resolution else {
                pendingAssets.append(asset)
                continue
            }

            let dateGroup = yearAndMonth(for: asset.creationDate)
            let hierarchy = hierarchyLocation(for: resolvedLocation)
            let locationKey = YearLocation(
                year: dateGroup.year,
                country: hierarchy.country,
                state: hierarchy.state,
                city: hierarchy.city
            )
            locatedGroups[locationKey, default: [:]][dateGroup.month, default: []].append(asset)
            legacyFlatCollections.insert(
                LegacyFlatCollection(
                    year: dateGroup.year,
                    name: "\(resolvedLocation.city), \(resolvedLocation.state)"
                )
            )
            if hierarchy.state == nil {
                legacyStateFolders.insert(
                    LegacyStateFolder(
                        year: dateGroup.year,
                        country: hierarchy.country,
                        state: resolvedLocation.state,
                        legacyCity: resolvedLocation.city,
                        targetCity: hierarchy.city
                    )
                )
            }
            resolvedAssets.append(asset)
        }
        locationResolver.flushCache()

        do {
            let root = try await findOrCreateRootFolder(named: rootFolderName)
            let reviewFolder = try await findOrCreateFolder(named: reviewFolderName, inside: root)
            let sortedGroups = locatedGroups.sorted {
                ($0.key.year, $0.key.country, $0.key.state ?? "", $0.key.city)
                    < ($1.key.year, $1.key.country, $1.key.state ?? "", $1.key.city)
            }
            let locationWrites = sortedGroups.reduce(0) { total, group in
                total + max(group.value.count, 1)
            }
            let totalWrites = locationWrites
                + (unknownAssets.isEmpty ? 0 : 1)
                + (pendingAssets.isEmpty ? 0 : 1)
            var completedWrites = 0

            // Repair earlier runs of the current hierarchy.
            if let oldUnknown = findAlbum(named: unknownLocationName, inside: reviewFolder), !gpsAssets.isEmpty {
                statusText = "Correcting Unknown Location…"
                try await remove(gpsAssets, from: oldUnknown)
            }
            if let oldPending = findAlbum(named: pendingLocationName, inside: reviewFolder), !resolvedAssets.isEmpty {
                try await remove(resolvedAssets, from: oldPending)
            }

            for (key, monthGroups) in sortedGroups {
                let hierarchyDescription = [key.year, key.country, key.state, key.city]
                    .compactMap { $0 }
                    .joined(separator: " / ")
                statusText = "Updating \(hierarchyDescription)…"
                let yearFolder = try await findOrCreateFolder(named: key.year, inside: root)
                let countryFolder = try await findOrCreateFolder(named: key.country, inside: yearFolder)
                let cityParent: PHCollectionList
                if let state = key.state {
                    cityParent = try await findOrCreateFolder(named: state, inside: countryFolder)
                } else {
                    cityParent = countryFolder
                }

                if monthGroups.count == 1, let assets = monthGroups.values.first {
                    let locationAlbum = try await findOrCreateAlbum(named: key.city, inside: cityParent)
                    try await add(assets, to: locationAlbum)
                    completedWrites += 1
                    progress = 0.72 + Double(completedWrites) / Double(max(totalWrites, 1)) * 0.28
                } else {
                    let locationFolder = try await findOrCreateFolder(named: key.city, inside: cityParent)
                    for (month, assets) in monthGroups.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }) {
                        let monthAlbum = try await findOrCreateAlbum(named: month.name, inside: locationFolder)
                        try await add(assets, to: monthAlbum)
                        completedWrites += 1
                        progress = 0.72 + Double(completedWrites) / Double(max(totalWrites, 1)) * 0.28
                    }

                    // Migration happens only after every month album has been populated.
                    if let oldSingleAlbum = findAlbum(named: key.city, inside: cityParent) {
                        try await deleteAlbum(oldSingleAlbum)
                    }
                }
            }

            // Remove older app-created hierarchy levels only after every new
            // destination has been populated. Original Photos assets remain intact.
            for legacy in legacyFlatCollections {
                guard let yearFolder = findFolder(named: legacy.year, inside: root) else { continue }
                if let album = findAlbum(named: legacy.name, inside: yearFolder) {
                    try await deleteAlbum(album)
                }
                if let folder = findFolder(named: legacy.name, inside: yearFolder) {
                    try await deleteFolder(folder)
                }
            }
            for legacy in legacyStateFolders {
                guard let yearFolder = findFolder(named: legacy.year, inside: root),
                      let countryFolder = findFolder(named: legacy.country, inside: yearFolder),
                      let stateFolder = findFolder(named: legacy.state, inside: countryFolder) else { continue }
                let destinationKey = YearLocation(
                    year: legacy.year,
                    country: legacy.country,
                    state: nil,
                    city: legacy.targetCity
                )
                let destinationUsesFolder = (locatedGroups[destinationKey]?.count ?? 0) > 1
                let stateIsDestination = destinationUsesFolder
                    && legacy.state.caseInsensitiveCompare(legacy.targetCity) == .orderedSame

                if stateIsDestination {
                    if let album = findAlbum(named: legacy.legacyCity, inside: stateFolder) {
                        try await deleteAlbum(album)
                    }
                    if let folder = findFolder(named: legacy.legacyCity, inside: stateFolder) {
                        try await deleteFolder(folder)
                    }
                } else {
                    try await deleteFolder(stateFolder)
                }
            }

            if !unknownAssets.isEmpty {
                statusText = "Updating \(unknownLocationName)…"
                let album = try await findOrCreateAlbum(named: unknownLocationName, inside: reviewFolder)
                try await add(unknownAssets, to: album)
            }

            if !pendingAssets.isEmpty {
                statusText = "Saving locations that need another lookup…"
                let album = try await findOrCreateAlbum(named: pendingLocationName, inside: reviewFolder)
                try await add(pendingAssets, to: album)
            }

            progress = 1
            statusText = "Organized \(totalAssets) media items across \(locatedGroups.count) locations"
        } catch {
            presentError("The albums could not be updated: \(error.localizedDescription)")
        }
    }

    private func yearAndMonth(for date: Date?) -> (year: String, month: MonthGroup) {
        guard let date else {
            return ("Unknown Date", MonthGroup(sortOrder: 99, name: "Unknown Date"))
        }
        let components = groupingCalendar.dateComponents([.year, .month], from: date)
        guard let year = components.year,
              let month = components.month,
              month >= 1,
              month <= monthNames.count else {
            return ("Unknown Date", MonthGroup(sortOrder: 99, name: "Unknown Date"))
        }
        return (String(format: "%04d", year), MonthGroup(sortOrder: month, name: monthNames[month - 1]))
    }

    private func hierarchyLocation(for location: ResolvedLocation) -> HierarchyLocation {
        let isIndia = location.country.caseInsensitiveCompare("India") == .orderedSame
        let isDelhi = location.state.caseInsensitiveCompare("Delhi") == .orderedSame
            || location.state.localizedCaseInsensitiveContains("Delhi")

        if isIndia && !isDelhi {
            return HierarchyLocation(country: "India", state: location.state, city: location.city)
        }
        if isIndia {
            return HierarchyLocation(country: "India", state: nil, city: "Delhi")
        }
        return HierarchyLocation(country: location.country, state: nil, city: location.city)
    }

    private func findOrCreateRootFolder(named name: String) async throws -> PHCollectionList {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        var matchingFolder: PHCollectionList?
        folders.enumerateObjects { folder, _, stop in
            if folder.localizedTitle == name && folder.canPerform(.addContent) {
                matchingFolder = folder
                stop.pointee = true
            }
        }
        if let existing = matchingFolder {
            return existing
        }
        return try await createFolder(named: name)
    }

    private func findOrCreateFolder(named name: String, inside parent: PHCollectionList) async throws -> PHCollectionList {
        if let existing = childCollections(in: parent).compactMap({ $0 as? PHCollectionList })
            .first(where: { $0.localizedTitle == name && $0.canPerform(.addContent) }) {
            return existing
        }
        let folder = try await createFolder(named: name)
        try await addChild(folder, to: parent)
        return folder
    }

    private func createFolder(named name: String) async throws -> PHCollectionList {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: name)
                .placeholderForCreatedCollectionList.localIdentifier
        }
        guard let identifier,
              let folder = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [identifier], options: nil
              ).firstObject else {
            throw OrganizerError.collectionCreationFailed(name)
        }
        return folder
    }

    private func findOrCreateAlbum(named name: String, inside parent: PHCollectionList) async throws -> PHAssetCollection {
        if let existing = childCollections(in: parent).compactMap({ $0 as? PHAssetCollection })
            .first(where: { $0.localizedTitle == name && $0.canPerform(.addContent) }) {
            return existing
        }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil
              ).firstObject else {
            throw OrganizerError.collectionCreationFailed(name)
        }
        try await addChild(album, to: parent)
        return album
    }

    private func findAlbum(named name: String, inside parent: PHCollectionList) -> PHAssetCollection? {
        childCollections(in: parent).compactMap { $0 as? PHAssetCollection }
            .first(where: { $0.localizedTitle == name })
    }

    private func findFolder(named name: String, inside parent: PHCollectionList) -> PHCollectionList? {
        childCollections(in: parent).compactMap { $0 as? PHCollectionList }
            .first(where: { $0.localizedTitle == name })
    }

    private func childCollections(in parent: PHCollectionList) -> [PHCollection] {
        let result = PHCollection.fetchCollections(in: parent, options: nil)
        var collections: [PHCollection] = []
        result.enumerateObjects { collection, _, _ in collections.append(collection) }
        return collections
    }

    private func addChild(_ child: PHCollection, to parent: PHCollectionList) async throws {
        guard parent.canPerform(.addContent) else {
            throw OrganizerError.collectionNotEditable(parent.localizedTitle ?? "Photos folder")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest(for: parent)?.addChildCollections([child] as NSArray)
        }
    }

    private func add(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        guard album.canPerform(.addContent) else {
            throw OrganizerError.collectionNotEditable(album.localizedTitle ?? "Photos album")
        }

        // Smaller transactions avoid oversized Photos change requests for large libraries.
        for start in stride(from: 0, to: assets.count, by: 500) {
            let end = min(start + 500, assets.count)
            let batch = Array(assets[start..<end])
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.addAssets(batch as NSArray)
            }
        }
    }

    private func remove(_ assets: [PHAsset], from album: PHAssetCollection) async throws {
        guard album.canPerform(.removeContent) else { return }
        for start in stride(from: 0, to: assets.count, by: 500) {
            let end = min(start + 500, assets.count)
            let batch = Array(assets[start..<end])
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(batch as NSArray)
            }
        }
    }

    private func deleteAlbum(_ album: PHAssetCollection) async throws {
        guard album.canPerform(.deleteContent) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
    }

    private func deleteFolder(_ folder: PHCollectionList) async throws {
        guard folder.canPerform(.deleteContent) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
        }
    }

    private func presentError(_ message: String) {
        statusText = ""
        alertMessage = message
        showAlert = true
    }
}

private struct YearLocation: Hashable {
    let year: String
    let country: String
    let state: String?
    let city: String
}

private struct HierarchyLocation {
    let country: String
    let state: String?
    let city: String
}

private struct LegacyFlatCollection: Hashable {
    let year: String
    let name: String
}

private struct LegacyStateFolder: Hashable {
    let year: String
    let country: String
    let state: String
    let legacyCity: String
    let targetCity: String
}

private struct MonthGroup: Hashable {
    let sortOrder: Int
    let name: String
}

private enum LocationResolution {
    case resolved(ResolvedLocation)
    case unresolved
}

private struct CoordinateKey: Hashable {
    let latitude: Int
    let longitude: Int

    init(_ coordinate: CLLocationCoordinate2D) {
        // Roughly 1 km buckets reduce duplicate lookups while ignoring tiny GPS drift.
        latitude = Int((coordinate.latitude * 100).rounded())
        longitude = Int((coordinate.longitude * 100).rounded())
    }
}

private enum OrganizerError: LocalizedError {
    case collectionCreationFailed(String)
    case collectionNotEditable(String)

    var errorDescription: String? {
        switch self {
        case .collectionCreationFailed(let name):
            return "Could not create “\(name)”."
        case .collectionNotEditable(let name):
            return "“\(name)” cannot be modified. Rename or remove the existing Photos item, then try again."
        }
    }
}
