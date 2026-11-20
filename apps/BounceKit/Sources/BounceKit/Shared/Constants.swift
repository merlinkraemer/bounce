import Foundation
import SwiftUI

public enum BounceConstants {
    /// Imports at or above this duration are suggested as long recordings, and
    /// (with Recordings off) trigger the import sheet's "turn on" hint.
    /// The user can always override the suggestion in the track editor.
    public static let setAutoTagDurationThreshold: TimeInterval = 15 * 60

    public static let productionBonjourServiceType = "_bounce-sync._tcp"
    public static let developmentBonjourServiceType = "_bounce-dev._tcp"
    public static var bonjourServiceType: String {
        isDevelopmentBuild ? developmentBonjourServiceType : productionBonjourServiceType
    }
    public static let bonjourDomain = "local."
    public static var keychainService: String {
        isDevelopmentBuild ? "com.bounce.dev.pairingKey" : "com.bounce.pairingKey"
    }
    public static var applicationSupportDirectoryName: String {
        isDevelopmentBuild ? "Bounce Dev" : "Bounce"
    }
    /// Where the Mac points first-time users to install the iPhone app.
    public static let iPhoneAppURL = "https://testflight.apple.com/join/JXS63nZW"
    /// Where the iPhone points users who have no Bounce on their Mac yet.
    /// "Send Link to Mac" shares it from the pair sheet.
    public static let macAppDownloadURL: URL? = URL(string: "https://onbounce.app")
    public static let pairingLinkHost = "onbounce.app"
    public static let pairingLinkPath = "/pair"
    public static let defaultHTTPPort: UInt16 = 0  // 0 = random port

    public static var isDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    // MARK: - Popovers (macOS)
    public static let popoverWidth: CGFloat = 320
    public static let popoverMaxHeight: CGFloat = 540
    public static let popoverRowHorizontalPadding: CGFloat = 12
    public static let popoverRowVerticalPadding: CGFloat = 10
    public static let popoverRowCornerRadius: CGFloat = 8
    public static let popoverHoverOpacity: CGFloat = 0.06

    // MARK: - Modal & panel surfaces (macOS)
    /// Single hover tint for interactive rows in modals, panels and popovers.
    public static let panelHoverOpacity: Double = 0.06
    /// Card/group/row corner radius (edit cards, sync rows, playlist cover).
    public static let panelCornerRadius: CGFloat = 10
    /// Inline field / focus-highlight radius inside panel rows.
    public static let panelFieldCornerRadius: CGFloat = 6
    /// Hairline border width for inline fields.
    public static let panelHairlineWidth: CGFloat = 0.5
    /// Neutral fill opacity for status/choice pills; the capsule shape stays native.
    public static let panelPillFillOpacity: Double = 0.16

    // MARK: - Transport
    public static let transportBarMaxWidth: CGFloat = 675
    public static let transportBarHeight: CGFloat = 52
    public static let transportBarBottomPadding: CGFloat = 12
    /// Padding built into the floating transport bar's own frame around the pill.
    public static let transportBarChromeTopPadding: CGFloat = 4
    public static let transportBarChromeBottomPadding: CGFloat = 8
    /// The transport bar's real laid-out height (pill plus its own chrome
    /// padding). The catalogue's bottom fade and bottom content inset both
    /// derive from this so neither can drift from the footer it clears.
    public static let transportBarOuterHeight: CGFloat =
        transportBarHeight + transportBarChromeTopPadding + transportBarChromeBottomPadding

    // MARK: - macOS library layout
    /// Keeps the catalogue readable on wide windows while allowing it to fill
    /// the available column at narrower sizes.
    public static let catalogueContentMaxWidth: CGFloat = 1040

    /// Height of the native titlebar/toolbar band above the catalogue content.
    /// Reference band for the catalogue column; the resting clearance below is
    /// derived from it and kept constant so it cannot race the row heights.
    public static let titlebarChromeHeight: CGFloat = 52

    /// Height of the catalogue top edge fade: the live titlebar/toolbar band
    /// (~52pt) plus a short ramp, so the fade dissolves by the time the first
    /// row or playlist header starts and initial content stays readable.
    /// `LibraryScrollView` carries the whole resting clearance as this
    /// constant `contentInsets.top` (rows still scroll through the band while
    /// scrolling), so the fade and the resting position can never diverge.
    public static let columnTopFadeHeight: CGFloat = 56

    /// Height of the catalogue bottom edge fade, measured from the bottom
    /// edge. Equals the transport bar's real laid-out footprint (which the
    /// bar's own padding constants define), and the scrolling table's bottom
    /// content inset reads this same value so the last row clears both the
    /// fade and the floating footer at rest.
    public static let columnBottomFadeHeight: CGFloat = transportBarOuterHeight

    // MARK: - Note cards (macOS)
    public static let noteCardCornerRadius: CGFloat = 10
    public static let noteCardInset: CGFloat = 12
    public static let noteCardSpacing: CGFloat = 8
    public static let noteBadgeSlotWidth: CGFloat = 24

    #if os(iOS)
    public static let mainWaveformHeight: CGFloat = 220
    public static let miniWaveformHeight: CGFloat = 40
    #elseif os(macOS)
    public static let miniWaveformHeight: CGFloat = 32
    #endif

    // MARK: - Edit surfaces
    #if os(macOS)
    public static var editingBackgroundStyle: some ShapeStyle {
        WindowBackgroundShapeStyle.windowBackground
    }
    #else
    public static var editingBackgroundStyle: some ShapeStyle {
        Material.ultraThickMaterial
    }
    #endif
}
