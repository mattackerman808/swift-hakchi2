import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "TaskRunner")

/// Async task runner with progress tracking
@MainActor
final class TaskRunner: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var currentTask: String = ""
    @Published var progress: Double = 0.0
    @Published var canCancel: Bool = false
    @Published var error: Error?

    private var currentTaskHandle: Task<Void, Never>?

    /// Run an async task with progress reporting
    func run(
        name: String,
        cancellable: Bool = true,
        operation: @escaping @Sendable (TaskRunner) async throws -> Void
    ) {
        guard !isRunning else { return }

        isRunning = true
        currentTask = name
        progress = 0.0
        canCancel = cancellable
        error = nil

        logger.info("Task started: \(name)")
        currentTaskHandle = Task { [weak self] in
            do {
                guard let self else { return }
                try await operation(self)
                logger.info("Task completed: \(name)")
                await MainActor.run {
                    self.isRunning = false
                    self.progress = 1.0
                }
            } catch is CancellationError {
                logger.info("Task cancelled: \(name)")
                await MainActor.run {
                    self?.isRunning = false
                    self?.currentTask = "Cancelled"
                }
            } catch {
                logger.error("Task failed: \(name) — \(error.localizedDescription)")
                await MainActor.run {
                    self?.isRunning = false
                    self?.error = error
                }
            }
        }
    }

    /// Update progress from within a task
    nonisolated func updateProgress(status: String, fraction: Double) {
        Task { @MainActor [weak self] in
            self?.currentTask = status
            self?.progress = fraction
        }
    }

    /// Cancel the current task
    func cancel() {
        currentTaskHandle?.cancel()
        currentTaskHandle = nil
    }
}
