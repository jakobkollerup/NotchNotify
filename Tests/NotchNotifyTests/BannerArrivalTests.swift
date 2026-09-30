import Foundation
import Testing
@testable import NotchNotifyCore

@Suite("Banner arrival scheduling") @MainActor
struct BannerArrivalTests {
    @Test func firstArrivalRunsBeforeReturningToTheRunLoop() {
        let coalescer = Debouncer()
        var calls = 0
        coalescer.schedule(delay: 0.05, leading: true) { calls += 1 }
        #expect(calls == 1, "The native banner must be hidden on the first event, before the settling delay")
        coalescer.cancel()
    }

    @Test func layoutBurstProducesOneImmediateAndOneSettledPass() async throws {
        let coalescer = Debouncer()
        var calls = 0
        for _ in 0..<40 {
            coalescer.schedule(delay: 0.02, leading: true) { calls += 1 }
        }
        #expect(calls == 1, "Layout churn must not run dozens of synchronous AX sweeps")
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 2)
        coalescer.schedule(delay: 0.02, leading: true) { calls += 1 }
        #expect(calls == 3, "The next arrival must get its own immediate pass")
        coalescer.cancel()
    }

    @Test func stoppingCancelsTheSettlingPass() async throws {
        let coalescer = Debouncer()
        var calls = 0
        coalescer.schedule(delay: 0.02, leading: true) { calls += 1 }
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1, "A stopped engine must not re-hide a restored window")
    }

    @Test func nativeAndSettingsDebouncesStillWait() async throws {
        let coalescer = Debouncer()
        var calls = 0
        for _ in 0..<10 {
            coalescer.schedule(delay: 0.02) { calls += 1 }
        }
        #expect(calls == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }
}
