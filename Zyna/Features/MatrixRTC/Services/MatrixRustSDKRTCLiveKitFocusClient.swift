//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRTC
import MatrixRTCLiveKit
import MatrixRustSDK

struct MatrixRustSDKRTCLiveKitFocus: Sendable {
    let discoveredTransport: MatrixRTCLiveKitDiscoveredTransport
    let sfuConfig: MatrixRTCLiveKitSFUConfig
}

enum MatrixRustSDKRTCLiveKitFocusError: Error, Equatable {
    case missingLiveKitServiceURL
}

final class MatrixRustSDKRTCLiveKitFocusClient: @unchecked Sendable {
    private let client: Client
    private let transportDiscoveryClient: MatrixRTCLiveKitTransportDiscoveryClient
    private let sfuClient: MatrixRTCLiveKitSFUClient

    init(
        client: Client,
        transportDiscoveryClient: MatrixRTCLiveKitTransportDiscoveryClient = MatrixRTCLiveKitTransportDiscoveryClient(),
        sfuClient: MatrixRTCLiveKitSFUClient = MatrixRTCLiveKitSFUClient()
    ) {
        self.client = client
        self.transportDiscoveryClient = transportDiscoveryClient
        self.sfuClient = sfuClient
    }

    func discoverPreferredTransport(
        fallbackServiceURL: String? = nil
    ) async throws -> MatrixRTCLiveKitDiscoveredTransport? {
        let session = try client.session()
        return await transportDiscoveryClient.discoverPreferredTransport(
            homeserverURL: session.homeserverUrl,
            accessToken: session.accessToken,
            serverName: try? client.userIdServerName(),
            fallbackServiceURL: fallbackServiceURL
        )
    }

    func requestOpenIDToken() async throws -> MatrixRTCLiveKitOpenIDToken {
        let token = try await client.requestOpenidToken()
        return MatrixRTCLiveKitOpenIDToken(
            accessToken: token.accessToken,
            tokenType: token.tokenType,
            matrixServerName: token.matrixServerName,
            expiresIn: token.expiresInSeconds
        )
    }

    func sfuConfig(
        for membership: MatrixRTCMembershipIdentity,
        transport: MatrixRTCTransport,
        roomId: String,
        endpointVersion: MatrixRTCLiveKitJWTEndpointVersion = .legacy,
        delayDelegation: MatrixRTCLiveKitDelayDelegation? = nil
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        guard let serviceURL = transport.liveKitServiceURL else {
            throw MatrixRustSDKRTCLiveKitFocusError.missingLiveKitServiceURL
        }

        let openIDToken = try await requestOpenIDToken()
        return try await sfuClient.sfuConfig(
            openIDToken: openIDToken,
            membership: membership,
            serviceURL: serviceURL,
            roomId: roomId,
            endpointVersion: endpointVersion,
            delayDelegation: delayDelegation
        )
    }

    func discoverAndAuthenticate(
        membership: MatrixRTCMembershipIdentity,
        roomId: String,
        fallbackServiceURL: String? = nil,
        endpointVersion: MatrixRTCLiveKitJWTEndpointVersion = .legacy,
        delayDelegation: MatrixRTCLiveKitDelayDelegation? = nil
    ) async throws -> MatrixRustSDKRTCLiveKitFocus? {
        guard let discoveredTransport = try await discoverPreferredTransport(
            fallbackServiceURL: fallbackServiceURL
        ) else {
            return nil
        }

        let sfuConfig = try await sfuConfig(
            for: membership,
            transport: discoveredTransport.transport,
            roomId: roomId,
            endpointVersion: endpointVersion,
            delayDelegation: delayDelegation
        )

        return MatrixRustSDKRTCLiveKitFocus(
            discoveredTransport: discoveredTransport,
            sfuConfig: sfuConfig
        )
    }
}
