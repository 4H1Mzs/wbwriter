import AppKit
import SwiftUI

enum Links {
    static let website = URL(string: "https://4h1m.com/")!
    static let support = URL(string: "https://www.darujme.cz/4h1m")!
    static let instagram = URL(string: "https://www.instagram.com/4h1m.production/")!
    static let ndi = URL(string: "https://ndi.video")!
}

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    private var orgLogo: NSImage? {
        Bundle.main.image(forResource: colorScheme == .dark ? "4h1m-logo-white" : "4h1m-logo")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("WBWriter").font(.system(size: 26, weight: .bold))
                Text(version).font(.callout).foregroundStyle(.secondary)
                Text("Live stage whiteboard → NDI® / HDMI")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)

            Divider()

            VStack(spacing: 14) {
                Text("Developed by 4H1M, z.s.")
                    .font(.headline)
                if let orgLogo {
                    Button { openURL(Links.website) } label: {
                        Image(nsImage: orgLogo)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 120, height: 120)
                    }
                    .buttonStyle(.plain)
                    .help("4h1m.com")
                }
                Text("4H1M, z.s. is a Czech nonprofit audiovisual production serving churches and Christian events through sound, lighting, visuals, livestreaming and video. WBWriter is free — if it helps your show, you can support 4H1M's development and ministry.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button { openURL(Links.support) } label: {
                    Label("Support 4H1M", systemImage: "heart.fill")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.36, green: 0.13, blue: 0.6))
                .controlSize(.large)

                HStack(spacing: 16) {
                    Link("4h1m.com", destination: Links.website)
                    Text("·").foregroundStyle(.tertiary)
                    Link("Instagram @4h1m.production", destination: Links.instagram)
                }
                .font(.callout)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)

            Divider()

            VStack(spacing: 4) {
                Text("NDI® is a registered trademark of Vizrt NDI AB.")
                Link("ndi.video", destination: Links.ndi)
                Text("© 2026 4H1M, z.s.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
    }
}
