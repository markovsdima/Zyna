//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import EmbeddedElementCall
import MatrixRustSDK
import AVFoundation
import AVKit
import Combine
import UIKit
import WebKit

private let logElementCall = ScopedLog(.call)

final class ElementCallViewController: UIViewController {

    private enum ScriptMessageName {
        static let diagnostics = "elementCallDiagnostics"
        static let widgetAction = "elementCallWidgetAction"
        static let showNativeOutputDevicePicker = "elementCallShowNativeOutputDevicePicker"
        static let onOutputDeviceSelect = "elementCallOnOutputDeviceSelect"
        static let onBackButtonPressed = "elementCallOnBackButtonPressed"
    }

    private struct WidgetControlMessage: Codable {

        struct Data: Codable {
            var audioEnabled: Bool?

            enum CodingKeys: String, CodingKey {
                case audioEnabled = "audio_enabled"
            }
        }

        let direction: String
        let action: String
        var data = Data()
        let widgetId: String
        var requestId = "widgetapi-\(UUID())"

        enum CodingKeys: String, CodingKey {
            case direction = "api"
            case action
            case data
            case widgetId
            case requestId
        }
    }

    var onDismiss: (() -> Void)?
    var onPictureInPictureStarted: (() -> Void)?
    var onPictureInPictureStopped: (() -> Void)?
    var onPictureInPictureRestoreRequested: ((@escaping (Bool) -> Void) -> Void)?
    var roomID: String { room.id() }
    var isPictureInPictureActive: Bool {
        pictureInPictureController?.isPictureInPictureActive == true
    }

    private let room: Room
    private let roomName: String
    private let deviceID: String?
    private let voiceOnly: Bool
    private let webView: WKWebView
    private let webViewContainerView = UIView()
    private let pictureInPictureViewController = AVPictureInPictureVideoCallViewController()
    private let staticServer = ElementCallStaticServer()
    private let statusLabel = UILabel()
    private let minimizeButton = UIButton(type: .system)
    private let routePickerView = AVRoutePickerView(frame: .zero)
    private var pictureInPictureController: AVPictureInPictureController?
    private var widgetDriver: ElementCallWidgetDriver?
    private var isDismissing = false
    private var widgetURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private static let earpieceID = "earpiece-id"

    init(
        room: Room,
        roomName: String,
        deviceID: String?,
        voiceOnly: Bool = false
    ) {
        self.room = room
        self.roomName = roomName
        self.deviceID = deviceID
        self.voiceOnly = voiceOnly

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Self.diagnosticsUserScript())
        configuration.userContentController.addUserScript(Self.widgetBridgeUserScript())

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        configuration.userContentController.add(self, name: ScriptMessageName.diagnostics)
        configuration.userContentController.add(self, name: ScriptMessageName.widgetAction)
        configuration.userContentController.add(self, name: ScriptMessageName.showNativeOutputDevicePicker)
        configuration.userContentController.add(self, name: ScriptMessageName.onOutputDeviceSelect)
        configuration.userContentController.add(self, name: ScriptMessageName.onBackButtonPressed)

        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessageName.diagnostics)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessageName.widgetAction)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessageName.showNativeOutputDevicePicker)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessageName.onOutputDeviceSelect)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ScriptMessageName.onBackButtonPressed)
        staticServer.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        setupWebView()
        setupPictureInPicture()
        setupOverlay()
        bindSystemActions()
        loadElementCall()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webViewContainerView.frame = view.bounds
        if webView.superview === webViewContainerView {
            webView.frame = webViewContainerView.bounds
        }
        bringOverlayToFront()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bringOverlayToFront()
    }

    private func setupWebView() {
        webViewContainerView.backgroundColor = .black
        webViewContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webViewContainerView.frame = view.bounds
        view.addSubview(webViewContainerView)

        webView.backgroundColor = .black
        webView.isOpaque = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = webViewContainerView.bounds
        webViewContainerView.addSubview(webView)

        routePickerView.isHidden = true
        routePickerView.isUserInteractionEnabled = false
        webView.addSubview(routePickerView)
    }

    private func setupPictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            logElementCall("Embedded Element Call Picture in Picture is not supported on this device")
            return
        }

        pictureInPictureViewController.preferredContentSize = CGSize(width: 1920, height: 1080)
        pictureInPictureViewController.view.backgroundColor = .black

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: webViewContainerView,
            contentViewController: pictureInPictureViewController
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        pictureInPictureController = controller
    }

    private func setupOverlay() {
        setupMinimizeButton()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = String(localized: "Loading")
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setupMinimizeButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 16,
            weight: .semibold
        )
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        configuration.background.cornerRadius = 22

        minimizeButton.configuration = configuration
        minimizeButton.tintColor = .white
        minimizeButton.backgroundColor = .clear
        minimizeButton.layer.cornerRadius = 22
        minimizeButton.layer.cornerCurve = .continuous
        minimizeButton.layer.zPosition = 1000
        minimizeButton.layer.shadowColor = UIColor.black.cgColor
        minimizeButton.layer.shadowOpacity = 0.25
        minimizeButton.layer.shadowRadius = 8
        minimizeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        minimizeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        minimizeButton.layer.borderWidth = 0.5
        minimizeButton.clipsToBounds = false
        minimizeButton.accessibilityLabel = String(localized: "Minimize")
        minimizeButton.accessibilityIdentifier = "elementCallMinimizeButton"
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.addTarget(self, action: #selector(minimizeButtonTapped), for: .touchUpInside)
        view.addSubview(minimizeButton)

        NSLayoutConstraint.activate([
            minimizeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            minimizeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            minimizeButton.widthAnchor.constraint(equalToConstant: 44),
            minimizeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func bringOverlayToFront() {
        view.bringSubviewToFront(minimizeButton)
        view.bringSubviewToFront(statusLabel)
    }

    private func loadElementCall() {
        guard let appURL = EmbeddedElementCall.appURL else {
            logElementCall("Embedded Element Call appURL is nil")
            showError(String(localized: "Element Call bundle is not available."))
            return
        }

        let distDirectoryURL = appURL.deletingLastPathComponent()
        staticServer.start(rootDirectoryURL: distDirectoryURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let baseURL):
                    self.loadElementCallWidget(baseURL: baseURL)
                case .failure(let error):
                    logElementCall("Embedded Element Call server failed: \(error)")
                    self.showError(String(localized: "Element Call local server failed to start."))
                }
            }
        }
    }

    private func showError(_ message: String) {
        statusLabel.isHidden = false
        statusLabel.text = message
        statusLabel.textColor = .secondaryLabel
    }

    private func loadElementCallWidget(baseURL: URL) {
        guard let deviceID, !deviceID.isEmpty else {
            logElementCall("Embedded Element Call missing Matrix device ID")
            showError(String(localized: "Element Call session is missing a Matrix device ID."))
            return
        }

        let widgetDriver = ElementCallWidgetDriver(room: room, deviceID: deviceID)
        self.widgetDriver = widgetDriver

        widgetDriver.onMessageToWidget = { [weak self] message in
            DispatchQueue.main.async {
                self?.postMessageToWidget(message)
            }
        }
        widgetDriver.onCallEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.dismissElementCall()
            }
        }
        widgetDriver.onMediaStateChanged = { [weak self] audioEnabled, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                ElementCallKitService.shared.setAudioEnabled(
                    audioEnabled,
                    roomID: self.room.id()
                )
            }
        }

        let callBaseURL = baseURL.appendingPathComponent("room")
        let theme = view.traitCollection.userInterfaceStyle == .light ? "light" : "dark"
        let voiceOnly = self.voiceOnly
        Task { [weak self, widgetDriver] in
            let result = await widgetDriver.start(
                baseURL: callBaseURL,
                clientID: "com.zyna.ios",
                theme: theme,
                voiceOnly: voiceOnly
            )

            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let widgetURL):
                    self.widgetURL = widgetURL
                    ElementCallKitService.shared.setupCallSession(
                        roomID: self.room.id(),
                        roomDisplayName: self.roomName
                    )
                    logElementCall("Loading Embedded Element Call \(EmbeddedElementCall.version) widget for room \(self.roomName) from \(widgetURL)")
                    self.webView.load(URLRequest(url: widgetURL))
                case .failure(let error):
                    logElementCall("Embedded Element Call widget failed: \(error)")
                    self.showError(String(localized: "Element Call widget failed to start."))
                }
            }
        }
    }

    private func postMessageToWidget(_ json: String) {
        webView.evaluateJavaScript("postMessage(\(json), '*')") { _, error in
            if let error {
                logElementCall("Embedded Element Call postMessage failed: \(error)")
            }
        }
    }

    private func postControlMessageToWidget(_ message: WidgetControlMessage) {
        do {
            let data = try JSONEncoder().encode(message)
            guard let json = String(data: data, encoding: .utf8) else {
                logElementCall("Embedded Element Call control message was not UTF-8")
                return
            }
            postMessageToWidget(json)
        } catch {
            logElementCall("Embedded Element Call control message encoding failed: \(error)")
        }
    }

    private func bindSystemActions() {
        ElementCallKitService.shared.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .endCall(let roomID):
                    guard roomID == self.room.id() else { return }
                    self.hangupAndDismiss()
                case .setAudioEnabled(let enabled, let roomID):
                    guard roomID == self.room.id() else { return }
                    self.setWidgetAudioEnabled(enabled)
                case .receivedIncomingCallRequest, .startCall:
                    break
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateOutputsListOnWeb()
            }
            .store(in: &cancellables)
    }

    private func hangupAndDismiss() {
        guard let widgetDriver else {
            dismissElementCall()
            return
        }

        postControlMessageToWidget(
            WidgetControlMessage(
                direction: "fromWidget",
                action: "im.vector.hangup",
                widgetId: widgetDriver.widgetID
            )
        )
        dismissElementCall()
    }

    private func setWidgetAudioEnabled(_ enabled: Bool) {
        guard let widgetDriver else { return }
        postControlMessageToWidget(
            WidgetControlMessage(
                direction: "toWidget",
                action: "io.element.device_mute",
                data: .init(audioEnabled: enabled),
                widgetId: widgetDriver.widgetID
            )
        )
    }

    @objc private func minimizeButtonTapped() {
        requestPictureInPicture()
    }

    func stopPictureInPicture() {
        guard isPictureInPictureActive else { return }
        pictureInPictureController?.stopPictureInPicture()
    }

    private func requestPictureInPicture() {
        guard let pictureInPictureController else {
            logElementCall("Embedded Element Call Picture in Picture controller is unavailable")
            return
        }

        guard !pictureInPictureController.isPictureInPictureActive else { return }

        guard pictureInPictureController.isPictureInPicturePossible else {
            logElementCall("Embedded Element Call Picture in Picture is not possible yet")
            return
        }

        webView.evaluateJavaScript("window.controls?.canEnterPip?.() === true") { [weak pictureInPictureController] result, error in
            guard let pictureInPictureController else { return }
            if let error {
                logElementCall("Embedded Element Call Picture in Picture eligibility failed: \(error)")
                return
            }

            guard result as? Bool == true else {
                logElementCall("Embedded Element Call widget declined Picture in Picture")
                return
            }

            pictureInPictureController.startPictureInPicture()
        }
    }

    private func evaluatePictureInPictureJavaScript(_ source: String) {
        webView.evaluateJavaScript(source) { _, error in
            if let error {
                logElementCall("Embedded Element Call Picture in Picture JS failed: \(error)")
            }
        }
    }

    private func moveWebView(to containerView: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = containerView.bounds
        containerView.addSubview(webView)
    }

    private func tapRoutePickerView() {
        guard let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton else {
            return
        }
        button.sendActions(for: .touchUpInside)
    }

    private func handleOutputDeviceSelected(deviceID: String) {
        UIDevice.current.isProximityMonitoringEnabled = deviceID == Self.earpieceID
    }

    private func updateOutputsListOnWeb() {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }

        let devices: [[String: Any]]
        if currentOutput.portType == .builtInSpeaker {
            devices = [[
                "id": currentOutput.uid,
                "name": currentOutput.portName,
                "forEarpiece": true,
                "isSpeaker": true
            ]]
        } else {
            devices = [[
                "id": "dummy",
                "name": "dummy"
            ]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: devices),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript("window.controls?.setAvailableOutputDevices?.(\(json))") { _, error in
            if let error {
                logElementCall("Embedded Element Call output device update failed: \(error)")
            }
        }
    }

    private func dismissElementCall() {
        guard !isDismissing else { return }
        isDismissing = true
        stopPictureInPicture()
        ElementCallKitService.shared.tearDownCallSession()
        UIDevice.current.isProximityMonitoringEnabled = false
        staticServer.stop()
        onDismiss?()
    }

    private static func diagnosticsUserScript() -> WKUserScript {
        let source = """
        (() => {
          const post = (type, payload) => {
            try {
              window.webkit.messageHandlers.\(ScriptMessageName.diagnostics).postMessage({
                type,
                payload: String(payload)
              });
            } catch (_) {}
          };

          ["log", "warn", "error"].forEach((level) => {
            const original = console[level];
            console[level] = (...args) => {
              post(`console.${level}`, args.map(String).join(" "));
              original.apply(console, args);
            };
          });

          window.addEventListener("error", (event) => {
            post("window.error", `${event.message} @ ${event.filename}:${event.lineno}:${event.colno}`);
          });

          window.addEventListener("unhandledrejection", (event) => {
            post("unhandledrejection", event.reason && (event.reason.stack || event.reason.message || event.reason));
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static func widgetBridgeUserScript() -> WKUserScript {
        let source = """
        (() => {
          window.controls = window.controls || {};
          window.controls.showNativeOutputDevicePicker = () => {
            window.webkit.messageHandlers.\(ScriptMessageName.showNativeOutputDevicePicker).postMessage("");
          };
          window.controls.onOutputDeviceSelect = (id) => {
            window.webkit.messageHandlers.\(ScriptMessageName.onOutputDeviceSelect).postMessage(String(id));
          };
          window.controls.onBackButtonPressed = () => {
            window.webkit.messageHandlers.\(ScriptMessageName.onBackButtonPressed).postMessage("");
          };

          window.addEventListener("message", (event) => {
            const data = event.data;
            if (!data || typeof data !== "object") return;
            if ((data.response && data.api === "toWidget") || (!data.response && data.api === "fromWidget")) {
              window.webkit.messageHandlers.\(ScriptMessageName.widgetAction).postMessage(JSON.stringify(data));
            }
          }, false);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }
}

extension ElementCallViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusLabel.isHidden = false
        statusLabel.text = String(localized: "Loading")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.isHidden = true
        bringOverlayToFront()
        logElementCall("Embedded Element Call finished loading")
        updateOutputsListOnWeb()
        logPageDiagnostics(after: 0.3)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        logElementCall("Embedded Element Call navigation failed: \(error)")
        showError(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        logElementCall("Embedded Element Call provisional navigation failed: \(error)")
        showError(error.localizedDescription)
    }
}

private extension ElementCallViewController {

    func logPageDiagnostics(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.webView.evaluateJavaScript(
                """
                JSON.stringify({
                  href: window.location.href,
                  pathname: window.location.pathname,
                  secureContext: window.isSecureContext,
                  hasMediaDevices: !!navigator.mediaDevices,
                  bodyClass: document.body ? document.body.className : null,
                  rootChildren: document.getElementById("root") ? document.getElementById("root").childElementCount : null,
                  bodyText: document.body ? document.body.innerText.slice(0, 500) : null
                })
                """
            ) { result, error in
                if let error {
                    logElementCall("Embedded Element Call diagnostics failed: \(error)")
                    return
                }
                logElementCall("Embedded Element Call diagnostics: \(result ?? "nil")")
            }
        }
    }
}

extension ElementCallViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == ScriptMessageName.widgetAction, let body = message.body as? String {
            Task { [weak self] in
                await self?.widgetDriver?.handleMessage(body)
            }
            return
        }

        if message.name == ScriptMessageName.showNativeOutputDevicePicker {
            tapRoutePickerView()
            return
        }

        if message.name == ScriptMessageName.onOutputDeviceSelect,
           let deviceID = message.body as? String {
            handleOutputDeviceSelected(deviceID: deviceID)
            return
        }

        if message.name == ScriptMessageName.onBackButtonPressed {
            requestPictureInPicture()
            return
        }

        guard message.name == ScriptMessageName.diagnostics,
              let payload = message.body as? [String: Any] else {
            return
        }
        let type = payload["type"] as? String ?? "unknown"
        let body = payload["payload"] as? String ?? ""
        logElementCall("Embedded Element Call JS \(type): \(body)")
    }
}

extension ElementCallViewController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        moveWebView(to: pictureInPictureViewController.view)
        evaluatePictureInPictureJavaScript("window.controls?.enablePip?.()")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard !isDismissing else { return }
        onPictureInPictureStarted?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        moveWebView(to: webViewContainerView)
        evaluatePictureInPictureJavaScript("window.controls?.disablePip?.()")
        logElementCall("Embedded Element Call Picture in Picture failed: \(error)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard !isDismissing else {
            completionHandler(false)
            return
        }

        onPictureInPictureRestoreRequested?(completionHandler) ?? completionHandler(false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        moveWebView(to: webViewContainerView)
        evaluatePictureInPictureJavaScript("window.controls?.disablePip?.()")

        guard !isDismissing else { return }
        onPictureInPictureStopped?()
    }
}

extension ElementCallViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard let widgetURL else {
            decisionHandler(.deny)
            return
        }

        guard origin.host == widgetURL.host else {
            decisionHandler(.deny)
            return
        }

        updateOutputsListOnWeb()
        decisionHandler(.grant)
    }
}
