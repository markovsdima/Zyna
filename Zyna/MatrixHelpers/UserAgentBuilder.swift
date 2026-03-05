//
//  UserAgentBuilder.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 03.08.2025.
//

import UIKit

enum UserAgentBuilder {
    private static let userAgent: String = {
        let clientName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Zyna-iOS"
        let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let systemVersion = UIDevice.current.systemVersion
        return "\(clientName)/\(clientVersion) (iPhone; iOS \(systemVersion))"
    }()
    
    static func makeASCIIUserAgent() -> String {
        return userAgent.asciifyIfNeeded() ?? "unknown"
    }
}
