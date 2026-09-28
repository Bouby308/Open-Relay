import SwiftUI
import UIKit

// MARK: - Message Gesture Arbitration
//
// Chat-app style ownership: a horizontal swipe that *starts on a message* is a
// reply swipe and nothing else; a swipe that starts anywhere else opens the
// sidebar. Message recognizers mark the touch on touch-down (before any
// movement) and SidebarOpeningGesture refuses to begin for that touch — so the
// two can never fire together, with no timing race.
//
// Message recognizers also recognize simultaneously with the enclosing
// UIScrollView, so a vertical drag that starts on a bubble scrolls normally.

@MainActor
enum MessageGestureArbiter {
    /// The UITouch currently owned by a message (set on touch-down, cleared on end).
    private(set) static weak var ownedTouch: UITouch?

    static func claim(_ touch: UITouch) { ownedTouch = touch }

    static func release(_ touch: UITouch?) {
        if touch == nil || ownedTouch === touch { ownedTouch = nil }
    }

    /// Whether the in-flight touch began on a message.
    static var isTouchOnMessage: Bool {
        guard let t = ownedTouch else { return false }
        return t.phase != .ended && t.phase != .cancelled
    }
}

/// Shared hit filter: never steal touches from text inputs, controls, or
/// horizontally-scrollable content inside a message (code blocks, tables).
@MainActor
func isInsideEditableOrControl(_ view: UIView?) -> Bool {
    var ancestor = view
    while let v = ancestor {
        if v is UIControl { return true }
        if let text = v as? UITextView, text.isEditable { return true }
        if let scroll = v as? UIScrollView, scroll.isScrollEnabled,
           scroll.contentSize.width > scroll.bounds.width + 1 { return true }
        ancestor = v.superview
    }
    return false
}

/// Pan subclass that releases the arbiter when the touch sequence ends.
final class MessagePanRecognizer: UIPanGestureRecognizer {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        touches.forEach { MessageGestureArbiter.release($0) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        touches.forEach { MessageGestureArbiter.release($0) }
    }
}

// MARK: - Swipe To Reply

/// Direction-locked swipe on a message (rightward for others' messages, leftward
/// for your own). Vertical motion fails it immediately so scrolling wins.
struct MessageSwipeGesture: UIGestureRecognizerRepresentable {
    enum Direction { case right, left }

    var isEnabled: Bool = true
    var threshold: CGFloat = 64
    /// `.left` for own (trailing-aligned) messages, `.right` for everyone else's.
    var direction: Direction = .right
    /// Current (rubber-banded) offset while dragging; negative for `.left`.
    var onChanged: (CGFloat) -> Void
    /// `true` when released past the threshold.
    var onEnded: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(direction: direction) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = MessagePanRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = isEnabled
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // Window space: the gesture's view slides with the swipe offset, so its own
        // coordinate space would under-report the finger's travel.
        let sign: CGFloat = direction == .right ? 1 : -1
        let dx = max(0, pan.translation(in: pan.view?.window).x * sign)
        let damped = dx <= threshold ? dx : threshold + (dx - threshold) * 0.3
        let magnitude = min(damped, threshold * 1.6)
        let offset = magnitude * sign
        switch pan.state {
        case .began:
            context.coordinator.crossed = false
            onChanged(offset)
        case .changed:
            let crossed = magnitude >= threshold
            if crossed != context.coordinator.crossed {
                context.coordinator.crossed = crossed
                Haptics.play(crossed ? .medium : .light)
            }
            onChanged(offset)
        case .ended:
            onEnded(magnitude >= threshold)
        case .cancelled, .failed:
            onEnded(false)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var crossed = false
        var direction: Direction

        init(direction: Direction) { self.direction = direction }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if isInsideEditableOrControl(touch.view) { return false }
            // Only right-swipe messages claim the touch: a rightward swipe on an
            // own (left-swipe) message should still be free to open the sidebar.
            if direction == .right { MessageGestureArbiter.claim(touch) }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view?.window)
            let along = direction == .right ? v.x : -v.x
            return along > 0 && along > abs(v.y) * 1.3
        }

        // Scroll view + long press keep working alongside (the swipe only begins
        // for horizontal motion, which the vertical scroll view ignores).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other is SidebarPanRecognizer)
        }
    }
}

// MARK: - Long Press (menu)

/// Long press that coexists with scrolling: moving more than ~10pt fails it and
/// the scroll view keeps the touch.
struct MessageLongPressGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool = true
    var minimumDuration: TimeInterval = 0.32
    var onBegan: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let lp = UILongPressGestureRecognizer()
        lp.minimumPressDuration = minimumDuration
        lp.allowableMovement = 10
        lp.delegate = context.coordinator
        lp.isEnabled = isEnabled
        return lp
    }

    func updateUIGestureRecognizer(_ lp: UILongPressGestureRecognizer, context: Context) {
        lp.isEnabled = isEnabled
        lp.minimumPressDuration = minimumDuration
    }

    func handleUIGestureRecognizerAction(_ lp: UILongPressGestureRecognizer, context: Context) {
        if lp.state == .began { onBegan() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // No arbiter claim: touch ownership comes from the right-swipe reply
            // gesture, so a rightward swipe on an own message can open the sidebar.
            !isInsideEditableOrControl(touch.view)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - Bubble-scoped gestures

/// Swipe-to-reply + long-press menu, attached to a message's *content* (bubble,
/// header, reactions) rather than its full-width row, so empty space beside a
/// message stays free for the sidebar-opening swipe.
struct ChannelMessageGestures: ViewModifier {
    var swipeEnabled: Bool
    var longPressEnabled: Bool
    var threshold: CGFloat = 64
    var direction: MessageSwipeGesture.Direction = .right
    var onSwipeChanged: (CGFloat) -> Void
    var onSwipeEnded: (Bool) -> Void
    var onLongPress: () -> Void

    func body(content: Content) -> some View {
        content
            .gesture(MessageSwipeGesture(
                isEnabled: swipeEnabled,
                threshold: threshold,
                direction: direction,
                onChanged: onSwipeChanged,
                onEnded: onSwipeEnded
            ))
            .gesture(MessageLongPressGesture(
                isEnabled: longPressEnabled,
                onBegan: onLongPress
            ))
    }
}

// MARK: - Keyboard

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Horizontal Scroll Lock

/// Keeps a vertical message list from drifting sideways while a reply swipe
/// offsets a row (directional lock + no horizontal bounce).
struct ChannelScrollHorizontalLock: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            var current = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    scroll.alwaysBounceHorizontal = false
                    scroll.showsHorizontalScrollIndicator = false
                    scroll.isDirectionalLockEnabled = true
                    // Let row gestures see touches immediately (no 150ms delay),
                    // which keeps swipe/long-press responsive without blocking scroll.
                    scroll.delaysContentTouches = false
                    break
                }
                current = v.superview
            }
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
