import AppKit
import CoreLocation
import Foundation

/// Home geofence (300m) via machine location — reverse-geocoded address for UI.
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
            case .denied: return "Location denied — enable in System Settings"
            case .error(let m): return m
            }
        }
    }

    @Published private(set) var status: PlaceStatus = .homeNotSet
    @Published private(set) var homeSet: Bool = false
    @Published private(set) var lastAccuracy: CLLocationAccuracy = -1
    @Published private(set) var lastMessage: String?
    /// Nearest address for the saved home pin (reverse geocode).
    @Published private(set) var homeAddress: String?
    /// Distance from home in meters (if known).
    @Published private(set) var distanceFromHome: CLLocationDistance?

    var allowsRoutine: Bool {
        switch status {
        case .homeNotSet: return true
        case .atHome: return true
        case .locating: return true
        case .away, .denied, .error: return false
        }
    }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let defaultsHomeLat = "rise.home.lat"
    private let defaultsHomeLon = "rise.home.lon"
    private let defaultsHomeRadius = "rise.home.radius"
    private let defaultsHomeSet = "rise.home.set"
    private let defaultsHomeAddress = "rise.home.address"

    /// 300m — neighborhood-scale, not building-only.
    private(set) var homeRadius: CLLocationDistance = 300
    private var homeCoordinate: CLLocationCoordinate2D?
    private var pendingSetHome = false
    private var setHomeTimeout: Timer?

    var onStatusChange: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        loadHome()
        if homeSet {
            refreshAuthorizationAndStart()
        }
    }

    func refreshAuthorizationAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdates()
            recomputeStatus()
        case .denied, .restricted:
            status = .denied
            lastMessage = "Location access is off for Rise."
            notifyChange()
        @unknown default:
            break
        }
    }

    func setHomeHere() {
        pendingSetHome = true
        status = .locating
        lastMessage = "Getting your location…"
        notifyChange()

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            armSetHomeTimeout(seconds: 20)
            return

        case .denied, .restricted:
            pendingSetHome = false
            status = .denied
            lastMessage = "Location denied"
            notifyChange()
            presentDeniedAlert()
            return

        case .authorizedAlways, .authorizedWhenInUse:
            startUpdates()
            if let loc = usableLocation(manager.location) {
                finishSetHome(with: loc)
                return
            }
            manager.requestLocation()
            armSetHomeTimeout(seconds: 15)
            return

        @unknown default:
            pendingSetHome = false
            status = .error("Location unsupported")
            notifyChange()
            presentAlert(title: "Rise", text: "Location services are unavailable on this Mac.")
        }
    }

    func clearHome() {
        homeCoordinate = nil
        homeSet = false
        homeAddress = nil
        distanceFromHome = nil
        pendingSetHome = false
        setHomeTimeout?.invalidate()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: defaultsHomeLat)
        ud.removeObject(forKey: defaultsHomeLon)
        ud.removeObject(forKey: defaultsHomeAddress)
        ud.set(false, forKey: defaultsHomeSet)
        status = .homeNotSet
        lastMessage = "Home cleared"
        notifyChange()
        presentAlert(title: "Rise", text: "Home cleared. Breaks run everywhere again (within work hours).")
    }

    // MARK: - Internals

    private func armSetHomeTimeout(seconds: TimeInterval) {
        setHomeTimeout?.invalidate()
        setHomeTimeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingSetHome else { return }
                self.pendingSetHome = false
                self.status = self.homeSet ? self.status : .error("Couldn’t get location")
                self.lastMessage = "Timed out waiting for location"
                self.notifyChange()
                self.presentAlert(
                    title: "Couldn’t set home",
                    text: """
                    Rise didn’t receive a location fix.

                    Check Location Services is On and Rise is allowed, then try again.
                    """
                )
            }
        }
        if let t = setHomeTimeout {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func finishSetHome(with location: CLLocation) {
        setHomeTimeout?.invalidate()
        setHomeTimeout = nil
        pendingSetHome = false
        saveHome(coordinate: location.coordinate)
        lastAccuracy = location.horizontalAccuracy
        recomputeStatus(with: location)
        lastMessage = "Home set"
        notifyChange()

        // Reverse geocode for address display
        reverseGeocodeHome(location) { [weak self] address in
            guard let self else { return }
            let acc = location.horizontalAccuracy > 0
                ? String(format: "±%.0f m", location.horizontalAccuracy)
                : "ok"
            let radiusNote = "Within \(Int(self.homeRadius)) m of home"
            let body: String
            if let address, !address.isEmpty {
                body = """
                \(address)

                \(radiusNote) · GPS \(acc)
                Alerts run at home and pause when you’re farther away.
                """
            } else {
                body = """
                Home pin saved (\(radiusNote)).

                Couldn’t resolve a street address — GPS \(acc).
                Alerts still use the 300 m radius.
                """
            }
            self.presentAlert(title: "Home set", text: body)
        }
    }

    private func reverseGeocodeHome(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.homeAddress = nil
                    self.notifyChange()
                    completion(nil)
                    _ = error
                    return
                }
                let text = Self.formatAddress(placemarks?.first)
                self.homeAddress = text
                if let text {
                    UserDefaults.standard.set(text, forKey: self.defaultsHomeAddress)
                }
                self.notifyChange()
                completion(text)
            }
        }
    }

    private static func formatAddress(_ place: CLPlacemark?) -> String? {
        guard let place else { return nil }
        var parts: [String] = []
        // Prefer street-level
        if let sub = place.subThoroughfare, let thr = place.thoroughfare {
            parts.append("\(sub) \(thr)")
        } else if let thr = place.thoroughfare {
            parts.append(thr)
        } else if let name = place.name, place.thoroughfare == nil {
            // name alone can be a POI; only use if no street
            parts.append(name)
        }
        if let locality = place.locality { parts.append(locality) }
        if let area = place.administrativeArea { parts.append(area) }
        if let pc = place.postalCode { parts.append(pc) }
        let joined = parts.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    private func usableLocation(_ loc: CLLocation?) -> CLLocation? {
        guard let loc else { return nil }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 5000 else { return nil }
        guard abs(loc.timestamp.timeIntervalSinceNow) < 120 else { return nil }
        return loc
    }

    private func loadHome() {
        let ud = UserDefaults.standard
        homeSet = ud.bool(forKey: defaultsHomeSet)
        // Always prefer 300m; migrate old 150m installs
        let stored = ud.object(forKey: defaultsHomeRadius) as? Double
        homeRadius = 300
        if stored != 300 {
            ud.set(300.0, forKey: defaultsHomeRadius)
        }
        homeAddress = ud.string(forKey: defaultsHomeAddress)
        if homeSet {
            let lat = ud.double(forKey: defaultsHomeLat)
            let lon = ud.double(forKey: defaultsHomeLon)
            homeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            status = .locating
            // Refresh address if missing
            if homeAddress == nil {
                let loc = CLLocation(latitude: lat, longitude: lon)
                reverseGeocodeHome(loc) { _ in }
            }
        } else {
            status = .homeNotSet
        }
    }

    private func saveHome(coordinate: CLLocationCoordinate2D) {
        homeCoordinate = coordinate
        homeSet = true
        homeRadius = 300
        let ud = UserDefaults.standard
        ud.set(coordinate.latitude, forKey: defaultsHomeLat)
        ud.set(coordinate.longitude, forKey: defaultsHomeLon)
        ud.set(homeRadius, forKey: defaultsHomeRadius)
        ud.set(true, forKey: defaultsHomeSet)
    }

    private func startUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    private func recomputeStatus(with location: CLLocation? = nil) {
        guard homeSet, let home = homeCoordinate else {
            if !pendingSetHome { status = .homeNotSet }
            distanceFromHome = nil
            return
        }
        guard let location = usableLocation(location) ?? usableLocation(manager.location) else {
            status = .locating
            notifyChange()
            return
        }
        lastAccuracy = location.horizontalAccuracy
        let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
        let distance = location.distance(from: homeLoc)
        distanceFromHome = distance
        status = distance <= homeRadius ? .atHome : .away
        notifyChange()
    }

    private func notifyChange() {
        objectWillChange.send()
        onStatusChange?()
    }

    private func presentDeniedAlert() {
        presentAlert(
            title: "Location access needed",
            text: """
            Rise needs Location to know when you’re at home.

            System Settings → Privacy & Security → Location Services → Rise
            """,
            settings: true
        )
    }

    private func presentAlert(title: String, text: String, settings: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        if settings {
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if settings, response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.startUpdates()
                if self.pendingSetHome {
                    if let loc = self.usableLocation(manager.location) {
                        self.finishSetHome(with: loc)
                    } else {
                        manager.requestLocation()
                        self.armSetHomeTimeout(seconds: 15)
                    }
                } else {
                    self.recomputeStatus()
                }
            case .denied, .restricted:
                self.pendingSetHome = false
                self.setHomeTimeout?.invalidate()
                self.status = .denied
                self.lastMessage = "Location denied"
                self.notifyChange()
                if !self.homeSet {
                    self.presentDeniedAlert()
                }
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            if self.pendingSetHome, let good = self.usableLocation(loc) {
                self.finishSetHome(with: good)
                return
            }
            self.recomputeStatus(with: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let msg = error.localizedDescription
            if self.pendingSetHome {
                self.pendingSetHome = false
                self.setHomeTimeout?.invalidate()
                self.status = .error("Location failed")
                self.lastMessage = msg
                self.notifyChange()
                self.presentAlert(
                    title: "Couldn’t set home",
                    text: "Location error: \(msg)"
                )
            } else if self.homeSet {
                self.status = .error("Location unavailable")
                self.notifyChange()
            }
        }
    }
}
