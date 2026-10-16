import Foundation

// Extension-only transport adapter. Reuses the app's exact ArrivalService parser.
struct APIError: LocalizedError {
	let message: String
	var errorDescription: String? { message }
}
enum DirectAPI {
	static func json(_ url: URL) async throws -> [String: Any] {
		guard url.scheme == "https", ["rt.data.gov.hk", "data.etabus.gov.hk"].contains(url.host ?? "") else {
			throw APIError(message: "Invalid operator address")
		}
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 10
		config.timeoutIntervalForResource = 12
		config.httpCookieStorage = nil
		config.urlCredentialStorage = nil
		let session = URLSession(configuration: config)
		defer { session.invalidateAndCancel() }
		let (data, response) = try await session.data(from: url)
		guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
			data.count <= 4_000_000, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw APIError(message: "Operator unavailable")
		}
		return result
	}
}
