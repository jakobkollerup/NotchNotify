import SwiftUI

package enum NotchMotionMode: String, CaseIterable, Identifiable {
    case system
    case full

    package var id: String { rawValue }
    var label: String { self == .system ? "Follow macOS" : "Full animations" }

    func reducesMotion(systemEnabled: Bool) -> Bool { self == .system && systemEnabled }
}

package enum NotchAnimationStyle: String, CaseIterable, Identifiable {
    case expand
    case dropDown
    case easeInOut
    case fade
    case bounce

    package var id: String { rawValue }

    var label: String {
        switch self {
        case .expand: return "Expand"
        case .dropDown: return "Drop down"
        case .easeInOut: return "Ease in/out"
        case .fade: return "Fade"
        case .bounce: return "Bounce"
        }
    }

    var explanation: String {
        switch self {
        case .expand: return "Grows slowly from the notch with a soft spring."
        case .dropDown: return "Slides down from the top edge of the display."
        case .easeInOut: return "Expands gently, slowing at the beginning and end."
        case .fade: return "Fades into place without moving."
        case .bounce: return "Pops out of the notch with a subtle bounce."
        }
    }

    var expandsFromNotch: Bool {
        switch self {
        case .expand, .easeInOut, .bounce: return true
        case .dropDown, .fade: return false
        }
    }

    var entrance: Animation {
        switch self {
        case .expand: return .spring(duration: 0.62, bounce: 0)
        case .dropDown: return .easeOut(duration: 0.38)
        case .easeInOut: return .easeInOut(duration: 0.48)
        case .fade: return .easeInOut(duration: 0.24)
        case .bounce: return .spring(duration: 0.48, bounce: 0.24)
        }
    }

    var contentRevealDelay: Duration {
        .milliseconds(self == .expand ? 130 : 70)
    }

    var contentReveal: Animation {
        .easeOut(duration: self == .expand ? 0.24 : 0.20)
    }

    var exit: Animation {
        switch self {
        case .expand, .bounce: return .spring(duration: 0.28, bounce: 0)
        case .dropDown: return .easeIn(duration: 0.26)
        case .easeInOut: return .easeInOut(duration: 0.30)
        case .fade: return .easeInOut(duration: 0.20)
        }
    }
}
