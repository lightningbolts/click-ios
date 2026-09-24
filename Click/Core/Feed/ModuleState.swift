import Foundation

/// Load state for one independently refreshed screen module (spec §13).
///
/// Distinguishes the cases the old client conflated: nothing loaded yet, cached value shown
/// while refreshing, fresh value, confirmed-empty value (a successful response whose value is
/// empty), a failure with or without cached data, and a module that cannot load at all right
/// now (for example discovery without location access).
public struct ModuleState<Value: Equatable & Sendable>: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
        case unavailable(String)
    }

    public private(set) var value: Value?
    public private(set) var phase: Phase
    /// The phase before the in-flight load began, restored when that load is cancelled.
    private var phaseBeforeLoading: Phase = .idle

    public init(value: Value? = nil, phase: Phase = .idle) {
        self.value = value
        self.phase = phase
    }

    /// Seeds a cached value without claiming it is fresh.
    public mutating func seed(_ cached: Value?) {
        guard value == nil, let cached else { return }
        value = cached
    }

    public mutating func begin() {
        if phase != .loading { phaseBeforeLoading = phase }
        phase = .loading
    }

    public mutating func succeed(_ fresh: Value) {
        value = fresh
        phase = .loaded
    }

    /// Records a failure but keeps any value already shown (it becomes stale, not empty).
    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    /// Records a thrown error. Cancellation (navigation, view teardown) is not a failure: the
    /// previous phase is restored and nothing is shown as stale.
    public mutating func fail(_ error: any Error) {
        if error.isCancellation {
            if phase == .loading { phase = phaseBeforeLoading }
            return
        }
        fail(error.userFacingMessage)
    }

    /// Ends a load without new data and without claiming failure (e.g. no location fix).
    public mutating func succeedKeepingValue() {
        phase = value == nil ? .idle : .loaded
    }

    public mutating func markUnavailable(_ reason: String) {
        value = nil
        phase = .unavailable(reason)
    }

    /// True once a server response has been applied in this session.
    public var isFresh: Bool { phase == .loaded }

    /// True while a value is on screen that did not come from this session's successful refresh.
    public var isStale: Bool {
        guard value != nil else { return false }
        if case .failed = phase { return true }
        return false
    }

    /// Nothing to show yet and a request is in flight (or about to be).
    public var isPending: Bool {
        value == nil && (phase == .loading || phase == .idle)
    }

    public var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }
}

extension Error {
    /// A short, stable user-facing description. Raw server bodies are never surfaced.
    var userFacingMessage: String {
        switch self as? APIError {
        case .offline: "You're offline."
        case .timeout: "The request timed out."
        case .unauthorized: "Your session needs to refresh."
        case .forbidden: "You don't have access to this."
        case .notFound: "This is no longer available."
        case .rateLimited: "Too many requests. Try again shortly."
        case .server, .decoding, .conflict, .validation, .invalidURL, .cancelled, nil:
            "Something went wrong. Try again."
        }
    }

    /// True for cancellations from SwiftUI `.task` teardown or URLSession, which are never failures.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if (self as? APIError) == .cancelled { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    var isOffline: Bool {
        switch self as? APIError {
        case .offline, .timeout: true
        default: false
        }
    }
}
