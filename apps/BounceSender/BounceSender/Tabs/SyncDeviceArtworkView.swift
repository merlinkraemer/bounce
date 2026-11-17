import SwiftUI

struct SyncDeviceArtworkView: View {
    let isConnected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .tertiaryLabelColor).opacity(0.85),
                            Color(nsColor: .quaternaryLabelColor).opacity(0.65),
                            Color.black.opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isConnected ? 0.18 : 0.10), radius: 24, y: 16)

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(screenBackground)
                .padding(10)
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.92))
                        .frame(width: 92, height: 24)
                        .padding(.top, 18)
                }
                .overlay(alignment: .bottom) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.55))
                        .frame(width: 110, height: 5)
                        .padding(.bottom, 14)
                }

            sideButtons
        }
        .aspectRatio(0.54, contentMode: .fit)
    }

    private var screenBackground: some ShapeStyle {
        LinearGradient(
            colors: isConnected
                ? [
                    Color(red: 0.13, green: 0.22, blue: 0.42),
                    Color(red: 0.09, green: 0.35, blue: 0.53),
                    Color(red: 0.20, green: 0.54, blue: 0.58)
                ]
                : [
                    Color(nsColor: .controlBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var sideButtons: some View {
        ZStack {
            HStack {
                VStack(spacing: 16) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 4, height: 34)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 4, height: 56)
                }

                Spacer()

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 4, height: 70)
            }
            .padding(.horizontal, 2)
        }
    }
}

struct SyncMiniDeviceArtworkView: View {
    let isConnected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(nsColor: .tertiaryLabelColor).opacity(0.8),
                        Color.black.opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isConnected
                                ? [
                                    Color(red: 0.12, green: 0.22, blue: 0.42),
                                    Color(red: 0.13, green: 0.46, blue: 0.55)
                                ]
                                : [
                                    Color(nsColor: .controlBackgroundColor),
                                    Color(nsColor: .underPageBackgroundColor)
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(3)
            )
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.92))
                    .frame(width: 14, height: 4)
                    .padding(.top, 5)
            }
            .frame(width: 24, height: 42)
    }
}
