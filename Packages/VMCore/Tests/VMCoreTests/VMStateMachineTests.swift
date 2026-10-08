import XCTest
@testable import VMCore

final class VMStateMachineTests: XCTestCase {
    func testHappyPath() throws {
        var m = VMStateMachine()
        XCTAssertEqual(m.state, .stopped)
        try m.apply(.startRequested); XCTAssertEqual(m.state, .starting)
        try m.apply(.startSucceeded); XCTAssertEqual(m.state, .running)
        try m.apply(.pauseSucceeded); XCTAssertEqual(m.state, .paused)
        try m.apply(.resumeSucceeded); XCTAssertEqual(m.state, .running)
        try m.apply(.stopRequested); XCTAssertEqual(m.state, .stopping)
        m.markStopped(); XCTAssertEqual(m.state, .stopped)
    }

    func testInvalidTransitionThrows() {
        var m = VMStateMachine()
        XCTAssertThrowsError(try m.apply(.pauseSucceeded)) { error in
            XCTAssertEqual(error as? VMStateError, .invalidTransition(from: .stopped, event: .pauseSucceeded))
        }
        XCTAssertEqual(m.state, .stopped)
    }

    func testCannotStartTwice() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested)
        XCTAssertThrowsError(try m.apply(.startRequested))
    }

    func testFailureRecordsMessageAndAllowsRestart() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested)
        m.fail("sin memoria")
        XCTAssertEqual(m.state, .error)
        XCTAssertEqual(m.lastError, "sin memoria")
        try m.apply(.startRequested)
        XCTAssertEqual(m.state, .starting)
        XCTAssertNil(m.lastError)
    }

    func testStopAbandonedReturnsToRunning() throws {
        var m = VMStateMachine()
        try m.apply(.startRequested); try m.apply(.startSucceeded); try m.apply(.stopRequested)
        try m.apply(.stopAbandoned)
        XCTAssertEqual(m.state, .running)
    }

    func testIsActive() {
        XCTAssertFalse(VMState.stopped.isActive)
        XCTAssertFalse(VMState.error.isActive)
        XCTAssertTrue(VMState.running.isActive)
        XCTAssertTrue(VMState.paused.isActive)
        XCTAssertTrue(VMState.starting.isActive)
    }
}
