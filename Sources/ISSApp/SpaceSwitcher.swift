import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
import QuartzCore

private let switcherLog = Logger(subsystem: "com.instant-swipe.iss", category: "switcher")

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

final class SpaceSwitcher {
    private let kCGSEventTypeField = CGEventField(rawValue: 55)!
    private let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
    private let kCGEventGestureSwipeMask = CGEventField(rawValue: 115)!
    private let kCGEventGestureScrollY = CGEventField(rawValue: 119)!
    private let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
    fileprivate let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
    private let kCGEventGestureSwipePositionX = CGEventField(rawValue: 125)!
    private let kCGEventGestureSwipePositionY = CGEventField(rawValue: 126)!
    fileprivate let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
    fileprivate let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!
    fileprivate let kCGEventGesturePhase = CGEventField(rawValue: 132)!
    fileprivate let kCGEventGesturePhaseAlias = CGEventField(rawValue: 134)!
    private let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!
    private let kCGEventGestureZoomDeltaY = CGEventField(rawValue: 138)!
    private let kCGEventGestureZoomDeltaX = CGEventField(rawValue: 139)!
    private let kCGEventSourceProcessAlias = CGEventField(rawValue: 169)!
    /// Record ID, in the serialized CGEvent form, of the raw IOHID queue
    /// payload that macOS 27 validates synthetic dock swipes against. It is
    /// not reachable through the CGEvent field API, so it has to be appended
    /// to the serialized bytes (see augmentDockSwipeEvent).
    fileprivate let kCGEventRawIOHIDPayload: UInt16 = 4205

    fileprivate let kIOHIDEventTypeVelocity: UInt32 = 9
    fileprivate let kIOHIDEventTypeFluidTouchGesture: UInt32 = 23
    private let kIOHIDGestureFlavorDockPrimary: UInt16 = 3

    private let kCGSEventGesture: Int64 = 29
    private let kCGSEventDockControl: Int64 = 30
    private let kIOHIDEventTypeDockSwipe: Int64 = 23
    private let kCGGestureMotionHorizontal: Int64 = 1

    private let kGestureBegan: Int64 = 1
    private let kGestureChanged: Int64 = 2
    fileprivate let kGestureEnded: Int64 = 4
    fileprivate let kGestureCancelled: Int64 = 8

    /// macOS 27 silently drops synthetic DockControl events unless they carry
    /// a raw IOHID payload, and it flips the sign convention of swipe
    /// progress/velocity. Ported from upstream iss.c. Override with
    /// ISS_FORCE_EVENT_AUGMENTATION=1/0 when testing.
    static let requiresEventAugmentation: Bool = {
        if let forced = ProcessInfo.processInfo.environment["ISS_FORCE_EVENT_AUGMENTATION"] {
            return forced == "1"
        }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }()

    /// Velocity of the synthetic End on macOS 27: high enough that the Dock
    /// switches with no animation, and a low value for the edge bounce.
    private static let instantSwitchVelocity = 9999.0
    private static let edgeBumpVelocity = 100.0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swipeTracking = false
    private var swipeFired = false
    private var passthrough = 0
    private var bumpTicker: BumpTicker?

    func startMonitoring() -> Bool {
        if tap != nil {
            return true
        }

        guard AXIsProcessTrusted() else {
            return false
        }

        let mask = (1 << kCGSEventGesture) | (1 << kCGSEventDockControl)
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: SpaceSwitcher.tapCallback,
            userInfo: observer
        ) else {
            return false
        }

        let loopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        tap = eventTap
        source = loopSource
        return true
    }

    func stopMonitoring() {
        guard let tap, let source else {
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
        self.tap = nil
    }

    func switchSpace(direction: SpaceDirection) -> Bool {
        let right = direction == .right

        if Self.requiresEventAugmentation {
            // macOS 27: at an edge, post the same sequence with a low
            // velocity so the Dock shows a gentle rubber-band bounce instead
            // of the full-force one. (The pre-27 edge bump's unaugmented
            // events are ignored by the Dock.)
            let canSwitch = canSwitch(right: right)
            let velocity = canSwitch ? Self.instantSwitchVelocity : Self.edgeBumpVelocity
            runOnMain { self.postAugmentedSwitch(right: right, velocity: velocity) }
            return canSwitch
        }

        // Hop to the main run loop so passthrough increments are ordered with
        // the tap callback's reads.
        let canSwitch = canSwitch(right: right)
        let post = {
            if canSwitch {
                self.postPhase(phase: self.kGestureBegan, right: right)
                self.postPhase(phase: self.kGestureChanged, right: right)
                self.postPhase(phase: self.kGestureEnded, right: right)
            } else {
                // At the leftmost/rightmost space — show a brief rubber-band
                // bounce so the user sees that there's nothing to switch to.
                self.postEdgeBump(right: right)
            }
        }

        runOnMain(post)
        return canSwitch
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    // Mimics a slow real swipe so the Dock animates the rubber-band slide and
    // bounce. A CADisplayLink drives one Changed event per vsync, then we
    // close out with the same fake_move + fake_cancel pair the tap callback
    // uses, to suppress any leftover commit animation. Main run loop only.
    private func postEdgeBump(right: Bool) {
        bumpTicker?.cancel()

        let dir: Double = right ? 1 : -1
        let peak = 0.4
        let duration: TimeInterval = 0.04

        postBumpPhase(phase: kGestureBegan, right: right, progress: 0)

        bumpTicker = BumpTicker(duration: duration) { [weak self] fraction, done in
            guard let self else { return }

            if done {
                if let fakeMove = self.makeDockEvent(phase: self.kGestureChanged, right: true) {
                    fakeMove.post(tap: .cgSessionEventTap)
                }
                if let fakeCancel = self.makeDockEvent(phase: self.kGestureCancelled, right: true) {
                    fakeCancel.post(tap: .cgSessionEventTap)
                }
                self.bumpTicker = nil
            } else {
                let progress = dir * peak * fraction
                self.postBumpPhase(phase: self.kGestureChanged, right: right, progress: progress)
            }
        }
    }

    func canSwitch(direction: SpaceDirection) -> Bool {
        canSwitch(right: direction == .right)
    }

    private func canSwitch(right: Bool) -> Bool {
        let connection = CGSMainConnectionID()
        guard let displaysRef = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue(),
              let displays = displaysRef as? [[String: Any]] else {
            return true
        }

        var activeSpace = activeSpaceID(displays: displays)
        if activeSpace == 0 {
            activeSpace = CGSGetActiveSpace(connection)
        }

        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else {
                continue
            }

            for (index, space) in spaces.enumerated() {
                guard let managedSpaceID = space["ManagedSpaceID"] as? NSNumber else {
                    continue
                }

                if managedSpaceID.uint64Value == activeSpace {
                    if right {
                        return index < spaces.count - 1
                    }
                    return index > 0
                }
            }
        }

        return true
    }

    private func activeSpaceID(displays: [[String: Any]]) -> UInt64 {
        guard let activeDisplayIdentifier = cursorDisplayIdentifier(),
              let targetDisplay = displays.first(where: { ($0["Display Identifier"] as? String) == activeDisplayIdentifier }) else {
            return 0
        }

        return activeSpaceID(forDisplay: targetDisplay)
    }

    private func activeSpaceID(forDisplay display: [String: Any]) -> UInt64 {
        guard let currentSpace = display["Current Space"] as? [String: Any],
              let id = currentSpace["id64"] as? NSNumber else {
            return 0
        }

        return id.uint64Value
    }

    private func cursorDisplayIdentifier() -> String? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }

        let cursorLocation = event.location
        var cursorDisplay = CGDirectDisplayID()
        var cursorDisplayCount: UInt32 = 0

        let err = CGGetDisplaysWithPoint(cursorLocation, 1, &cursorDisplay, &cursorDisplayCount)
        guard err == .success, cursorDisplayCount > 0,
            let displayUUID = CGDisplayCreateUUIDFromDisplayID(cursorDisplay) else {
            return nil
        }

        return CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String
    }

    private func postPhase(phase: Int64, right: Bool) {
        guard let ev = makeDockEvent(phase: phase, right: right) else {
            return
        }

        ev.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: right ? 400 : -400)
        ev.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)

        passthrough += 2
        postPair(with: ev)
    }

    // Tiny swipe with low velocity so the Dock starts a gesture session, sees
    // there's no neighbouring space, and bounces back. Progress is the
    // cumulative fraction of the swipe distance (negative for leftward).
    private func postBumpPhase(phase: Int64, right: Bool, progress: Double) {
        guard let ev = makeDockEvent(phase: phase, right: right) else {
            return
        }

        ev.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0)
        ev.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
        ev.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress)

        passthrough += 2
        postPair(with: ev)
    }

    private func makeDockEvent(phase: Int64, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }

        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase)
        event.setIntegerValueField(kCGEventScrollGestureFlagBits, value: right ? 1 : 0)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kCGGestureMotionHorizontal)
        event.setDoubleValueField(kCGEventGestureScrollY, value: 0)
        // Match iss.c: this field must be set to FLT_TRUE_MIN (smallest float
        // subnormal). Double.leastNonzeroMagnitude (5e-324) is a different bit
        // pattern and the Dock silently ignores events that use it.
        event.setDoubleValueField(kCGEventGestureZoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        return event
    }

    // MARK: - macOS 27 augmented events

    private func postAugmentedSwitch(right: Bool, velocity: Double = SpaceSwitcher.instantSwitchVelocity) {
        var events: [CGEvent] = []
        for phase in [kGestureBegan, kGestureChanged, kGestureEnded] {
            guard let event = makeAugmentedDockEvent(phase: phase, right: right, velocity: velocity) else {
                switcherLog.error("failed to build augmented dock event phase=\(phase)")
                return
            }
            events.append(event)
        }

        for event in events {
            passthrough += 2
            postPair(with: event)
        }
    }

    // Field set that upstream found the macOS 27 Dock to accept. Note the
    // sign convention: negative progress/velocity moves to the space on the
    // right, the opposite of the pre-27 events built by makeDockEvent and of
    // the real trackpad events (verified: the Switch Left/Right buttons go the
    // right way with this mapping).
    private func makeAugmentedDockEvent(phase: Int64, right: Bool, velocity: Double) -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }

        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGesturePhase, value: phase)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: right ? -1.0 : 1.0)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kCGGestureMotionHorizontal)
        event.setIntegerValueField(kCGEventGesturePhaseAlias, value: phase)
        event.setDoubleValueField(kCGEventGestureZoomDeltaY, value: 3.0)
        event.setDoubleValueField(kCGEventSourceProcessAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(kCGEventGestureSwipePositionX, value: 0.1)
        if phase == kGestureEnded {
            event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: right ? -velocity : velocity)
        }

        return augmentDockSwipeEvent(event)
    }

    // Round-trips the event through its serialized form so the raw IOHID
    // payload record can be appended; CGEvent offers no other way to set it.
    private func augmentDockSwipeEvent(_ event: CGEvent) -> CGEvent? {
        guard let serialized = event.data else {
            return nil
        }

        var bytes = serialized as Data
        // Serialized CGEvents start with a 4-byte format version; only
        // version 2 is known to accept the appended record.
        guard bytes.count >= 4, bytes.prefix(4).elementsEqual([0, 0, 0, 2]) else {
            switcherLog.error("unexpected serialized CGEvent header; cannot augment")
            return nil
        }

        let payload = makeIOHIDPayload(for: event)
        // Record header is big-endian: 16-bit length, then 16-bit record ID.
        bytes.append(UInt8(payload.count >> 8))
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8(kCGEventRawIOHIDPayload >> 8))
        bytes.append(UInt8(kCGEventRawIOHIDPayload & 0xFF))
        bytes.append(payload)

        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }

    // Serialized IOHID system queue element: a 28-byte header followed by a
    // fluid-touch gesture event (40 bytes) and, when there is any velocity or
    // the phase is Ended, a child velocity event (28 bytes). Layout is
    // reverse-engineered (upstream iss.c); all fields are native-endian and
    // packed, positions/velocities are 16.16 fixed point.
    private func makeIOHIDPayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(kCGEventGesturePhase)
        let motion = event.getIntegerValueField(kCGEventGestureSwipeMotion)
        let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
        let positionX = event.getDoubleValueField(kCGEventGestureSwipePositionX)
        let positionY = event.getDoubleValueField(kCGEventGestureSwipePositionY)
        let velocityX = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
        let velocityY = event.getDoubleValueField(kCGEventGestureSwipeVelocityY)
        let swipeMask = event.getIntegerValueField(kCGEventGestureSwipeMask)
        let includeVelocity = velocityX != 0 || velocityY != 0 || phase == kGestureEnded

        var payload = Data()

        // IOHIDSystemQueueElement header.
        let timestamp = event.timestamp
        payload.append(littleEndian: timestamp != 0 ? UInt64(timestamp) : mach_absolute_time())
        payload.append(littleEndian: UInt64(0))                        // sender ID
        payload.append(littleEndian: UInt32(0))                        // options
        payload.append(littleEndian: UInt32(0))                        // attribute length
        payload.append(littleEndian: UInt32(includeVelocity ? 2 : 1))  // event count

        // IOHIDEvent base + fluid touch gesture data.
        payload.append(littleEndian: UInt32(40))                       // size
        payload.append(littleEndian: kIOHIDEventTypeFluidTouchGesture)
        payload.append(littleEndian: UInt32(truncatingIfNeeded: (phase & 0xFF) << 24)) // options
        payload.append(contentsOf: [0, 0, 0, 0])                       // depth + reserved
        payload.append(littleEndian: fixed1616(positionX))
        payload.append(littleEndian: fixed1616(positionY))
        payload.append(littleEndian: Int32(0))                         // position z
        payload.append(littleEndian: UInt32(truncatingIfNeeded: swipeMask))
        payload.append(littleEndian: UInt16(truncatingIfNeeded: motion))
        payload.append(littleEndian: kIOHIDGestureFlavorDockPrimary)
        payload.append(littleEndian: fixed1616(progress))

        if includeVelocity {
            // IOHIDEvent base + velocity data, nested one level deep.
            payload.append(littleEndian: UInt32(28))                   // size
            payload.append(littleEndian: kIOHIDEventTypeVelocity)
            payload.append(littleEndian: UInt32(0))                    // options
            payload.append(contentsOf: [1, 0, 0, 0])                   // depth 1 + reserved
            payload.append(littleEndian: fixed1616(velocityX))
            payload.append(littleEndian: fixed1616(velocityY))
            payload.append(littleEndian: Int32(0))                     // velocity z
        }

        return payload
    }

    fileprivate func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64(value * 65536.0))
        if fixed == 0 && value != 0 {
            return value > 0 ? 1 : -1
        }
        return fixed
    }

    private func postPair(with dockEvent: CGEvent) {
        guard let companion = CGEvent(source: nil) else {
            return
        }

        companion.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)
        dockEvent.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(event)
        }

        let instance = Unmanaged<SpaceSwitcher>.fromOpaque(userInfo).takeUnretainedValue()
        return instance.handleTap(type: type, event: event)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let eventType = event.getIntegerValueField(kCGSEventTypeField)

        if passthrough > 0 && (eventType == kCGSEventDockControl || eventType == kCGSEventGesture) {
            passthrough -= 1
            switcherLog.debug("passthrough event eventType=\(eventType) remaining=\(self.passthrough)")
            return Unmanaged.passRetained(event)
        }

        if eventType == kCGSEventDockControl,
           event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe,
           event.getIntegerValueField(kCGEventGestureSwipeMotion) == kCGGestureMotionHorizontal {
            let phase = event.getIntegerValueField(kCGEventGesturePhase)
            switcherLog.debug("tap intercepted dock swipe phase=\(phase) passthrough=\(self.passthrough)")

            if Self.requiresEventAugmentation {
                return handleAugmentedDockSwipe(phase: phase, event: event)
            }

            if phase == kGestureBegan {
                swipeTracking = true
                swipeFired = false
                return Unmanaged.passRetained(event)
            }

            if phase == kGestureChanged {
                if swipeFired {
                    return nil
                }
                return Unmanaged.passRetained(event)
            }

            if phase == kGestureEnded {
                let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
                let right = progress > 0
                if progress != 0, canSwitch(right: right) {
                    swipeFired = true
                    postPhase(phase: kGestureEnded, right: right)
                    swipeTracking = false
                    return nil
                }
            }

            passthrough += 2
            if let fakeMove = makeDockEvent(phase: kGestureChanged, right: true) {
                fakeMove.post(tap: .cgSessionEventTap)
            }
            if let fakeCancel = makeDockEvent(phase: kGestureCancelled, right: true) {
                fakeCancel.post(tap: .cgSessionEventTap)
            }
            swipeTracking = false
            return nil
        }

        if eventType == kCGSEventGesture && swipeTracking {
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // macOS 27 flow. Same shape as the pre-27 flow: the real Began/Changed
    // pass through so the Dock tracks the fingers, and the instant switch
    // fires on lift by replacing the real End. Unlike pre-27, the replacement
    // is the real End rewritten in place rather than a fresh synthetic event
    // (see makeInstantEndCopy); the augmented synthetic sequence is only used
    // for CLI/menu-triggered switches.
    private func handleAugmentedDockSwipe(phase: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        if phase == kGestureBegan {
            swipeTracking = true
            swipeFired = false
            return Unmanaged.passRetained(event)
        }

        if phase == kGestureChanged {
            if swipeFired {
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        if phase == kGestureEnded {
            swipeTracking = false
            let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
            // Real events keep the pre-27 sign convention (positive = right);
            // only the synthetic augmented events use the reversed sign.
            let right = progress > 0
            let allowed = progress != 0 && canSwitch(right: right)
            switcherLog.debug("real End progress=\(progress, privacy: .public) right=\(right, privacy: .public) allowed=\(allowed, privacy: .public)")
            if allowed {
                swipeFired = true
                // The Dock keys its gesture session on the sender ID inside
                // the raw IOHID record, so sender-less synthetic events can't
                // close it (next swipe stuck), and a passed-through End makes
                // it commit its own animated switch (skips a space). Instead,
                // rewrite the real End in place into an instant End: same
                // session, full progress, huge velocity. If that fails, the
                // untouched End gives the Dock's native (animated) switch.
                if let instant = makeInstantEndCopy(of: event, right: right) {
                    return Unmanaged.passRetained(instant)
                }
                switcherLog.error("could not rewrite real End; falling back to native switch")
            }
            // At an edge, let the Dock finish its own rubber-band return.
            return Unmanaged.passRetained(event)
        }

        // Cancelled (or unknown phase): let the Dock wind down natively.
        swipeTracking = false
        return Unmanaged.passRetained(event)
    }
}

// MARK: - Rewriting real macOS 27 events

extension SpaceSwitcher {
    /// Turns a real End into an instant End that keeps the real session
    /// identity: full progress and a huge velocity. Both the CGEvent fields
    /// and the raw IOHID record (4205) are rewritten, since the Dock reads
    /// phase/progress/velocity from the record, whose sign convention is
    /// negative = right (the opposite of the CGEvent progress field on real
    /// events). Returns nil if the event has no record or can't be rebuilt.
    fileprivate func makeInstantEndCopy(of event: CGEvent, right: Bool) -> CGEvent? {
        let phase = kGestureEnded
        let progress = right ? -1.0 : 1.0
        let velocityX = right ? -Self.instantSwitchVelocity : Self.instantSwitchVelocity

        event.setIntegerValueField(kCGEventGesturePhase, value: phase)
        event.setIntegerValueField(kCGEventGesturePhaseAlias, value: phase)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress)
        event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: velocityX)
        event.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)

        guard let serialized = event.data else {
            return nil
        }
        var bytes = serialized as Data
        guard let record = findSerializedRecord(kCGEventRawIOHIDPayload, in: bytes) else {
            switcherLog.debug("real End carries no IOHID record")
            return nil
        }

        let payload = record.lowerBound
        let payloadLength = record.count

        // Header (28) + fluid gesture event: phase lives in the top byte of
        // base.options (little-endian byte 39), progress at byte 64.
        let headerLength = 28
        let fluid = payload + headerLength
        guard payloadLength >= headerLength + 40,
              readLE32(bytes, at: fluid + 4) == kIOHIDEventTypeFluidTouchGesture else {
            switcherLog.debug("unexpected IOHID record layout")
            return nil
        }
        bytes[fluid + 11] = UInt8(truncatingIfNeeded: phase)
        writeLE32(&bytes, at: fluid + 36, value: UInt32(bitPattern: fixed1616(progress)))

        // Optional child velocity event right after the gesture event.
        let velocity = fluid + 40
        if payloadLength >= headerLength + 40 + 28,
           readLE32(bytes, at: velocity + 4) == kIOHIDEventTypeVelocity {
            writeLE32(&bytes, at: velocity + 16, value: UInt32(bitPattern: fixed1616(velocityX)))
            writeLE32(&bytes, at: velocity + 20, value: 0)
        } else {
            switcherLog.debug("real End has no velocity child; velocity only in fields")
        }

        return CGEvent(withDataAllocator: nil, data: bytes as CFData)
    }

    /// Walks the serialized CGEvent (4-byte version header, then records of
    /// big-endian 16-bit count + 16-bit ID; the ID's top nibble selects the
    /// unit size). Returns the byte range of the record's payload.
    private func findSerializedRecord(_ id: UInt16, in bytes: Data) -> Range<Int>? {
        var offset = 4
        while offset + 4 <= bytes.count {
            let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            let fieldID = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
            let unit: Int
            switch fieldID >> 12 {
            case 0x0: unit = 8
            case 0x1: unit = 1
            case 0x4, 0xC: unit = 4
            default: return nil
            }
            let length = count * unit
            let start = offset + 4
            guard start + length <= bytes.count else { return nil }
            if fieldID == id {
                return start..<(start + length)
            }
            offset = start + length
        }
        return nil
    }

    private func readLE32(_ bytes: Data, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func writeLE32(_ bytes: inout Data, at offset: Int, value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

// Drives a per-vsync callback for `duration` seconds, then one final
// invocation with `done == true` so the caller can post a closing event
// sequence. Owns the CADisplayLink and tears it down on cancel().
private final class BumpTicker: NSObject {
    private let duration: TimeInterval
    private let onTick: (_ fraction: Double, _ done: Bool) -> Void
    private let startTime: CFTimeInterval
    private var displayLink: CADisplayLink?

    init(duration: TimeInterval, onTick: @escaping (_ fraction: Double, _ done: Bool) -> Void) {
        self.duration = duration
        self.onTick = onTick
        self.startTime = CACurrentMediaTime()
        super.init()

        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed >= duration {
            onTick(1.0, true)
            cancel()
        } else {
            onTick(elapsed / duration, false)
        }
    }
}
