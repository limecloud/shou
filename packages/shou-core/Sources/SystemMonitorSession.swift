import Foundation
import Observation

/// One serial sampler per window. Hidden pages stop unless the user enables the status item.
@MainActor @Observable public final class SystemMonitorSession {
    public private(set) var sample: SystemMonitorSample?
    public private(set) var history: [SystemMonitorSample]=[]
    public private(set) var paused=false
    public private(set) var backgroundEnabled=false
    public private(set) var failed=false
    public private(set) var isSampling=false
    @ObservationIgnored public var updated: (() -> Void)?
    @ObservationIgnored private let source: any SystemMonitorSampling
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var calculator=SystemMonitorCalculator()
    @ObservationIgnored private var visible=false
    @ObservationIgnored private var disposed=false
    @ObservationIgnored private var generation=0
    @ObservationIgnored private var task: Task<Void,Never>?

    public init(source: any SystemMonitorSampling, interval: Duration = .seconds(2)) { self.source=source; self.interval=interval }
    deinit { task?.cancel() }
    public func setVisible(_ value: Bool) { guard visible != value else { return }; visible=value; reconcile() }
    public func setBackgroundEnabled(_ value: Bool) { backgroundEnabled=value; reconcile(); updated?() }
    public func setPaused(_ value: Bool) { paused=value; reconcile(); updated?() }
    public func shutdown() { disposed=true; reconcile(); updated=nil }
    private var desired: Bool { !disposed && !paused && (visible || backgroundEnabled) }
    private func reconcile() {
        if !desired {
            generation += 1; calculator.resetBaseline(); task?.cancel(); isSampling=false
        } else if task == nil {
            let current=generation
            isSampling=true
            task=Task { [weak self] in await self?.run(current) }
        }
    }
    private func run(_ current: Int) async {
        while !Task.isCancelled && desired && current == generation {
            do {
                let observation=try await source.observe()
                guard !Task.isCancelled && desired && current == generation else { break }
                sample=calculator.append(observation); history=calculator.history; failed=false; updated?()
            } catch {
                guard !Task.isCancelled && desired && current == generation else { break }
                failed=true; calculator.resetBaseline(); updated?()
            }
            do { try await Task.sleep(for: interval) } catch { break }
        }
        task=nil; isSampling=false
        reconcile()
    }
}
