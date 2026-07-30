import CoreLocation
import Foundation

/// Home geofence via machine location — breaks active at home, paused when away.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    enum PlaceStatus: Equatable {
        case homeNotSet
        case locating
        case atHome
        case away
        case denied
        case error(String)

        var menuLabel: String {
            switch self {
            case .homeNotSet: return "Home not set"
            case .locating: return "Locating…"
            case .atHome: return "At home"
            case .away: return "Away from home"
            case .denied: return "Location denied"
            case .error(let m): return m
            }
        }
    }

    @Published private(set) var status: PlaceStatus = .homeNotSet
    @Published private(set) var homeSet: Bool = false
    @Published private(set) var lastAccuracy: CLLocationAccuracy = -1

    /// When home is set, schedule only runs while at home.
    var allowsRoutine: Bool {
        switch status {
        case .homeNotSet: return true // no geofence yet
        case .atHome: return true
        case .locating: return true // don't pause while we figure it out
        case .away, .denied, .error: return false
        }
    }

    private let manager = CLLocationManager()
    private let defaultsHomeLat = "rise.home.lat"
    private let defaultsHomeLon = "rise.home.lon"
    private let defaultsHomeRadius = "rise.home.radius"
    private let defaultsHomeSet = "rise.home.set"

    /// Meters — ~building / block scale, not street-level stalking.
    private(set) var homeRadius: CLLocationDistance = 150

    private var homeCoordinate: CLLocationCoordinate2D?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        loadHome()
        refreshAuthorizationAndStart()
    }

    func refreshAuthorizationAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdates()
            recomputeStatus()
        case .denied, .restricted:
            status = homeSet ? .denied : .homeNotSet
        @unknown default:
            break
        }
    }

    /// Capture current location as home (user must be at home).
    func setHomeHere() {
        refreshAuthorizationAndStart()
        if let loc = manager.location {
            saveHome(coordinate: loc.coordinate)
            recomputeStatus(with: loc)
            return
        }
        // Wait for next fix
        pendingSetHome = true
        status = .locating
        startUpdates()
    }

    func clearHome() {
        homeCoordinate = nil
        homeSet = false
        UserDefaults.standard.removeObject(forKey: defaultsHomeLat)
        UserDefaults.standard.removeObject(forKey: defaultsHomeLon)
        UserDefaults.standard.set(false, forKey: defaultsHomeSet)
        status = .homeNotSet
        pendingSetHome = false
    }

    private var pendingSetHome = false

    private func loadHome() {
        let ud = UserDefaults.standard
        homeSet = ud.bool(forKey: defaultsHomeSet)
        homeRadius = ud.object(forKey: defaultsHomeRadius) as? Double ?? 150
        if homeSet {
            let lat = ud.double(forKey: defaultsHomeLat)
            let lon = ud.double(forKey: defaultsHomeLon)
            homeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            status = .locating
        } else {
            status = .homeNotSet
        }
    }

    private func saveHome(coordinate: CLLocationCoordinate2D) {
        homeCoordinate = coordinate
        homeSet = true
        let ud = UserDefaults.standard
        ud.set(coordinate.latitude, forKey: defaultsHomeLat)
        ud.set(coordinate.longitude, forKey: defaultsHomeLon)
        ud.set(homeRadius, forKey: defaultsHomeRadius)
        ud.set(true, forKey: defaultsHomeSet)
    }

    private func startUpdates() {
        manager.startUpdatingLocation()
        // Significant changes are cheaper for “at home / away”
        manager.startMonitoringSignificantLocationChanges()
    }

    private func recomputeStatus(with location: CLLocation? = nil) {
        guard homeSet, let home = homeCoordinate else {
            status = .homeNotSet
            return
        }
        guard let location = location ?? manager.location else {
            status = .locating
            return
        }
        lastAccuracy = location.horizontalAccuracy
        let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
        let distance = location.distance(from: homeLoc)
        status = distance <= homeRadius ? .atHome : .away
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthorizationAndStart()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            if self.pendingSetHome {
                self.pendingSetHome = false
                self.saveHome(coordinate: loc.coordinate)
            }
            self.recomputeStatus(with: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.homeSet {
                self.status = .error("Location unavailable")
            }
        }
    }
}
