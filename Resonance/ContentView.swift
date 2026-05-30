import SwiftUI
import SmartSpectra
import AVFoundation
import UIKit

// MARK: - Pattern
private enum Pattern: String, CaseIterable, Identifiable {
    case relaxed        = "Relaxed"
    case box            = "Box"
    case fourSevenEight = "4-7-8"
    var id: String { rawValue }

    var phases: [(label: String, duration: Double)] {
        switch self {
        case .relaxed:        return [("Inhale", 5), ("Exhale", 5)]
        case .box:            return [("Inhale", 4), ("Hold", 4), ("Exhale", 4), ("Hold", 4)]
        case .fourSevenEight: return [("Inhale", 4), ("Hold", 7), ("Exhale", 8)]
        }
    }

    var cycleDuration: Double { phases.map(\.duration).reduce(0, +) }

    var subtitle: String {
        switch self {
        case .relaxed:        return "5 · 5 — gentle start"
        case .box:            return "4 · 4 · 4 · 4 — focus"
        case .fourSevenEight: return "4 · 7 · 8 — deep calm"
        }
    }

    var bpm: Int { Int((60.0 / cycleDuration).rounded()) }

    var sessionDuration: Double {
        switch self {
        case .relaxed:        return 60
        case .box:            return 90
        case .fourSevenEight: return 120
        }
    }

    var sessionDurationLabel: String {
        switch self {
        case .relaxed:        return "1-minute"
        case .box:            return "90-second"
        case .fourSevenEight: return "2-minute"
        }
    }
}

// MARK: - Session Phase
private enum SessionPhase {
    case learning, acquiring, breathing, complete
}

// MARK: - Palette
private let cCream      = Color(red: 0.97, green: 0.95, blue: 0.91)
private let cPaper      = Color(red: 0.93, green: 0.91, blue: 0.86)
private let cSand       = Color(red: 0.85, green: 0.82, blue: 0.76)
private let cBrown      = Color(red: 0.35, green: 0.28, blue: 0.22)
private let cBrownLight = Color(red: 0.55, green: 0.48, blue: 0.40)
private let cSage       = Color(red: 0.42, green: 0.58, blue: 0.48)
private let cSageMid    = Color(red: 0.52, green: 0.68, blue: 0.56)
private let cSageLight  = Color(red: 0.72, green: 0.82, blue: 0.74)
private let cWarn       = Color(red: 0.75, green: 0.45, blue: 0.25)

// MARK: - Breath Event
private struct BreathEvent {
    let expectedPhase: String
    let startTime: Date
    let duration: Double
    var matched: Bool = false
}

// MARK: - Haptics
private let impactLight  = UIImpactFeedbackGenerator(style: .light)
private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
private let notifyGen    = UINotificationFeedbackGenerator()

// MARK: - ContentView
struct ContentView: View {

    private enum TraceWindow {
        static let rate              = 120
        static let arterialWaveform  = 240
        static let breathingWaveform = 180
    }

    private let sdk = SmartSpectraSDK.shared

    // Session
    @State private var sessionPhase: SessionPhase = .learning
    @State private var selectedPattern: Pattern   = .box
    @State private var sessionElapsed: Double     = 0
    @State private var sessionTimer: Timer?       = nil

    // Pacer
    @State private var pacerPhaseIndex  = 0
    @State private var pacerProgress: Double = 0
    @State private var pacerTimer: Timer?    = nil
    @State private var pacerElapsed: Double  = 0

    // Accuracy
    @State private var breathEvents: [BreathEvent] = []
    @State private var accuracyScore: Int = 0

    // Live ring
    @State private var liveRingScale: CGFloat = 1.0

    // Acquiring
    @State private var acquiringPulse: CGFloat = 0.7

    // Metrics
    @State private var pulseRateBuffer:        [MeasurementWithConfidence] = []
    @State private var breathingRateBuffer:    [MeasurementWithConfidence] = []
    @State private var arterialPressureBuffer: [MeasurementWithConfidence] = []
    @State private var chestBuffer:            [SmartSpectra.Measurement]  = []
    @State private var abdomenBuffer:          [SmartSpectra.Measurement]  = []
    @State private var latestHrv:              Hrv?
    @State private var startHrv:               Double? = nil
    @State private var latestExpressionScores: [ExpressionScore] = []
    @State private var sessionExpressions:     [ExpressionScore] = []
    @State private var didStartSDK             = false

    init() {
        sdk.config.apiKey             = "YOUR_API_KEY_HERE"
        sdk.config.cameraPosition     = .front
        sdk.config.imageOutputEnabled = true
        sdk.config.requestedMetrics   =
            SmartSpectraConfig.breathingMetrics +
            SmartSpectraConfig.cardioMetrics + [.expressions]
        impactLight.prepare()
        impactMedium.prepare()
        notifyGen.prepare()
    }

    // MARK: - Computed
    private var metrics: Metrics? { sdk.metrics }

    private var metricsUpdateToken: Int64 {
        [
            metrics?.cardio.pulseRate.last?.timestamp,
            metrics?.breathing.rate.last?.timestamp,
            metrics?.cardio.hrv.last?.timestamp,
            metrics?.breathing.upperTrace.last?.timestamp,
            metrics?.face.expression.last?.timestamp,
        ]
        .compactMap { $0 }
        .max() ?? 0
    }

    private var hasSignal: Bool { breathingRateBuffer.last != nil }

    private var currentPhase: (label: String, duration: Double) {
        selectedPattern.phases[pacerPhaseIndex]
    }

    private var pacerRingScale: CGFloat {
        switch currentPhase.label {
        case "Inhale": return 0.62 + CGFloat(pacerProgress) * 0.38
        case "Exhale": return 1.0  - CGFloat(pacerProgress) * 0.38
        default:       return pacerPhaseIndex == 1 ? 1.0 : 0.62
        }
    }

    private var ringScale: CGFloat {
        chestBuffer.count > 10 ? liveRingScale : pacerRingScale
    }

    private var sessionProgress: Double { min(sessionElapsed / selectedPattern.sessionDuration, 1.0) }

    private var sessionTimeLeft: String {
        let left = max(selectedPattern.sessionDuration - sessionElapsed, 0)
        return String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
    }

    private var breathingRateText: String {
        guard let last = breathingRateBuffer.last else { return "—" }
        return "\(Int(Double(last.value).rounded()))"
    }

    private var phaseCountdown: String {
        let elapsed = pacerElapsed.truncatingRemainder(dividingBy: currentPhase.duration)
        let left    = max(currentPhase.duration - elapsed, 0)
        return "\(max(1, Int(ceil(left))))s"
    }

    private var validationHint: String {
        sdk.validationStatus?.hint ?? "Center your face and show your upper chest"
    }

    // Live sync nudge
    private var syncNudge: (text: String, color: Color) {
        guard breathEvents.count >= 2 else {
            return ("Follow the ring", cBrownLight)
        }
        let recent  = breathEvents.suffix(3)
        let matched = recent.filter { $0.matched }.count
        switch matched {
        case 3: return ("In sync ✓", cSage)
        case 2: return ("Almost there", cSageMid)
        default: return ("Slow down", cWarn)
        }
    }


    // Ring color based on sync
    private var ringGlowColor: Color {
        guard breathEvents.count >= 2 else { return cSage }
        let recent  = breathEvents.suffix(3)
        let matched = recent.filter { $0.matched }.count
        switch matched {
        case 3: return cSage
        case 2: return cSageMid
        default: return cWarn
        }
    }

    // Expression
    private var dominantExpression: String {
        guard let top = sessionExpressions.max(by: { $0.confidence < $1.confidence }) else { return "—" }
        return expressionName(top.type)
    }

    private var accuracyLabel: String {
        switch accuracyScore {
        case 85...100: return "Excellent"
        case 70..<85:  return "Good"
        default:       return "Keep going"
        }
    }

    private var accuracyMessage: String {
        switch accuracyScore {
        case 85...100: return "You stayed in sync with the pacer — your nervous system felt every breath."
        case 70..<85:  return "Solid session. A few breaths drifted — try slowing down even more."
        default:       return "Breathing is a practice. Even partial sync delivers real benefits."
        }
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            cCream.ignoresSafeArea()
            switch sessionPhase {
            case .learning:  learningView.transition(.opacity)
            case .acquiring: acquiringView.transition(.opacity)
            case .breathing: breathingView.transition(.opacity)
            case .complete:  completeView.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: sessionPhase)
        .task(id: metricsUpdateToken) {
            mergeCurrentMetrics()
            if hasSignal && sessionPhase == .acquiring {
                startSession()
            }
        }
    }

    // MARK: - Learning View
    private var learningView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Resonance")
                        .font(.system(size: 34, weight: .light, design: .serif))
                        .foregroundStyle(cBrown)
                    Text("Mindful breathing pacer")
                        .font(.system(size: 15))
                        .foregroundStyle(cBrownLight)
                }
                .padding(.top, 60)
                .padding(.bottom, 40)

                VStack(alignment: .leading, spacing: 20) {
                    learnCard(icon: "lungs",
                              heading: "You're probably breathing too fast",
                              body: "Most adults breathe 15–20 times per minute — nearly twice the optimal rate. Shallow, rapid breathing keeps your nervous system in a low-level stress state all day.")
                    learnCard(icon: "waveform.path.ecg",
                              heading: "5–6 breaths per minute is the sweet spot",
                              body: "Researchers call this your resonance frequency — the pace at which heart rate variability peaks and your cardiovascular system synchronizes. It's measurably calming within minutes.")
                    learnCard(icon: "arrow.down.heart",
                              heading: "A long exhale activates the vagus nerve",
                              body: "Slow exhalations trigger the parasympathetic nervous system — your body's rest-and-digest mode. Heart rate drops. Cortisol falls. You can feel it within seconds.")
                    learnCard(icon: "chart.line.uptrend.xyaxis",
                              heading: "HRV is your score",
                              body: "Heart rate variability measures nervous system flexibility. Higher HRV means more resilience to stress. This session will move yours — we'll show you before and after.")
                }
                .padding(.horizontal, 24)

                VStack(spacing: 14) {
                    Text("Choose your pattern")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(cBrownLight)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        ForEach(Pattern.allCases) { pattern in
                            Button { selectedPattern = pattern } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pattern.rawValue)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(cBrown)
                                        Text(pattern.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(cBrownLight)
                                    }
                                    Spacer()
                                    Text("\(pattern.bpm) bpm · \(pattern.sessionDurationLabel)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(cBrownLight)
                                    if selectedPattern == pattern {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(cSage)
                                            .font(.system(size: 18))
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .background(
                                    selectedPattern == pattern ? cSageLight.opacity(0.35) : cPaper,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            selectedPattern == pattern ? cSage.opacity(0.5) : cSand.opacity(0.6),
                                            lineWidth: 0.75
                                        )
                                )
                            }
                        }
                    }

                    Button { beginAcquiring() } label: {
                        Text("Begin \(selectedPattern.sessionDurationLabel) session")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(cSage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 52)
            }
        }
    }

    private func learnCard(icon: String, heading: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(cSage)
                .frame(width: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(cBrown)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(cBrownLight)
                    .lineSpacing(4)
            }
        }
        .padding(16)
        .background(cPaper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cSand.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Acquiring View
    private var acquiringView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 40) {
                VStack(spacing: 8) {
                    Text("Resonance")
                        .font(.system(size: 22, weight: .light, design: .serif))
                        .foregroundStyle(cBrown)
                    Text(selectedPattern.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(cBrownLight)
                }

                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(cSage.opacity(0.12 - Double(i) * 0.03), lineWidth: 1)
                            .frame(width: 200 + CGFloat(i) * 30, height: 200 + CGFloat(i) * 30)
                            .scaleEffect(acquiringPulse + CGFloat(i) * 0.08)
                            .animation(
                                .easeInOut(duration: 1.8).repeatForever(autoreverses: true).delay(Double(i) * 0.3),
                                value: acquiringPulse
                            )
                    }
                    Circle().fill(cPaper).frame(width: 200, height: 200)
                    if let image = sdk.imageOutput {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 200, height: 200)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 52))
                            .foregroundStyle(cSand)
                    }
                    Circle()
                        .stroke(cSage.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 200, height: 200)
                }
                .frame(width: 300, height: 300)

                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        BreathingDots()
                        Text("Reading your signal")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(cBrown)
                    }
                    Text(validationHint)
                        .font(.system(size: 12))
                        .foregroundStyle(cBrownLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            Spacer()
            Button {
                stopSDK()
                withAnimation { sessionPhase = .learning }
            } label: {
                Text("Go back")
                    .font(.system(size: 14))
                    .foregroundStyle(cBrownLight)
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: - Breathing View
    private var breathingView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resonance")
                        .font(.system(size: 18, weight: .light, design: .serif))
                        .foregroundStyle(cBrown)
                    Text(selectedPattern.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(cBrownLight)
                }
                Spacer()
                Text(sessionTimeLeft)
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .foregroundStyle(cBrown)
            }
            .padding(.horizontal, 28)
            .padding(.top, 56)
            .padding(.bottom, 16)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(cSand.opacity(0.4)).frame(height: 2)
                    Capsule().fill(cSage)
                        .frame(width: geo.size.width * CGFloat(sessionProgress), height: 2)
                        .animation(.linear(duration: 0.5), value: sessionProgress)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 28)
            .padding(.bottom, 32)

            Spacer()

            // Ring
            ZStack {
                if let image = sdk.imageOutput {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 260)
                        .clipShape(Circle())
                        .opacity(0.25)
                }

                // Outer data-driven glow — color reflects sync
                Circle()
                    .stroke(ringGlowColor.opacity(0.45), lineWidth: 20)
                    .frame(width: 228, height: 228)
                    .scaleEffect(ringScale)
                    .opacity(0.35 + Double(ringScale - 0.62) * 0.9)
                    .animation(.easeInOut(duration: 0.25), value: ringScale)
                    .animation(.easeInOut(duration: 0.6), value: ringGlowColor)

                // Track
                Circle()
                    .stroke(cSand.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 250, height: 250)

                // Progress arc
                Circle()
                    .trim(from: 0, to: pacerProgress)
                    .stroke(cSage, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 250, height: 250)
                    .animation(.linear(duration: 0.1), value: pacerProgress)

                // Inner fill
                Circle()
                    .fill(cSageLight.opacity(0.2))
                    .frame(width: 188, height: 188)
                    .scaleEffect(pacerRingScale)
                    .animation(.easeInOut(duration: 0.5), value: pacerRingScale)

                Circle()
                    .stroke(cSage.opacity(0.45), lineWidth: 1)
                    .frame(width: 188, height: 188)
                    .scaleEffect(pacerRingScale)
                    .animation(.easeInOut(duration: 0.5), value: pacerRingScale)

                // Phase label
                VStack(spacing: 6) {
                    Text(currentPhase.label)
                        .font(.system(size: 24, weight: .light, design: .serif))
                        .foregroundStyle(cBrown)
                    Text(phaseCountdown)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(cBrownLight)
                }
            }
            .frame(height: 270)

            // Live nudge
            Text(syncNudge.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(syncNudge.color)
                .padding(.top, 16)
                .animation(.easeInOut(duration: 0.4), value: syncNudge.text)

            Spacer()

            // Waveform
            if chestBuffer.count > 1 {
                WaveformView(
                    samples: chestBuffer.suffix(180).map { Double($0.value) },
                    strokeColor: cSageMid
                )
                .frame(height: 44)
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            } else {
                Color.clear.frame(height: 92)
            }
        }
    }

    // MARK: - Complete View
    private var completeView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: accuracyScore >= 70 ? "leaf" : "leaf")
                        .font(.system(size: 36))
                        .foregroundStyle(accuracyScore >= 70 ? cSage : cWarn)
                    Text("Session complete")
                        .font(.system(size: 28, weight: .light, design: .serif))
                        .foregroundStyle(cBrown)
                    Text(accuracyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(cBrownLight)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.top, 60)

                // Resonance score
                VStack(spacing: 8) {
                    Text("Resonance score")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(cBrownLight)

                    ZStack {
                        Circle()
                            .stroke(cSand.opacity(0.4), lineWidth: 8)
                            .frame(width: 140, height: 140)
                        Circle()
                            .trim(from: 0, to: CGFloat(accuracyScore) / 100.0)
                            .stroke(
                                accuracyScore >= 70 ? cSage : cWarn,
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 140, height: 140)
                            .animation(.easeOut(duration: 1.2), value: accuracyScore)

                        VStack(spacing: 2) {
                            Text("\(accuracyScore)")
                                .font(.system(size: 42, weight: .light, design: .monospaced))
                                .foregroundStyle(cBrown)
                            Text(accuracyLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accuracyScore >= 70 ? cSage : cWarn)
                        }
                    }

                    Text("How closely your breathing matched\nthe pacer using live camera waveform data")
                        .font(.system(size: 11))
                        .foregroundStyle(cSand)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(cPaper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cSand.opacity(0.5), lineWidth: 0.5)
                )
                .padding(.horizontal, 24)

                // Expression + breathing stats row
                HStack(spacing: 12) {
                    statTile(
                        label: "Expression detected",
                        value: dominantExpression,
                        icon: "face.smiling"
                    )
                    statTile(
                        label: "Pattern",
                        value: selectedPattern.rawValue,
                        icon: "waveform"
                    )
                }
                .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    Button { resetForRestart() } label: {
                        Text("Practice again")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(cSage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Button {
                        resetForRestart()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { sessionPhase = .learning }
                        }
                    } label: {
                        Text("Change pattern")
                            .font(.system(size: 15))
                            .foregroundStyle(cBrownLight)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 52)
            }
        }
    }

    private func statTile(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(cSage)
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(cBrown)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(cBrownLight)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(cPaper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cSand.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Logic
    private func beginAcquiring() {
        withAnimation { sessionPhase = .acquiring }
        acquiringPulse = 1.0
        Task { await startSDKIfNeeded() }
    }

    private func startSession() {
        breathEvents        = []
        sessionExpressions  = []
        accuracyScore       = 0
        sessionElapsed      = 0
        pacerPhaseIndex     = 0
        pacerProgress       = 0
        pacerElapsed        = 0
        liveRingScale       = 1.0

        startHrv = latestHrv?.rmssd
        if startHrv == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.startHrv == nil { self.startHrv = self.latestHrv?.rmssd }
            }
        }

        withAnimation { sessionPhase = .breathing }
        startPacer()
        startSessionTimer()
        impactMedium.impactOccurred()
    }

    private func resetForRestart() {
        stopPacer()
        stopSessionTimer()
        stopSDK()
        resetBuffers()
        breathEvents       = []
        sessionExpressions = []
        accuracyScore      = 0
        didStartSDK        = false
        withAnimation { sessionPhase = .acquiring }
        acquiringPulse = 1.0
        Task { await startSDKIfNeeded() }
    }

    private func startSessionTimer() {
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            sessionElapsed += 0.5
            if sessionElapsed >= selectedPattern.sessionDuration {
                stopPacer()
                stopSessionTimer()
                computeAccuracyScore()
                notifyGen.notificationOccurred(.success)
                withAnimation { sessionPhase = .complete }
            }
        }
    }

    private func stopSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    private func startPacer() {
        let tick: Double = 0.05
        pacerTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { _ in
            let phases        = selectedPattern.phases
            let phaseDuration = phases[pacerPhaseIndex].duration
            pacerElapsed += tick
            let phaseElapsed  = pacerElapsed.truncatingRemainder(dividingBy: phaseDuration)
            pacerProgress     = phaseElapsed / phaseDuration

            if phaseElapsed + tick >= phaseDuration {
                let nextIndex = (pacerPhaseIndex + 1) % phases.count
                let nextPhase = phases[nextIndex]

                // Haptic on phase change
                impactLight.impactOccurred()

                if nextPhase.label == "Inhale" || nextPhase.label == "Exhale" {
                    breathEvents.append(BreathEvent(
                        expectedPhase: nextPhase.label,
                        startTime: Date(),
                        duration: nextPhase.duration
                    ))
                }
                pacerPhaseIndex = nextIndex
                pacerElapsed    = Double(pacerPhaseIndex) * phaseDuration
            }
        }
    }

    private func stopPacer() {
        pacerTimer?.invalidate()
        pacerTimer      = nil
        pacerProgress   = 0
        pacerPhaseIndex = 0
        pacerElapsed    = 0
    }

    private func startSDKIfNeeded() async {
        guard !didStartSDK else { return }
        didStartSDK = true
        resetBuffers()
        try? await sdk.start()
    }

    private func stopSDK() {
        Task { try? await sdk.stop() }
    }

    private func computeAccuracyScore() {
        guard !breathEvents.isEmpty else { accuracyScore = 50; return }
        let matched  = breathEvents.filter { $0.matched }.count
        accuracyScore = Int((Double(matched) / Double(breathEvents.count)) * 100)
    }

    // MARK: - Metrics
    private func mergeCurrentMetrics() {
        guard let metrics else { return }

        if !metrics.cardio.pulseRate.isEmpty {
            pulseRateBuffer.appendProtoArray(contentsOf: metrics.cardio.pulseRate)
            pulseRateBuffer = Array(pulseRateBuffer.suffix(TraceWindow.rate))
        }
        if !metrics.breathing.rate.isEmpty {
            breathingRateBuffer.appendProtoArray(contentsOf: metrics.breathing.rate)
            breathingRateBuffer = Array(breathingRateBuffer.suffix(TraceWindow.rate))
        }
        if !metrics.cardio.arterialPressureTrace.isEmpty {
            arterialPressureBuffer.appendProtoArray(contentsOf: metrics.cardio.arterialPressureTrace)
            arterialPressureBuffer = Array(arterialPressureBuffer.suffix(TraceWindow.arterialWaveform))
        }
        if !metrics.breathing.upperTrace.isEmpty {
            chestBuffer.appendProtoArray(contentsOf: metrics.breathing.upperTrace)
            chestBuffer = Array(chestBuffer.suffix(TraceWindow.breathingWaveform))

            if chestBuffer.count > 10 {
                let all         = chestBuffer.map { Double($0.value) }
                let globalMin   = all.min() ?? 0
                let globalMax   = all.max() ?? 1
                let globalRange = max(globalMax - globalMin, 0.001)
                let latest      = Double(chestBuffer.last?.value ?? 0)
                liveRingScale   = CGFloat(0.88 + ((latest - globalMin) / globalRange) * 0.24)

                // Score breath events against waveform
                let now = Date()
                for i in breathEvents.indices {
                    guard !breathEvents[i].matched else { continue }
                    let event   = breathEvents[i]
                    let elapsed = now.timeIntervalSince(event.startTime)
                    guard elapsed <= event.duration + 1.0 else { continue }
                    let window  = Array(all.suffix(max(2, Int(elapsed * 10))))
                    guard window.count > 2 else { continue }
                    let rise    = (window.last ?? 0) - (window.first ?? 0)
                    if event.expectedPhase == "Inhale" && rise > globalRange * 0.15 {
                        breathEvents[i].matched = true
                    } else if event.expectedPhase == "Exhale" && rise < -(globalRange * 0.15) {
                        breathEvents[i].matched = true
                    }
                }
            }
        }
        if !metrics.breathing.lowerTrace.isEmpty {
            abdomenBuffer.appendProtoArray(contentsOf: metrics.breathing.lowerTrace)
            abdomenBuffer = Array(abdomenBuffer.suffix(TraceWindow.breathingWaveform))
        }
        if let hrv = metrics.cardio.hrv.last { latestHrv = hrv }

        // Collect expressions during session
        if sessionPhase == .breathing,
           let scores = metrics.face.expression.last?.scores,
           !scores.isEmpty {
            sessionExpressions.append(contentsOf: scores)
        }
    }

    private func resetBuffers() {
        pulseRateBuffer.removeAll(keepingCapacity: true)
        breathingRateBuffer.removeAll(keepingCapacity: true)
        arterialPressureBuffer.removeAll(keepingCapacity: true)
        chestBuffer.removeAll(keepingCapacity: true)
        abdomenBuffer.removeAll(keepingCapacity: true)
        latestHrv      = nil
        liveRingScale  = 1.0
    }

    // MARK: - Helpers
    private func expressionName(_ type: ExpressionType) -> String {
        switch type {
        case .happy:    return "Happy"
        case .neutral:  return "Neutral"
        case .sad:      return "Sad"
        case .angry:    return "Angry"
        case .fear:     return "Fearful"
        case .surprise: return "Surprised"
        case .disgust:  return "Disgusted"
        case .contempt: return "Contempt"
        default:        return "Neutral"
        }
    }
}

// MARK: - Waveform View
private struct WaveformView: View {
    let samples: [Double]
    let strokeColor: Color

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard samples.count > 1 else { return }
                let minVal = samples.min() ?? 0
                let maxVal = samples.max() ?? 1
                let range  = max(maxVal - minVal, 0.0001)
                for (i, sample) in samples.enumerated() {
                    let x = geometry.size.width * CGFloat(i) / CGFloat(samples.count - 1)
                    let y = geometry.size.height * CGFloat(1 - (sample - minVal) / range)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else       { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Breathing Dots
private struct BreathingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(cSage)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animate ? 1.0 : 0.4)
                    .opacity(animate ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.9).repeatForever().delay(Double(i) * 0.2),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
