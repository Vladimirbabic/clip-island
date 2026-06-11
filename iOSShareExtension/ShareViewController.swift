import SwiftData
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await saveSharedContent() }
    }

    private func configureView() {
        view.backgroundColor = .black

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = UIColor(red: 0.78, green: 0.22, blue: 0.88, alpha: 1)
        icon.contentMode = .scaleAspectFit

        activityIndicator.color = .white
        activityIndicator.startAnimating()

        statusLabel.text = "Saving to ClipStory"
        statusLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center

        detailLabel.text = "Preparing shared content..."
        detailLabel.font = .systemFont(ofSize: 15, weight: .medium)
        detailLabel.textColor = .white.withAlphaComponent(0.58)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, activityIndicator, statusLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @MainActor
    private func saveSharedContent() async {
        do {
            let contents = try await ShareContentExtractor.contents(from: extensionContext)
            guard !contents.isEmpty else {
                finish(
                    success: false,
                    message: "Nothing Saved",
                    detail: "ClipStory could not read a supported item from this share."
                )
                return
            }

            let persistence = ModelContainerFactory.makeShared()
            let store = ClipStore(container: persistence.container)
            var savedCount = 0
            for content in contents {
                if store.insertManual(content) != nil {
                    savedCount += 1
                }
            }

            guard savedCount > 0 else {
                finish(success: false, message: "Nothing Saved", detail: "ClipStory could not save this item.")
                return
            }

            let itemText = savedCount == 1 ? "item" : "items"
            finish(success: true, message: "Saved to ClipStory", detail: "\(savedCount) \(itemText) added.")
        } catch {
            finish(success: false, message: "Could Not Save", detail: error.localizedDescription)
        }
    }

    private func finish(success: Bool, message: String, detail: String) {
        activityIndicator.stopAnimating()
        statusLabel.text = message
        detailLabel.text = detail

        let delay: TimeInterval = success ? 0.65 : 1.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if success {
                self.extensionContext?.completeRequest(returningItems: nil)
            } else {
                let error = NSError(
                    domain: "ClipStoryShareExtension",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: detail]
                )
                self.extensionContext?.cancelRequest(withError: error)
            }
        }
    }
}

private enum ShareContentExtractor {
    static func contents(from context: NSExtensionContext?) async throws -> [CapturedContent] {
        let providers = (context?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        var contents: [CapturedContent] = []
        for provider in providers {
            if let content = await content(from: provider) {
                contents.append(content)
            }
        }
        return contents
    }

    private static func content(from provider: NSItemProvider) async -> CapturedContent? {
        if let content = await urlContent(from: provider) { return content }
        if let content = await textContent(from: provider) { return content }
        if let content = await imageContent(from: provider) { return content }
        if let content = await fileContent(from: provider) { return content }
        return nil
    }

    private static func urlContent(from provider: NSItemProvider) async -> CapturedContent? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              let item = try? await loadItem(from: provider, typeIdentifier: UTType.url.identifier),
              let url = urlValue(from: item)
        else { return nil }

        return CapturedContent(
            kind: .url,
            text: url.absoluteString,
            sourceAppName: "Share Sheet",
            sourceAppBundleID: Bundle.main.bundleIdentifier
        )
    }

    private static func textContent(from provider: NSItemProvider) async -> CapturedContent? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
              let item = try? await loadItem(from: provider, typeIdentifier: UTType.plainText.identifier),
              let text = stringValue(from: item)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        return CapturedContent(
            kind: .text,
            text: text,
            sourceAppName: "Share Sheet",
            sourceAppBundleID: Bundle.main.bundleIdentifier
        )
    }

    private static func imageContent(from provider: NSItemProvider) async -> CapturedContent? {
        guard let typeIdentifier = firstRegisteredType(in: provider, conformingTo: .image) else {
            return nil
        }

        if let data = try? await loadData(from: provider, typeIdentifier: typeIdentifier),
           let imageData = imageDataWithinLimit(data) {
            return CapturedContent(
                kind: .image,
                imageData: imageData,
                sourceAppName: "Share Sheet",
                sourceAppBundleID: Bundle.main.bundleIdentifier
            )
        }

        if let payload = try? await loadFilePayload(from: provider, typeIdentifier: typeIdentifier),
           let imageData = imageDataWithinLimit(payload.data) {
            return CapturedContent(
                kind: .image,
                imageData: imageData,
                sourceAppName: "Share Sheet",
                sourceAppBundleID: Bundle.main.bundleIdentifier
            )
        }

        return nil
    }

    private static func fileContent(from provider: NSItemProvider) async -> CapturedContent? {
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return !type.conforms(to: .url)
                && !type.conforms(to: .plainText)
                && !type.conforms(to: .image)
        }) else {
            return nil
        }

        guard let payload = try? await loadFilePayload(from: provider, typeIdentifier: typeIdentifier),
              payload.data.count <= AppConstants.maxManualFileByteCount
        else {
            return nil
        }

        return CapturedContent(
            kind: .file,
            fileData: payload.data,
            fileName: payload.fileName,
            fileTypeIdentifier: typeIdentifier,
            sourceAppName: "Share Sheet",
            sourceAppBundleID: Bundle.main.bundleIdentifier
        )
    }

    private static func firstRegisteredType(in provider: NSItemProvider, conformingTo target: UTType) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: target) == true
        }
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item as? NSSecureCoding)
                }
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private static func loadFilePayload(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> (data: Data, fileName: String, typeIdentifier: String) {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                do {
                    if let error {
                        throw error
                    }
                    guard let url else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: (data, url.lastPathComponent, typeIdentifier))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func stringValue(from item: NSSecureCoding) -> String? {
        if let value = item as? String { return value }
        if let value = item as? NSString { return value as String }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = item as? URL { return url.absoluteString }
        if let url = item as? NSURL { return url.absoluteString }
        return nil
    }

    private static func urlValue(from item: NSSecureCoding) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = stringValue(from: item) { return URL(string: string) }
        return nil
    }

    private static func imageDataWithinLimit(_ data: Data) -> Data? {
        guard data.count > AppConstants.maxImageByteCount else { return data }
        guard let image = UIImage(data: data) else { return nil }
        return downscaledPNGData(from: image)
    }

    private static func downscaledPNGData(from image: UIImage) -> Data? {
        let minimumDimension: CGFloat = 64
        var size = image.size
        for _ in 0..<7 {
            size = CGSize(width: size.width * 0.72, height: size.height * 0.72)
            guard size.width >= minimumDimension, size.height >= minimumDimension else {
                return nil
            }

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = resized.pngData(), data.count <= AppConstants.maxImageByteCount {
                return data
            }
        }
        return nil
    }
}
