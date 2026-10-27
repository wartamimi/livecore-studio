import XCTest
@testable import LiveCoreCore
#if canImport(Glibc)
import Glibc
#endif
import Foundation

final class ConcurrencyTests: XCTestCase {
    func testRingBufferRoundsCapacityAndWraps() {
        let rb = SPSCFloatRingBuffer(minimumCapacity: 5)
        XCTAssertEqual(rb.capacity, 8)
        var src: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(rb.write(&src, count: 6), 6)
        var dst = [Float](repeating: 0, count: 4)
        XCTAssertEqual(rb.read(into: &dst, count: 4), 4)
        XCTAssertEqual(dst, [1, 2, 3, 4])
        var more: [Float] = [7, 8, 9, 10, 11, 12, 13]
        XCTAssertEqual(rb.write(&more, count: 7), 6, "only 6 free slots, overflow dropped")
        var all = [Float](repeating: 0, count: 8)
        XCTAssertEqual(rb.read(into: &all, count: 8), 8)
        XCTAssertEqual(all, [5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(rb.availableToRead, 0)
    }

    func testRingBufferUnderrunLeavesDestinationUntouched() {
        let rb = SPSCFloatRingBuffer(minimumCapacity: 16)
        var src: [Float] = [1, 2]
        rb.write(&src, count: 2)
        var dst = [Float](repeating: -1, count: 4)
        XCTAssertEqual(rb.read(into: &dst, count: 4), 2)
        XCTAssertEqual(dst, [1, 2, -1, -1])
    }

    func testRingBufferConcurrentProducerConsumerPreservesOrder() {
        let rb = SPSCFloatRingBuffer(minimumCapacity: 1024)
        let total = 2_000_000
        let done = DispatchSemaphore(value: 0)
        // Values are k % 4096 (exact in Float) so the consumer can verify strict ordering.
        Thread.detachNewThread {
            var chunk = [Float](repeating: 0, count: 97)
            var produced = 0
            while produced < total {
                let n = min(chunk.count, total - produced)
                for i in 0..<n { chunk[i] = Float((produced + i) % 4096) }
                var written = 0
                while written < n {
                    written += chunk.withUnsafeBufferPointer { rb.write($0.baseAddress! + written, count: n - written) }
                }
                produced += n
            }
            done.signal()
        }
        var consumed = 0
        var buf = [Float](repeating: 0, count: 61)
        var errors = 0
        while consumed < total {
            let n = rb.read(into: &buf, count: buf.count)
            for i in 0..<n where buf[i] != Float((consumed + i) % 4096) { errors += 1 }
            consumed += n
        }
        done.wait()
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(consumed, total)
    }

    func testAtomicFloatStoreMaxAndExchange() {
        let a = AtomicFloat(0)
        a.storeMax(0.5); a.storeMax(0.2)
        XCTAssertEqual(a.value, 0.5)
        XCTAssertEqual(a.exchange(0), 0.5)
        XCTAssertEqual(a.value, 0)
        let c = AtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<10_000 { c.add() } }
        XCTAssertEqual(c.value, 80_000)
    }

    func testBackoffSchedule() {
        let b = ExponentialBackoff(initialDelay: 1, multiplier: 2, maxDelay: 10, maxAttempts: 5, jitterFraction: 0)
        XCTAssertEqual((0..<5).map { b.delay(forAttempt: $0)! }, [1, 2, 4, 8, 10])
        XCTAssertNil(b.delay(forAttempt: 5))
        let j = ExponentialBackoff(initialDelay: 10, multiplier: 2, maxDelay: 30, maxAttempts: 0, jitterFraction: 0.1)
        XCTAssertEqual(j.delay(forAttempt: 0, random01: 1)!, 11, accuracy: 1e-9)
        XCTAssertEqual(j.delay(forAttempt: 0, random01: 0)!, 9, accuracy: 1e-9)
        XCTAssertNotNil(j.delay(forAttempt: 1000), "0 = unlimited attempts")
    }

    func testRedaction() {
        XCTAssertEqual(Redaction.maskKey("abcd-efgh-ijkl-mnop"), "ab••••••op")
        XCTAssertEqual(Redaction.maskKey("short"), "••••••")
        XCTAssertEqual(Redaction.scrub("publish live/sk_123456 failed, sk_123456 bad", secrets: ["sk_123456"]),
                       "publish live/<redacted> failed, <redacted> bad")
    }
}

final class ClockAnchorTests: XCTestCase {
    func testAnchorMapsSampleIndexToHostTime() {
        let a = ClockAnchor()
        XCTAssertNil(a.read())
        a.publish(sampleIndex: 48000, hostSeconds: 100)
        XCTAssertEqual(a.hostTime(ofSample: 96000, sampleRate: 48000)!, 101, accuracy: 1e-9)
        XCTAssertEqual(a.hostTime(ofSample: 24000, sampleRate: 48000)!, 99.5, accuracy: 1e-9)
    }

    func testAnchorReadsAreNeverTorn() {
        let a = ClockAnchor()
        let stop = AtomicBool(false)
        Thread.detachNewThread {
            var i: UInt64 = 1
            while !stop.value { a.publish(sampleIndex: i, hostSeconds: Double(i) * 2); i += 1 }
        }
        var torn = 0
        for _ in 0..<200_000 {
            if let r = a.read(), r.hostSeconds != Double(r.sampleIndex) * 2 { torn += 1 }
        }
        stop.value = true
        XCTAssertEqual(torn, 0)
    }
}
