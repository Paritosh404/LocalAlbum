import CoreLocation
import Foundation
import SQLite3

struct ResolvedLocation: Codable, Hashable {
    let country: String
    let state: String
    let city: String
}

final class HybridLocationResolver {
    private let india = IndiaPlaceDatabase()
    private let geocoder = CLGeocoder()
    private var cache: [String: ResolvedLocation]
    private let cacheURL: URL?
    private var cacheIsDirty = false

    init() {
        let manager = FileManager.default
        let directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let resolvedCacheURL: URL?
        if let directory {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            resolvedCacheURL = directory.appendingPathComponent("LocationLookupCacheV2.json")
        } else {
            resolvedCacheURL = nil
        }
        cacheURL = resolvedCacheURL

        if let resolvedCacheURL,
           let data = try? Data(contentsOf: resolvedCacheURL),
           let decoded = try? JSONDecoder().decode([String: ResolvedLocation].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func resolve(_ location: CLLocation) async -> ResolvedLocation? {
        let key = cacheKey(for: location.coordinate)
        if let cached = cache[key] { return cached }

        if india.contains(location.coordinate),
           let result = india.nearestPlace(to: location.coordinate) {
            remember(result, for: key)
            return result
        }

        if let result = await resolveWithApple(location) {
            remember(result, for: key)
            return result
        }
        return nil
    }

    func flushCache() {
        guard cacheIsDirty, let cacheURL,
              let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try data.write(to: cacheURL, options: .atomic)
            cacheIsDirty = false
        } catch {
            // A cache write failure should never prevent photo organization.
        }
    }

    private func remember(_ value: ResolvedLocation, for key: String) {
        cache[key] = value
        cacheIsDirty = true
        if cache.count.isMultiple(of: 100) { flushCache() }
    }

    private func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private func resolveWithApple(_ location: CLLocation) async -> ResolvedLocation? {
        for attempt in 0..<4 {
            do {
                guard let placemark = try await geocoder.reverseGeocodeLocation(location).first else {
                    throw LocationResolverError.emptyResult
                }
                guard let country = nonEmpty(placemark.country)
                        ?? nonEmpty(placemark.isoCountryCode) else {
                    throw LocationResolverError.emptyResult
                }
                let state = nonEmpty(placemark.administrativeArea) ?? "Unknown State or Region"
                let city = nonEmpty(placemark.locality)
                    ?? nonEmpty(placemark.subAdministrativeArea)
                    ?? "Unknown City"
                return ResolvedLocation(country: country, state: state, city: city)
            } catch {
                guard attempt < 3 else { return nil }
                let delay = UInt64(attempt + 1) * 700_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private final class IndiaPlaceDatabase {
    private var database: OpaquePointer?
    private let boundary: IndiaBoundary?

    init() {
        boundary = IndiaBoundary.loadFromBundle()
        guard let url = Bundle.main.url(forResource: "IndiaPlaces", withExtension: "sqlite")
                ?? Bundle.main.url(forResource: "IndiaPlaces", withExtension: "sqlite", subdirectory: "Resources") else {
            return
        }
        if sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            database = nil
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        boundary?.contains(coordinate) == true
    }

    func nearestPlace(to coordinate: CLLocationCoordinate2D) -> ResolvedLocation? {
        guard let database else { return nil }
        let maximumDistance = 50.0
        let latitudeDelta = maximumDistance / 111.0
        let cosine = max(cos(coordinate.latitude * .pi / 180), 0.2)
        let longitudeDelta = maximumDistance / (111.0 * cosine)

        let sql = """
            SELECT p.name, COALESCE(s.name, ''), p.latitude, p.longitude,
                   p.population, p.feature_code
            FROM place_rtree r
            JOIN places p ON p.id = r.id
            LEFT JOIN states s ON s.code = p.state_code
            WHERE r.min_latitude >= ?1 AND r.max_latitude <= ?2
              AND r.min_longitude >= ?3 AND r.max_longitude <= ?4
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, coordinate.latitude - latitudeDelta)
        sqlite3_bind_double(statement, 2, coordinate.latitude + latitudeDelta)
        sqlite3_bind_double(statement, 3, coordinate.longitude - longitudeDelta)
        sqlite3_bind_double(statement, 4, coordinate.longitude + longitudeDelta)

        var candidates: [PlaceCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameText = sqlite3_column_text(statement, 0),
                  let stateText = sqlite3_column_text(statement, 1),
                  let featureText = sqlite3_column_text(statement, 5) else { continue }
            let name = String(decodingCString: nameText, as: UTF8.self)
            let state = String(decodingCString: stateText, as: UTF8.self)
            let latitude = sqlite3_column_double(statement, 2)
            let longitude = sqlite3_column_double(statement, 3)
            let population = sqlite3_column_int64(statement, 4)
            let featureCode = String(decodingCString: featureText, as: UTF8.self)
            let distance = haversine(
                from: coordinate,
                to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
            if distance <= maximumDistance {
                candidates.append(
                    PlaceCandidate(
                        name: name,
                        state: state,
                        distance: distance,
                        population: population,
                        featureCode: featureCode
                    )
                )
            }
        }

        guard !candidates.isEmpty else { return nil }
        let recognizedCities = candidates.filter {
            $0.distance <= catchmentRadius(for: $0)
                && ($0.population >= 100_000 || $0.featureCode.hasPrefix("PPLA") || $0.featureCode == "PPLC")
        }
        let chosen: PlaceCandidate?
        if recognizedCities.isEmpty {
            chosen = candidates.min(by: { $0.distance < $1.distance })
        } else {
            chosen = recognizedCities.min(by: { cityScore($0) < cityScore($1) })
        }
        guard let chosen else { return nil }
        return ResolvedLocation(
            country: "India",
            state: chosen.state.isEmpty ? "Unknown State or Region" : chosen.state,
            city: chosen.name
        )
    }

    private func catchmentRadius(for candidate: PlaceCandidate) -> Double {
        if candidate.population >= 1_000_000 || candidate.featureCode == "PPLC" { return 40 }
        if candidate.population >= 100_000 || candidate.featureCode.hasPrefix("PPLA") { return 30 }
        return 20
    }

    private func cityScore(_ candidate: PlaceCandidate) -> Double {
        let populationBonus = min(log10(Double(candidate.population) + 1) * 0.7, 5)
        let capitalBonus = candidate.featureCode.hasPrefix("PPLA") || candidate.featureCode == "PPLC" ? 1.5 : 0
        return candidate.distance - populationBonus - capitalBonus
    }

    private func haversine(
        from first: CLLocationCoordinate2D,
        to second: CLLocationCoordinate2D
    ) -> Double {
        let radius = 6_371.0
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let firstLatitude = first.latitude * .pi / 180
        let secondLatitude = second.latitude * .pi / 180
        let value = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return radius * 2 * atan2(sqrt(value), sqrt(1 - value))
    }
}

private struct PlaceCandidate {
    let name: String
    let state: String
    let distance: Double
    let population: Int64
    let featureCode: String
}

private struct IndiaBoundary: Decodable {
    let type: String
    let coordinates: [[[[Double]]]]

    static func loadFromBundle() -> IndiaBoundary? {
        guard let url = Bundle.main.url(forResource: "IndiaBoundary", withExtension: "json")
                ?? Bundle.main.url(forResource: "IndiaBoundary", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IndiaBoundary.self, from: data)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard type == "MultiPolygon" else { return false }
        let point = [coordinate.longitude, coordinate.latitude]
        for polygon in coordinates {
            guard let outer = polygon.first, pointInRing(point, ring: outer) else { continue }
            let isInHole = polygon.dropFirst().contains { pointInRing(point, ring: $0) }
            if !isInHole { return true }
        }
        return false
    }

    private func pointInRing(_ point: [Double], ring: [[Double]]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring.count - 1
        for current in ring.indices {
            let xi = ring[current][0]
            let yi = ring[current][1]
            let xj = ring[previous][0]
            let yj = ring[previous][1]
            let crosses = ((yi > point[1]) != (yj > point[1]))
                && (point[0] < (xj - xi) * (point[1] - yi) / (yj - yi) + xi)
            if crosses { inside.toggle() }
            previous = current
        }
        return inside
    }
}

private enum LocationResolverError: Error {
    case emptyResult
}
