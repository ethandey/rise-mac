import AppKit
import CoreLocation
import Foundation

/// Named desk places (home / office) with 300 m geofences.
/// Home and office use the **same** full desk routine; only standing-desk flag is per-place.
/// Away from all set places → café soft mode.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    enum PlaceKind: String, CaseIterable {
        case home
        case office

        var title: String {
            switch self {
            case .home: return "Home"
            case .office: return "Office"
            }
        }
    }

    enum PlaceStatus: Equatable {
        case noneSet
        case locating
        case atHome
        case atOffice
        case away
        case denied
        case error(String)

        var menuLabel: String {
            switch self {
            case .noneSet: return "No places set"
            case .locating: return "Locating…"
            case .atHome: return "At home"
            case .atOffice: return "At office"
            case .away: return "Away (café mode)"
            case .denied: return "Location denied — enable in System Settings"
            case .error(let m): return m
            }
        }
    }

    @Published private(set) var status: PlaceStatus = .noneSet
    @Published private(set) var homeSet: Bool = false
    @Published private(set) var officeSet: Bool = false
    @Published private(set) var homeAddress: String?
    @Published private(set) var officeAddress: String?
    @Published private(set) var homeHasStandingDesk: Bool = true
    @Published private(set) var officeHasStandingDesk: Bool = true
    @Published private(set) var lastAccuracy: CLLocationAccuracy = -1
    @Published private(set) var lastMessage: String?
    @Published private(set) var distanceFromHome: CLLocationDistance?
    @Published private(set) var distanceFromOffice: CLLocationDistance?

    /// Schedule may run. Denied/error pause.
    var allowsRoutine: Bool {
        switch status {
        case .noneSet, .atHome, .atOffice, .locating, .away: return true
        case .denied, .error: return false
        }
    }

    /// Outside all set desk places → café soft popups.
    var isCafeMode: Bool {
        if case .away = status { return true }
        return false
    }

    /// At a desk place (home or office) — full firm routine.
    var isAtDeskPlace: Bool {
        switch status {
        case .atHome, .atOffice: return true
        default: return false
        }
    }

    /// Standing desk for the place you’re at (or home default if none set).
    var standingDeskForCurrentPlace: Bool {
        switch status {
        case .atHome: return homeHasStandingDesk
        case .atOffice: return officeHasStandingDesk
        case .noneSet, .locating:
            // No geofence yet — use home preference if set, else home default
            if homeSet { return homeHasStandingDesk }
            if officeSet { return officeHasStandingDesk }
            return homeHasStandingDesk
        case .away, .denied, .error:
            return false
        }
    }

    var anyPlaceSet: Bool { homeSet || officeSet }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let placeRadius: CLLocationDistance = 300

    private var homeCoordinate: CLLocationCoordinate2D?
    private var officeCoordinate: CLLocationCoordinate2D?
    private var pendingKind: PlaceKind?
    private var setTimeout: Timer?

    var onStatusChange: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        loadPlaces()
        if anyPlaceSet {
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

    // MARK: - Set / clear places

    /// Pin home to current location (replaces any previous home pin).
    func setHomeHere() { beginSet(kind: .home) }

    /// Pin office to current location (replaces any previous office pin).
    func setOfficeHere() { beginSet(kind: .office) }

    func setStandingDesk(for kind: PlaceKind, enabled: Bool) {
        switch kind {
        case .home:
            homeHasStandingDesk = enabled
            UserDefaults.standard.set(enabled, forKey: Keys.homeStanding)
        case .office:
            officeHasStandingDesk = enabled
            UserDefaults.standard.set(enabled, forKey: Keys.officeStanding)
        }
        // Keep legacy key in sync for current place
        UserDefaults.standard.set(standingDeskForCurrentPlace, forKey: "rise.desk.hasStanding")
        notifyChange()
    }

    // MARK: - Internals

    private enum Keys {
        static let homeLat = "rise.home.lat"
        static let homeLon = "rise.home.lon"
        static let homeSet = "rise.home.set"
        static let homeAddress = "rise.home.address"
        static let homeStanding = "rise.place.home.hasStanding"
        static let officeLat = "rise.office.lat"
        static let officeLon = "rise.office.lon"
        static let officeSet = "rise.office.set"
        static let officeAddress = "rise.office.address"
        static let officeStanding = "rise.place.office.hasStanding"
        static let radius = "rise.home.radius"
    }

    private func beginSet(kind: PlaceKind) {
        pendingKind = kind
        status = .locating
        lastMessage = "Getting your location…"
        notifyChange()

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            armTimeout(seconds: 20)
        case .denied, .restricted:
            pendingKind = nil
            status = .denied
            lastMessage = "Location denied"
            notifyChange()
            presentDeniedAlert()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdates()
            if let loc = usableLocation(manager.location) {
                finishSet(kind: kind, with: loc)
            } else {
                manager.requestLocation()
                armTimeout(seconds: 15)
            }
        @unknown default:
            pendingKind = nil
            status = .error("Location unsupported")
            notifyChange()
            presentAlert(title: "Rise", text: "Location services are unavailable on this Mac.")
        }
    }

    private func armTimeout(seconds: TimeInterval) {
        setTimeout?.invalidate()
        setTimeout = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingKind != nil else { return }
                let kind = self.pendingKind!
                self.pendingKind = nil
                self.recomputeStatus()
                self.lastMessage = "Timed out waiting for location"
                self.notifyChange()
                self.presentAlert(
                    title: "Couldn’t set \(kind.title.lowercased())",
                    text: """
                    Rise didn’t receive a location fix.

                    Check Location Services is On and Rise is allowed, then try again.
                    """
                )
            }
        }
        if let t = setTimeout {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func finishSet(kind: PlaceKind, with location: CLLocation) {
        setTimeout?.invalidate()
        setTimeout = nil
        pendingKind = nil
        let updating: Bool
        switch kind {
        case .home: updating = homeSet
        case .office: updating = officeSet
        }
        // Overwrites previous pin for this place
        save(kind: kind, coordinate: location.coordinate)
        lastAccuracy = location.horizontalAccuracy
        recomputeStatus(with: location)
        lastMessage = "\(kind.title) \(updating ? "updated" : "set")"
        notifyChange()

        reverseGeocode(kind: kind, location: location) { [weak self] address in
            guard let self else { return }
            let acc = location.horizontalAccuracy > 0
                ? String(format: "±%.0f m", location.horizontalAccuracy)
                : "ok"
            let verb = updating ? "updated" : "set"
            let body: String
            if let address, !address.isEmpty {
                body = """
                \(address)

                Within \(Int(self.placeRadius)) m · GPS \(acc)
                Previous pin replaced.
                """
            } else {
                body = """
                \(kind.title) pin \(verb) (within \(Int(self.placeRadius)) m).
                GPS \(acc). Previous pin replaced if one existed.
                """
            }
            self.presentAlert(title: "\(kind.title) \(verb)", text: body)
        }
    }

    private func reverseGeocode(kind: PlaceKind, location: CLLocation, completion: @escaping (String?) -> Void) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    completion(nil)
                    return
                }
                let text = Self.formatAddress(placemarks?.first)
                switch kind {
                case .home:
                    self.homeAddress = text
                    if let text { UserDefaults.standard.set(text, forKey: Keys.homeAddress) }
                case .office:
                    self.officeAddress = text
                    if let text { UserDefaults.standard.set(text, forKey: Keys.officeAddress) }
                }
                self.notifyChange()
                completion(text)
            }
        }
    }

    private static func formatAddress(_ place: CLPlacemark?) -> String? {
        guard let place else { return nil }
        var parts: [String] = []
        if let sub = place.subThoroughfare, let thr = place.thoroughfare {
            parts.append("\(sub) \(thr)")
        } else if let thr = place.thoroughfare {
            parts.append(thr)
        } else if let name = place.name, place.thoroughfare == nil {
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

    private func loadPlaces() {
        let ud = UserDefaults.standard
        ud.set(placeRadius, forKey: Keys.radius)

        homeSet = ud.bool(forKey: Keys.homeSet)
        officeSet = ud.bool(forKey: Keys.officeSet)
        homeAddress = ud.string(forKey: Keys.homeAddress)
        officeAddress = ud.string(forKey: Keys.officeAddress)

        // Standing desk: migrate legacy global flag to home if needed
        if ud.object(forKey: Keys.homeStanding) != nil {
            homeHasStandingDesk = ud.bool(forKey: Keys.homeStanding)
        } else if ud.object(forKey: "rise.desk.hasStanding") != nil {
            homeHasStandingDesk = ud.bool(forKey: "rise.desk.hasStanding")
            ud.set(homeHasStandingDesk, forKey: Keys.homeStanding)
        } else {
            homeHasStandingDesk = true
            ud.set(true, forKey: Keys.homeStanding)
        }
        if ud.object(forKey: Keys.officeStanding) != nil {
            officeHasStandingDesk = ud.bool(forKey: Keys.officeStanding)
        } else {
            officeHasStandingDesk = true
            ud.set(true, forKey: Keys.officeStanding)
        }

        if homeSet {
            homeCoordinate = CLLocationCoordinate2D(
                latitude: ud.double(forKey: Keys.homeLat),
                longitude: ud.double(forKey: Keys.homeLon)
            )
            if homeAddress == nil, let c = homeCoordinate {
                reverseGeocode(kind: .home, location: CLLocation(latitude: c.latitude, longitude: c.longitude)) { _ in }
            }
        }
        if officeSet {
            officeCoordinate = CLLocationCoordinate2D(
                latitude: ud.double(forKey: Keys.officeLat),
                longitude: ud.double(forKey: Keys.officeLon)
            )
            if officeAddress == nil, let c = officeCoordinate {
                reverseGeocode(kind: .office, location: CLLocation(latitude: c.latitude, longitude: c.longitude)) { _ in }
            }
        }

        status = anyPlaceSet ? .locating : .noneSet
    }

    private func save(kind: PlaceKind, coordinate: CLLocationCoordinate2D) {
        let ud = UserDefaults.standard
        switch kind {
        case .home:
            homeCoordinate = coordinate
            homeSet = true
            ud.set(coordinate.latitude, forKey: Keys.homeLat)
            ud.set(coordinate.longitude, forKey: Keys.homeLon)
            ud.set(true, forKey: Keys.homeSet)
        case .office:
            officeCoordinate = coordinate
            officeSet = true
            ud.set(coordinate.latitude, forKey: Keys.officeLat)
            ud.set(coordinate.longitude, forKey: Keys.officeLon)
            ud.set(true, forKey: Keys.officeSet)
        }
        ud.set(placeRadius, forKey: Keys.radius)
    }

    private func startUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    private func recomputeStatus(with location: CLLocation? = nil) {
        guard anyPlaceSet else {
            if pendingKind == nil { status = .noneSet }
            distanceFromHome = nil
            distanceFromOffice = nil
            notifyChange()
            return
        }
        guard let location = usableLocation(location) ?? usableLocation(manager.location) else {
            if pendingKind == nil { status = .locating }
            notifyChange()
            return
        }
        lastAccuracy = location.horizontalAccuracy

        var inHome = false
        var inOffice = false
        if homeSet, let home = homeCoordinate {
            let d = location.distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
            distanceFromHome = d
            inHome = d <= placeRadius
        } else {
            distanceFromHome = nil
        }
        if officeSet, let office = officeCoordinate {
            let d = location.distance(from: CLLocation(latitude: office.latitude, longitude: office.longitude))
            distanceFromOffice = d
            inOffice = d <= placeRadius
        } else {
            distanceFromOffice = nil
        }

        // Prefer the closer match if both overlap (unlikely)
        if inHome, inOffice {
            let dh = distanceFromHome ?? .greatestFiniteMagnitude
            let doff = distanceFromOffice ?? .greatestFiniteMagnitude
            status = dh <= doff ? .atHome : .atOffice
        } else if inHome {
            status = .atHome
        } else if inOffice {
            status = .atOffice
        } else {
            status = .away
        }
        UserDefaults.standard.set(standingDeskForCurrentPlace, forKey: "rise.desk.hasStanding")
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
            Rise needs Location to know when you’re at home or the office.

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
                if let kind = self.pendingKind {
                    if let loc = self.usableLocation(manager.location) {
                        self.finishSet(kind: kind, with: loc)
                    } else {
                        manager.requestLocation()
                        self.armTimeout(seconds: 15)
                    }
                } else {
                    self.recomputeStatus()
                }
            case .denied, .restricted:
                self.pendingKind = nil
                self.setTimeout?.invalidate()
                self.status = .denied
                self.lastMessage = "Location denied"
                self.notifyChange()
                if !self.anyPlaceSet {
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
            if let kind = self.pendingKind, let good = self.usableLocation(loc) {
                self.finishSet(kind: kind, with: good)
                return
            }
            self.recomputeStatus(with: loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let msg = error.localizedDescription
            if let kind = self.pendingKind {
                self.pendingKind = nil
                self.setTimeout?.invalidate()
                self.recomputeStatus()
                self.lastMessage = msg
                self.notifyChange()
                self.presentAlert(
                    title: "Couldn’t set \(kind.title.lowercased())",
                    text: "Location error: \(msg)"
                )
            } else if self.anyPlaceSet {
                self.status = .error("Location unavailable")
                self.notifyChange()
            }
        }
    }
}
