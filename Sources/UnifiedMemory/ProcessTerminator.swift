import Darwin
import Foundation

/// Sends a signal to a captured process instance, without privileges or an async suspension.
struct ProcessTerminator {
    enum Action: Sendable, Equatable {
        case terminate
        case forceKill

        var signal: Int32 { self == .terminate ? SIGTERM : SIGKILL }
        var signalName: String { self == .terminate ? "SIGTERM" : "SIGKILL" }
        var buttonTitle: String { self == .terminate ? "Terminate" : "Force Kill" }
    }

    enum Failure: LocalizedError, Equatable {
        case protectedPID(pid_t)
        case ownProcess
        case missingIdentity
        case identityLookupFailed(Int32)
        case identityChanged
        case signalFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .protectedPID(let pid):
                return "PID \(pid) is protected. Select a process with a PID greater than 1. No signal was sent."
            case .ownProcess:
                return "Unified Memory cannot terminate itself. Select another process. No signal was sent."
            case .missingIdentity:
                return "The process start time is unavailable. Refresh and select a row with a readable identity. No signal was sent."
            case .identityLookupFailed(let code):
                return Self.systemError(code, operation: "verify the process identity")
            case .identityChanged:
                return "This PID now belongs to a different process instance. Refresh and select the intended process again. No signal was sent."
            case .signalFailed(let code):
                return Self.systemError(code, operation: "send the signal")
            }
        }

        private static func systemError(_ code: Int32, operation: String) -> String {
            switch code {
            case ESRCH:
                return "The process is no longer running. Refresh the process list. No signal was sent."
            case EPERM, EACCES:
                return "macOS denied permission to \(operation). Choose a process owned by your user; protected processes cannot be terminated here. No signal was sent."
            default:
                return "macOS could not \(operation): \(String(cString: strerror(code))) (errno \(code)). Refresh the process list and try again. No signal was sent."
            }
        }
    }
    static func canTerminate(_ process: ProcessMemoryItem) -> Bool {
        (try? validateTarget(process)) != nil
    }
    /// Pure validation can also reject unsafe targets without attempting any signal.
    static func validateTarget(_ process: ProcessMemoryItem) throws -> UInt64 {
        guard process.pid > 1 else { throw Failure.protectedPID(process.pid) }
        guard process.pid != getpid() else { throw Failure.ownProcess }
        guard let expectedStart = process.startTime, expectedStart != 0 else {
            throw Failure.missingIdentity
        }
        return expectedStart
    }

    /// Success means the kernel accepted the signal, not that the process has exited.
    static func send(_ action: Action, to process: ProcessMemoryItem) throws {
        let expectedStart = try validateTarget(process)

        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw Failure.identityLookupFailed(errno) }
        guard usage.ri_proc_start_abstime != 0 else { throw Failure.missingIdentity }
        guard usage.ri_proc_start_abstime == expectedStart else { throw Failure.identityChanged }

        // macOS has no pidfd-style atomic identity-and-signal API. Keep this last
        // check adjacent to kill, with no await; a small kernel race still exists.
        guard Darwin.kill(process.pid, action.signal) == 0 else {
            throw Failure.signalFailed(errno)
        }
    }
}
