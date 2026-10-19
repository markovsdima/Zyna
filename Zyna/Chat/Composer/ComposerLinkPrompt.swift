//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

@MainActor
enum ComposerLinkPrompt {
    static func present(from presenter: UIViewController, current: String?, completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: String(localized: "Link"), message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = current
            $0.placeholder = "https://example.com"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.accessibilityLabel = String(localized: "Link address")
        }
        let save = UIAlertAction(title: String(localized: "Save"), style: .default) { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text,
                  let destination = destination(from: text) else { return }
            completion(destination)
        }
        save.isEnabled = current.flatMap { destination(from: $0) } != nil
        alert.textFields?.first?.addAction(UIAction { [weak save] action in
            let text = (action.sender as? UITextField)?.text ?? ""
            save?.isEnabled = destination(from: text) != nil
        }, for: .editingChanged)
        alert.addAction(save)
        if current != nil {
            alert.addAction(UIAlertAction(title: String(localized: "Remove Link"), style: .destructive) { _ in
                completion(nil)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        presenter.present(alert, animated: true)
    }

    static func destination(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = URLComponents(string: text)?.scheme {
            // A domain or localhost followed by a port looks like a scheme
            // to URLComponents. Require an actual port and no credentials;
            // other explicit schemes still go through the normal URL policy.
            let canBeHost = scheme.contains(".") || scheme.lowercased() == "localhost"
            guard canBeHost,
                  let components = URLComponents(string: "https://" + text),
                  components.port != nil, components.user == nil else {
                return RichTextURLPolicy.destination(from: text)
            }
        }
        let value = text.hasPrefix("//") ? "https:" + text : "https://" + text
        return RichTextURLPolicy.destination(from: value)
    }
}
