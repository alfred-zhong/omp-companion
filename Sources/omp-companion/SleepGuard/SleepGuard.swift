import Foundation

/// 阻止系统睡眠 / 显示器睡眠的守护:基于 IOPMAssertion。
///
/// 单会话模型:调 `start(bucket:)` 即创建 / 续期会话;调 `cancel()` 立即释放。
/// 不持久化;进程退出即结束。
///
/// @MainActor 化后:所有方法同步在主线程,无需 NSLock / DispatchQueue.main.async。
/// 资源管理走 `IOPMAssertionAdapter`,1Hz 推进走 `CountdownTicker`。
@MainActor
public final class SleepGuard {
    private let state: AppState
    private let adapter: IOPMAssertionAdapter
    private let ticker: CountdownTicker
    private let tickerFactory: () -> CountdownTicker
    private var currentAssertions: (system: UInt32, display: UInt32) = (0, 0)

    public init(
        state: AppState,
        adapter: IOPMAssertionAdapter = LiveIOPMAssertionAdapter(),
        ticker: CountdownTicker? = nil
    ) {
        self.state = state
        self.adapter = adapter
        let ticker = ticker ?? TimerCountdownTicker()
        self.ticker = ticker
        self.tickerFactory = { ticker }
    }

    /// 测试用 init:每次 cancel 后重建 ticker。
    init(
        state: AppState,
        adapter: IOPMAssertionAdapter,
        tickerFactory: @escaping () -> CountdownTicker
    ) {
        self.state = state
        self.adapter = adapter
        self.ticker = tickerFactory()
        self.tickerFactory = tickerFactory
    }

    /// 当前是否持有活跃 assertion。
    public var isActive: Bool {
        currentAssertions.system != 0 || currentAssertions.display != 0
    }

    /// 启动或覆盖到指定档位(endAt = now + duration)。
    @discardableResult
    public func start(bucket: CaffeinateBucket) -> CaffeinateSession {
        // 先释放旧 assertion
        if isActive {
            adapter.release(system: currentAssertions.system, display: currentAssertions.display)
            currentAssertions = (0, 0)
        }
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(bucket.minutes) * 60)
        let pair = adapter.acquire(name: "omp-companion: \(bucket.minutes) 分钟")
        currentAssertions = pair
        if pair.system == 0 || pair.display == 0 {
            // acquire 失败:不暴露 session
            state.setCaffeinateSession(nil)
            ticker.stop()
            return CaffeinateSession(bucket: bucket, startedAt: now, endAt: end)
        }
        let session = CaffeinateSession(bucket: bucket, startedAt: now, endAt: end)
        state.setCaffeinateSession(session)
        ticker.start(interval: 1.0) { [weak self] in
            self?.advanceTick()
        }
        return session
    }

    /// 立即释放当前会话(无操作时安全)。
    public func cancel() {
        if isActive {
            adapter.release(system: currentAssertions.system, display: currentAssertions.display)
            currentAssertions = (0, 0)
        }
        ticker.stop()
        state.setCaffeinateSession(nil)
    }

    private func advanceTick() {
        guard let session = state.caffeinateSession else {
            ticker.stop()
            return
        }
        let now = Date()
        if !session.isActive(now: now) {
            cancel()
            return
        }
        state.advanceCountdownTick()
    }
}
