import UIKit
import MapLibre

// Run inside an iOS simulator harness, with a bundled local style (no server/GPS required).
@MainActor
enum SavedMapCameraChecks {
    static func run(styleURL: URL) async {
        let map = MLNMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 400), styleURL: styleURL)
        let camera = SavedMapCamera()
        var interactions = 0
        camera.onInteraction = { interactions += 1 }
        camera.update(map, focus: .route, target: nil)
        precondition(camera.allowsRouteFit)
        camera.willChange(map, reason: .gesturePan)
        camera.update(map, focus: .route, target: nil) // Stale SwiftUI input during an active gesture.
        precondition(camera.focus == .free && !camera.allowsRouteFit)
        for _ in 0..<10 { await Task.yield() }
        precondition(interactions == 1)
        camera.update(map, focus: .free, target: nil)
        let target = MapCameraTarget(lat: 22.283, lon: 114.137, zoom: 16)
        camera.update(map, focus: .user, target: target)
        precondition(camera.focus == .user && !camera.allowsRouteFit)
        precondition(abs(map.centerCoordinate.latitude - target.lat) < 0.00001)
        camera.willChange(map, reason: .gesturePan)
        camera.update(map, focus: .route, target: target) // Newer button tap wins over the queued gesture.
        for _ in 0..<10 { await Task.yield() }
        precondition(interactions == 1 && camera.focus == .route && camera.allowsRouteFit)
        camera.willChange(map, reason: .programmatic)
        for _ in 0..<10 { await Task.yield() }
        precondition(interactions == 1 && camera.focus == .route)
        precondition(SavedMapFocus.free.next == .user && SavedMapFocus.route.next == .user && SavedMapFocus.user.next == .route)
        print("PASS: pan survives stale update; new camera command wins over queued pan; programmatic moves do not reset focus")
    }
}
