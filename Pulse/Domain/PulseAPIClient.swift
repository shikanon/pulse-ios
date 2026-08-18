import Foundation

struct PublishResponse: Decodable { let url: URL }

struct PulseAPIClient {
    // Swap this development URL for the deployed private API hostname at release time.
    var baseURL = URL(string: "http://localhost:8787/v1")!

    func publish(app: InteractiveApp) async throws -> URL {
        var request = URLRequest(url: baseURL.appending(path: "apps"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(app)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(PublishResponse.self, from: data).url
    }
}
