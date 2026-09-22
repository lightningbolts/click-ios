import Foundation
import AVFoundation
import Photos
import Contacts
import CoreLocation
import UserNotifications
import UIKit

public enum PermissionType: Sendable {
    case camera
    case photoLibrary
    case contacts
    case microphone
    case locationWhenInUse
    case notifications
}

public enum PermissionStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var isAuthorized: Bool {
        self == .authorized
    }
}

/// Lightweight, contextual coordinator for platform capabilities and permissions.
/// Avoids eager prompt storms on app launch; prompts only on intentional user gestures.
@MainActor
public final class PermissionCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = PermissionCoordinator()

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<PermissionStatus, Never>?

    public override init() {
        super.init()
        locationManager.delegate = self
    }

    /// Queries the current authorization status for a permission type without prompting the user.
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

        case .notifications:
            // Sync check is unavailable for UNUserNotificationCenter; default to notDetermined if unknown
            return .notDetermined
        }
    }

    /// Request authorization contextually on explicit user action.
    public func requestPermission(for type: PermissionType) async -> PermissionStatus {
        switch type {
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied

        case .photoLibrary:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return (status == .authorized || status == .limited) ? .authorized : .denied

        case .contacts:
            let store = CNContactStore()
            do {
                let granted = try await store.requestAccess(for: .contacts)
                return granted ? .authorized : .denied
            } catch {
                return .denied
            }

        case .microphone:
            let granted = await AVAudioApplication.requestRecordPermission()
            return granted ? .authorized : .denied

        case .locationWhenInUse:
            let current = locationManager.authorizationStatus
            if current != .notDetermined {
                return (current == .authorizedWhenInUse || current == .authorizedAlways) ? .authorized : .denied
            }
            return await withCheckedContinuation { continuation in
                self.locationContinuation = continuation
                self.locationManager.requestWhenInUseAuthorization()
            }

        case .notifications:
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                return granted ? .authorized : .denied
            } catch {
                return .denied
            }
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            continuation.resume(returning: .authorized)
        case .denied:
            continuation.resume(returning: .denied)
        case .restricted:
            continuation.resume(returning: .restricted)
        case .notDetermined:
            break
        @unknown default:
            continuation.resume(returning: .denied)
        }
    }

    /// Deep links the user directly into iOS System Settings for recoverable permission denials.
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
