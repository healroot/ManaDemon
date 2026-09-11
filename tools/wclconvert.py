#!/usr/bin/env python3
"""tools/wclconvert.py <raw.json> --healer <name> [<raw.json> --healer <name> ...]
                       [--out .logs/wcl-records.lua]

Turns a raw fight downloaded by tools/wclfetch.py into a ManaDemon recording --
the same stream Engine/FightRecorder.lua writes -- so that somebody else's raid
replays through our own engine with no engine changes.

What is MEASURED from the log (and how):
  maxHP      least squares of absolute HP change (damage - healing) against the
             reported HP percentage; the residual is carried into the record
  mana       the healer's own mana at every one of their casts (classResources)
  cost       the cast's own mana cost, as the client reported it
  regen      least squares over the mana curve: what is left after the costs.
             This absorbs Innervate, potions, Mana Spring and Judgement of
             Wisdom into one observed rate, which is what `energize` means.
  known      family -> highest rank they actually cast
  crit       their realised heal crit rate over the fight
What is INFERRED and marked as such:
  role       the player who took the most damage is the tank; our healer is the
             healer; everybody else is a damager
  healing    the spellPower the client reported on their own casts, x
             SPELLPOWER_TO_HEALING -- the log's field is SPELL DAMAGE, not +healing

See tools/wclfetch.py for the classResources key-name trap.
"""
import json, os, sys
from collections import Counter, defaultdict

K = dict(DMG=1, FHEAL=2, OWNCAST=3, OWNHEAL=4, OWNTICK=5, CASTSTART=6,
         CANCEL=7, FORM=8, DIED=9, ABSORB=10, CD=11, AURA=12, THREAT=13, ECAST=14)
CRIT_FLAG = 100000

# v0.14.7. The `spellPower` a TBC log carries on a cast is the character sheet's
# SPELL DAMAGE, not their +healing, and the two are not the same number: healing
# gear is itemised at roughly +88 healing per +31 damage. Taking it for +healing
# ran every imported raid healer at a third of their real power, which is where
# "Rejuvenation R13 and Regrowth R10 read 1.6-1.8x low" came from -- the spell
# data was never the problem.
#
# The factor is MEASURED, not looked up: `tools/wclcheckkit.lua --fit` solves
# each parse for the +healing that makes our model reproduce what the log says
# each spell healed. Four independent families (Rejuvenation's tick, Regrowth's
# tick, Lifebloom's tick and its bloom) agree on one value per parse to within a
# few percent, and over the 17 parses of the corpus that value divided by the
# reported spellPower is  min 2.66, median 3.08, max 3.46.  The spread is real
# gear variation, so a single constant still leaves +-13% on +healing (about
# +-6% on a heal); `--fit` is how a parse's own residual is read back.
SPELLPOWER_TO_HEALING = 3.08
HP_EVERY, MANA_EVERY = 5.0, 2.0
HEAL_FAMILIES = ("Lifebloom", "Rejuvenation", "Regrowth", "Healing Touch",
                 "Swiftmend", "Tranquility", "Nourish")


def hp_timeline(blob):
    """actor -> sorted [(t_ms, hp percent)] from every event that reports one."""
    obs = defaultdict(list)
    for stream in ("healing", "casts", "damage"):
        for e in blob[stream]:
            ra, hp = e.get("resourceActor"), e.get("hitPoints")
            aid = e.get("sourceID") if ra == 1 else (e.get("targetID") if ra == 2 else None)
            if aid is not None and hp is not None and e.get("maxHitPoints") == 100:
                obs[aid].append((e["timestamp"], hp))
    return {a: sorted(set(v)) for a, v in obs.items()}


def measure_maxhp(blob, byid):
    """Absolute max health per player, fitted to the percentages. Returns
    {actor: (maxHP, mean residual in percentage points, n intervals)}."""
    delta = []
    for e in blob["damage"]:
        if (e.get("amount") or 0) > 0:
            delta.append((e["timestamp"], e.get("targetID"), -e["amount"]))
    for e in blob["healing"]:
        if (e.get("amount") or 0) > 0:
            delta.append((e["timestamp"], e.get("targetID"), e["amount"]))
    delta.sort()
    per = defaultdict(list)
    for ts, a, d in delta:
        per[a].append((ts, d))

    out = {}
    for aid, pts in hp_timeline(blob).items():
        if byid.get(aid, {}).get("type") != "Player":
            continue
        rows = []
        for (t1, p1), (t2, p2) in zip(pts, pts[1:]):
            if p1 >= 100 and p2 >= 100:
                continue                       # capped: healing is invisible here
            dpct = p2 - p1
            if abs(dpct) < 3:
                continue                       # 1% granularity: need a real move
            dabs = sum(d for ts, d in per.get(aid, []) if t1 < ts <= t2)
            if dabs:
                rows.append((dabs, dpct))
        if len(rows) < 3:
            continue
        num = sum(a * p for a, p in rows)
        den = sum(p * p for a, p in rows)
        if den <= 0:
            continue
        mx = num / den * 100
        resid = sum(abs(a / (mx / 100) - p) for a, p in rows) / len(rows)
        out[aid] = (int(round(mx)), resid, len(rows))
    return out


def healer_mana(blob, hid):
    """[(t_ms, mana, base cost paid here)] and max mana, from the healer's casts.
    A `begincast` observes the mana without spending any, so its cost is 0."""
    pts, mx = [], 0
    for e in blob["casts"]:
        if e.get("sourceID") != hid or e.get("resourceActor") != 1:
            continue
        cr = (e.get("classResources") or [{}])[0]
        cur, top = cr.get("type"), cr.get("amount")   # NOT what the keys say
        if cur is None or top is None:
            continue
        mx = max(mx, top)
        cost = (cr.get("max") or 0) if e.get("type") == "cast" else 0
        pts.append((e["timestamp"], cur, cost))
    return sorted(set(pts)), mx


def mana_track(rows, dur, t0):
    """The healer's mana on a grid, and the regen that explains it, measured.

    The mana on a cast event is the mana BEFORE that cast is paid for, so the
    curve after costs is a step function through (t, mana - cost). Between two
    grid points the regen that must have happened is

        regen = (mana_after(g2) - mana_after(g1) + everything spent in between) / dt

    One constant rate cannot describe a druid fight: an Innervate is worth
    several hundred mana a second for twenty seconds and a potion is a step. The
    engine already reads a per-sample rate (`scenario.rates`), so the measured
    rate goes in per window and the whole curve -- Innervate, potion, rune and
    all -- comes back out.

    This means the two MANA gates re-check a curve the rates were taken from and
    cannot fail; they are not evidence here. Health curves, deaths, foreign
    healing and spend coverage still are.

    rows: [(t_ms, mana_before, cost)] sorted. Returns (grid, rates, spent).
    """
    if not rows:
        return [], [], 0
    post = [((t - t0) / 1000.0, m - c) for t, m, c in rows]
    spends = [((t - t0) / 1000.0, c) for t, m, c in rows if c]
    spent = sum(c for _, c in spends)

    def at(g):
        v = rows[0][1]                     # before the first cast: as observed
        for t, m in post:
            if t <= g:
                v = m
            else:
                break
        return v

    grid, gt = [], 0.0
    while gt <= dur + 1e-9:
        grid.append(round(gt, 3))
        gt += MANA_EVERY

    rates, vals = [], []
    for i, g in enumerate(grid):
        vals.append(int(round(at(g))))
        g2 = grid[i + 1] if i + 1 < len(grid) else g + MANA_EVERY
        dt = g2 - g
        window = sum(c for t, c in spends if g <= t < g2)
        r = (at(g2) - at(g) + window) / dt if dt > 0 else 0.0
        rates.append(max(0.0, round(r, 3)))
    return list(zip(grid, vals)), rates, spent


def lua(v, indent=0):
    pad = "  " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    if isinstance(v, (int,)):
        return str(v)
    if isinstance(v, float):
        return ("%.4f" % v).rstrip("0").rstrip(".") or "0"
    if isinstance(v, str):
        return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    if isinstance(v, list):
        if not v:
            return "{}"
        inner = ", ".join(lua(x, indent + 1) for x in v)
        if len(inner) < 100:
            return "{ %s }" % inner
        return "{\n" + "".join("%s  %s,\n" % (pad, lua(x, indent + 1)) for x in v) + pad + "}"
    if isinstance(v, dict):
        if not v:
            return "{}"
        parts = []
        for k, val in v.items():
            key = "[%d]" % k if isinstance(k, int) else (
                k if k.isidentifier() else '["%s"]' % k)
            parts.append("%s  %s = %s," % (pad, key, lua(val, indent + 1)))
        return "{\n" + "\n".join(parts) + "\n" + pad + "}"
    raise TypeError(type(v))


def convert(blob, healer):
    byid = {a["id"]: a for a in blob["actors"]}
    abil = {a["gameID"]: a["name"] for a in blob["abilities"]}
    fight = blob["fight"]
    t0, t1 = fight["startTime"], fight["endTime"]
    dur = (t1 - t0) / 1000.0

    hid = next((a["id"] for a in blob["actors"]
                if a["name"] == healer and a["type"] == "Player"), None)
    if hid is None:
        raise SystemExit("no player named %s in %s" % (healer, blob["code"]))

    maxhp = measure_maxhp(blob, byid)
    players = [i for i in (fight.get("friendlyPlayers") or []) if i in byid]
    players = [i for i in players if i in maxhp] or players

    took = Counter()
    for e in blob["damage"]:
        if e.get("targetID") in byid and (e.get("amount") or 0) > 0:
            took[e["targetID"]] += e["amount"]
    tank = took.most_common(1)[0][0] if took else None

    # roster, healer first is NOT required; keep report order for stability
    order = sorted(players, key=lambda i: (i != hid, -took.get(i, 0), byid[i]["name"]))
    idx = {aid: n + 1 for n, aid in enumerate(order)}
    roster = []
    for aid in order:
        a = byid[aid]
        role = "HEALER" if aid == hid else ("TANK" if aid == tank else "DAMAGER")
        roster.append({
            "name": a["name"], "guid": "wcl:%s:%d" % (blob["code"], aid),
            "class": (a.get("subType") or "?").upper(),
            "role": role, "roleSource": "wcl-inferred",
            "maxHP": maxhp.get(aid, (0,))[0],
        })

    # ---- the healer's mana, measured ----------------------------------------
    mana_pts, pool = healer_mana(blob, hid)
    track, rates, spent_total = mana_track(mana_pts, dur, t0)

    # ---- events -------------------------------------------------------------
    ev = []          # (t seconds, kind, tgt, amt, x)
    for e in blob["damage"]:
        t, amt = e.get("targetID"), (e.get("amount") or 0)
        if amt > 0 and t in idx:
            ev.append(((e["timestamp"] - t0) / 1000.0, K["DMG"], idx[t], amt,
                       e.get("abilityGameID") or 0))
    for e in blob["healing"]:
        t = e.get("targetID")
        if t not in idx:
            continue
        amount, over = e.get("amount") or 0, e.get("overheal") or 0
        ts = (e["timestamp"] - t0) / 1000.0
        sid = e.get("abilityGameID") or 0
        if e.get("sourceID") == hid:
            gross = amount + over
            if gross > 0:
                crit = CRIT_FLAG if e.get("hitType") == 2 else 0
                kind = K["OWNTICK"] if e.get("tick") else K["OWNHEAL"]
                ev.append((ts, kind, idx[t], gross, sid + crit))
        elif amount > 0:
            ev.append((ts, K["FHEAL"], idx[t], amount, sid))
    for e in blob["casts"]:
        if e.get("sourceID") != hid:
            continue
        ts = (e["timestamp"] - t0) / 1000.0
        sid = e.get("abilityGameID") or 0
        tgt = idx.get(e.get("targetID"), -1)
        if e.get("type") == "begincast":
            ev.append((ts, K["CASTSTART"], tgt, 0, sid))
            continue
        cr = (e.get("classResources") or [{}])[0]
        cost = int(cr.get("max") or 0)             # NOT what the key says
        ev.append((ts, K["OWNCAST"], tgt, cost, sid))
    for e in blob["deaths"]:
        t = e.get("targetID")
        if t in idx:
            ev.append(((e["timestamp"] - t0) / 1000.0, K["DIED"], idx[t], 0, 0))
    ev.sort(key=lambda r: (r[0], r[1]))

    stream_ev = {"t": [], "kind": [], "tgt": [], "amt": [], "x": []}
    for t, k, tg, amt, x in ev:
        stream_ev["t"].append(round(t, 3))
        stream_ev["kind"].append(k)
        stream_ev["tgt"].append(tg)
        stream_ev["amt"].append(int(amt))
        stream_ev["x"].append(int(x))

    # ---- health, reconstructed then snapshotted on a 5s grid ----------------
    # The log reports health as a PERCENTAGE, and only on events that happen to
    # carry the actor's resources -- somebody nobody touches for a minute has no
    # samples at all. Forward-filling the last percentage leaves them frozen at
    # 100% while the fight kills them, which is what made every health curve
    # fail its gate.
    #
    # So: integrate. Absolute damage and healing are both known exactly, so HP
    # moves event by event; each reported percentage is an ANCHOR that resets
    # the running value (it is exact to the 1% it is quantised at, and it also
    # catches whatever the event stream does not carry -- absorbs, unlogged
    # environmental damage). Between anchors the arithmetic carries it.
    tl = hp_timeline(blob)
    moves = defaultdict(list)
    for e in blob["damage"]:
        if (e.get("amount") or 0) > 0 and e.get("targetID") in idx:
            moves[e["targetID"]].append((e["timestamp"], -e["amount"]))
    for e in blob["healing"]:
        if (e.get("amount") or 0) > 0 and e.get("targetID") in idx:
            moves[e["targetID"]].append((e["timestamp"], e["amount"]))
    died = {}
    for e in blob["deaths"]:
        if e.get("targetID") in idx:
            died.setdefault(e["targetID"], e["timestamp"])

    curves = {}
    for aid in order:
        mx = maxhp.get(aid, (0,))[0]
        if mx <= 0:
            curves[aid] = []
            continue
        anchors = tl.get(aid) or []
        # tag: 0 = an anchor (resync), 1 = a move. Sorting on the tag keeps the
        # anchor first when both land on the same millisecond.
        stream = sorted([(t, 0, 0) for t, _p in anchors]
                        + [(t, 1, d) for t, d in moves.get(aid, [])])
        cur = (anchors[0][1] / 100.0 * mx) if anchors else mx
        pts, ai = [(t0, cur)], 0
        for ts, tag, d in stream:
            if tag == 0:
                while ai < len(anchors) and anchors[ai][0] < ts:
                    ai += 1
                if ai < len(anchors) and anchors[ai][0] == ts:
                    cur = anchors[ai][1] / 100.0 * mx     # re-sync to the truth
            else:
                cur += d
            cur = max(0.0, min(float(mx), cur))
            pts.append((ts, cur))
        curves[aid] = pts

    def hp_at(aid, ms):
        pts = curves.get(aid) or []
        if not pts:
            return maxhp.get(aid, (0,))[0]
        d = died.get(aid)
        if d is not None and ms >= d:
            return 0
        v = pts[0][1]
        for ts, val in pts:
            if ts <= ms:
                v = val
            else:
                break
        return v

    hp = {"t": [], "hp": {}, "max": {}}
    for aid in order:
        hp["hp"][idx[aid]] = []
        hp["max"][idx[aid]] = []
    gt = 0.0
    while gt <= dur + 1e-9:
        hp["t"].append(round(gt, 3))
        ms = t0 + gt * 1000
        for aid in order:
            hp["hp"][idx[aid]].append(int(round(hp_at(aid, ms))))
            hp["max"][idx[aid]].append(maxhp.get(aid, (0,))[0])
        gt += HP_EVERY

    mana = {"t": [], "v": [], "base": [], "cast": []}
    for i, (gt, v) in enumerate(track):
        mana["t"].append(gt)
        mana["v"].append(v)
        mana["base"].append(rates[i])
        mana["cast"].append(rates[i])

    # ---- what they had, and what they were --------------------------------
    known, ranks = {}, defaultdict(list)
    for e in blob["casts"]:
        if e.get("sourceID") != hid or e.get("type") != "cast":
            continue
        nm = abil.get(e.get("abilityGameID"), "")
        for fam in HEAL_FAMILIES:
            if nm == fam or nm.startswith(fam):
                ranks[fam.replace(" ", "")].append(e["abilityGameID"])
    for fam, ids in ranks.items():
        known[fam] = max(ids)

    heals = [e for e in blob["healing"] if e.get("sourceID") == hid and not e.get("tick")]
    crits = sum(1 for e in heals if e.get("hitType") == 2)
    critpct = (100.0 * crits / len(heals)) if heals else 0.0
    sp = Counter(e.get("spellPower") for e in blob["casts"]
                 if e.get("sourceID") == hid and e.get("resourceActor") == 1
                 and e.get("spellPower"))
    spellpower = sp.most_common(1)[0][0] if sp else 0
    healing = spellpower * SPELLPOWER_TO_HEALING

    ci = {}
    for e in blob.get("combatantinfo", []):
        if e.get("sourceID") == hid:
            ci = e

    # Talents. The log carries the POINT SPLIT per tree, not the individual
    # talents -- Blohz reads [0, 0, 61]. Restoration has 62 points' worth of
    # talents worth taking, so a 55+ point split leaves almost no freedom: the
    # healing talents below are in every deep resto build. They are applied and
    # then CHECKED, by comparing what our model then predicts each spell heals
    # against what the log says it actually healed (tools/wclcheckkit.py). An
    # inferred talent that makes the prediction worse is a wrong inference.
    #
    # Moonglow lives in Balance and is NOT applied here: a 0-point Balance tree
    # cannot have it, and the recorded costs are the client's own anyway.
    trees = [t.get("id", 0) for t in (ci.get("talents") or [])]
    resto = trees[2] if len(trees) >= 3 else 0
    talents = {}
    if resto >= 55:
        talents = {
            "Gift of Nature": 5, "Improved Rejuvenation": 3,
            "Empowered Rejuvenation": 5, "Empowered Touch": 2,
            "Improved Regrowth": 5, "Tranquil Spirit": 5, "Naturalist": 5,
        }
    elif resto >= 40:
        talents = {"Gift of Nature": 5, "Improved Rejuvenation": 3,
                   "Empowered Rejuvenation": 5}
    start_mana = track[0][1] if track else pool

    names = {}
    for a in blob["abilities"]:
        if a["gameID"] in set(stream_ev["x"]) or a["gameID"] in set(known.values()):
            names[a["gameID"]] = a["name"]

    own_h = sum(a for k, a in zip(stream_ev["kind"], stream_ev["amt"])
                if k in (K["OWNHEAL"], K["OWNTICK"]))
    for_h = sum(a for k, a in zip(stream_ev["kind"], stream_ev["amt"]) if k == K["FHEAL"])
    foreign_share = for_h / (own_h + for_h) if (own_h + for_h) > 0 else 0.0

    stream = {
        # v2 (v0.14.7): own-heal amounts are gross ONCE. This converter always
        # wrote them that way -- WCL reports `amount` net with `overheal` on top,
        # so amount + overheal IS the gross -- but the game's own recorder did
        # not until v0.14.7, and the version is what tells the two apart.
        "v": 2,
        "id": int((blob["reportStart"] + t0) / 1000),
        "zone": "%s (WCL %s #%d)" % (fight["name"], blob["code"], fight["id"]),
        # the encounter on its own: `zone` carries the report code so a record can
        # be identified, which makes it useless as a key for grouping fights of
        # the same boss together. Engine/Intuition.lua keys on this.
        "encounter": fight["name"],
        "t0": 0, "dur": round(dur, 2), "pool": pool,
        "roster": roster,
        "tracked": [idx[a] for a in order],
        "ev": stream_ev, "n": len(stream_ev["t"]),
        "hp": hp, "mana": mana,
        "precasts": [], "deaths": [], "truncated": False,
        "auraOn": {}, "auraN": 0, "auraTruncated": False, "threatOn": {},
        "names": names, "pinned": True,
        "ownCasts": sum(1 for k in stream_ev["kind"] if k == K["OWNCAST"]),
        "spent": spent_total,
        "foreignShare": round(foreign_share, 4),
        "initial": {
            "mana": start_mana,
            # a starting value only: scenario.rates overrides it from t=0
            "apiBase": rates[0] if rates else 0, "apiCasting": rates[0] if rates else 0,
            "form": "caster", "energize": 0, "known": known,
            "auras": [], "buffs": [],
        },
        "imported": {
            "source": "warcraftlogs", "report": blob["code"], "fight": fight["id"],
            "host": blob.get("host"), "healer": healer,
            "url": "https://%s.warcraftlogs.com/reports/%s#fight=%d"
                   % (blob.get("host", "fresh"), blob["code"], fight["id"]),
            "regenMeasured": "per 2s window, see tools/wclconvert.py",
            "regenMean": round(sum(rates) / len(rates), 2) if rates else 0,
            "regenPeak": round(max(rates), 2) if rates else 0,
            "hpResidual": round(max((v[1] for v in maxhp.values()), default=0), 2),
            "note": "maxHP is fitted to the reported HP percentages. Regen is "
                    "measured per 2s window off the healer's own mana curve, so the "
                    "two mana gates re-check their own input and cannot fail. "
                    "Health curves, deaths, foreign healing and spend coverage can.",
        },
    }

    profile = {
        "at": int((blob["reportStart"] + t0) / 1000), "level": 70, "class": "DRUID",
        "healing": int(healing), "spellPower": int(spellpower),
        "crit": round(critpct, 2),
        "spirit": int(ci.get("spirit") or 0), "intellect": int(ci.get("intellect") or 0),
        "manaMax": pool, "form": "caster",
        "talents": talents,
        # v0.13: this profile came out of a log, not out of a client. The
        # importer reads it to decide the spellbook: a level 70 druid knows
        # every rank whose trainer level is at or below 70, which the stub's
        # own IsSpellKnown (the author's level 64 book) does not.
        "fromLog": True,
    }
    return stream, profile, ("%s-%s" % (healer, byid[hid].get("server") or "WCL"))


def main():
    args, jobs, out = sys.argv[1:], [], ".logs/wcl-records.lua"
    i = 0
    while i < len(args):
        if args[i] == "--out":
            out = args[i + 1]; i += 2; continue
        if args[i] == "--healer":
            jobs[-1][1] = args[i + 1]; i += 2; continue
        jobs.append([args[i], None]); i += 1
    if not jobs:
        raise SystemExit(__doc__)

    chars = {}
    for path, healer in jobs:
        blob = json.load(open(path))
        stream, profile, key = convert(blob, healer)
        chars.setdefault(key, {"recordings": [], "profile": profile,
                               "fights": [], "coachMarks": {}})
        chars[key]["recordings"].append(stream)
        imp = stream["imported"]
        print("%-22s %6.1fs %4d ev %2d tgt  pool %5d  spent %6d  regen mean %5.1f peak %6.1f/s"
              % (key, stream["dur"], stream["n"], len(stream["roster"]), stream["pool"],
                 stream["spent"], imp["regenMean"], imp["regenPeak"]))
        print("%-22s foreign healing %.0f%%   known %s"
              % ("", stream["foreignShare"] * 100, ", ".join(sorted(stream["initial"]["known"]))))

    # An APPENDIX for the live game database. A SavedVariables file is executed
    # as Lua, so a block appended after the table can push the imported fights
    # into whichever character is logged in without rewriting one byte of what
    # the client wrote. On the next logout the client serialises them back out
    # normally, and deleting the block is the whole undo.
    ap = os.path.splitext(out)[0] + "-append.lua"
    with open(ap, "w") as f:
        f.write("-- Appended by tools/wclconvert.py: fights imported from Warcraft Logs.\n"
                "-- Paste at the END of the game's ManaDemon.lua (client closed).\n"
                "-- Delete this block to remove them. It pushes each fight onto whichever\n"
                "-- character table already exists, newest first.\n")
        f.write("do\n  local imported = {\n")
        for key, c in chars.items():
            for st in c["recordings"]:
                f.write("    " + lua(st, 2) + ",\n")
        f.write("  }\n"
                "  local db = ManaDemonDB\n"
                "  if db and db.char then\n"
                "    for _, c in pairs(db.char) do\n"
                "      c.recordings = c.recordings or {}\n"
                "      for i = #imported, 1, -1 do\n"
                "        local dup = false\n"
                "        for _, r in ipairs(c.recordings) do\n"
                "          if r.id == imported[i].id then dup = true break end\n"
                "        end\n"
                "        if not dup then table.insert(c.recordings, 1, imported[i]) end\n"
                "      end\n"
                "    end\n"
                "  end\n"
                "end\n")
    print("wrote %s (%.1f MB)  -- paste into the game's SavedVariables"
          % (ap, os.path.getsize(ap) / 1e6))

    db = {"char": chars, "profileKeys": {}, "global": {}}
    with open(out, "w") as f:
        f.write("-- Generated by tools/wclconvert.py from Warcraft Logs.\n")
        f.write("-- Not a recording this client made: see each stream's `imported` table.\n")
        f.write("ManaDemonDB = " + lua(db) + "\n")
    print("wrote %s (%.1f MB)" % (out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()
