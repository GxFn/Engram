import ClipCore
import ClipPipeline
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let noteTextView = UITextView()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var timeoutWorkItem: DispatchWorkItem?
    private var draft = ShareClipDraft()
    private var didFinishLoading = false
    private var didComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        loadSharedItems()
        scheduleSoftTimeout()
    }

    deinit {
        timeoutWorkItem?.cancel()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Preparing clip..."
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true

        previewLabel.text = "Waiting for shared content."
        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 3
        previewLabel.adjustsFontForContentSizeCategory = true

        noteTextView.font = .preferredFont(forTextStyle: .body)
        noteTextView.layer.borderColor = UIColor.separator.cgColor
        noteTextView.layer.borderWidth = 1
        noteTextView.layer.cornerRadius = 8
        noteTextView.text = ""
        noteTextView.accessibilityLabel = "Optional note"

        saveButton.setTitle("Save", for: .normal)
        saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelButton, saveButton])
        buttonStack.axis = .horizontal
        buttonStack.alignment = .center
        buttonStack.distribution = .equalSpacing

        let stack = UIStackView(arrangedSubviews: [statusLabel, previewLabel, noteTextView, buttonStack])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.bottomAnchor),
            noteTextView.heightAnchor.constraint(equalToConstant: 104)
        ])
    }

    private func loadSharedItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        guard !providers.isEmpty else {
            didFinishLoading = true
            statusLabel.text = "No supported content"
            return
        }

        let group = DispatchGroup()
        for provider in providers {
            loadPropertyList(from: provider, group: group)
            loadURL(from: provider, group: group)
            loadPlainText(from: provider, group: group)
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !self.didComplete else {
                return
            }

            self.didFinishLoading = true
            self.updateLoadedState()
        }
    }

    private func loadPropertyList(from provider: NSItemProvider, group: DispatchGroup) {
        let typeIdentifier = UTType.propertyList.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return
        }

        group.enter()
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.draft.mergePropertyList(item)
                self?.refreshPreview()
                group.leave()
            }
        }
    }

    private func loadURL(from provider: NSItemProvider, group: DispatchGroup) {
        let typeIdentifier = UTType.url.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return
        }

        group.enter()
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.draft.mergeURL(item)
                self?.refreshPreview()
                group.leave()
            }
        }
    }

    private func loadPlainText(from provider: NSItemProvider, group: DispatchGroup) {
        let typeIdentifier = UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            return
        }

        group.enter()
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.draft.mergePlainText(item)
                self?.refreshPreview()
                group.leave()
            }
        }
    }

    private func scheduleSoftTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.enqueueAndComplete(reason: .timeout)
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func updateLoadedState() {
        if draft.canCreateClip {
            statusLabel.text = "Ready to save"
            saveButton.isEnabled = true
        } else {
            statusLabel.text = "No supported content"
            saveButton.isEnabled = false
        }
        refreshPreview()
    }

    private func refreshPreview() {
        previewLabel.text = draft.previewText
        if !didFinishLoading, draft.canCreateClip {
            statusLabel.text = "Loading details..."
            saveButton.isEnabled = true
        }
    }

    @objc private func saveTapped() {
        enqueueAndComplete(reason: .userAction)
    }

    @objc private func cancelTapped() {
        completeExtension()
    }

    private func enqueueAndComplete(reason: CompletionReason) {
        guard !didComplete else {
            return
        }

        if reason == .timeout {
            statusLabel.text = "Saving available content..."
        }

        guard let clip = draft.makeClip(note: noteTextView.text) else {
            completeExtension()
            return
        }

        do {
            try ClipQueueWriter().enqueue(clip)
            completeExtension()
        } catch {
            didComplete = true
            timeoutWorkItem?.cancel()
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func completeExtension() {
        guard !didComplete else {
            return
        }

        didComplete = true
        timeoutWorkItem?.cancel()
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

private enum CompletionReason {
    case timeout
    case userAction
}

private struct ShareClipDraft {
    private(set) var plainText: String?
    private(set) var selectionText: String?
    private(set) var url: URL?
    private(set) var title: String?

    var canCreateClip: Bool {
        makeClip(note: nil) != nil
    }

    var previewText: String {
        if let url {
            return [title, url.absoluteString].compactMap(\.nonEmptyTrimmed).joined(separator: "\n")
        }

        if let text = plainText.nonEmptyTrimmed ?? selectionText.nonEmptyTrimmed {
            return text
        }

        return "Waiting for shared content."
    }

    mutating func mergePlainText(_ item: NSSecureCoding?) {
        if let value = stringValue(from: item).nonEmptyTrimmed {
            plainText = value
        }
    }

    mutating func mergeURL(_ item: NSSecureCoding?) {
        if let value = urlValue(from: item) {
            url = value
        }
    }

    mutating func mergePropertyList(_ item: NSSecureCoding?) {
        guard let dictionary = item as? [String: Any] else {
            return
        }

        let results = dictionary["NSExtensionJavaScriptPreprocessingResultsKey"] as? [String: Any] ?? dictionary
        if let value = (results["title"] as? String).nonEmptyTrimmed {
            title = value
        }
        if let value = (results["selection"] as? String).nonEmptyTrimmed {
            selectionText = value
        }
        if let value = (results["url"] as? String).nonEmptyTrimmed ?? (results["baseURI"] as? String).nonEmptyTrimmed,
           let parsedURL = URL(string: value) {
            url = parsedURL
        }
    }

    func makeClip(note: String?) -> Clip? {
        let trimmedNote = note.nonEmptyTrimmed
        let body = plainText.nonEmptyTrimmed ?? selectionText.nonEmptyTrimmed
        if let url {
            return Clip(
                id: UUID().uuidString,
                source: .url(url),
                title: title.nonEmptyTrimmed,
                note: trimmedNote,
                bodyText: body,
                createdAt: Date()
            )
        }

        guard let text = body else {
            return nil
        }

        return Clip(
            id: UUID().uuidString,
            source: .text(text),
            title: title.nonEmptyTrimmed,
            note: trimmedNote,
            bodyText: text,
            createdAt: Date()
        )
    }

    private func stringValue(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }
        if let attributedString = item as? NSAttributedString {
            return attributedString.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if let url = item as? URL {
            return url.absoluteString
        }
        return nil
    }

    private func urlValue(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let string = stringValue(from: item).nonEmptyTrimmed {
            return URL(string: string)
        }
        return nil
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyTrimmed: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
