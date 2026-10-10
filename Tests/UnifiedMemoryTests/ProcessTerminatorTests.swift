import Darwin
import Foundation
import XCTest
@testable import UnifiedMemory

final class ProcessTerminatorTests: XCTestCase {
    func testReaderCapturesIdentityAndSIGTERMExitsOwnedChild() async throws {
        let child = try SleepChild()
        defer { child.cleanUp() }

        let snapshot = try await ProcessMemoryReader().read()
        let captured = try XCTUnwrap(snapshot.items.first { $0.pid == child.item.pid })
        XCTAssertEqual(captured.startTime, child.item.startTime)
        XCTAssertNotNil(captured.footprint)
        XCTAssertTrue(ProcessTerminator.canTerminate(captured))

        try ProcessTerminator.send(.terminate, to: captured)
        guard child.waitForExit() else { return }
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGTERM)
    }

    func testSIGKILLExitsOwnedChild() throws {
        let child = try SleepChild()
        defer { child.cleanUp() }

        try ProcessTerminator.send(.forceKill, to: child.item)
        guard child.waitForExit() else { return }
        XCTAssertEqual(child.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.process.terminationStatus, SIGKILL)
    }

    func testChangedIdentityRejectsBothSignalsAndLeavesChildAlive() throws {
        let child = try SleepChild()
        defer { child.cleanUp() }
        let actualStart = try XCTUnwrap(child.item.startTime)
        let mismatched = ProcessMemoryItem(
            pid: child.item.pid, name: child.item.name, footprint: child.item.footprint,
            startTime: actualStart == UInt64.max ? actualStart - 1 : actualStart + 1
        )
        XCTAssertNotEqual(child.item.id, mismatched.id)

        for action in [ProcessTerminator.Action.terminate, .forceKill] {
            XCTAssertThrowsError(try ProcessTerminator.send(action, to: mismatched)) { error in
                XCTAssertEqual(error as? ProcessTerminator.Failure, .identityChanged)
            }
            XCTAssertTrue(child.process.isRunning)
        }
    }

    func testUnavailableAndZeroIdentityRejectBothSignalsAndLeaveChildAlive() throws {
        let child = try SleepChild()
        defer { child.cleanUp() }

        for startTime in [nil, UInt64(0)] {
            let unavailable = ProcessMemoryItem(
                pid: child.item.pid, name: child.item.name,
                footprint: child.item.footprint, startTime: startTime
            )
            XCTAssertFalse(ProcessTerminator.canTerminate(unavailable))
            for action in [ProcessTerminator.Action.terminate, .forceKill] {
                XCTAssertThrowsError(try ProcessTerminator.send(action, to: unavailable)) { error in
                    XCTAssertEqual(error as? ProcessTerminator.Failure, .missingIdentity)
                }
                XCTAssertTrue(child.process.isRunning)
            }
        }
    }

    func testProtectedAndSelfPIDValidationNeverAttemptsASignal() {
        // Exercise the same pure validation used by send(), rather than risk
        // signaling a process group, launchd, or the full-suite test runner.
        for pid in [pid_t(-1), 0, 1] {
            let protected = ProcessMemoryItem(pid: pid, name: "protected", footprint: nil, startTime: 1)
            XCTAssertFalse(ProcessTerminator.canTerminate(protected))
            XCTAssertThrowsError(try ProcessTerminator.validateTarget(protected)) { error in
                XCTAssertEqual(error as? ProcessTerminator.Failure, .protectedPID(pid))
            }
        }
        let own = ProcessMemoryItem(pid: getpid(), name: "test runner", footprint: nil, startTime: 1)
        XCTAssertFalse(ProcessTerminator.canTerminate(own))
        XCTAssertThrowsError(try ProcessTerminator.validateTarget(own)) { error in
            XCTAssertEqual(error as? ProcessTerminator.Failure, .ownProcess)
        }
    }

    func testExitedChildCannotReceiveAnotherSignal() throws {
        let child = try SleepChild()
        defer { child.cleanUp() }
        try ProcessTerminator.send(.forceKill, to: child.item)
        guard child.waitForExit() else { return }

        for action in [ProcessTerminator.Action.terminate, .forceKill] {
            XCTAssertThrowsError(try ProcessTerminator.send(action, to: child.item)) { error in
                // A concurrently reused PID must fail closed too, not target its replacement.
                let failure = error as? ProcessTerminator.Failure
                XCTAssertTrue(failure == .identityLookupFailed(ESRCH) || failure == .identityChanged)
            }
        }
    }
}

private final class SleepChild {
    let process: Process
    let item: ProcessMemoryItem
    private let exited: DispatchSemaphore

    init() throws {
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"] // Bounded even if setup fails before identity is available.
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard usage.ri_proc_start_abstime != 0 else {
            throw ProcessTerminator.Failure.missingIdentity
        }
        self.process = process
        self.exited = exited
        item = ProcessMemoryItem(
            pid: process.processIdentifier, name: "sleep", footprint: usage.ri_phys_footprint,
            startTime: usage.ri_proc_start_abstime
        )
    }

    @discardableResult
    func waitForExit(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let didExit = exited.wait(timeout: .now() + 5) == .success
        XCTAssertTrue(didExit, "Owned sleep child did not exit after its signal", file: file, line: line)
        return didExit
    }

    func cleanUp(file: StaticString = #filePath, line: UInt = #line) {
        guard process.isRunning else { return }
        do {
            try ProcessTerminator.send(.forceKill, to: item)
            waitForExit(file: file, line: line)
        } catch {
            XCTFail("Could not clean up the identity-checked owned sleep child: \(error)", file: file, line: line)
        }
    }
}
