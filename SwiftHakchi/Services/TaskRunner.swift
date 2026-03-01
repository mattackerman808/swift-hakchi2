import Foundation

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

        currentTaskHandle = Task { [weak self] in
            do {
                guard let self else { return }
                try await operation(self)
                await MainActor.run {
                    self.isRunning = false
                    self.progress = 1.0
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.isRunning = false
                    self?.currentTask = "Cancelled"
                }
            } catch {
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
