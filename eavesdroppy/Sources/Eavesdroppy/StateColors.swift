import SwiftUI

/// AdaptiveColors has no warning or destructive token, so state colour lives here and nowhere else: a future token
/// swap is one edit.
enum StateColor {
    static let warning = Color.orange
    static let destructive = Color.red
    static let info = Color.blue
}
