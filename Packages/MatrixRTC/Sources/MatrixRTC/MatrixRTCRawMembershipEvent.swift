import Foundation

public struct MatrixRTCRawMembershipEvent: Equatable, Sendable {
    public static let legacyCallMemberEventType = "org.matrix.msc3401.call.member"
    public static let rtcMemberEventType = "org.matrix.msc4143.rtc.member"

    public let eventId: String
    public let eventType: String
    public let stateKey: String?
    public let sender: String
    public let originServerTimestamp: Int64
    public let contentJSON: String

    public init(
        eventId: String,
        eventType: String,
        stateKey: String?,
        sender: String,
        originServerTimestamp: Int64,
        contentJSON: String
    ) {
        self.eventId = eventId
        self.eventType = eventType
        self.stateKey = stateKey
        self.sender = sender
        self.originServerTimestamp = originServerTimestamp
        self.contentJSON = contentJSON
    }
}
