//
//  w8gApp.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import SwiftUI

@main
struct w8gApp: App {
    init() {
        OfflineMapNetwork.configure()
    }
	var body: some Scene {
		WindowGroup {
			ContentView()
		}
	}
}
