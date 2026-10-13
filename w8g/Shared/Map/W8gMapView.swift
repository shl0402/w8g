//
//  W8gMapView.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import SwiftUI
import CoreLocation
import MapLibre

struct MapCameraTarget: Equatable {
    let id = UUID()
    let lat: Double
    let lon: Double
    let zoom: Double
}

struct W8gMapView: UIViewRepresentable {
    let place: Place?
    let cameraTarget: MapCameraTarget?
    let showsLocation: Bool
    let onLocation: (CLLocation?) -> Void
    let onLocationError: () -> Void
    let reloadID: UUID
    let onError: (String?) -> Void
    let journey: Journey?
    let routeFitID: UUID
    var savedFocus: SavedMapFocus? = nil
    var onMapInteraction: () -> Void = { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError, onLocation: onLocation, onLocationError: onLocationError)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(
            frame: .zero,
            styleURL: URL(string: "https://tiles.openfreemap.org/styles/liberty")
        )
        map.delegate = context.coordinator
        map.showsUserHeadingIndicator = true
        map.showsUserLocation = showsLocation
        map.setCenter(
            CLLocationCoordinate2D(latitude: 22.31, longitude: 114.17),
            zoomLevel: 10.5, animated: false
        )
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 16, y: 92)
        // Keep the provider's built-in attribution button visible.
        context.coordinator.reloadID = reloadID
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onError = onError
        coordinator.onLocation = onLocation
        coordinator.onLocationError = onLocationError
        if map.showsUserLocation != showsLocation {
            map.showsUserLocation = showsLocation
        }
        if coordinator.reloadID != reloadID {
            coordinator.reloadID = reloadID
            map.reloadStyle(map)
        }

        if coordinator.selectedID != place?.id {
            if let pin = coordinator.placePin { map.removeAnnotation(pin) }
            coordinator.placePin = nil
            coordinator.selectedID = place?.id
            if let place {
                let pin = MLNPointAnnotation()
                pin.coordinate = place.coordinate
                pin.title = place.name
                map.addAnnotation(pin)
                coordinator.placePin = pin
            }
        }

        if savedFocus == nil, let target = cameraTarget, target.id != coordinator.cameraID {
            coordinator.cameraID = target.id
            map.setCenter(
                CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon),
                zoomLevel: target.zoom, animated: map.style != nil
            )
        }
        coordinator.savedCamera.onInteraction = onMapInteraction
        coordinator.savedCamera.update(map, focus: savedFocus, target: cameraTarget)
        coordinator.routeOverlay.update(map, journey: journey, fitID: routeFitID)
        // A stationary map may not render another frame just because fitID changed.
        coordinator.routeOverlay.fitIfNeeded(map, enabled: coordinator.savedCamera.allowsRouteFit)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.showsUserLocation = false
        map.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var onError: (String?) -> Void
        let routeOverlay = RouteMapOverlay()
        let savedCamera = SavedMapCamera()
        var cameraID: UUID?
        var reloadID: UUID?
        var selectedID: String?
        var placePin: MLNPointAnnotation?
        var onLocation: (CLLocation?) -> Void
        var onLocationError: () -> Void

        init(
            onError: @escaping (String?) -> Void,
            onLocation: @escaping (CLLocation?) -> Void,
            onLocationError: @escaping () -> Void
        ) {
            self.onError = onError
            self.onLocation = onLocation
            self.onLocationError = onLocationError
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            savedCamera.willChange(mapView, reason: reason)
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            let fix = userLocation?.location
            Task { @MainActor [weak self] in self?.onLocation(fix) }
        }

        func mapView(_ mapView: MLNMapView, didFailToLocateUserWithError error: Error) {
            Task { @MainActor [weak self] in self?.onLocationError() }
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            routeOverlay.refreshStyle(mapView)
            Task { @MainActor [weak self] in self?.onError(nil) }
        }

        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            routeOverlay.fitIfNeeded(mapView, enabled: savedCamera.allowsRouteFit)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            Task { @MainActor [weak self] in
                self?.onError("The map could not load. Check your internet connection and retry.")
            }
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            true
        }
    }
}
