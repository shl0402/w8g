import SwiftUI

struct ServicesSettingsView: View {
	let accountID: String
	@State private var key = ""
	@State private var visible = false
	@State private var message: String?
	@State private var testing = false
	var body: some View {
		Form {
			Section("Google Maps") {
				HStack {
					Group {
						if visible {
							TextField("Google Maps API key", text: $key)
						} else {
							SecureField("Google Maps API key", text: $key)
						}
					}.textInputAutocapitalization(.never).autocorrectionDisabled()
					Button {
						visible.toggle()
					} label: {
						Image(systemName: visible ? "eye.slash" : "eye").frame(
							width: 44, height: 44)
					}
					.buttonStyle(.plain).accessibilityLabel(
						visible ? "Hide key" : "Show key")
				}
				Button("Save key") {
					do {
						try DeviceAPIKeys.saveGoogle(key)
						message = "Saved on this iPhone."
						visible = false
					} catch { message = error.localizedDescription }
				}.disabled(
					key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing
				)
				Button("Test saved key") {
					testing = true
					Task {
						do {
							_ = try await GooglePlacesService().search(
								"Hong Kong Station")
							message =
								"Places API connected. Route access is checked when planning."
						} catch { message = error.localizedDescription }
						testing = false
					}
				}.disabled(testing)
				Button("Remove key", role: .destructive) {
					do {
						try DeviceAPIKeys.removeGoogle()
						key = ""
						message = "Key removed."
					} catch { message = error.localizedDescription }
				}.disabled(testing)
				if testing { ProgressView() }
				if let message { Text(message).font(.footnote) }
				Text(
					"Enable Places API (New) and Routes API in your Google project. Your provider may charge for searches and connection tests. Keys stay in this iPhone’s Keychain, shared between signed-in and guest modes; they are sent only to Google."
				).font(.footnote)
			}
			Section("AI") {
				NavigationLink("Gemini key and model") {
					GeminiSettingsView(accountID: accountID)
				}
			}
			Section("Live arrivals") {
				Text("MTR · KMB/LWB · Citybus")
				Text("Direct public operator APIs. No API key required.").font(.footnote)
				NavigationLink("Check next arrivals") { ArrivalsView() }
			}
		}
		.navigationTitle("Services").navigationBarTitleDisplayMode(.inline)
		.onAppear {
			do { key = try DeviceAPIKeys.google() ?? "" } catch {
				message = error.localizedDescription
			}
		}
	}
}
