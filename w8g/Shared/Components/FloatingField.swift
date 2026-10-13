//
//  FloatingField.swift
//  w8g
//
//  Created by Samuel on 26/9/2026.
//

import Foundation
import SwiftUI
import UIKit

struct FloatingField: View {
	let title: String
	@Binding var text: String

	var secure = false
	var contentType: UITextContentType? = nil
	var keyboard: UIKeyboardType = .default

    @State private var isPasswordVisible = false
	@FocusState private var isFocused: Bool
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var labelIsRaised: Bool {
		isFocused || !text.isEmpty
	}

	var body: some View {
		ZStack(alignment: .leading) {
			Text(title)
				.font(labelIsRaised ? .caption : .body)
				.foregroundStyle(AppTheme.secondaryText)
				.offset(y: labelIsRaised ? -17 : 0)
                .padding(.trailing, secure ? 44 : 0)
				.allowsHitTesting(false)
				.accessibilityHidden(true)

			Group {
                if secure && !isPasswordVisible {
                    SecureField("", text: $text)
				} else {
					TextField("", text: $text)
				}
			}
			.textFieldStyle(.plain)
			.textContentType(contentType)
			.keyboardType(keyboard)
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
			.focused($isFocused)
			.accessibilityLabel(title)
			.padding(.top, labelIsRaised ? 20 : 0)
            .padding(.trailing, secure ? 44 : 0)
		}
        .overlay(alignment: .trailing) {
            if secure {
                Button {
                    isPasswordVisible.toggle()

                    Task { @MainActor in
                        await Task.yield()
                        isFocused = true
                    }
                } label: {
                    Image(
                        systemName: isPasswordVisible
                            ? "eye.slash"
                            : "eye"
                    )
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isPasswordVisible
                        ? "Hide password"
                        : "Show password"
                )
            }
        }
		.padding(.horizontal, 16)
		.frame(minHeight: 68)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.white)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isFocused {
                        isFocused = true
                    }
                }
        }
		.overlay {
			RoundedRectangle(cornerRadius: 16)
				.strokeBorder(
					isFocused
						? AppTheme.ink
						: AppTheme.ink.opacity(0.12),
					lineWidth: 1
				)
                .allowsHitTesting(false)
		}
		.animation(
			reduceMotion ? nil : .easeOut(duration: 0.16),
			value: labelIsRaised
		)
	}
}
