# DOOP

A dupe on WHOOP: a personal recovery app for the Google Fitbit Air, in the spirit of WHOOP, Bevel and Athlytic, built to need
no logging. Recovery, strain, sleep, training load, illness watch, energy and stress, healthspan, and a
"For you" feed from on-device models. Everything is scored against your own baselines and stays on the phone.

## Data, with nothing to log

```
Fitbit Air → Google Health app → Apple Health → DOOP   sleep, heart rate, workouts, vitals, steps
Omada scale → Apple Health → DOOP                       weight
Food app → Apple Health → DOOP (optional)                meals, protein, caffeine, drinks
Calendar (read-only) · weather (Open-Meteo) · time zone     late meetings, hot nights, travel
Google Health API (optional)                                HRV, which Apple Health doesn't receive
```

The only input is one optional yes/no a day ("Drinks last night?"), asked only when overnight heart rate
carries alcohol's signature, answerable from the notification.

## Screens

| Tab | Screens |
|---|---|
| Today | Glass sphere beating at your resting HR · Recovery · Strain dial · Tonight planner (bedtime slider → forecast) · For you |
| Sleep | Nightlines (every night on a clock axis) · consistency · tonight's need · stages · hours vs need |
| Train | Load ratio gauge · fitness vs fatigue · weekly strain · workout cost · workout detail with zones |
| Learn | Automatic day log · what moves you (effects with uncertainty) · discoveries · explorer · patterns · weekly report |
| Body | Energy bank and stress · box breathing · health monitor · healthspan and pace of aging · weight and food |

Plus lock-screen and home-screen widgets, and an "Ask Claude" button that hands a summary to your own Claude app.
Every technical number has an ⓘ with a plain explanation.

## On-device models (no LLM)

| Model | Method | Validation |
|---|---|---|
| Tomorrow forecast | Ridge regression on tonight's plan, today's strain/recovery and habits; walk-forward backtest | LifeSnaps (51 real Fitbit users): ±9.9 pts vs ±12.4 for "same as today", 21% better, wins for 42/51 |
| Habit effects | Ridge regression holding other habits, strain, bedtime and weekend steady; 95% intervals | Recovers planted effects in demo data |
| Illness watch | Grouped multi-signal deviation + 2-night persistence | LifeSnaps: ~2.9 alert episodes per person-year |
| Trend changes | One-sided CUSUM | Demo |
| Auto-logging | Rules per source; alcohol from first-half-of-night heart rate | Demo |
| Load and cost | Banister fitness-fatigue, acute:chronic ratio, learned strain→next-day cost | Demo |
| Healthspan | VO₂max → FRIEND fitness age + capped adjustments (heuristic) | Not validated |

Methods and citations are in each engine's doc comments under `Core/Metrics/`.

## Layout

```
Core/        engines (also a Swift package for tests): Models, Metrics, Google, Coach (Ask Claude summary), Demo
App/         SwiftUI app: tabs, HealthKit/Calendar/Weather sources, notifications, widget bridge, Metal sphere
Widget/      WidgetKit extension · Shared/ snapshot shared via App Group
SelfTest/    `swift run`: 30 checks on demo data
Validation/  `python3 prepare.py && swift run -c release && python3 report.py`: real-data check on LifeSnaps
```

See [SETUP.md](SETUP.md) to install on your iPhone. Not a medical device. Google Health API layer adapted from
[Pulse](https://github.com/Luraxx/pulse) (Apache 2.0, see NOTICE).
