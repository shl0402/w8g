//
//  OfflineMapNetwork.swift
//  w8g
//
//  Created by Samuel on 1/10/2026.
//

import Foundation
import MapLibre

// This applies only to MapLibre's requests, never the login/routing API client.
nonisolated final class OfflineMapNetwork: @unchecked Sendable {
    static let shared = OfflineMapNetwork()
    private let lock = NSLock()
    private var enabled = false

    var allowsRequests: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); defer { lock.unlock() }; enabled = newValue }
    }

    @MainActor static func configure() {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [OfflineMapBlocker.self] + (configuration.protocolClasses ?? [])
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }
}

// Cached MapLibre resources still render; uncached requests fail locally when signed out.
nonisolated final class OfflineMapBlocker: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        let scheme = request.url?.scheme
        return (scheme == "http" || scheme == "https") && !OfflineMapNetwork.shared.allowsRequests
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() { }
}
