# Resonance

**A mindful breathing pacer for iOS that uses your camera to verify you're actually breathing.**

---

## Inspiration

I have asthma. For most of my life, breathing has been something I had to think about, especially during exercise, where losing control of my breath can trigger an attack. Over time I started researching mindful breathing as a way to stay in control, and discovered a body of research around *resonance frequency breathing*: slowing your breath to 5–6 cycles per minute to maximally activate the parasympathetic nervous system and increase heart rate variability.

The problem with every breathing app I tried: they're just timers with pretty animations. They have no idea whether you're actually breathing. I wanted something that could close that loop, an app that reads your real breathing using just your phone's camera, and tells you whether you're in sync.

That's Resonance.

---

## What it does

Resonance is a 1-2 minute guided breathing session that uses the [SmartSpectra SDK](https://smartspectra.presagetech.com/) to measure your physiology in real time via your iPhone's front camera. No wearables required.

**The flow:**

1. **Learn**: Before you start, the app explains the science: why you're likely breathing too fast, what resonance frequency breathing is, how a long exhale activates the vagus nerve, and why HRV is the metric that matters.

2. **Choose a pattern**: Three options, each with a different duration:
   - *Relaxed* (5 in · 5 out) - 1 minute, 6 breaths/min
   - *Box Breathing* (4 · 4 · 4 · 4) - 90 seconds, used by Navy SEALs and therapists
   - *4-7-8* (4 in · 7 hold · 8 out) - 2 minutes, maximises vagal activation

3. **Signal acquisition**: The camera starts and the app waits until it has a stable breathing signal before beginning. Your face appears in a pulsing circle while it reads your baseline.

4. **Breathe**: A ring expands and contracts to guide your breath. The outer glow ring is driven by your *actual* chest waveform from the SDK. It pulses with your real inhales and exhales, not just a timer. A live nudge ("In sync ✓" / "Slow down") updates in real time based on whether your waveform matches the pacer. Haptic feedback pulses on every phase transition so you can follow along with your eyes closed.

5. **Results** — At the end you see a *Resonance Score* (0-100) measuring how accurately your breathing matched the pacer, based on live chest waveform analysis. You also see the dominant facial expression detected during your session.

---

## How to use it

### Requirements
- iPhone (physical device required — camera access needed)
- iOS 17+
- Xcode 16+
- A free [Presage SmartSpectra API key](https://physiology.presagetech.com/auth/register)

### Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/dizzyfrogs/resonance.git
   cd resonance
   ```

2. Open `Resonance.xcodeproj` in Xcode.

3. Add the SmartSpectra Swift package:
   - File → Add Package Dependencies
   - URL: `https://github.com/Presage-Security/SmartSpectra-Swift/`
   - Branch: `main`

4. Add your API key in `ContentView.swift`:
   ```swift
   sdk.config.apiKey = "YOUR_API_KEY_HERE"
   ```

5. Add camera permission:
   - Select the Resonance target → Info tab
   - Add `Privacy - Camera Usage Description`
   - Value: `Resonance needs camera access to read your breathing.`

6. Plug in your iPhone, select it as the run destination, and hit ⌘R.

### Tips for best results
- Sit still with your face centered and upper chest visible
- Use bright, even lighting
- Keep the phone propped at roughly face height
- Wait for the signal acquisition screen to transition automatically — don't rush it

---

## How it was built

Resonance is a single-file SwiftUI app built on top of the **Presage SmartSpectra SDK**, which performs camera-based photoplethysmography to extract physiological signals in real time.

### SDK signals used

| Signal | How it's used |
|---|---|
| `breathing.upperTrace` | Drives the outer glow ring and accuracy scoring |
| `breathing.rate` | Signal acquisition trigger and live display |
| `cardio.hrv` | Before/after HRV baseline capture |
| `cardio.pulseRate` | Collected throughout session |
| `face.expression` | Dominant expression shown on completion screen |
| `cardio.arterialPressureTrace` | Collected for future sessions |

### Accuracy scoring

The core innovation is the Resonance Score. Rather than just running a timer, the app:

1. Logs a `BreathEvent` every time the pacer transitions to an Inhale or Exhale phase
2. Monitors the `upperTrace` chest waveform during each event window
3. Checks whether the waveform rises (Inhale) or falls (Exhale) by more than 15% of the global range
4. Score = matched events / total events × 100

This means the score reflects whether your body actually followed the pacer.

### Stack

- **Language:** Swift
- **UI:** SwiftUI (single `ContentView.swift`)
- **SDK:** [SmartSpectra Swift SDK](https://github.com/Presage-Security/SmartSpectra-Swift/)
- **Haptics:** `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`
- **No third-party UI libraries**

### Architecture

Everything lives in `ContentView.swift`. Session state is managed through a `SessionPhase` enum (`.learning` → `.acquiring` → `.breathing` → `.complete`). The pacer runs on a 50ms `Timer` for smooth animation. Waveform data is buffered in rolling arrays and processed on each SDK metrics update.
