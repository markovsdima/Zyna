// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG
import Foundation

/// Opt-in causal trace, not a performance probe. No contents or raw IDs.
/// Hashes correlate one process only; the fixed cap also bounds queued writes.
enum ChatReadReceiptTrace {
    static let enabled = ProcessInfo.processInfo.environment["ZYNA_RECEIPT_TRACE"] == "1"
    private static let remaining = Atomic(2048)
    private static let writer = DispatchQueue(label: "zyna.read-receipt.trace", qos: .utility)
    private static let session = UUID().uuidString
    private static var handle: FileHandle? // writer queue only

    static func record(_ stage: String, eventID: String? = nil, state: String = "") {
        guard enabled, remaining.withValue({ count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }) else { return }
        let value: [String: Any] = ["session": session, "epoch": Date().timeIntervalSince1970,
            "stage": stage, "event": eventID.map { String(UInt(bitPattern: $0.hashValue), radix: 16) } ?? "none",
            "state": state]
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        writer.async {
            if handle == nil {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("read-receipts.jsonl")
                try? Data().write(to: url)
                handle = try? FileHandle(forWritingTo: url)
            }
            try? handle?.write(contentsOf: bytes + Data([10]))
        }
    }
}
#endif
