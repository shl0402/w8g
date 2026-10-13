//
//  AccountEntryView.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import Foundation
import SwiftUI

enum AccountScreen: Hashable {
	case signIn
	case signUp
	case resetPassword

	var title: String {
		switch self {
		case .signIn: "Sign in"
		case .signUp: "Create account"
		case .resetPassword: "Reset password"
		}
	}

	var buttonTitle: String {
		self == .resetPassword ? "Send reset link" : title
	}
}

struct AccountEntryView: View {
	let screen: AccountScreen
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var confirmationPassword = ""
	@State private var username = ""
	@State private var email = ""
	@State private var password = ""

    private var canSubmit: Bool {
        guard !session.isWorking else {
            return false
        }

        let hasUsername = !username.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty

        let hasEmail = !email.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty

        switch screen {
        case .signIn:
            return hasUsername && !password.isEmpty
            
        case .signUp:
            return hasUsername && hasEmail && !password.isEmpty
            
        case .resetPassword:
            switch session.recoveryStage {
            case .request:
                return hasEmail
            case .confirm:
                return false
            case .changePassword:
                return (8...200).contains(password.count)
                && password == confirmationPassword
            case .done:
                return false
            }
        }
    }
        
    private var submitTitle: String {
        guard screen == .resetPassword else { return screen.buttonTitle }
        switch session.recoveryStage {
        case .request: return "Send reset link"
        case .confirm: return "Waiting for email confirmation…"
        case .changePassword: return "Update password"
        case .done: return "Password updated"
        }
    }

    private var shouldCheckRecovery: Bool {
        screen == .resetPassword
            && session.recoveryStage == .confirm
            && scenePhase == .active
    }

    private var entryTitle: String {
        guard screen == .resetPassword else { return screen.title }
        switch session.recoveryStage {
        case .confirm: return "Check your email"
        case .done: return "Password updated"
        default: return screen.title
        }
    }

    private var showsSubmitButton: Bool {
        screen != .resetPassword
            || session.recoveryStage == .request
            || session.recoveryStage == .changePassword
    }

    private var recoveryInstruction: String? {
        session.recoveryStage == .request
            ? "Enter the email linked to your account."
            : nil
    }
        
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 28) {
				if screen == .signIn {
					HStack(spacing: 12) {
						Image("W8gLogo")
							.resizable()
							.scaledToFit()
							.frame(width: 48, height: 48)
							.accessibilityHidden(true)

						Text("w8g")
							.font(.title.bold())
					}
					.padding(.bottom, 12)
				}

                HStack(spacing: 12) {
                    if screen == .resetPassword && session.recoveryStage == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }

                    Text(entryTitle)
                        .font(.title2.bold())
                }
                .accessibilityElement(children: .combine)

                if screen == .resetPassword, let instruction = recoveryInstruction {
                    Text(instruction)
                    .foregroundStyle(AppTheme.secondaryText)
				}

				VStack(spacing: 12) {
					if screen != .resetPassword {
						FloatingField(
							title: screen == .signIn
								? "Username or email"
								: "Username",
							text: $username,
							contentType: .username
						)
					}

                    if screen != .signIn && (screen != .resetPassword || session.recoveryStage == .request) {
						FloatingField(
							title: "Email",
							text: $email,
							contentType: .emailAddress,
							keyboard: .emailAddress
						)
					}

					if screen != .resetPassword {
						FloatingField(
							title: "Password",
							text: $password,
							secure: true,
							contentType: screen == .signUp
								? .newPassword
								: .password
						)
					}
                    
                    if screen == .resetPassword {
                        if session.recoveryStage == .confirm {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Waiting for confirmation")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        }
                        if session.recoveryStage == .changePassword {
                            FloatingField(
                                title: "New password",
                                text: $password,
                                secure: true,
                                contentType: .newPassword
                            )
                            FloatingField(
                                title: "Confirm new password",
                                text: $confirmationPassword,
                                secure: true,
                                contentType: .newPassword
                            )
                        }
                    }

					if screen == .signIn {
						NavigationLink(
							value: AccountScreen.resetPassword
						) {
							Text("Forgot password?")
								.font(.subheadline.weight(.medium))
								.frame(minHeight: 44)
						}
						.frame(
							maxWidth: .infinity,
							alignment: .trailing
						)
					}
				}

                    if let message = session.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                
                    if screen != .resetPassword, let message = session.infoMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.ink)
                    }
                
                if showsSubmitButton {
                    Button {
                        Task {
                            switch screen {
                            case .signIn:
                                await session.signIn(
                                    login: username,
                                    password: password
                                )
                                
                            case .signUp:
                                await session.signUp(
                                    username: username,
                                    email: email,
                                    password: password
                                )
                                
                            case .resetPassword:
                                switch session.recoveryStage {
                                case .request:
                                    await session.requestPasswordReset(email: email)
                                case .confirm:
                                    break
                                case .changePassword:
                                    await session.finishPasswordReset(
                                        password: password,
                                        confirmation: confirmationPassword
                                    )
                                case .done:
                                    break
                                }
                            }
                            
                            password = ""
                            confirmationPassword = ""
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if session.isWorking {
                                ProgressView()
                                    .tint(.white)
                            }
                            
                            Text(
                                session.isWorking
                                ? "Please wait…"
                                : submitTitle
                            )
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .foregroundStyle(.white)
                        .background(
                            AppTheme.ink,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .opacity(canSubmit || session.isWorking ? 1 : 0.55)
                }
                
                if screen == .resetPassword && session.recoveryStage != .request {
                    Button(session.recoveryStage == .done ? "Back to sign in" : "Cancel reset") {
                        session.clearPasswordReset()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }

				if screen == .signIn {
                    NavigationLink(value: AccountScreen.signUp) {
						Text("Create an account")
							.font(.subheadline.weight(.semibold))
							.frame(
								maxWidth: .infinity,
								minHeight: 44
							)
					}

					Divider()

					NavigationLink(value: AppDestination.offline) {
						HStack(spacing: 14) {
							Image(systemName: "bookmark")
								.font(.title3)

							VStack(alignment: .leading, spacing: 4) {
								Text("Continue offline")
									.font(
										.subheadline.weight(.semibold)
									)

								Text("Open routes saved on this iPhone")
									.font(.footnote)
									.foregroundStyle(
										AppTheme.secondaryText
									)
							}

							Spacer(minLength: 4)

							Image(systemName: "chevron.right")
								.font(.caption.weight(.semibold))
						}
						.padding(16)
						.background(
							AppTheme.ink.opacity(0.04),
							in: RoundedRectangle(cornerRadius: 16)
						)
					}

                    if session.restoreError != nil {
                        Button("Retry saved sign-in") {
                            Task { await session.restoreSession(force: true) }
                        }
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
				}
			}
			.padding(.horizontal, 24)
			.padding(.vertical, 24)
			.frame(maxWidth: 440)
			.frame(maxWidth: .infinity)
		}
        .disabled(session.isWorking)
		.background(AppTheme.background)
		.foregroundStyle(AppTheme.ink)
		.scrollDismissesKeyboard(.interactively)
		.navigationBarTitleDisplayMode(.inline)
        .task(id: shouldCheckRecovery) {
            guard shouldCheckRecovery else { return }
            while !Task.isCancelled {
                await session.checkPasswordReset()
                guard session.recoveryStage == .confirm else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
        .onAppear {
            if screen == .resetPassword {
                session.isResetScreenVisible = true
            } else {
                session.errorMessage = nil
                session.infoMessage = nil
            }
        }
        .onDisappear {
            if screen == .resetPassword {
                session.isResetScreenVisible = false
            }
        }
	}
}
