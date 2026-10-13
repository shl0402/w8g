import SwiftUI
import UIKit

struct AIMessageBubble: View {
	let message: AIMessage
	@Binding var editingMessage: UUID?
	var canEdit: Bool
	@Binding var draft: String
	let submitEdit: (String) -> Bool
	@FocusState private var editingFocused: Bool

	var body: some View {
		HStack(alignment: .bottom, spacing: 8) {
			if message.isUser { Spacer(minLength: 36) }
			VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
				if !message.isUser {
					Label("Gemini", systemImage: "sparkles")
						.font(.caption.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
				}
                if editingMessage == message.id {
                    VStack(alignment: .trailing, spacing: 8) {
                        TextField("Edit message", text: $draft, axis: .vertical)
                            .lineLimit(2...10)
                            .focused($editingFocused)
                            .accessibilityLabel("Edit your message")
                        HStack {
                            Button("Cancel") { editingMessage = nil }
                            Spacer()
                            Button {
                                if submitEdit(draft) { editingMessage = nil }
                            } label: {
                                Image(systemName: "paperplane.fill").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Send edited message")
                            .disabled(!canEdit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 3000)
                        }.font(.subheadline.weight(.medium))
                    }
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    .onAppear { editingFocused = true }
                } else {
				Text(message.text)
					.textSelection(.enabled)
					.padding(.horizontal, 15).padding(.vertical, 12)
					.foregroundStyle(message.isUser ? Color.white : AppTheme.ink)
					.background(message.isUser ? AppTheme.ink : Color.white,
						in: RoundedRectangle(cornerRadius: 20))
					.contextMenu {
						Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
						ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
						if message.isUser { Button { draft = message.text; editingMessage = message.id } label: { Label("Edit message", systemImage: "pencil") }.disabled(!canEdit) }
					}
                }

				HStack(spacing: 5) {
					Text(message.date, style: .time)
					if message.isUser {
						Text(statusLabel)
					}
				}.font(.caption2).foregroundStyle(AppTheme.secondaryText)
			}
			if !message.isUser { Spacer(minLength: 36) }
		}
	}

	private var statusLabel: String {
		switch message.status {
		case .sent: "Sent"
		case .sending: "Sending…"
		case .failed: "Failed"
		case .cancelled: "Stopped"
		}
	}
}
