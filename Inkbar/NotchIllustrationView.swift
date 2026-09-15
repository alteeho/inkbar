import SwiftUI

struct NotchIllustrationView: View {
    var hideNotch: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var covered = false
    @State private var loop: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            NotchDemoScene(
                size: geo.size,
                covered: covered,
                colorScheme: colorScheme
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .onAppear { updateLoop() }
        .onChange(of: hideNotch) { _, _ in
            updateLoop()
        }
        .onDisappear {
            loop?.cancel()
            loop = nil
        }
    }

    private func updateLoop() {
        loop?.cancel()
        loop = nil
        if !hideNotch {
            withAnimation(.easeInOut(duration: 0.4)) { covered = false }
            return
        }
        startLoop()
    }

    private func startLoop() {
        loop?.cancel()
        if reduceMotion {
            covered = true
            return
        }
        covered = false
        loop = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.55)) { covered = true }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) { covered = false }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

private struct NotchDemoScene: View {
    var size: CGSize
    var covered: Bool
    var colorScheme: ColorScheme

    private let barHeight: CGFloat = 12
    private let notchWidth: CGFloat = 70

    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            appWindow
            menuBar
            notch
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(
                colors: sky,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(blobA.opacity(0.9))
                .frame(width: 150, height: 150)
                .blur(radius: 22)
                .position(x: size.width * 0.78, y: size.height * 0.42)
            Circle()
                .fill(blobB.opacity(0.8))
                .frame(width: 130, height: 130)
                .blur(radius: 20)
                .position(x: size.width * 0.18, y: size.height * 0.7)
            Circle()
                .fill(blobC.opacity(0.7))
                .frame(width: 100, height: 100)
                .blur(radius: 18)
                .position(x: size.width * 0.52, y: size.height * 0.85)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private var appWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.32, blue: 0.30))
                    .frame(width: 7, height: 7)
                Circle()
                    .fill(Color(red: 0.99, green: 0.76, blue: 0.18))
                    .frame(width: 7, height: 7)
                Circle()
                    .fill(Color(red: 0.22, green: 0.78, blue: 0.35))
                    .frame(width: 7, height: 7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 16, alignment: .center)
            Spacer(minLength: 0)
        }
        .frame(width: 132, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(windowFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .offset(x: 12, y: barHeight + 10)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var menuBar: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)
                .opacity(covered ? 1 : 0.18)

            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "apple.logo")
                    Text("Finder")
                        .fontWeight(.semibold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                }
                Spacer(minLength: notchWidth + 10)
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    Image(systemName: "magnifyingglass")
                    Text("9:41")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(menuForeground)
            .padding(.horizontal, 8)
        }
        .frame(width: size.width, height: barHeight)
        .allowsHitTesting(false)
    }

    private var notch: some View {
        MacNotchShape()
            .fill(Color.black)
            .frame(width: notchWidth, height: barHeight)
            .opacity(covered ? 0 : 1)
            .frame(width: size.width, height: size.height, alignment: .top)
            .allowsHitTesting(false)
    }

    private var menuForeground: Color {
        if covered {
            return Color.white.opacity(0.94)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.9)
            : Color.black.opacity(0.82)
    }

    private var windowFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.white.opacity(0.92)
    }

    private var sky: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.16, green: 0.22, blue: 0.42),
                Color(red: 0.28, green: 0.18, blue: 0.38),
                Color(red: 0.12, green: 0.24, blue: 0.36)
            ]
        }
        return [
            Color(red: 0.55, green: 0.72, blue: 0.96),
            Color(red: 0.98, green: 0.72, blue: 0.52),
            Color(red: 0.78, green: 0.58, blue: 0.90)
        ]
    }

    private var blobA: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.52, blue: 0.32)
            : Color(red: 1.0, green: 0.58, blue: 0.36)
    }

    private var blobB: Color {
        colorScheme == .dark
            ? Color(red: 0.28, green: 0.48, blue: 0.92)
            : Color(red: 0.32, green: 0.52, blue: 0.94)
    }

    private var blobC: Color {
        colorScheme == .dark
            ? Color(red: 0.72, green: 0.42, blue: 0.86)
            : Color(red: 0.82, green: 0.48, blue: 0.90)
    }
}

/// MacBook notch: wide and shallow, flush with the top, small ears, modest bottom radius.
private struct MacNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ear = min(rect.height * 0.22, 2.4)
        let body = rect.insetBy(dx: ear, dy: 0)
        let bottomR = min(body.height * 0.32, 4)
        var path = Path()
        path.move(to: CGPoint(x: body.minX - ear, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.minY + ear),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottomR))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + bottomR, y: body.maxY),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX - bottomR, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.maxY - bottomR),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + ear))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX + ear, y: body.minY),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }
}
