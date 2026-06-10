import SwiftUI

/// Brief bottom-of-screen capsule used for copy feedback ("Copied" /
/// "Nothing to copy").
struct FeedbackBanner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Feedback content for a copy attempt; success drives text and icon.
struct CopyFeedback: Equatable {
    let text: String
    let systemImage: String

    init(success: Bool) {
        self.text = success ? "Copied" : "Nothing to copy"
        self.systemImage = success ? "checkmark.circle.fill" : "exclamationmark.circle"
    }
}
