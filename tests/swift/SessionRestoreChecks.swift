import Foundation

// Stand-ins isolate the real AppSession state machine from network and Keychain.
struct Account: Equatable { let id: String }
struct SignupResponse { let user: Account?; let message: String? }
struct RecoveryRequest { let requestToken: String; let expiresAt: Double; let message: String }
@MainActor final class AuthService {
    static var pending: [CheckedContinuation<Account?, Error>] = []
    func restoreSession() async throws -> Account? {
        // Deliberately ignores cancellation to simulate an already queued reply.
        try await withCheckedThrowingContinuation { Self.pending.append($0) }
    }
    func signIn(login: String, password: String) async throws -> Account { Account(id: "manual") }
    func signUp(username: String, email: String, password: String) async throws -> SignupResponse { SignupResponse(user: nil, message: "Confirm email") }
    func requestPasswordReset(email: String) async throws -> RecoveryRequest { fatalError("Not used") }
    func passwordResetStatus(ticket: String) async throws -> String { "pending" }
    func finishPasswordReset(ticket: String, password: String) async throws -> String { "Updated" }
    func signOut() async throws { }
}

@main struct Checks {
    @MainActor static func waitForRequest() async {
        while AuthService.pending.isEmpty { await Task.yield() }
    }
    @MainActor static func main() async {
        for fails in [false, true] {
            let session = AppSession()
            let restore = Task { await session.restoreSession() }
            await waitForRequest()
            session.useManualSignIn()
            assert(!session.isRestoringSession)
            try? await Task.sleep(for: .milliseconds(1))
            await session.signIn(login: "test", password: "test")
            let reply = AuthService.pending.removeFirst()
            if fails { reply.resume(throwing: URLError(.timedOut)) }
            else { reply.resume(returning: Account(id: "old-account")) }
            await restore.value
            assert(session.account?.id == "manual")
            assert(session.restoreError == nil)
        }
        print("PASS: late success and late failure cannot replace manual login")

        let session = AppSession()
        let first = Task { await session.restoreSession() }
        await waitForRequest()
        let oldReply = AuthService.pending.removeFirst()
        session.useManualSignIn()
        let retry = Task { await session.restoreSession(force: true) }
        await waitForRequest()
        oldReply.resume(returning: nil)
        await first.value
        assert(session.isRestoringSession)
        AuthService.pending.removeFirst().resume(returning: Account(id: "retry-account"))
        await retry.value
        assert(!session.isRestoringSession && session.account?.id == "retry-account")
        print("PASS: old restore cannot dismiss or overwrite a newer retry")

        let failure = AppSession()
        let attempt = Task { await failure.restoreSession() }
        await waitForRequest()
        AuthService.pending.removeFirst().resume(throwing: URLError(.timedOut))
        await attempt.value
        assert(!failure.isRestoringSession && failure.restoreError != nil)
        failure.useManualSignIn()
        assert(failure.restoreError == nil)
        print("PASS: connection error still permits manual sign-in")
    }
}
