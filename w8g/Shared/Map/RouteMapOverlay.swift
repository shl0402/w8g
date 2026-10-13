//
//  RouteMapOverlay.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation
import MapLibre
import SwiftUI
import UIKit

// Owned by W8gMapView.Coordinator; drawing is separate from search and route requests.
@MainActor
final class RouteMapOverlay {
    private var journey: Journey?
    private var styleID: ObjectIdentifier?
    private var drawnID: String?
    private var fitID: UUID?
    private var needsFit = false
    private var fittedSize = CGSize.zero
    private var coordinates: [CLLocationCoordinate2D] = []
    private var layerIDs: [String] = []
    private var sourceIDs: [String] = []
    private var pins: [MLNPointAnnotation] = []

    func update(_ map: MLNMapView, journey: Journey?, fitID: UUID) {
        if self.journey?.id != journey?.id {
            self.journey = journey
            coordinates = journey?.mapCoordinates ?? []
            needsFit = journey != nil
        }
        if self.fitID != fitID {
            self.fitID = fitID
            needsFit = journey != nil
        }
        refreshStyle(map)
    }

    func refreshStyle(_ map: MLNMapView) {
        guard let style = map.style else { return }
        let newStyleID = ObjectIdentifier(style)
        guard drawnID != journey?.id || styleID != newStyleID else { return }
        if styleID == newStyleID {
            for id in layerIDs { if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) } }
            for id in sourceIDs {
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
        }
        layerIDs = []
        sourceIDs = []
        map.removeAnnotations(pins)
        pins = []
        styleID = newStyleID
        drawnID = journey?.id
        guard let journey else { return }
        for (index, leg) in journey.displayLegs.enumerated() {
            var points = leg.coordinates
            guard points.count >= 2 else { continue }
            let id = "w8g-route-\(index)"
            let shape = MLNPolyline(coordinates: &points, count: UInt(points.count))
            let source = MLNShapeSource(identifier: id, shape: shape, options: nil)
            style.addSource(source)
            sourceIDs.append(id)
            let outline = MLNLineStyleLayer(identifier: id + "-outline", source: source)
            outline.lineColor = NSExpression(forConstantValue: UIColor.white)
            outline.lineWidth = NSExpression(forConstantValue: 8)
            style.addLayer(outline)
            layerIDs.append(outline.identifier)
            let line = MLNLineStyleLayer(identifier: id + "-line", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor(TransitAppearance.color(leg)))
            line.lineWidth = NSExpression(forConstantValue: 5)
            if leg.isWalking { line.lineDashPattern = NSExpression(forConstantValue: [1, 1.5]) }
            style.addLayer(line)
            layerIDs.append(line.identifier)
        }
        for (index, stop) in journey.stops.enumerated() where stop.isInHongKong {
            let pin = MLNPointAnnotation()
            pin.coordinate = stop.coordinate
            pin.title =
                (index == 0
                    ? "Start: " : index == journey.stops.count - 1 ? "Destination: " : "Stop \(index): ")
                + stop.name
            pins.append(pin)
        }
        map.addAnnotations(pins)
        needsFit = true
    }

    // Called after rendering so fitting uses the real map height above the results panel.
    // Panning/zooming does not refit; only a new route, a resize or the fit button does.
    func fitIfNeeded(_ map: MLNMapView, enabled: Bool = true) {
        guard enabled, journey != nil, !coordinates.isEmpty, map.style != nil,
            map.bounds.width > 0, map.bounds.height > 0,
            needsFit || fittedSize != map.bounds.size
        else { return }
        needsFit = false
        fittedSize = map.bounds.size
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
            let minLon = longitudes.min(), let maxLon = longitudes.max()
        else { return }
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: minLat - 0.0003, longitude: minLon - 0.0003),
            ne: CLLocationCoordinate2D(latitude: maxLat + 0.0003, longitude: maxLon + 0.0003)
        )
        let padding = UIEdgeInsets(
            top: min(150, map.bounds.height * 0.38), left: 40,
            bottom: min(100, map.bounds.height * 0.3), right: 50)
        map.direction = 0
        map.setVisibleCoordinateBounds(bounds, edgePadding: padding, animated: false, completionHandler: nil)
    }
}
