// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG || CHAT_LIST_PLAYGROUND
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ChatLoadGeneratorViewController: UIViewController, PHPickerViewControllerDelegate {
    private let chat: ChatViewModel
    private var image: ProcessedImage?
    private lazy var generator = chat.makeLoadGenerator { [weak self] in self?.image }
    private let count = UITextField()
    private let photoEvery = UITextField()
    private let interval = UITextField()
    private let photoButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let summary = UILabel()
    private let status = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private var cancellables = Set<AnyCancellable>()
    private var isPreparingImage = false
    private var savedIdleTimer: Bool?

    init(chat: ChatViewModel) {
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        title = "Генератор сообщений"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        stack.addArrangedSubview(label("Чат: \(chat.roomName)", style: .headline))
        stack.addArrangedSubview(label("Это настоящие сообщения. Закрытие панели не останавливает запуск. При уходе из чата или сворачивании приложения — пауза.", style: .subheadline))
        addField(count, title: "Всего сообщений, включая фото", value: "1000", keyboard: .numberPad, to: stack)
        addField(photoEvery, title: "Фото вместо каждого N-го сообщения · 0 — без фото", value: "100", keyboard: .numberPad, to: stack)
        addField(interval, title: "Пауза после подтверждения, секунды", value: "0.25", keyboard: .decimalPad, to: stack)
        photoButton.configuration = .bordered()
        photoButton.setTitle("Выбрать фото", for: .normal)
        photoButton.addTarget(self, action: #selector(pickPhoto), for: .touchUpInside)
        stack.addArrangedSubview(photoButton)
        summary.numberOfLines = 0
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.textColor = .secondaryLabel
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(progress)
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .body)
        status.accessibilityTraits = .updatesFrequently
        stack.addArrangedSubview(status)
        startButton.configuration = .filled()
        startButton.addTarget(self, action: #selector(startOrResume), for: .touchUpInside)
        stack.addArrangedSubview(startButton)
        pauseButton.configuration = .bordered()
        pauseButton.setTitle("Остановить", for: .normal)
        pauseButton.addTarget(self, action: #selector(pause), for: .touchUpInside)
        stack.addArrangedSubview(pauseButton)
        stack.addArrangedSubview(label("В очереди генератора — одно сообщение. Экран не гаснет во время работы. Прогресс хранится до закрытия чата; фото каждый раз загружается как отдельное вложение.", style: .footnote))

        generator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.pause() }
            .store(in: &cancellables)
        render()
    }

    @objc func pause() {
        generator.pause()
        restoreIdleTimer()
        if isViewLoaded { render() }
    }

    private func restoreIdleTimer() {
        if let savedIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
            self.savedIdleTimer = nil
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func addField(_ field: UITextField, title: String, value: String,
                          keyboard: UIKeyboardType, to stack: UIStackView) {
        stack.addArrangedSubview(label(title, style: .subheadline))
        field.text = value
        field.accessibilityLabel = title
        field.keyboardType = keyboard
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        field.addTarget(self, action: #selector(render), for: .editingChanged)
        stack.addArrangedSubview(field)
    }

    private func configuration() throws -> ChatLoadGenerator.Configuration {
        guard let count = Int(count.text ?? ""), let every = Int(photoEvery.text ?? ""),
              let seconds = Double((interval.text ?? "").replacingOccurrences(of: ",", with: ".")) else {
            throw ChatLoadGenerator.Failure("Заполните количество, частоту фото и интервал числами.")
        }
        return try .init(count: count, photoEvery: every, interval: seconds)
    }

    @objc private func startOrResume() {
        view.endEditing(true)
        do {
            if generator.state == .paused || generator.state == .failed {
                try generator.resume()
            } else {
                let config = try configuration()
                guard config.photoCount == 0 || image != nil else {
                    throw ChatLoadGenerator.Failure("Выберите фото или укажите 0 для запуска только с текстом.")
                }
                try generator.start(config)
            }
            render()
        } catch { show(error) }
    }

    @objc private func render() {
        let editable = generator.state == .idle || generator.state == .finished
        [count, photoEvery, interval].forEach { $0.isEnabled = editable }
        photoButton.isEnabled = editable && !isPreparingImage
        let resumable = generator.state == .paused || generator.state == .failed
        startButton.isEnabled = (editable || resumable) && !isPreparingImage
        startButton.setTitle(resumable ? "Продолжить" : "Начать отправку", for: .normal)
        pauseButton.isEnabled = generator.state == .running
        status.text = "Подтверждено: \(generator.sent)\n\(generator.detail)"
        progress.progress = generator.configuration.map { Float(generator.sent) / Float($0.count) } ?? 0
        if let config = try? configuration() {
            summary.text = "\(config.count - config.photoCount) текстовых + \(config.photoCount) фото.\nИнтервал добавляется к времени отправки; ограничения сервера могут замедлить запуск."
        } else {
            summary.text = "Проверьте параметры."
        }
        if generator.state == .running {
            if savedIdleTimer == nil { savedIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            restoreIdleTimer()
        }
    }

    @objc private func pickPhoto() {
        view.endEditing(true)
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else { return }
        isPreparingImage = true
        photoButton.setTitle("Подготовка фото…", for: .normal)
        render()
        Task { [weak self] in
            let data: Data? = await withCheckedContinuation { continuation in
                result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            do {
                guard let data else { throw ChatLoadGenerator.Failure("Не удалось прочитать фото.") }
                let processed = try await MediaPreprocessor.processImage(from: data)
                guard let self else { return }
                self.image = processed
                self.photoButton.setTitle("Фото \(processed.width) × \(processed.height) · заменить", for: .normal)
            } catch {
                self?.photoButton.setTitle(self?.image == nil ? "Выбрать фото" : "Заменить фото", for: .normal)
                self?.show(error)
            }
            self?.isPreparingImage = false
            self?.render()
        }
    }

    private func show(_ error: Error) {
        let alert = UIAlertController(title: "Генератор сообщений", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
