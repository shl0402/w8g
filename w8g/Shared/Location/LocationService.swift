//
//  LocationService.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var isLocating = false
    private(set) var isAuthorized = false
    private(set) var centerRequestID = UUID()
    private(set) var errorMessage: String?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var standalone = false
    @ObservationIgnored private var lastFix: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        updateAuthorization()
    }

    func locate(standalone: Bool = false) {
        guard !isLocating else { return }
        self.standalone = standalone
        errorMessage = nil
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") is String else {
            fail("The app's location permission description is missing. Check the top level of Info.plist.")
            return
        }
        isLocating = true
        startTimeout()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            updateAuthorization()
            if let lastFix, abs(lastFix.timestamp.timeIntervalSinceNow) < 15 {
                receive(lastFix)
            }
            if standalone && isLocating { manager.requestLocation() }
        case .denied, .restricted:
            fail("Allow Location access for w8g in iPhone Settings. You can still search for places.")
        @unknown default:
            fail("Location access is unavailable.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorization()
        if standalone && isLocating && isAuthorized { manager.requestLocation() }
        if isLocating && (manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted) {
            fail("Location access was not allowed. You can still search for places.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard standalone, isLocating else { return }
        receive(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard standalone, isLocating else { return }
        reportLocationError()
    }

    // MapLibre supplies live fixes; no second GPS-update stream is started here.
    func receive(_ fix: CLLocation?) {
        guard isAuthorized, let fix, fix.horizontalAccuracy >= 0,
            abs(fix.timestamp.timeIntervalSinceNow) < 30 else { return }
        lastFix = fix
        coordinate = fix.coordinate
        errorMessage = nil
        if isLocating {
            isLocating = false
            timeoutTask?.cancel()
            centerRequestID = UUID()
        }
    }

    func reportLocationError() {
        fail("Could not get your location. Check Location Services, then try again near a window or outdoors.")
    }

    func cancel() {
        isLocating = false
        timeoutTask?.cancel()
    }

    private func updateAuthorization() {
        isAuthorized = manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        if !isAuthorized {
            coordinate = nil
            lastFix = nil
        }
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            self?.fail("Still waiting for your location. Check permission and try again outdoors.")
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        isLocating = false
        timeoutTask?.cancel()
    }
}
