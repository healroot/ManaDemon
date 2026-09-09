#!/usr/bin/env python3
"""tools/wclrules.py <raw.json> --healer <name> [--observed <out.lua>]

What the healer actually did, and the state of the fight when they did it.
Every number here comes straight out of the log -- no spell model is involved,
so this stands whatever our own heal values turn out to be.

For each cast: the target's health, the damage that target took in the trailing
5s, what was already ticking on them, and how many other people were hurt.
Then the same rows grouped per spell, which is where a rule shows itself.
"""
import json, sys, statistics
from collections import defaultdict, Counter

HOT_DUR = {"Lifebloom": 7.0, "Rejuvenation": 12.0, "Regrowth": 21.0}


def observed_table(b, hid, abil, out):
    """The median gross, non-crit amount each spell actually healed, as a Lua
    table for tools/wclcheckkit.lua to hold our model against."""
    g = defaultdict(list)
    for e in b["healing"]:
        if e.get("sourceID") != hid or e.get("hitType") == 2:
            continue
        gross = (e.get("amount") or 0) + (e.get("overheal") or 0)
        if gross > 0:
            g[(e.get("abilityGameID"), "tick" if e.get("tick") else "direct")].append(gross)
    rows = []
    for (sid, what), v in sorted(g.items(), key=lambda x: -len(x[1])):
        if len(v) < 3:
            continue
        nm = abil.get(sid, str(sid))
        rows.append('{id=%d,what="%s",label="%s %s",median=%.1f,stacks=%d}'
                    % (sid, what, nm, what, statistics.median(v),
                       3 if (nm == "Lifebloom" and what == "tick") else 1))
    return "{" + ",".join(rows) + "}"


def main():
    path = sys.argv[1]
    healer = sys.argv[sys.argv.index("--healer") + 1]
    b = json.load(open(path))
    byid = {a["id"]: a for a in b["actors"]}
    abil = {a["gameID"]: a["name"] for a in b["abilities"]}
    fight = b["fight"]
    t0 = fight["startTime"]
    hid = next(a["id"] for a in b["actors"] if a["name"] == healer)

    # --- absolute health, integrated, percentages as anchors (as the importer) --
    obs = defaultdict(list)
    for st in ("healing", "casts", "damage"):
        for e in b[st]:
            ra, hp = e.get("resourceActor"), e.get("hitPoints")
            aid = e.get("sourceID") if ra == 1 else (e.get("targetID") if ra == 2 else None)
            if aid is not None and hp is not None and e.get("maxHitPoints") == 100:
                obs[aid].append((e["timestamp"], hp))
    obs = {a: sorted(set(v)) for a, v in obs.items()}

    def pct_at(aid, ms):
        pts = obs.get(aid) or []
        v = pts[0][1] if pts else 100
        for ts, p in pts:
            if ts <= ms:
                v = p
            else:
                break
        return v

    dmg = defaultdict(list)
    for e in b["damage"]:
        if (e.get("amount") or 0) > 0 and e.get("targetID") in byid:
            dmg[e["targetID"]].append((e["timestamp"], e["amount"]))

    def taken(aid, ms, window=5000):
        return sum(a for ts, a in dmg.get(aid, []) if ms - window < ts <= ms)

    players = [i for i in (fight.get("friendlyPlayers") or []) if i in byid]

    # --- the healer's own casts, in order, with what was rolling ---------------
    applied = defaultdict(dict)        # target -> family -> (t_ms, stacks)
    rows = []
    casts = sorted([e for e in b["casts"]
                    if e.get("sourceID") == hid and e.get("type") == "cast"],
                   key=lambda e: e["timestamp"])
    for e in casts:
        ts = e["timestamp"]
        fam = abil.get(e.get("abilityGameID"), "?")
        tgt = e.get("targetID")
        cr = (e.get("classResources") or [{}])[0]
        rolling = []
        for f, (at, st) in list(applied.get(tgt, {}).items()):
            if ts - at < HOT_DUR.get(f, 0) * 1000:
                rolling.append("%s%s" % (f[:2], ("x%d" % st) if st > 1 else ""))
        hurt = sum(1 for p in players if p != tgt and pct_at(p, ts) < 90)
        rows.append({
            "t": (ts - t0) / 1000.0, "spell": fam,
            "target": byid.get(tgt, {}).get("name", "-"),
            "role": "TANK" if tgt == max(dmg, key=lambda k: sum(a for _, a in dmg[k]),
                                         default=None) else "other",
            "hp": pct_at(tgt, ts) if tgt in byid else None,
            "in5s": taken(tgt, ts) if tgt in byid else 0,
            "rolling": ",".join(sorted(rolling)) or "-",
            "othersHurt": hurt,
            "mana": cr.get("type"), "pool": cr.get("amount"),
        })
        if fam in HOT_DUR and tgt is not None:
            prev = applied[tgt].get(fam)
            st = 1
            if fam == "Lifebloom" and prev and ts - prev[0] < HOT_DUR[fam] * 1000:
                st = min(3, prev[1] + 1)
            applied[tgt][fam] = (ts, st)

    print("== %s on %s (%s, %.0fs) -- every cast with the state it was made in"
          % (healer, fight["name"], b["code"], (fight["endTime"] - t0) / 1000))
    print("%7s %-15s %-14s %5s %7s %-14s %6s %6s"
          % ("t", "spell", "target", "hp%", "dmg/5s", "already on them", "others", "mana"))
    for r in rows:
        print("%7.1f %-15s %-14s %5s %7d %-14s %6d %6s"
              % (r["t"], r["spell"][:15], r["target"][:14],
                 "-" if r["hp"] is None else "%d" % r["hp"], r["in5s"],
                 r["rolling"][:14], r["othersHurt"], r["mana"]))

    if "--observed" in sys.argv:
        dest = sys.argv[sys.argv.index("--observed") + 1]
        key = "%s-%s" % (healer, byid[hid].get("server") or "WCL")
        with open(dest, "w") as f:
            f.write("return {[%r]=%s}\n" % (key, observed_table(b, hid, abil, dest)))
        print("wrote %s" % dest)

    print("\n== the rule each spell looks like")
    per = defaultdict(list)
    for r in rows:
        if r["hp"] is not None:
            per[r["spell"]].append(r)
    print("%-16s %4s  %-22s  %-20s  %s"
          % ("spell", "n", "hp% at cast (min/med/max)", "damage in prior 5s", "cast onto"))
    for sp, rs in sorted(per.items(), key=lambda x: -len(x[1])):
        if len(rs) < 3:
            continue
        hp = sorted(r["hp"] for r in rs)
        d = sorted(r["in5s"] for r in rs)
        onto = Counter(r["rolling"] for r in rs).most_common(2)
        print("%-16s %4d  %3d / %3d / %3d          %5d / %5d / %5d     %s"
              % (sp[:16], len(rs), hp[0], statistics.median(hp), hp[-1],
                 d[0], statistics.median(d), d[-1],
                 ", ".join("%s:%d" % (k, v) for k, v in onto)))


if __name__ == "__main__":
    main()
