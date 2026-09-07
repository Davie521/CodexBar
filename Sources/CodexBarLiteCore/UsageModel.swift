import Foundation
import Observation

@MainActor
@Observable
public final class UsageModel {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var failure: UsageFailure?
    public private(set) var isRefreshing = false
    public let isExample: Bool
    public var showRemaining = true
    private let client: any UsageFetching

    public init(client: any UsageFetching, example: UsageSnapshot? = nil) {
        self.client = client
        self.snapshot = example
        self.isExample = example != nil
    }

    public func refresh() async {
        guard !self.isRefreshing, !self.isExample else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        do {
            let result = try await self.client.fetch()
            try Task.checkCancellation()
            self.snapshot = result
            self.failure = nil
        } catch is CancellationError {
            return
        } catch {
            // Do not leave the previous account's numbers visible after a login change or failure.
            self.snapshot = nil
            self.failure = (error as? UsageFailure) ?? .network
        }
    }
}
