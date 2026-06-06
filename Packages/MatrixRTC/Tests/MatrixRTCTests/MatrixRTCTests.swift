import Testing
@testable import MatrixRTC

@Test func computesRtcBackendIdentity() {
    let identity = MatrixRTCMembershipIdentity(
        userId: "@alice:example.com",
        deviceId: "DEVICE123",
        memberId: "memberABC"
    )

    #expect(identity.rtcBackendIdentity == "J+T45tGruxc+HrUOqJJlyQSV33m728Cme4+vt8/SWrU")
}
