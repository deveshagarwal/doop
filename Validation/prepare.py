"""Downloads the LifeSnaps daily CSV (CC BY 4.0, Yfantidou et al. 2022, Sci Data) and converts it
to the JSON the Swift harness reads. Only the 2 MB daily file is fetched, via HTTP range requests
into the 615 MB Zenodo zip."""
import csv, io, json, os, urllib.request, zipfile

URL = "https://zenodo.org/api/records/7229547/files/rais_anonymized.zip/content"
CSV = "data/daily_fitbit_sema_df_unprocessed.csv"

class HTTPFile(io.RawIOBase):
    def __init__(self, url):
        head = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"))
        self.url, self.size, self.pos = head.url, int(head.headers["Content-Length"]), 0
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, o, w=0):
        self.pos = o if w == 0 else (self.pos + o if w == 1 else self.size + o)
        return self.pos
    def readinto(self, b):
        n = min(len(b), self.size - self.pos)
        if n <= 0: return 0
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{self.pos + n - 1}"})
        data = urllib.request.urlopen(req).read()
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)

def fetch():
    os.makedirs("data", exist_ok=True)
    if os.path.exists(CSV): return
    z = zipfile.ZipFile(io.BufferedReader(HTTPFile(URL), buffer_size=1 << 20))
    name = next(n for n in z.namelist() if n.endswith("daily_fitbit_sema_df_unprocessed.csv"))
    open(CSV, "wb").write(z.read(name))

def num(v):
    try:
        f = float(v)
        return None if f != f else f
    except (TypeError, ValueError):
        return None

def main():
    fetch()
    users = {}
    for r in csv.DictReader(open(CSV)):
        u = users.setdefault(r["id"], {"id": r["id"], "age": r["age"], "gender": r["gender"], "days": []})
        u["days"].append({
            "date": r["date"][:10],
            "rmssd": num(r["rmssd"]), "rhr": num(r["resting_hr"]), "temp": num(r["nightly_temperature"]),
            "resp": num(r["full_sleep_breathing_rate"]), "spo2": num(r["spo2"]),
            "asleep": num(r["minutesAsleep"]), "awake": num(r["minutesAwake"]), "inBedMs": num(r["sleep_duration"]),
            "z1": num(r["minutes_in_default_zone_1"]), "z2": num(r["minutes_in_default_zone_2"]),
            "z3": num(r["minutes_in_default_zone_3"]), "steps": num(r["steps"]),
            # reference signals, never fed to the engines
            "tired": num(r["TIRED"]), "rested": num(r["RESTED/RELAXED"]),
            "fbSleep": num(r["sleep_points_percentage"]), "fbResponsiveness": num(r["responsiveness_points_percentage"]),
            "fbExertion": num(r["exertion_points_percentage"]), "veryActive": num(r["very_active_minutes"]),
        })
    json.dump(list(users.values()), open("data/lifesnaps.json", "w"))
    print(f"{len(users)} participants, {sum(len(u['days']) for u in users.values())} days")

main()
