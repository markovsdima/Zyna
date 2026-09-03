//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

final class SwiftUIWrapper<Content: View>: UIViewController {

    private let rootView: Content
    private let forcedStyle: UIUserInterfaceStyle
    private var hostingController: UIHostingController<Content>?

    /// - Parameter forcedStyle: `.unspecified` inherits the surrounding
    ///   interface style. Screens built on hardcoded light artwork pass
    ///   `.light`; new screens should stay themed and leave this alone.
    init(rootView: Content, forcedStyle: UIUserInterfaceStyle = .unspecified) {
        self.rootView = rootView
        self.forcedStyle = forcedStyle
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupHostingController()
    }
    
    private func setupHostingController() {
        let hosting = UIHostingController(rootView: rootView)
        hostingController = hosting
        hostingController?.overrideUserInterfaceStyle = forcedStyle
        
        addChild(hosting)
        view.addSubview(hosting.view)
        
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        hosting.didMove(toParent: self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        navigationController?.navigationBar.prefersLargeTitles = false
    }
    
    deinit {
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
    }
}

extension View {
    func wrapped(forcedStyle: UIUserInterfaceStyle = .unspecified) -> SwiftUIWrapper<Self> {
        SwiftUIWrapper(rootView: self, forcedStyle: forcedStyle)
    }
}
