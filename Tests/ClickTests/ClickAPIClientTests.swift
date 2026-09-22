import Testing
import Foundation
@testable import Click

@Suite("Click API Client & Error Taxonomy Tests")
struct ClickAPIClientTests {
    @Test("APIError localized descriptions are user-safe and clear")
    func apiErrorDescriptions() {
        let offlineErr = APIError.offline
        #expect(offlineErr.localizedDescription.contains("offline"))

        let authErr = APIError.unauthorized
        #expect(authErr.localizedDescription.contains("expired"))

        let valErr = APIError.validation(code: "400", message: "Email format is invalid.")
        #expect(valErr.localizedDescription == "Email format is invalid.")
    }

    @Test("APIRequest constructs expected defaults")
    func apiRequestDefaults() {
        let req = APIRequest(path: "/api/ping")
        #expect(req.path == "/api/ping")
        #expect(req.method == .get)
        #expect(req.requiresAuth == true)
        #expect(req.body == nil)
        #expect(req.headers.isEmpty)
    }
}
