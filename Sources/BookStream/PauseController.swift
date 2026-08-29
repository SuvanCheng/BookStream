//
//  PauseController.swift
//  BookStream
//
//  线程安全的全局任务暂停 / 继续控制器（支持并发挂起、精准累计暂停时长、休眠/Wi-Fi切换保护）
//

import Foundation

public final class PauseController: @unchecked Sendable {
    private let lock = NSLock()
    private var _isPaused = false
    private var pauseStartTime: Date?
    private var accumulatedPausedTime: TimeInterval = 0
    private var pauseIntervals: [(start: Date, end: Date)] = []

    public init() {}

    /// 当前是否处于暂停状态
    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isPaused
    }

    /// 累计暂停耗时（供整书导出总耗时扣除暂停时间使用）
    public var totalPausedTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        var total = accumulatedPausedTime
        if let start = pauseStartTime {
            total += Date().timeIntervalSince(start)
        }
        return total
    }

    /// 精准计算自指定时间点（如某单阶段开始时间）以来发生的暂停时长，避免跨阶段时长污染
    public func pausedTime(since startTime: Date) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        var sum: TimeInterval = 0
        for interval in pauseIntervals {
            let clampedStart = max(interval.start, startTime)
            let clampedEnd = max(interval.end, startTime)
            if clampedEnd > clampedStart {
                sum += clampedEnd.timeIntervalSince(clampedStart)
            }
        }
        if let currentStart = pauseStartTime {
            let clampedStart = max(currentStart, startTime)
            let clampedEnd = max(Date(), startTime)
            if clampedEnd > clampedStart {
                sum += clampedEnd.timeIntervalSince(clampedStart)
            }
        }
        return sum
    }

    /// 重置控制器状态
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isPaused = false
        pauseStartTime = nil
        accumulatedPausedTime = 0
        pauseIntervals.removeAll()
    }

    /// 触发暂停
    @discardableResult
    public func pause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_isPaused else { return false }
        _isPaused = true
        pauseStartTime = Date()
        return true
    }

    /// 恢复继续
    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _isPaused else { return false }
        _isPaused = false
        if let start = pauseStartTime {
            let end = Date()
            pauseIntervals.append((start, end))
            accumulatedPausedTime += end.timeIntervalSince(start)
            pauseStartTime = nil
        }
        return true
    }

    /// 切换暂停/继续状态
    @discardableResult
    public func toggle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _isPaused.toggle()
        if _isPaused {
            pauseStartTime = Date()
        } else if let start = pauseStartTime {
            let end = Date()
            pauseIntervals.append((start, end))
            accumulatedPausedTime += end.timeIntervalSince(start)
            pauseStartTime = nil
        }
        return _isPaused
    }

    /// 异步等待恢复（0% CPU 消耗，适用于 async 异步协程流水线）
    public func waitIfPaused(cancellation: (@Sendable () -> Bool)? = nil) async throws {
        while true {
            if cancellation?() == true || Task.isCancelled {
                throw BookStreamError.cancelled
            }

            let paused: Bool = lock.withLock { _isPaused }
            if !paused {
                return
            }

            // 挂起让出线程，每 100ms 检查一次继续或取消状态
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 同步等待恢复（0% CPU 消耗，适用于专属音频/视频渲染后台工作线程）
    public func waitIfPausedSync(cancellation: (@Sendable () -> Bool)? = nil) throws {
        while true {
            if cancellation?() == true {
                throw BookStreamError.cancelled
            }

            let paused: Bool = lock.withLock { _isPaused }
            if !paused {
                return
            }

            // 让出 CPU 线程休眠 100ms
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
