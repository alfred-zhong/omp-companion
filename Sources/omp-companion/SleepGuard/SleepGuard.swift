import Foundation
import IOKit.pwr_mgt

/// 阻止系统睡眠 / 显示器睡眠的守护：基于 IOPMAssertion。
///
/// 单会话模型：调 `start(bucket:)` 即创建 / 续期会话；调 `cancel()` 立即释放。
/// 不持久化；进程退出即结束。
public final class SleepGuard: @unchecked Sendable {
    private let state: AppState
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private let lock = NSLock()

    public init(state: AppState) {
        self.state = state
    }

    deinit {
        cancel()
    }

    /// 当前是否持有活跃 assertion。
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return systemAssertionID != 0 || displayAssertionID != 0
    }

    /// 启动或覆盖到指定档位（endAt = now + duration）。
    @discardableResult
    public func start(bucket: CaffeinateBucket) -> CaffeinateSession {
        let now = Date()
        let end = now.addingTimeInterval(TimeInterval(bucket.minutes) * 60)
        let session = CaffeinateSession(bucket: bucket, startedAt: now, endAt: end)

        lock.lock()
        releaseAssertionsLocked()
        let systemResult = acquireAssertionLocked(
            type: "PreventUserIdleSystemSleep" as CFString,
            name: "omp-companion: 阻止系统休眠 \(bucket.minutes) 分钟"
        )
        let displayResult = acquireAssertionLocked(
            type: "PreventUserIdleDisplaySleep" as CFString,
            name: "omp-companion: 阻止显示器休眠 \(bucket.minutes) 分钟"
        )
        systemAssertionID = systemResult
        displayAssertionID = displayResult
        lock.unlock()

        let acquired = systemResult != 0 && displayResult != 0
        let finalSession = acquired ? session : nil
        if !acquired {
            // 部分失败：rollback 任意已建立的
            lock.lock()
            releaseAssertionsLocked()
            lock.unlock()
        }

        DispatchQueue.main.async { [weak self] in
            self?.state.setCaffeinateSession(finalSession)
            self?.restartTicking()
        }
        return finalSession ?? session
    }

    /// 立即释放当前会话（无操作时安全）。
    public func cancel() {
        lock.lock()
        releaseAssertionsLocked()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.state.setCaffeinateSession(nil)
            self?.stopTicking()
        }
    }

    // MARK: - Timer

    private func restartTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// 1 秒一次：检查 endAt；到期就 cancel；推进 countdownTick。
    private func tick() {
        guard let session = state.caffeinateSession else {
            stopTicking()
            return
        }
        let now = Date()
        if !session.isActive(now: now) {
            cancel()
            return
        }
        state.advanceCountdownTick()
    }

    // MARK: - IOPMAssertion

    /// 必须在 lock 持锁状态调用；返回 0 表示失败。
    private func acquireAssertionLocked(type: CFString, name: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            return id
        }
        return 0
    }

    private func releaseAssertionsLocked() {
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }
}
