import Foundation
import Testing
import LibGit2

/// Covers how quickly a dead git connection is allowed to sit.
///
/// Periodic sync repeats the ref advertisement every couple of seconds.
/// That request has to give up soon, or a server that cannot be reached
/// looks fine until a pack transfer's long timeout runs out.
struct MTLSRequestTimeoutTests {
    @Test func refAdvertisementGivesUpSoonerThanAPackTransfer() {
        #expect(MTLSTransport.requestTimeout(for: .refAdvertisement) == 15)
        #expect(MTLSTransport.requestTimeout(for: .packTransfer) == 300)
    }
}
