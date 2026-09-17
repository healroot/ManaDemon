# tools/ — the offline harness

Everything here runs the **real addon files** against a fake WoW client
(`tools/wowstub.lua`), so it catches ordering and arithmetic bugs a syntax check cannot.
Nothing in `tools/` ships: `release.sh` builds from the `.toc`'s own file list.

```bash
bash tools/run.sh tools/<script>.lua [args]
```

`run.sh` builds a real Lua 5.1.5 into `tools/.lua` on first use (gitignored), then runs the
script against this checkout. **It passes the checkout root as `arg[1]`**, so a script's own
arguments start at `arg[2]` — the older tools survive reading from `arg[1]` only because
their parsers happen to reject a path.

Python tools run directly with `python3` and need no harness.

---

## 1. The test suites

Run all of them before committing anything the engine, the recorder or a tooltip touches.

| suite | what it holds down |
|---|---|
| `simcheck.lua` | the engine's ten self-tests + the BF-1 fixture replay (`--curve` prints the mana curve beside the log's) |
| `reccheck.lua` | a whole scripted pull through the real combat-log handler: the stream, the labels, the summary row |
| `replaycheck.lua` | the trace and the replay state machine; *seek == step*; **the causality invariant** |
| `replayui.lua` | the replay window painted under the stub — the nil-index / argument-order / bare-pipe class of bug |
| `runcheck.lua` | a whole scripted dungeon: pulls, gaps, a drink at a known rate, a death, the budget, auto-stop |
| `reviewui.lua` | the Review tab: rows, buttons, and the `run:pull` address across tab, commands and replay |
| `navui.lua` | the navigation kit: lazy panes, one pane at a time, the remembered path |
| `dashui.lua` | the one window, driven the way a mouse would |
| `regencheck.lua` | `/md regentest` against a scripted mana stream, and **what it stores** |
| `simwindow.lua` | every preset combination's scenario, baselines and search |
| `solvercheck.lua` | the solver: deposits, the gap integral, causality, the four forecasts, the explainer |
| `timeline.lua` | the run's clock: segments, seeks, health across a gap |
| `spelltip.lua` | the spell tooltip (v0.14.9): druid only, once per showing, off means off, and **every number on it is the model's own** — the tick and bloom the simulator heals with, the dashboard's heal |

```bash
for t in simcheck reccheck replaycheck replayui runcheck reviewui navui dashui \
         regencheck simwindow solvercheck timeline spelltip; do
  printf "%-13s " "$t"; bash tools/run.sh tools/$t.lua 2>&1 | tail -1
done
```

---

## 2. Working with real recordings

### `import.lua` — your own fights, offline

Loads the game's SavedVariables as the addon's database and runs the same engine the Review
tab runs, without the game.

```bash
bash tools/run.sh tools/import.lua list                 # every recording + its verdict
bash tools/run.sh tools/import.lua validate 1           # the eight gates, in full
bash tools/run.sh tools/import.lua replay 1             # every cast, its label and its reason
bash tools/run.sh tools/import.lua coach 1 force        # the search and the card
bash tools/run.sh tools/import.lua spells 1             # where the mana went, by kind
bash tools/run.sh tools/import.lua export 1             # -> .logs/recordings/<id>.txt
bash tools/run.sh tools/import.lua runs                 # stored runs
bash tools/run.sh tools/import.lua validate 3 --run 1   # run 1, pull 3 (the "1:3" address)
```

Options: `--file <path>` (default `$MD_SAVEDVARS`, then `.logs/ManaDemon.lua`, then the
author's install), `--char "Name-Realm"`, `--run K`.

### `reproduce.lua` — does the engine reproduce the recording at all?

```bash
bash tools/run.sh tools/reproduce.lua .logs/wcl-holdout.lua .logs/wcl-holdout-observed.lua
```

Replays a recording's own casts and reports how much of the **recorded healing** the engine
generates from them, split per family and per heal event, with the cast count and the deaths
beside it. Run this before believing any comparison.

With an `observed.lua` the kit is first scaled to what the log says each spell healed, so
spell values are removed from the question and what is left is the engine alone.

Since **v0.14.7** the Malchezaar control reads **95% with no calibration at all**, and the
observed table is worth one point on top of that (95 -> 96) — which is what it should be
worth once the spell data is right. Per family, uncalibrated: Lifebloom 90%, Regrowth 87%,
Rejuvenation 103%, Swiftmend 67%. The old "uncalibrated 46-68%" was not the spell data: the
recorder was writing every own heal down as heal + overheal, so the **log** column was
inflated, not the engine column. A stream recorded before v0.14.7 (`v = 1`) is flagged in the
output and its share is not a statement about the engine. See `docs/SPEC-v0.14.md` §4b, §4c.

The `observed.lua` beside it is written by `wclrules.py --observed`:

```bash
python3 tools/wclrules.py .logs/wcl/waFx9B1kNQJWP3hq-103.json \
        --healer Samwellx --observed .logs/wcl-holdout-observed.lua
```

### `healcheck.lua` — this character's own heals against the model

```bash
bash tools/run.sh tools/healcheck.lua            # finds the SavedVariables the way import.lua does
bash tools/run.sh tools/healcheck.lua .logs/ManaDemon.lua
```

The client-side twin of `wclcheckkit.lua`: every own heal event in every recording, bucketed
by spell and kind, against what the model says that spell heals — with the **profile the
client itself wrote down**, so it is the one fully trusted calibration in the project.

Read it by the **minimum** column. A recorded amount is gross, so a bucket should be one
value; anything above its own minimum is overheal that should not be there. That is how
v0.14.7's recorder bug was found, and it is how the author confirms the fix: on the next
dungeon every bucket should sit on the model and stop running to twice it.

Lifebloom's tick is per-stack, so its bucket is three overlapping ones (1x / 2x / 3x a base);
the 1-stack cluster is printed separately.

### `solvercmp.lua` — the solver against the threshold rules

```bash
bash tools/run.sh tools/solvercmp.lua
bash tools/run.sh tools/solvercmp.lua --file .logs/wcl-all.lua
```

Sweeps `minValue` / `horizon` and prints the frontier against the rules baseline.

### `strategies.lua` — every strategy side by side

```bash
bash tools/run.sh tools/strategies.lua
bash tools/run.sh tools/strategies.lua --file .logs/wcl-all.lua --char "Blohz-Nightslayer"
```

Runs all of `SP.STRATEGY_SET` over every recording, on the same lexicographic tuple, and
marks which ones are causal. **This is the table to look at when choosing a strategy.**

---

## 3. Warcraft Logs

Credentials live in `.logs/wcl.json` (gitignored); the bearer token is cached in
`.logs/wcl.token` and refreshed automatically.

```bash
# 1. download one fight's raw event streams -> .logs/wcl/<report>-<fight>.json
python3 tools/wclfetch.py bdByCxDv6rVQhRMf 145

# 2. turn raw fights into ManaDemon recordings
python3 tools/wclconvert.py .logs/wcl/bdByCxDv6rVQhRMf-145.json --healer Blohz \
                            .logs/wcl/L8NJymzZW9RKtdYQ-27.json  --healer Ghnoy \
                            --out .logs/wcl-records.lua
```

**v0.14.7:** the `spellPower` a TBC log carries is the character sheet's **spell damage**, not
+healing, and the converter now scales it by `SPELLPOWER_TO_HEALING = 3.08` (measured by
`wclcheckkit.lua --fit` over 17 parses: min 2.66, median 3.08, max 3.46). Regenerate any
corpus converted before v0.14.7 — the healers in it are running at a third of their power.

`wclconvert.py` writes **two** files: `<out>.lua` (a SavedVariables-shaped database for the
offline tools) and `<out>-append.lua` (a block to paste at the end of the game's
`ManaDemon.lua` with the client closed, to replay the fights in-game — deleting the block is
the whole undo).

```bash
# 3. what the healer did, and the state of the fight when they did it
python3 tools/wclrules.py .logs/wcl/bdByCxDv6rVQhRMf-145.json --healer Blohz

# 4. what our model says a spell heals, against what the log says it DID
bash tools/run.sh tools/wclcheckkit.lua
#    ...and the other direction: solve each parse for the +healing that reproduces
#    it, one row at a time. Four families agreeing is what verifies Data/SpellData.lua.
bash tools/run.sh tools/wclcheckkit.lua .logs/wcl-records.lua .logs/wcl-observed.lua --fit

# 5. merge many imported fights into the shipped prior
bash tools/run.sh tools/buildintuition.lua .logs/wcl-all.lua
#    -> Data/Intuition_TBC.lua   (GENERATED - do not hand edit)
```

### What is on disk now

| file | what |
|---|---|
| `.logs/wcl/*.json` | 22 raw fights, kept so a conversion bug can be re-run without spending API points |
| `.logs/wcl-all.lua` | all 22 imported fights, 13 encounters — the corpus |
| `.logs/wcl-records.lua` | the two Nightbane parses (rank #1 and #50) |
| `.logs/wcl-*-append.lua` | the in-game paste blocks for each of the above |
| `Data/Intuition_TBC.lua` | the shipped prior built from `wcl-all.lua` |

**Two traps the converter documents, because both are silent:** `classResources`' key names
lie (`amount` is max mana, `type` is current mana, `max` is the cast's cost), and player
health is reported as a **percentage** — max HP is recovered by least squares against the
absolute damage and healing.

---

## 4. Not a tool

`harness.lua` (loads the addon files and returns `MD`), `wowstub.lua` (the fake client) and
`fakepull.lua` (the shared scripted pull) are machinery the suites use. Keep
`harness.lua`'s file list in step with `ManaDemon.toc`.
