import Foundation

/// 1Hz 倒计时驱动:start(interval:onTick:) 启动一个 Timer,onTick 周期性被调用;stop() 停。
/// SleepGuard 用它推进 `AppState.advanceCountdownTick()`。
@MainActor
public protocol CountdownTicker: AnyObject {
    func start(interval: TimeInterval, onTick: @escaping @MainActor () -> Void)
    func stop()
}

/// 生产实现:Timer + RunLoop.main.common。@MainActor 化后无需显式指定 runloop。
@MainActor
public final class TimerCountdownTicker: CountdownTicker {
    private var timer: Timer?

    public init() {}

    public func start(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            // Timer 的 closure 跑在 scheduled runloop;在 main thread 上(因为我们 @MainActor)
            MainActor.assumeIsolated {
                onTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// 测试用 Fake:不启 Timer,只记录 start/stop 调用 + tickCount。SelfCheck 用来断言生命周期。
@MainActor
public final class RecordingTicker: CountdownTicker {
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var tickCount = 0
    public var autoFireTicks: Int = 0  // 启动时立即 fire N 次模拟 onTick

    public init() {}

    public func start(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        startCount += 1
        for _ in 0..<autoFireTicks {
            tickCount += 1
            onTick()
        }
    }

    public func stop() {
        stopCount += 1
    }
}
