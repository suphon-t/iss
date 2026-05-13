import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
import QuartzCore

private let switcherLog = Logger(subsystem: "com.instant-swipe.issd", category: "switcher")

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

final class SpaceSwitcher {
    private let kCGSEventTypeField = CGEventField(rawValue: 55)!
    private let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
    private let kCGEventGestureScrollY = CGEventField(rawValue: 119)!
    private let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
    private let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
    private let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
    private let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!
    private let kCGEventGesturePhase = CGEventField(rawValue: 132)!
    private let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!
    private let kCGEventGestureZoomDeltaX = CGEventField(rawValue: 139)!

    private let kCGSEventGesture: Int64 = 29
    private let kCGSEventDockControl: Int64 = 30
    private let kIOHIDEventTypeDockSwipe: Int64 = 23
    private let kCGGestureMotionHorizontal: Int64 = 1

    private let kGestureBegan: Int64 = 1
    private let kGestureChanged: Int64 = 2
    private let kGestureEnded: Int64 = 4
    private let kGestureCancelled: Int64 = 8

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

        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.sync(execute: post)
        }
        return canSwitch
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
