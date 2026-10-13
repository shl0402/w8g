import CoreLocation
import MapLibre

// Panning resets the next arrow action to locating the user.
enum SavedMapFocus {
    case route, user, free
    var next: SavedMapFocus { self == .user ? .route : .user }
}

@MainActor
final class SavedMapCamera {
    private(set) var focus: SavedMapFocus?
    private var targetID: UUID?
    private var requestedFocus: SavedMapFocus?
    private var wasShowingLocation = false
    private var revision = 0
    var onInteraction: () -> Void = { }
    var allowsRouteFit: Bool { focus == nil || focus == .route }

    func update(_ map: MLNMapView, focus: SavedMapFocus?, target: MapCameraTarget?) {
        // Apply commands once. Unrelated SwiftUI updates must not restore an old
        // focus while a gesture callback is waiting to update the view's state.
        let changed = requestedFocus != focus
            || (focus == .user && targetID != target?.id)
            || wasShowingLocation != map.showsUserLocation
        guard changed else { return }
        requestedFocus = focus
        wasShowingLocation = map.showsUserLocation
        revision += 1
        self.focus = focus
        guard let focus else { return } // Explore keeps its existing camera behaviour.
        if focus == .user, let target {
            if targetID != target.id {
                targetID = target.id
                map.setCenter(CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon),
                              zoomLevel: min(target.zoom, map.maximumZoomLevel), animated: false)
            }
            if map.showsUserLocation && map.userTrackingMode != .follow {
                map.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
            }
        } else if map.userTrackingMode != .none {
            map.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        }
    }

    func willChange(_ map: MLNMapView, reason: MLNCameraChangeReason) {
        let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate,
            .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
        guard focus != nil, !reason.intersection(gestures).isEmpty else { return }
        guard focus != .free else { return }
        focus = .free
        let gestureRevision = revision
        if map.userTrackingMode != .none { map.setUserTrackingMode(.none, animated: false, completionHandler: nil) }
        Task { @MainActor [weak self] in
            guard let self, self.revision == gestureRevision, self.focus == .free else { return }
            self.onInteraction()
        }
    }
}
