# Baseline

A personal WHOOP-style app for the Google Fitbit Air. Recovery, strain, sleep, training load,
early illness signals, habit correlations and a Claude coach, all scored against your own
baselines and stored only on your phone.

## How data flows

```
Fitbit Air ─BLE─> Google Health app ─> Apple Health ─> Baseline     (sleep, HR, workouts, vitals)
                                  └──> Google Health API ─> Baseline (HRV, optional)
```

Apple Health is the primary source: no setup, no expiring tokens, background updates.
HRV does not transfer to Apple Health, so an optional Google Health API connection adds it.
Without it, recovery leans on resting HR, sleep and respiratory rate.

## What's in it

| Feature | How it's computed |
|---|---|
| Recovery 1–99% | HRV 45%, resting HR 25%, sleep 20%, respiratory rate 10%, each as a z-score vs your trailing 30 days (HRV log-transformed). Re-weights without HRV. |
| Strain 0–21 | Banister TRIMP per minute from heart-rate reserve, mapped `21·(1−e^(−TRIMP/110))`. Per-workout strain too. |
| Strain target | From recovery, trimmed when training load is spiking. |
| Sleep need / debt | Base need + ¼ of debt + extra after strain >10. Debt decays 30%/day. Bedtime from your habitual wake time. |
| Training load | 7-day vs 42-day EWMA (fatigue vs fitness), acute:chronic ratio with Gabbett's 0.8–1.3 sweet spot. |
| Illness watch | Overnight RHR/HRV, respiratory rate, skin temp, SpO₂ vs a baseline that skips the last 2 days. RHR and HRV count as one signal; a full alert needs respiratory rate or temperature to agree, so an alcohol night alone only reaches "watch". |
| Journal insights | Next-morning recovery, HRV and sleep with vs without each habit; needs 5 days each side; "solid" when the difference exceeds 2 standard errors. |
| Coach | Claude (`claude-opus-5`) gets a compact summary of your last 14 days, baselines and journal patterns. Streams replies. Your API key lives in the Keychain. |

Methods and citations are in the doc comments of each engine under `Core/Metrics/`.

## Layout

```
Core/          platform-neutral engines (also a Swift package, for tests)
  Models/      DayRecord, journal, JSON store
  Metrics/     Recovery, Strain, Sleep, TrainingLoad, IllnessDetector, JournalInsights, Analyzer
  Google/      Google Health API client + OAuth (adapted from Pulse, Apache 2.0)
  Coach/       Claude client + context builder
  Demo/        deterministic 90-day demo data with planted effects
App/           SwiftUI app, HealthKit reader, notifications, background refresh
SelfTest/      `swift run` engine checks, no Xcode needed
```

## Run

```bash
cd SelfTest && swift run        # engine checks
xcodegen generate               # after editing project.yml
open Baseline.xcodeproj
```

See [SETUP.md](SETUP.md) to install on your iPhone and connect your data.

Not a medical device. Credits: Google Health API layer adapted from
[Pulse](https://github.com/Luraxx/pulse) (Apache 2.0, see NOTICE).
