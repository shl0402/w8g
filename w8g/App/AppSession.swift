//
//  AppSession.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import Foundation

import Observation

enum RecoveryStage: Equatable {
    case request
    case confirm
    case changePassword
    case done
}

@Observable
@MainActor
final class AppSession {
    private(set) var isGuest = UserDefaults.standard.bool(forKey: "w8g.onlineGuest")
    func enterGuest() {
        guard account == nil else { return }
        useManualSignIn()
        isGuest = true
        UserDefaults.standard.set(true, forKey: "w8g.onlineGuest")
    }
    func leaveGuest() {
        isGuest = false
        UserDefaults.standard.set(false, forKey: "w8g.onlineGuest")
    }
    private(set) var account: Account?
    private(set) var isWorking = false
    private(set) var isRestoringSession = true
    private(set) var restoreError: String?

    @ObservationIgnored private var hasAttemptedRestore = false
    @ObservationIgnored private var restoreTask: Task<Account?, Error>?
    @ObservationIgnored private var restoreAttempt = UUID()

    func restoreSession(force: Bool = false) async {
        if isGuest { useManualSignIn(); return }
        guard !isWorking, account == nil, force || !hasAttemptedRestore else { return }
        restoreTask?.cancel()
        let attempt = UUID()
        restoreAttempt = attempt
        hasAttemptedRestore = true
        isRestoringSession = true
        restoreError = nil
        let task = Task { try await auth.restoreSession() }
        restoreTask = task
        defer {
            if restoreAttempt == attempt {
                isRestoringSession = false
                restoreTask = nil
            }
        }
        do {
            let restored = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard restoreAttempt == attempt, !Task.isCancelled else { return }
            account = restored
        } catch {
            guard restoreAttempt == attempt, !Task.isCancelled, !task.isCancelled else { return }
            restoreError = "Your saved sign-in could not be checked. " + readableMessage(for: error)
        }
    }

    func useManualSignIn() {
        // Invalidate first: a late restore reply must never replace a manual login.
        restoreAttempt = UUID()
        restoreTask?.cancel()
        restoreTask = nil
        hasAttemptedRestore = true
        isRestoringSession = false
        restoreError = nil
    }

    var errorMessage: String?
    var infoMessage: String?
    
    private(set) var recoveryStage = RecoveryStage.request
    var isResetScreenVisible = false

    @ObservationIgnored private var recoveryTicket: String?
    @ObservationIgnored private var recoveryExpiresAt: Date?
    @ObservationIgnored private let auth = AuthService()

    func signIn(login: String, password: String) async {
        guard !isWorking else {
            return
        }

        useManualSignIn()
        isWorking = true
        errorMessage = nil

        defer {
            isWorking = false
        }

        do {
            account = try await auth.signIn(
                login: login.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                password: password
            )
            restoreError = nil
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }
    
    func signUp(
        username: String,
        email: String,
        password: String
    ) async {
        guard !isWorking else {
            return
        }

        isWorking = true
        errorMessage = nil
        infoMessage = nil

        defer {
            isWorking = false
        }

        do {
            let response = try await auth.signUp(
                username: username.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                email: email.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                password: password
            )

            if let user = response.user {
                account = user
            } else {
                infoMessage = response.message
            }
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }
    
    func requestPasswordReset(email: String) async {
        guard !isWorking, recoveryStage == .request else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        infoMessage = nil
        guard !trimmedEmail.isEmpty else {
            errorMessage = "Enter your email address."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await auth.requestPasswordReset(email: trimmedEmail)
            recoveryTicket = response.requestToken
            recoveryExpiresAt = Date(timeIntervalSince1970: response.expiresAt)
            recoveryStage = .confirm
            infoMessage = response.message
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    func checkPasswordReset() async {
            guard !isWorking, recoveryStage == .confirm,
                let ticket = recoveryTicket
            else {
                return
            }
            guard let expires = recoveryExpiresAt, expires > Date() else {
                clearPasswordReset()
                errorMessage = "Request expired. Request a new reset email."
                return
            }

            do {
                let state = try await auth.passwordResetStatus(ticket: ticket)
                // Ignore replies from a cancelled check or an older reset request.
                guard !Task.isCancelled,
                    recoveryTicket == ticket,
                    recoveryStage == .confirm
                else {
                    return
                }

                switch state {
                case "pending":
                    errorMessage = nil
                case "confirmed":
                    errorMessage = nil
                    recoveryStage = .changePassword
                    infoMessage = "Email verified. Choose your new password."
                case "expired", "used":
                    clearPasswordReset()
                    errorMessage = "This request expired or was used. Request a new email."
                default:
                    errorMessage = "Could not read the confirmation status. Checking again shortly."
                }
            } catch {
                guard !Task.isCancelled,
                    recoveryTicket == ticket,
                    recoveryStage == .confirm
                else {
                    return
                }
                errorMessage = readableMessage(for: error)
            }
        }

    func finishPasswordReset(password: String, confirmation: String) async {
        guard !isWorking, recoveryStage == .changePassword,
            let ticket = recoveryTicket
        else { return }
        errorMessage = nil
        guard (8...200).contains(password.count) else {
            errorMessage = "Use a password of 8–200 characters."
            return
        }
        guard password == confirmation else {
            errorMessage = "The two passwords do not match."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            infoMessage = try await auth.finishPasswordReset(
                ticket: ticket, password: password
            )
            recoveryTicket = nil
            recoveryExpiresAt = nil
            recoveryStage = .done
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    func acceptPasswordResetLink(_ url: URL) async {
        guard url.scheme == "w8g", url.host == "auth", url.path == "/reset" else {
            return
        }
        guard recoveryTicket != nil else {
            errorMessage = "Request a reset email in this app first. If the app was closed completely, request a new link."
            return
        }
        // Opening the app is optional. The server is the source of approval.
        await checkPasswordReset()
    }

    func clearPasswordReset() {
        recoveryTicket = nil
        recoveryExpiresAt = nil
        recoveryStage = .request
        errorMessage = nil
        infoMessage = nil
    }

    func signOut() async {
        guard !isWorking else {
            return
        }

        isWorking = true
        errorMessage = nil

        defer {
            isWorking = false
        }

        do {
            try await auth.signOut()
            account = nil
            restoreError = nil
        } catch {
            errorMessage = readableMessage(for: error)
        }
    }

    private func readableMessage(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost,
                .cannotFindHost,
                .notConnectedToInternet,
                .timedOut:
                return "Cannot reach the server. Check that it is running, your Wi-Fi connection, and Local Network permission."

            case .appTransportSecurityRequiresSecureConnection:
                return "The local server connection is blocked by the app's network settings."

            default:
                return "The connection was interrupted. Please try again."
            }
        }

        if error is DecodingError {
            return "The server response could not be read. Please try again."
        }

        return error.localizedDescription
    }
}
