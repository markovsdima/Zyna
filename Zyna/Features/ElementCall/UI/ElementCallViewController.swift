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

    private let room: Room
    private let roomName: String
    private let deviceID: String?
    private let voiceOnly: Bool
    private let webView: WKWebView
    private let staticServer = ElementCallStaticServer()
    private let statusLabel = UILabel()
    private let routePickerView = AVRoutePickerView(frame: .zero)
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
        staticServer.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        setupWebView()
        setupOverlay()
        bindSystemActions()
        loadElementCall()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView.frame = view.bounds
    }

    private func setupWebView() {
        webView.backgroundColor = .black
        webView.isOpaque = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(webView)

        routePickerView.isHidden = true
        routePickerView.isUserInteractionEnabled = false
        webView.addSubview(routePickerView)
    }

    private func setupOverlay() {
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
          window.controls.onBackButtonPressed = () => {};

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

        guard message.name == ScriptMessageName.diagnostics,
              let payload = message.body as? [String: Any] else {
            return
        }
        let type = payload["type"] as? String ?? "unknown"
        let body = payload["payload"] as? String ?? ""
        logElementCall("Embedded Element Call JS \(type): \(body)")
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
