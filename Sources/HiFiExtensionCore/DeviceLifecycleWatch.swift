import AppKit
import CoreAudio
import Foundation

/// 在非实时队列上观察拔出、Hog 被抢和睡眠；IOProc 内不得做这些事。
final class DeviceLifecycleWatch: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case disconnected
        case busy
        case exclusiveModeLost
        case systemWillSleep
    }

    private let deviceID: AudioDeviceID
    private let deviceUID: String
    private let holdsHogMode: Bool
    private let queue: DispatchQueue
    private let handler: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var started = false
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var hogListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var sleepObserver: NSObjectProtocol?
    private var aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var hogAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyHogMode,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(
        deviceID: AudioDeviceID,
        deviceUID: String,
        holdsHogMode: Bool,
        queue: DispatchQueue,
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.holdsHogMode = holdsHogMode
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let queue = self.queue
        let aliveListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let watch = self else { return }
            queue.async { watch.emitIfDisconnected() }
        }
        let hogListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let watch = self else { return }
            queue.async { watch.emitIfHogLost() }
        }
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let watch = self else { return }
            queue.async { watch.emitIfDisconnected() }
        }
        self.aliveListener = aliveListener
        self.hogListener = hogListener
        self.devicesListener = devicesListener

        _ = AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, queue, aliveListener)
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            queue,
            devicesListener
        )
        if holdsHogMode {
            _ = AudioObjectAddPropertyListenerBlock(deviceID, &hogAddress, queue, hogListener)
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let watch = self else { return }
            queue.async { watch.emit(.systemWillSleep) }
        }
    }

    func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        let aliveListener = self.aliveListener
        let hogListener = self.hogListener
        let devicesListener = self.devicesListener
        let sleepObserver = self.sleepObserver
        self.aliveListener = nil
        self.hogListener = nil
        self.devicesListener = nil
        self.sleepObserver = nil
        lock.unlock()

        if let aliveListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, queue, aliveListener)
        }
        if let hogListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &hogAddress, queue, hogListener)
        }
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                queue,
                devicesListener
            )
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

    private func emitIfDisconnected() {
        if CoreAudioHALFormatProbe.isDeviceAlive(deviceID),
           (try? CoreAudioHALFormatProbe.resolveDeviceID(uid: deviceUID)) != nil {
            return
        }
        emit(.disconnected)
    }

    private func emitIfHogLost() {
        guard holdsHogMode else { return }
        var address = hogAddress
        guard let owner = try? CoreAudioHALFormatProbe.hogModeOwner(
            deviceID: deviceID,
            address: &address
        ) else {
            emit(.disconnected)
            return
        }
        if owner == getpid() { return }
        emit(owner == -1 ? .exclusiveModeLost : .busy)
    }

    private func emit(_ event: Event) {
        lock.lock()
        let running = started
        lock.unlock()
        guard running else { return }
        handler(event)
    }
}
