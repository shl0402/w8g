//
//  Place.swift
//  w8g
//
//  Created by Samuel on 29/9/2026.
//

import Foundation
import CoreLocation

struct Place: Codable, Identifiable, Equatable {
    let name: String
    let lat: Double
    let lon: Double
    var address: String?
    var nearby: String?
    var kind: String?
    var source: String?
    var attributions: [Attribution]? = nil
    struct Attribution: Codable, Equatable {
        let provider: String
        let uri: String?
    }

    var id: String {
        String(format: "%.5f,%.5f", locale: Locale(identifier: "en_US_POSIX"), lat, lon)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var subtitle: String {
        [address, nearby, kind].compactMap { $0 }
            .first { !$0.isEmpty } ?? "Hong Kong"
    }

    var isInHongKong: Bool {
        lat.isFinite && lon.isFinite
            && (22.08...22.6).contains(lat)
            && (113.8...114.5).contains(lon)
    }
}
