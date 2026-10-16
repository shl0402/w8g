//
//  AIPlacePicker.swift
//  w8g
//
//  Created by Samuel on 2/10/2026.
//

import Foundation
import SwiftUI

struct AIPlacePicker: View {
    let direct: Bool
    let choose: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [Place] = []
    @State private var loading = false
    @State private var errorMessage: String?

    init(query: String = "", direct: Bool = false, choose: @escaping (Place) -> Void) {
        _query = State(initialValue: query)
        self.choose = choose
        self.direct = direct
    }

    var body: some View {
        NavigationStack {
            List {
                if direct { GoogleAttributionView(places: results) }
                if loading { ProgressView("Searching…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(results) { place in
                    Button {
                        choose(place)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name).foregroundStyle(AppTheme.ink)
                            Text(place.subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
                if !loading && results.isEmpty && query.count >= 2 && errorMessage == nil {
                    Text("No matches. Try a fuller name or coordinates.")
                }
            }
            .searchable(text: $query, prompt: "Place name or coordinates")
            .navigationTitle("Choose location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                results = []
                errorMessage = nil
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { loading = false; return }
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    let found = try await (direct ? GooglePlacesService().search(query) : PlaceService().search(query))
                    try Task.checkCancellation()
                    results = found
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
                loading = false
            }
        }
        .tint(AppTheme.ink)
    }
}
