import Combine
import Foundation

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isPaused = false
    @Published private(set) var interval: Int = 1
    @Published private(set) var processes: ProcessMemorySnapshot?
    @Published private(set) var processError: String?
    @Published private(set) var temperature: TemperatureSnapshot?
    @Published private(set) var temperatureError: String?
    let sensorMonitor = SensorMonitor()
    private var sensorsVisible = false

    // Bounded circular history: no shifting or copying samples on every tick.
    private var samples = [MemorySnapshot?](repeating: nil, count: 301)
    private var first = 0
    private(set) var sampleCount = 0
    private let reader = MemoryReader()
    private var samplingTask: Task<Void, Never>?
    private let processReader = ProcessMemoryReader()
    private var processTask: Task<Void, Never>?
    private let temperatureReader = TemperatureReader()
    private var temperatureTask: Task<Void, Never>?

    init() {
        startSampling()
    }

    deinit {
        samplingTask?.cancel()
        processTask?.cancel()
        temperatureTask?.cancel()
    }

    func sample(at index: Int) -> MemorySnapshot? {
        guard index >= 0, index < sampleCount else { return nil }
        return samples[(first + index) % samples.count]
    }

    func refresh() {
        do {
            let next = try reader.read()
            let cutoff = next.timestamp.addingTimeInterval(-300)
            while sampleCount > 0, let oldest = samples[first], oldest.timestamp < cutoff {
                samples[first] = nil
                first = (first + 1) % samples.count
                sampleCount -= 1
            }
            if sampleCount == samples.count {
                samples[first] = next
                first = (first + 1) % samples.count
            } else {
                samples[(first + sampleCount) % samples.count] = next
                sampleCount += 1
            }
            error = nil
            // Publish after history is updated so the graph sees the same sample.
            snapshot = next
        } catch {
            self.error = error.localizedDescription
        }
        refreshProcesses()
        refreshTemperature()
        sensorMonitor.refresh()
    }

    private func refreshTemperature() {
        temperatureTask?.cancel()
        let reader = temperatureReader
        temperatureTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let next = try await reader.read()
                guard !Task.isCancelled else { return }
                self?.temperature = next
                self?.temperatureError = nil
                self?.sensorMonitor.updateTemperature(next, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                if let failedSnapshot = (error as? TemperatureReadError)?.snapshot {
                    self?.temperature = failedSnapshot
                }
                self?.temperatureError = error.localizedDescription
                self?.sensorMonitor.updateTemperature((error as? TemperatureReadError)?.snapshot, error: error.localizedDescription)
            }
        }
    }

    private func refreshProcesses() {
        processTask?.cancel()
        let reader = processReader
        processTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let next = try await reader.read()
                guard !Task.isCancelled else { return }
                self?.processes = next
                self?.processError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.processError = error.localizedDescription
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        sensorMonitor.configure(visible: sensorsVisible, paused: isPaused, interval: interval)
        if isPaused {
            samplingTask?.cancel()
            processTask?.cancel()
            temperatureTask?.cancel()
            samplingTask = nil
        } else {
            startSampling()
        }
    }

    func setSensorsVisible(_ visible: Bool) {
        sensorsVisible = visible
        sensorMonitor.configure(visible: visible, paused: isPaused, interval: interval)
        if visible && !isPaused { sensorMonitor.refresh() }
    }

    func setInterval(_ seconds: Int) {
        guard [1, 2, 5].contains(seconds), seconds != interval else { return }
        interval = seconds
        sensorMonitor.configure(visible: sensorsVisible, paused: isPaused, interval: interval)
        if !isPaused { startSampling() }
    }

    private func startSampling() {
        samplingTask?.cancel()
        refresh()
        let seconds = interval
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}
