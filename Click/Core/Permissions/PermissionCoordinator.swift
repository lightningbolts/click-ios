import Foundation
import AVFoundation
import Photos
import Contacts
import CoreLocation
import CoreBluetooth
import EventKit
import UserNotifications
import UIKit

public enum PermissionType: Sendable {
    case camera
    case photoLibrary
    case contacts
    case microphone
    case locationWhenInUse
    case calendar
    case bluetooth
    case notifications
}

public enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var isAuthorized: Bool { self == .authorized }
}

/// Lightweight contextual coordinator for platform capabilities.
/// It never prompts on app launch; requests occur only after explicit feature intent.
@MainActor
public final class PermissionCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = PermissionCoordinator()

    private let locationManager = CLLocationManager()
    private var locationContinuations: [CheckedContinuation<PermissionStatus, Never>] = []

    public override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Synchronous authorization state for capabilities that expose one.
    /// Notifications should use `statusAsync(for:)` for authoritative state.
    public func status(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .photoLibrary:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized, .limited: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .authorized
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .locationWhenInUse:
            switch locationManager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .authorized
            case .writeOnly, .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .denied
            }

        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }

        case .notifications:
            return .notDetermined
        }
    }

    public func statusAsync(for type: PermissionType) async -> PermissionStatus {
        guard type == .notifications else { return status(for: type) }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let resolved: PermissionStatus
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    resolved = .authorized
                case .denied:
                    resolved = .denied
                case .notDetermined:
                    resolved = .notDetermined
                @unknown default:
                    resolved = .denied
                }
                continuation.resume(returning: resolved)
            }
        }
    }

    /// Requests authorization contextually after explicit user intent.
    public func requestPermission(for type: PermissionType) async -> PermissionStatus {
        switch type {
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied

        case .photoLibrary:
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return (result == .authorized || result == .limited) ? .authorized : .denied

        case .contacts:
            do {
                return try await CNContactStore().requestAccess(for: .contacts) ? .authorized : .denied
            } catch {
                return .denied
            }

        case .microphone:
            return await AVAudioApplication.requestRecordPermission() ? .authorized : .denied

        case .locationWhenInUse:
            let current = status(for: .locationWhenInUse)
            guard current == .notDetermined else { return current }
            return await withCheckedContinuation { continuation in
                let shouldRequest = locationContinuations.isEmpty
                locationContinuations.append(continuation)
                if shouldRequest {
                    locationManager.requestWhenInUseAuthorization()
                }
            }

        case .calendar:
            do {
                return try await EKEventStore().requestFullAccessToEvents() ? .authorized : .denied
            } catch {
                return .denied
            }

        case .bluetooth:
            // CoreBluetooth has no standalone permission-request API. The real proximity
            // manager triggers the prompt when instantiated after explicit user intent.
            return status(for: .bluetooth)

        case .notifications:
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                return granted ? .authorized : .denied
            } catch {
                return .denied
            }
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let finalStatus: PermissionStatus
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: finalStatus = .authorized
        case .denied: finalStatus = .denied
        case .restricted: finalStatus = .restricted
        case .notDetermined: return
        @unknown default: finalStatus = .denied
        }

        let continuations = locationContinuations
        locationContinuations.removeAll()
        continuations.forEach { $0.resume(returning: finalStatus) }
    }

    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
