# Setup

## 1. Put it on your iPhone (10 min)

1. `open Baseline.xcodeproj`
2. Target **Baseline** → *Signing & Capabilities* → choose your Team (a free Apple ID works).
   If the bundle ID `com.dagarwal.baseline` is taken, change it in `project.yml` and run `xcodegen generate`.
3. Plug in your iPhone, select it as the run destination, press ▶︎.
   First run: on the phone, Settings → General → VPN & Device Management → trust your developer certificate.

A free Apple ID build expires after 7 days (re-run from Xcode). A paid developer account makes it a year.
HealthKit works with a free account.

## 2. Apple Health (2 min, required)

1. In the **Google Health** app (5.05 or newer): Connections → Apps and services → **Apple Health**, turn sharing on.
2. In Baseline: **Connect Apple Health**, allow all categories, allow notifications.

The first sync pulls 90 days. Recovery shows "calibrating" until there are 5 nights of baseline.

## 3. HRV via Google Health API (10 min once, optional but recommended)

1. [console.cloud.google.com](https://console.cloud.google.com) → new project (e.g. `baseline-personal`).
2. APIs & Services → Library → **Google Health API** → Enable.
3. Google Auth Platform → Audience: External, status **Testing**, add your Google account under **Test users**.
4. Data Access → Add scopes, search "Google Health", add:
   - `googlehealth.health_metrics_and_measurements.readonly`
   - `googlehealth.sleep.readonly`
   - `googlehealth.activity_and_fitness.readonly`
5. Credentials → Create OAuth client ID → **iOS**, bundle ID `com.dagarwal.baseline` (or yours). Copy the client ID.
6. Baseline → Settings → paste the client ID → **Connect Google Health**.

Because the project stays in Testing mode, Google expires the sign-in every 7 days. Settings shows a Reconnect button.
Publishing the project would need Google's verification and a security audit, which isn't worth it for one user.

## 4. Weight, meals, calendar, weather (2 min, optional)

- **Omada:** in the Omada app, Settings → Health Integration → Share with Health App, turn on weight.
- **Nourish:** check its Health settings allow *writing* nutrition (energy, protein, caffeine). If it only reads, meals won't appear.
- **Calendar and weather:** Baseline → Settings → Connect Calendar / Allow approximate location.

## 5. Widgets

Long-press the lock screen or home screen → add Baseline. The widget shares data with the app through an App
Group; with a free Apple ID, select your team for both the Baseline and BaselineWidget targets. If signing the
App Group fails, the app still works; only the widgets go blank.

## Troubleshooting

- **Recovery says "No HRV"**: expected without step 3.
- **Data looks hours old**: open the Google Health app once; it's the step that pulls from the band.
  Settings → "Newest heart rate" shows the real lag.
- **Google HTTP 403**: API not enabled or scopes not added. **access_denied**: you're not a test user.
- **A Google metric is empty**: Settings → Last sync log shows per-metric results. The v4 API is new and
  field names may shift; adjust candidate keys in `Core/Google/GoogleSync.swift`.
- **Demo mode**: Settings → Demo mode explores everything with generated data; your real data is untouched.
