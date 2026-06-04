//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

private let logElementCallServer = ScopedLog(.call)

final class ElementCallStaticServer {

    private enum ServerError: Error {
        case missingPort
    }

    private let queue = DispatchQueue(label: "com.zyna.element-call.static-server")
    private var listener: NWListener?
    private var rootDirectoryURL: URL?

    func start(
        rootDirectoryURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async {
            self.rootDirectoryURL = rootDirectoryURL

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            completion(.failure(ServerError.missingPort))
                            return
                        }
                        completion(.success(URL(string: "http://127.0.0.1:\(port)/")!))
                    case .failed(let error):
                        self?.stop()
                        completion(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }

                listener.start(queue: self.queue)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            var requestData = buffer
            if let data {
                requestData.append(data)
            }

            guard !requestData.containsHeaderTerminator else {
                self.respond(to: requestData, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: requestData)
        }
    }

    private func respond(to requestData: Data, on connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n").first else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        guard let fileURL = fileURL(forRequestPath: String(parts[1])) else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            send(
                status: "200 OK",
                body: method == "HEAD" ? Data() : data,
                contentLength: data.count,
                contentType: contentType(for: fileURL),
                on: connection
            )
        } catch {
            logElementCallServer("Element Call static server failed to read \(fileURL): \(error)")
            send(status: "500 Internal Server Error", body: Data(), contentType: "text/plain", on: connection)
        }
    }

    private func fileURL(forRequestPath requestPath: String) -> URL? {
        guard let rootDirectoryURL else { return nil }

        let rawPath = requestPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        guard !decodedPath.contains("..") else { return nil }

        var relativePath = decodedPath
        if relativePath == "/" {
            relativePath = "/index.html"
        }
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }

        if relativePath == "room" || relativePath == "room/" {
            return rootDirectoryURL.appendingPathComponent("index.html")
        }

        let fileURL = rootDirectoryURL.appendingPathComponent(relativePath)
        if FileManager.default.fileExistsAndIsFile(at: fileURL) {
            return fileURL
        }

        if relativePath.hasPrefix("room/") {
            let roomRelativePath = String(relativePath.dropFirst("room/".count))
            if roomRelativePath.isEmpty {
                return rootDirectoryURL.appendingPathComponent("index.html")
            }

            let roomFileURL = rootDirectoryURL.appendingPathComponent(roomRelativePath)
            if FileManager.default.fileExistsAndIsFile(at: roomFileURL) {
                return roomFileURL
            }
        }

        if (relativePath as NSString).pathExtension.isEmpty {
            return rootDirectoryURL.appendingPathComponent("index.html")
        }

        return nil
    }

    private func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "css":
            return "text/css"
        case "html":
            return "text/html"
        case "js", "mjs":
            return "text/javascript"
        case "json", "map":
            return "application/json"
        case "ogg":
            return "audio/ogg"
        case "mp3":
            return "audio/mpeg"
        case "png":
            return "image/png"
        case "svg":
            return "image/svg+xml"
        case "tflite":
            return "application/octet-stream"
        case "wasm":
            return "application/wasm"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        default:
            return "application/octet-stream"
        }
    }

    private func send(
        status: String,
        body: Data,
        contentLength: Int? = nil,
        contentType: String,
        on connection: NWConnection
    ) {
        let length = contentLength ?? body.count
        var response = Data()
        response.appendString("HTTP/1.1 \(status)\r\n")
        response.appendString("Content-Length: \(length)\r\n")
        response.appendString("Content-Type: \(contentType)\r\n")
        response.appendString("Cache-Control: no-cache\r\n")
        response.appendString("Connection: close\r\n")
        response.appendString("\r\n")
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private extension Data {

    var containsHeaderTerminator: Bool {
        guard count >= 4 else { return false }
        return withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            for index in 0..<(count - 3) {
                if bytes[index] == 13,
                   bytes[index + 1] == 10,
                   bytes[index + 2] == 13,
                   bytes[index + 3] == 10 {
                    return true
                }
            }
            return false
        }
    }

    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}

private extension FileManager {

    func fileExistsAndIsFile(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
