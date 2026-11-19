"""Compares Baseline's scores with LifeSnaps reference signals. Correlations are within-person
(each person's values centered on their own mean) because Baseline scores against personal baselines."""
import json, math, random
from collections import defaultdict

scores = {(s["id"], s["date"]): s for s in json.load(open("data/scores.json"))}
ref = {}
for u in json.load(open("data/lifesnaps.json")):
    for d in u["days"]:
        ref[(u["id"], d["date"])] = d

def within(pairs):
    """pairs: list of (person, x, y). Pearson r on person-centered values."""
    by = defaultdict(list)
    for p, x, y in pairs: by[p].append((x, y))
    xs, ys = [], []
    for v in by.values():
        if len(v) < 5: continue
        mx = sum(a for a, _ in v) / len(v); my = sum(b for _, b in v) / len(v)
        xs += [a - mx for a, _ in v]; ys += [b - my for _, b in v]
    n = len(xs)
    sxy = sum(a * b for a, b in zip(xs, ys)); sxx = sum(a * a for a in xs); syy = sum(b * b for b in ys)
    return (sxy / math.sqrt(sxx * syy) if sxx and syy else float("nan")), n

def perm_p(pairs, r_obs, iters=500):
    """Shuffle y within each person; how often is |r| at least as large by chance?"""
    by = defaultdict(list)
    for p, x, y in pairs: by[p].append((x, y))
    hits = 0
    rng = random.Random(1)
    for _ in range(iters):
        shuffled = []
        for p, v in by.items():
            ys = [y for _, y in v]; rng.shuffle(ys)
            shuffled += [(p, x, y) for (x, _), y in zip(v, ys)]
        if abs(within(shuffled)[0]) >= abs(r_obs): hits += 1
    return (hits + 1) / (iters + 1)

def compare(label, xkey, ykey, xsrc=scores, ysrc=ref):
    pairs = [(k[0], xsrc[k][xkey], ysrc[k][ykey]) for k in scores
             if xsrc.get(k, {}).get(xkey) is not None and ysrc.get(k, {}).get(ykey) is not None]
    r, n = within(pairs)
    p = perm_p(pairs, r) if n > 30 else float("nan")
    print(f"  {label:<58} r = {r:+.2f}  (n={n}, p≈{p:.3f})")

def group_diff(label, flag):
    """Within-person recovery difference: flagged days minus that person's unflagged days."""
    diffs = []
    by = defaultdict(lambda: ([], []))
    for k, s in scores.items():
        f = ref.get(k, {}).get(flag)
        if s.get("recovery") is None or f is None: continue
        by[k[0]][0 if f >= 1 else 1].append(s["recovery"])
    for on, off in by.values():
        if len(on) >= 3 and len(off) >= 3: diffs.append(sum(on) / len(on) - sum(off) / len(off))
    m = sum(diffs) / len(diffs); se = (sum((d - m) ** 2 for d in diffs) / (len(diffs) - 1)) ** 0.5 / len(diffs) ** 0.5
    print(f"  {label:<58} {m:+.1f} pts (±{1.96*se:.1f}, {len(diffs)} people)")

S = list(scores.values())
rec = [s for s in S if "recovery" in s]
print(f"COVERAGE  {len(S)} days, {len({s['id'] for s in S})} people")
print(f"  recovery scored on {len(rec)/len(S):.0%} of days; with HRV on {sum(s['usedHRV'] for s in rec)/max(1,len(rec)):.0%} of those")
print(f"  sleep scored on {sum('sleepPerf' in s for s in S)/len(S):.0%}; ACWR available on {sum('acwr' in s for s in S)/len(S):.0%}")
bad = [s for s in S if any(isinstance(v, float) and (math.isnan(v) or math.isinf(v)) for v in s.values())]
print(f"  NaN/inf values: {len(bad)}")

settled = [s["recovery"] for s in rec if not s.get("calibrating")]
g = sum(r >= 67 for r in settled) / len(settled); y = sum(34 <= r < 67 for r in settled) / len(settled)
print(f"\nRECOVERY DISTRIBUTION (calibrated days)  mean {sum(settled)/len(settled):.0f}%  "
      f"green {g:.0%} / yellow {y:.0%} / red {1-g-y:.0%}")

print("\nAGREEMENT WITH INDEPENDENT SIGNALS (within-person)")
# Note: these three are components of Fitbit's Stress Management Score, not its Daily Readiness or
# Sleep Score (LifeSnaps doesn't include those). They measure related but different things, so
# raw nightly HRV itself only reaches r≈0.20 against 'responsiveness'.
compare("Recovery vs Stress Score 'responsiveness' component", "recovery", "fbResponsiveness")
compare("Sleep performance vs Stress Score 'sleep patterns' component", "sleepPerf", "fbSleep")
compare("Strain vs Stress Score 'exertion balance' component", "strain", "fbExertion")
compare("Strain vs very-active minutes", "strain", "veryActive")
group_diff("Recovery on days people said TIRED vs not", "tired")
group_diff("Recovery on days people said RESTED/RELAXED vs not", "rested")

print("\nILLNESS WATCH (no illness labels in LifeSnaps, so this measures alarm rate)")
months = sum(1 for _ in S) / 30.4
alerts = sum(s["illness"] == 2 for s in S); watch = sum(s["illness"] == 1 for s in S)
print(f"  alerts: {alerts} ({alerts/months:.2f} per person-month)   watch: {watch} ({watch/months:.2f} per person-month)")
per = defaultdict(int)
for s in S:
    if s["illness"] == 2: per[s["id"]] += 1
print(f"  people with ≥1 alert: {len(per)}/{len({s['id'] for s in S})}; most alerts for one person: {max(per.values()) if per else 0}")

# Episodes: consecutive alert days for one person count once (that's one notification).
episodes = 0
for pid in {s["id"] for s in S}:
    days = sorted(s["date"] for s in S if s["id"] == pid and s["illness"] == 2)
    import datetime as dt
    prev = None
    for d in days:
        cur = dt.date.fromisoformat(d)
        if prev is None or (cur - prev).days > 2: episodes += 1
        prev = cur
print(f"  alert episodes: {episodes} ({episodes / months * 12:.1f} per person-year; typical adults catch 2-4 colds a year)")
