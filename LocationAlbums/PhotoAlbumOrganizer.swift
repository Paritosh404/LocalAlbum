import CoreLocation
import Foundation
import Photos

@MainActor
final class PhotoAlbumOrganizer: ObservableObject {
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusText = ""
    @Published var showAlert = false
    @Published var alertMessage = ""

    private let rootFolderName = "Organized Photos"
    private let unknownLocationName = "Unknown Location"
    private let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    func organize() async {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        statusText = "Requesting photo access…"
        defer { isRunning = false }

        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            presentError("Photo access is required. Enable it in Settings → Privacy & Security → Photos.")
            return
        }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: nil)
        guard fetchResult.count > 0 else {
            statusText = "No photos found"
            return
        }

        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        var locatedGroups: [LocationMonth: [PHAsset]] = [:]
        var unknownAssets: [PHAsset] = []
        var locationCache: [CoordinateKey: String?] = [:]
        let geocoder = CLGeocoder()

        for (index, asset) in assets.enumerated() {
            statusText = "Reading locations \(index + 1) of \(assets.count)…"
            progress = Double(index) / Double(assets.count) * 0.72

            guard let location = asset.location else {
                unknownAssets.append(asset)
                continue
            }

            let cacheKey = CoordinateKey(location.coordinate)
            let placeName: String?
            if let cached = locationCache[cacheKey] {
                placeName = cached
            } else {
                placeName = await cityAndState(for: location, using: geocoder)
                locationCache[cacheKey] = placeName
            }

            guard let placeName else {
                unknownAssets.append(asset)
                continue
            }

            let month = asset.creationDate.map(monthFormatter.string(from:)) ?? "Unknown Date"
            locatedGroups[LocationMonth(place: placeName, month: month), default: []].append(asset)
        }

        do {
            let root = try await findOrCreateRootFolder(named: rootFolderName)
            let sortedGroups = locatedGroups.sorted {
                ($0.key.place, $0.key.month) < ($1.key.place, $1.key.month)
            }
            let totalWrites = sortedGroups.count + (unknownAssets.isEmpty ? 0 : 1)
            var completedWrites = 0

            for (key, groupAssets) in sortedGroups {
                statusText = "Updating \(key.place) / \(key.month)…"
                let cityFolder = try await findOrCreateFolder(named: key.place, inside: root)
                let monthAlbum = try await findOrCreateAlbum(named: key.month, inside: cityFolder)
                try await add(groupAssets, to: monthAlbum)
                completedWrites += 1
                progress = 0.72 + Double(completedWrites) / Double(max(totalWrites, 1)) * 0.28
            }

            if !unknownAssets.isEmpty {
                statusText = "Updating \(unknownLocationName)…"
                let album = try await findOrCreateAlbum(named: unknownLocationName, inside: root)
                try await add(unknownAssets, to: album)
            }

            progress = 1
            let cityCount = Set(locatedGroups.keys.map(\.place)).count
            statusText = "Organized \(assets.count) photos across \(cityCount) locations"
        } catch {
            presentError("The albums could not be updated: \(error.localizedDescription)")
        }
    }

    /// Apple's locality represents city, town, village, or municipality.
    /// If it is absent, subAdministrativeArea is the county fallback.
    private func cityAndState(for location: CLLocation, using geocoder: CLGeocoder) async -> String? {
        do {
            guard let placemark = try await geocoder.reverseGeocodeLocation(location).first else { return nil }
            guard let place = nonEmpty(placemark.locality) ?? nonEmpty(placemark.subAdministrativeArea) else {
                return nil
            }
            if let state = nonEmpty(placemark.administrativeArea), state != place {
                return "\(place), \(state)"
            }
            if let country = nonEmpty(placemark.country), country != place {
                return "\(place), \(country)"
            }
            return place
        } catch {
            return nil
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func findOrCreateRootFolder(named name: String) async throws -> PHCollectionList {
        let folders = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
        var matchingFolder: PHCollectionList?
        folders.enumerateObjects { folder, _, stop in
            if folder.localizedTitle == name {
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
            .first(where: { $0.localizedTitle == name }) {
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
            .first(where: { $0.localizedTitle == name }) {
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

    private func childCollections(in parent: PHCollectionList) -> [PHCollection] {
        let result = PHCollection.fetchCollections(in: parent, options: nil)
        var collections: [PHCollection] = []
        result.enumerateObjects { collection, _, _ in collections.append(collection) }
        return collections
    }

    private func addChild(_ child: PHCollection, to parent: PHCollectionList) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHCollectionListChangeRequest(for: parent)?.addChildCollections([child] as NSArray)
        }
    }

    private func add(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    private func presentError(_ message: String) {
        statusText = ""
        alertMessage = message
        showAlert = true
    }
}

private struct LocationMonth: Hashable {
    let place: String
    let month: String
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

    var errorDescription: String? {
        switch self {
        case .collectionCreationFailed(let name):
            return "Could not create “\(name)”."
        }
    }
}
