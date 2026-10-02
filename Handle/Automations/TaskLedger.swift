import Foundation
import Combine

/// Background agent runs, memory only: what was asked,
/// whether it's still running, what came back, what it cost — and the handles
/// the kill switch cancels.
@MainActor
final class TaskLedger: ObservableObject {
    static let shared = TaskLedger()

    enum Status: String { case running, done, failed, cancelled }
    struct Entry: Identifiable {
        let id: String
        let goal: String
        var status: Status
        let started: Date
        var finished: Date?
        var result: String?
        var costUSD: Double?
        var task: Task<Void, Never>?
    }

    @Published private(set) var entries: [Entry] = []

    func start(goal: String) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        entries.insert(Entry(id: id, goal: goal, status: .running, started: Date()), at: 0)
        if entries.count > 30 { entries.removeLast(entries.count - 30) }
        return id
    }

    func attach(id: String, task: Task<Void, Never>) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].task = task
    }

    func finish(id: String, result: String, costUSD: Double? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].status == .running else { return }
        entries[i].status = result.isEmpty ? .failed : .done
        entries[i].finished = Date()
        entries[i].result = result
        entries[i].costUSD = costUSD
        entries[i].task = nil
    }

    /// The kill switch: every running background task is cancelled and marked so.
    func cancelAll() {
        for i in entries.indices where entries[i].status == .running {
            entries[i].task?.cancel()
            entries[i].task = nil
            entries[i].status = .cancelled
            entries[i].finished = Date()
            entries[i].result = "Cancelled."
        }
    }

    var running: [Entry] { entries.filter { $0.status == .running } }
}
