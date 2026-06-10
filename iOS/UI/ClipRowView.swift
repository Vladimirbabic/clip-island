import SwiftUI
import UIKit

/// One row in the history list: kind icon (or downsampled thumbnail),
/// two-line preview (link title for fetched URLs), source app + relative
/// time subtitle, and a pin badge.
struct ClipRowView: View {
    let item: ClipItem

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            leadingThumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.body)
                    .lineLimit(2)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 2)
    }

    /// Links that already have macOS-fetched metadata lead with their title.
    private var primaryText: String {
        if item.kind == .url, let title = item.linkTitle, !title.isEmpty {
            return title
        }
        return item.preview
    }

    @ViewBuilder
    private var leadingThumbnail: some View {
        if hasImagePayload, let thumbnail = ClipThumbnailLoader.thumbnail(for: item) {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(item.kind == .url ? "Link preview" : "Image preview")
        } else {
            Image(systemName: item.kind.systemImageName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(kindColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(item.kind.displayName)
        }
    }

    private var hasImagePayload: Bool {
        (item.kind == .image || item.kind == .url) && item.imageData != nil
    }

    private var kindColor: Color {
        switch item.kind {
        case .text: return .blue
        case .url: return .indigo
        case .image: return .green
        case .file: return .gray
        }
    }

    private var subtitleText: String {
        let time = Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: .now)
        guard let source = item.sourceAppName, !source.isEmpty else { return time }
        return "\(source) · \(time)"
    }
}
