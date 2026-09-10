# ManaDemon — session history

Running log of work sessions. Newest entry last. Any Claude session working on this
repo should read this file plus `docs/DECISIONS.md` before making changes, and append
a dated entry here when a session ends with meaningful progress.

---

## 2026-09-01 — Project inception: design debate + full v1 implementation

**Process:** The author requested a multi-agent workflow: two Opus agents brainstormed
from opposing stances ("Party A: Theorycrafter" — math correctness first; "Party B: UX
Pragmatist" — glanceable decision-driving UI first), exchanged rebuttals, the author
picked between disputed features, a draft implementation plan was written and both
agents critiqued it, and the judged synthesis was implemented. All contested calls,
who won each, and the formulas are in `docs/DECISIONS.md` — that file is the authority
on *why* the code is shaped the way it is.

**Author's decisions this session:**
- All four disputed extras in v1: Innervate/potion advisor, gear-change rank toast,
  5SR underline, drink reminder (drink reminder kept against Party A's cut vote).
- History fine-tuning of the OOM prediction: cut (only pull-time EWMA seeding from the
  last ~5 in-memory fights + "last fight" reference survive; no persistence).
- Class scope: TTO/advisor class-generic, rank dashboard druid-only.

**Built (v1 complete, 12 Lua files, all syntax-checked via python3+luaparser — no Lua
interpreter on this machine):**
- `ManaDemon.toc` (Interface 20506, `## OptionalDeps: ElvUI`), `Core.lua` (namespace,
  `MD:On`/`MD:RegisterCallback`/`MD:Fire`/`MD:OnTick`, talent scan by name, slash cmds),
  `Data/SpellData.lua` (static druid spell table + cost modifiers),
  `Engine/` (RegenModel with FSR state machine, SpendTracker EWMA + bucket stats,
  TTO + shared display string, RankMath with Pareto filter),
  `UI/` (Widget with 5SR underline + visibility hysteresis, Dashboard, Advisor,
  Summary), `Integrations/ElvUIDatatext.lua`, `Verify.lua` (`/md verify`, `/md fsrtest`).
- Docs: `CLAUDE.md`, `README.md`, `docs/DECISIONS.md`, this file.
- Bugs caught in self-review and fixed: widget not draggable during first-run preview;
  widget position saved without relativePoint (would shift after reload); FSR-test
  logger couldn't be detached (dispatcher has no unregister — flag pattern used).

**State at session end:**
- NOT committed to git (author hasn't asked; repo has zero commits).
- NOT tested in-game. `Data/SpellData.lua` values are best-effort from TBC references —
  the `-- VERIFY` rows (high-rank HT/Rejuv/Regrowth costs and heals, Tranquility costs,
  Lifebloom coefficients) are unconfirmed.

**Next steps (in order):**
1. Author runs `/md verify` in-game and reports output → fix `SpellData.lua` from it.
2. Author runs `/md fsrtest` → confirm the FSR anchor (cast completion vs mana deduction).
3. Confirm `GetManaRegen()` units and combat freshness on the anniversary client.
4. First git commit once data is verified (or before, if the author wants a snapshot).
5. v2 backlog lives at the bottom of `docs/DECISIONS.md`.

**Addendum 2 (same day) — v0.2.0 after first in-game test.** Author feedback:
1. *Boxes instead of `↓`/`∞`* — WoW's default fonts lack those glyphs. Fixed: display
   string is ASCII-only now (`^` up / `v` down / `vv` crit / `=` flat / `--` sustainable);
   summary separator switched from U+00B7 to `|`. RULE: no non-ASCII glyphs in any
   rendered string.
2. *Dashboard restructure* — now class tab (Druid) + Settings tab, spell subtabs
   (HT/Lifebloom/Rejuv/Regrowth), and per-spell a table of ALL ranks incl. unlearned
   (dimmed "not learned"), columns Rank/Lvl/Mana/Heal-per-cast/HPM/HPS/Cast/note.
   Pareto now marks rows ("dominated") instead of hiding them; `showDominated` setting
   removed. RankMath computes all ranks with a `known` flag (Pareto/suggested among
   known only).
3. *GUI settings* — Settings tab: mute, drink reminder, widget lock, minimap button
   toggle, widget position reset, spend half-life slider (5–60s).
4. *MinimapButtonButton integration* — new `UI/MinimapButton.lua`: standard named
   Button parented to Minimap (the pattern collectors adopt), left-click dashboard,
   right-click settings, draggable around the rim, angle persisted in `db.minimap`.
Version bumped to 0.2.0; release rebuilt (15 files). Still not committed, still
pending in-game `/md verify`.

**Addendum (same day):** Added `docs/HISTORY.md` + CLAUDE.md continuity instructions
(the author noted new Claude sessions don't remember old ones), and `release.sh` —
builds `dist/ManaDemon/` + `dist/ManaDemon-<version>.zip` from the `.toc`'s file list,
optionally installs into an AddOns folder passed as arg or `WOW_ADDONS` env var.
Tested: 14 files packaged. `dist/` gitignored. The author's WoW install path is not
yet known (auto-detection through /mnt was too slow) — ask for it once and record it here.

## 2026-09-02 — Feedback round 3 (v0.3.0): OOM+FULL clock, estimator rework, dashboard polish

**Git:** the harness required an isolated worktree for edits, which needs a commit to
branch from, so the previously uncommitted v0.2.0 state was committed as the initial
snapshot on `master` (`f2939b4`). This round's work is on branch
`worktree-feedback-round-3` (worktree `.claude/worktrees/feedback-round-3`, gitignored).
Merge it into `master` to pick it up: `git merge worktree-feedback-round-3`.

**Author feedback and what was done:**
1. *Second ElvUI datatext for current mana regen* — `ManaDemon Regen`: `Regen: 123` (mp5
   from `RM:Current()`, so casting regen inside the 5SR, `(5SR)` marker), same tooltip
   and click handling as the OOM datatext (shared code).
2. *OOM and FULL time at the same place* — debated (A/B + rebuttal, Fable judge; full
   table appended to `docs/DECISIONS.md`). Shipped: one clock whose label carries the
   sign (`OOM 1:20 v` / `FULL 0:45`), grey `rest 2:10` secondary (time to full if you
   stop casting), `OOM >4:00 =` when net rate is within noise, `>10m` cap, warm-up
   `OOM ...`, out of combat `FULL 1:12` / `FULL`. `/md rest` + Settings checkbox.
3. *Estimation jumps* — root causes were the p75-of-6-buckets pessimism (re-sorts every
   5s) and the binary FSR regen flip. Now: `rate + 1 sigma` from the EWMA loop
   (`ST:Estimate()`), FSR-duty-weighted regen (`RM:Effective()`), digit precision from
   sigma, value/mode latch (bad news instant, good news 2 ticks), arrow from the shown
   value. Out of combat the FULL clock uses observed mana gain so drinking is right.
4. *"Not learned" on ranks below a known one* — `SD:BuildKnown()` now finds the highest
   detectable rank per family and backfills every lower rank (they are prerequisites).
5. *Dashboard transparency* — flat near-opaque backdrop (0.06 grey, 95%).
6. *ElvUI-style tabs* — stock button textures gone; flat 0.1-grey backdrops, 1px black
   border, gold text + lighter backdrop on the active tab; same style for close/reset.
   No ElvUI dependency (values taken from ElvUI's defaults: backdrop 0.1, border black).
7. *Lifebloom x2 / x3* — virtual rows under Lifebloom: per refresh cast 6 ticks at the
   stack multiplier, no bloom; excluded from Pareto/suggestion (informational).

Also: `MD.version` now read from the .toc; `/md verify` prints drink-buff state and the
observed OOC fill next to `GetManaRegen` (premise check for item 3). All 13 Lua files
syntax-checked (python3 + luaparser). Release rebuilt as v0.3.0.

**Still pending:** in-game `/md verify` + `/md fsrtest` output; `K_SIGMA=1.0` and
`CV_STABLE=0.35` in `Engine/TTO.lua` are first guesses to tune from real fights.

**Addendum (same day) — Makefile.** Author asked for `make release` that prompts for the
source (main checkout or a worktree) and stacks output in the top-level `dist/` grouped
per source. `release.sh` gained `--src NAME|DIR`, `--out`, `--install`, `--list`, `--menu`
(repo root found via `git rev-parse --git-common-dir`, sources via `git worktree list`);
output is `dist/<name>/ManaDemon/` + zip, `<name>` = `main` or the worktree folder. The
`Makefile` wraps it (`release`, `install`, `list`, `clean`; `.RECIPEPREFIX = >`). Tested
from the worktree: menu, `SRC=main`, `SRC=feedback-round-3`, unknown source errors out.

## 2026-09-03 — Talent audit, Cell-style settings + debug console (v0.4.0)

**Talent audit (author asked "does our math consider talents?").** Verdict recorded in
`docs/DECISIONS.md` § Talent audit. Covered correctly: Gift of Nature, Improved /
Empowered Rejuvenation, Empowered Touch, Improved Regrowth, Naturalist (heal side);
Moonglow, Tranquil Spirit, Tree of Life (cost side); Intensity / Living Spirit /
Lunar Guidance / Natural Perfection / Tree aura via the client APIs. Found but NOT yet
changed (author to decide after `/md verify`): percent modifiers stack multiplicatively
in the code while the TBC client sums same-type percent mods (GoN + Imp Rejuv; Moonglow +
Tranquil Spirit; Moonglow + Tree of Life); Empowered Touch should ADD +10%/rank to the
HT coefficient, not multiply it (same for R5+, differs for R1–R4); Nature's Grace is not
modelled at all. Author then reported that **Dreamstate is not part of the mp5 value
Blizzard reports** — if true, both `GetManaRegen()` rates run low by 4/7/10% of Int per
5s in AND out of the 5SR and the whole in-combat clock is pessimistic by that constant.

**To settle it in-game the author asked for debug logs and a copyable log window "like
Cell does", plus Cell's settings-window style.** Done, mimicking `../Cell`:
- `UI/Style.lua` — widget kit written from scratch after Cell's `Widgets/Widgets.lua`:
  class-colour accent, 13/14px fonts (`MANADEMON_FONT*`), flat 0.115-grey backdrops with
  1px black border, buttons (`red`, `accent-hover`, ...), button groups (tab highlight),
  check buttons, titled panes, scroll frame with 5px accent thumb, scroll edit box,
  slider with value box, movable frame with 20px header bar, private flat tooltip.
- `UI/OptionsFrame.lua` — 432px options window; tab buttons on the top edge
  (`General | About  ManaDemon vX  ×`), height per tab, position saved in
  `db.optionsPos`, ESC closes. `/md options`, dashboard "Settings" button, minimap
  right-click all open it. Tabs subscribe to `ShowOptionsTab`.
- `UI/Options_General.lua` — panes: OOM Widget (lock, rest, reset position), Alerts
  (mute, drink), Model (half-life slider), Misc (minimap button, **Debug Console**,
  Verify spell data, Regen test). Replaces the dashboard's old Settings tab.
- `UI/Options_About.lua` — version, blurb, every command (`MD.COMMANDS`), verify steps.
- `UI/DebugConsole.lua` — Cell's DebugConsole concept: `MD:Debug(category, fmt, ...)`
  in Core (no-op unless `db.debug.enabled`), 1000-line memory ring, movable window with
  Enable checkbox, per-category filters (regen / mana / spend / tto / combat / chat /
  other), Clear, **Copy** (select-all edit box popup, Ctrl+C), Regen test button.
  `/md debug` toggles it. `MD:Print` mirrors into the `chat` category so `/md verify`
  output is copyable too.
- Log points: `GetManaRegen` value changes, 5SR start/end, every mana tick with
  `(5SR)` marker, every priced cast with source/max-rank, unpriced spells, pull seed,
  TTO mode transitions + a full state line every 5s in combat (15s out), pull/end of
  fight, talent scans, alerts.
- `/md regentest [N]` (`Verify.lua`) — the Dreamstate test: N s (default 30) idle,
  observed mana gain vs time-weighted `GetManaRegen`, diff compared with
  `{4,7,10}% × Int / 5`; prints a VERDICT (API includes / excludes Dreamstate) and
  flags mana spent, drink buff, 5SR time or <3 ticks as invalidating.
- `UI/Dashboard.lua` — rebuilt on the kit: header bar with title/close, spell tabs as an
  accent button group, "Settings" button top-right; settings pane removed.
- `Core.lua` — `DEFAULTS.debug`, `DEFAULTS.optionsPos`, recursive `FillDefaults`,
  `MD.RELEVANT_TALENTS` + `MD:TalentSummary()`, `MD.COMMANDS`, new slash commands.
- `.toc` 0.4.0; load order Style → Widget → Dashboard → OptionsFrame → Options_* →
  DebugConsole. All 18 files syntax-checked (python3 + luaparser).

**Next:** author runs `/md regentest` (idle, partial mana, no drink) and `/md verify`,
copies the console log. Then: add the Dreamstate term to `RegenModel` if excluded;
switch percent mods to additive if `/md verify` COST lines confirm; decide Nature's
Grace. `K_SIGMA` / `CV_STABLE` tuning still pending. The kept worktree
`.claude/worktrees/feedback-round-3` is identical to master and can be removed.

## 2026-09-03 (later) — Log review: Dreamstate confirmed, costs corrected (v0.4.1)

Author ran the console on a level 64 druid (342 Int, 299 Spi) and dropped three logs into
`.logs/` (gitignored, local evidence only): `spell-cast-test.txt` (verify + casts),
`no-dreamstate-regen-test.txt`, `dreamstate-regen-test.txt` (same character, respecced).

**Findings, with numbers**
- **Dreamstate is NOT in `GetManaRegen()`.** Without the talent: ticks +121/122 per 2s
  vs API base 60.16/s (diff −0.99/s over 30s, i.e. the API is exact). With Dreamstate 3
  (and Living Spirit dropped): API base 52.86/s but ticks +121 → observed 59.6/s; raw
  diff +9.4/s of which ~2.8/s was the test's 2.5s 5SR tail, leaving ≈6.6/s vs the
  expected 10% × 342 / 5 = 6.84/s. Cross-check: the gear/buff share derived from the
  API's own two numbers is 21 mp5 in BOTH specs (S = (base − casting)/(1 − Intensity)),
  so the missing 34 mp5 is exactly Dreamstate and nothing else changed.
- **`GetSpellPowerCost` works on this client** (44 costs checked) — the v1 premise "the
  2.5.x client does not reliably expose per-rank costs" was wrong.
- **Static costs were wrong** for Rejuvenation R6–R12 (live 160/195/235/280/335/360/370),
  Tranquility R1–R4 (525/705/975/1295), Swiftmend (271); Innervate costs 67 (a % of base
  mana, level-dependent). Actual mana drops in the cast log (−370 Rejuv R12, −575 Regrowth
  R9, −220 Lifebloom) confirm the live values. All cast times matched.
- **The level-70 spirit constant (0.009327) read 2× low at level 64**: modelled 25.8/s
  vs the real spirit share 56/s, so "gear ~171 mp5" was nonsense.
- **Display bug:** `FULL 2:05` stayed on screen for 15s+ while the model said 94s. Cause:
  the OOC fill EWMA was updated every 0.5s tick from a signal that only lands every 2s,
  so it oscillated ±10%; the latch demanded the identical quantized value on two
  consecutive ticks and never got it.

**Changes**
- `Engine/RegenModel.lua`: keeps raw `RM.apiBase/apiCasting`; `RM:Unreported()` adds
  Dreamstate (`{4,7,10}% × Int / 5`) to both rates (`RM.unreported`, shown in the
  dashboard line, datatext tooltip and verify snapshot). Observed OOC fill is now an
  EWMA over gain EVENTS (gain / interval), stale after 6s. `RM:Components()` derives the
  spirit share from the API's two numbers and the in-5SR talent (Druid Intensity, Priest
  Meditation, Mage Arcane Meditation) — no level constant. Refreshes on talent change.
- `Data/SpellData.lua`: `SD:GetCost()` is **live-first** (`SD:LiveCost`) with the static
  table as fallback, returns `cost, "api"|"table"`; `SD:StaticCost()` is the table-only
  figure the verify harness diffs against. Costs above corrected; Innervate has no static
  cost. The static fallback's multiplicative percent stacking is documented as a known
  ~2% error that only matters without the API.
- `Engine/TTO.lua`: the value latch accepts a candidate within one step of the previous
  candidate (jitter-tolerant) instead of demanding the identical value.
- `Verify.lua`: COST lines now say "static X, live Y (used)"; snapshot prints raw API +
  the Dreamstate term; `/md regentest` waits for the 5SR to end before measuring,
  compares against the RAW API (so the verdict stays valid now that the model adds
  Dreamstate) and prints observed − model as the residual to watch.

**Still open:** heal-side percent stacking (GoN + Imp Rejuv, ≈1%), Empowered Touch shape
(HT R1–R4 only), Nature's Grace, Lifebloom bloom × Empowered Rejuvenation, `K_SIGMA` /
`CV_STABLE` tuning from real fights. Other classes' int-based regen talents (Shaman
Unrelenting Storm) probably share Dreamstate's fate but are unmeasured, so not added.

## 2026-09-03 (later still) — Tree of Life form (v0.4.2)

Author: heal and cost values did not follow Tree of Life form — reduced HoT cost, and the
aura that adds 25% of the druid's Spirit as healing *received* by party members (not part
of the +healing stat). Done:
- `MD:InTreeForm()` uses `GetShapeshiftFormID() == TREE_FORM` (buff-name fallback);
  `UPDATE_SHAPESHIFT_FORM(S)` fires `FORM_CHANGED`; the dashboard refreshes on it (costs
  are live-first since v0.4.1, so the −20% shows as soon as it re-renders).
- `RankMath` adds `0.25 × Spirit` to the +healing input while in form (setting
  `db.treeAura`, default on, General > Model "Count Tree of Life aura"); the dashboard line
  shows `+450 healing (+75 Tree of Life aura on party targets)`; `RankMath.info` exposes the
  inputs. The aura goes through the same coefficient/penalty path as +healing (it is a
  "taken advertised benefit" in the MaNGOS-era formula) — unverified in-game, listed.
- Gear-change toast snapshots are keyed by form so shifting never triggers "rebind?".
- `/md verify` snapshot prints the form and the aura amount.

## 2026-09-03 (evening) — "To OOM" column (v0.4.3)

Author asked what HPS is (heal per cast / time the cast occupies; 1.5s GCD for instants —
throughput of chain-casting, healing *committed* per second for HoTs) and for a "casts to
OOM" column. `RankMath` rows now carry `casts = floor((mana − cost) / (cost − castingRegen ×
interval)) + 1` from the CURRENT mana at the in-5SR regen rate (`math.huge` → "inf" when
regen covers the cost; 0 when mana < cost). Dashboard: "To OOM" column, a grey hint line
explaining HPM / HPS / To OOM with the mana and mp5 used, and a 2s re-render while open so
the column follows mana (render only). `RankMath.info` gained `mana`, `castingRegen`.

**Addendum — HP5 column (v0.4.4).** The author's "HP5" idea: healing per 5s you can sustain
at zero mana, casting only as regen pays. 5SR-aware steady state: `T = cost / casting` if 5s of
casting regen cover the cost, else `T = 5 + (cost − 5·casting) / base`, never below the cast
interval; `HP5 = 5 · heal / T`. Dashboard widened to 760 for the extra column; hint line
explains all four metrics with the two regen rates used. Not part of the Pareto filter.

**Addendum — spamtest (v0.4.5).** Author chain-cast Lifebloom in Tree form: dashboard said 42,
OOM after 24. Even zero regen gives 37 from a full pool at 176/cast, so the start mana or the
real per-cast drop must differ from what the column used. `/md spamtest` now arms a counter:
first priced cast picks the spell, counts casts, real drops and regen until OOM (or 10s idle),
and prints the prediction from the armed mana next to the measured figures, flagging a
drop-vs-live-cost mismatch. `RankMath:CastsToOOM(cost, interval, mana, regen)` is public.

**Resolved (same day).** The 42-vs-24 discrepancy was a Clique misbinding: the author was
casting Rejuvenation (296 in Tree form, ~24 casts from 6544) instead of Lifebloom. Retested
with the right spell: the To OOM column matches. Consider the column verified in-game.

**Addendum — Simulate strip (v0.4.6).** Author asked for what-if inputs. `MD.sim` (session
only) holds overrides for +healing, crit %, casting mp5, resting mp5 and mana; `RankMath`
reads them (nil = live) and reports `info.simulated` + `info.live` for the labels. Dashboard:
a "Simulate:" row under the tabs with five edit boxes (blank = live, the live value in each
label), Clear button, orange SIMULATION prefix on the stats line while any override is set.
The gear-change toast is suppressed while simulating. Frame height 496.

## 2026-09-03 (night) — Commit, clean-up, plan

Committed v0.4.6 (`9da7dfe`, 22 files); removed the stale `feedback-round-3` worktree and
branch. Wrote `docs/PLAN.md` (Phase 1 druid: close verification items → model improvements
→ UX → housekeeping; Phase 2 other classes, Priest first, built on the generic parts) and
`docs/TESTING.md` (smoke test of the new UI, `/md verify`, Tree aura test, Lifebloom bloom
test, one logged real fight for the clock constants, spamtest, Simulate). Author agreed
with all suggestions; next session starts with whatever the tests return, then PLAN §1b.

## 2026-09-03 (late) — Smoke-test fixes, heal log (v0.4.7)

Author's smoke test: Simulate row overflowed the dashboard (live values were in the labels)
→ values are now grey placeholders inside the boxes, labels short. About tab rows overlapped
(fixed 14px rows, wrapped text) → rows sized by their text, frame height measured
(`MD.optionsTabHeight`). `/md verify` in Tree form showed the client ROUNDS modified costs
(Swiftmend 216.8 → 217; static fallback floored) and discounts **Tranquility** in form too →
both fixed in `SD:StaticCost`. Tooltips show base heal only (932 in/out of form), so the aura
and bloom tests need real heal amounts → new **heal** debug category logs every SPELL_HEAL /
SPELL_PERIODIC_HEAL the player lands (amount, overheal, crit, `[tree]`); console widened to
580. `docs/TESTING.md` §3/§4 rewritten around the heal log. Tests 1, 2, 6, 7 passed.

## 2026-09-03 (late) — Heal log results (v0.4.8)

Author's heal log: **Lifebloom matches the model exactly** (tick 87, bloom 864 with Emp Rejuv
on the bloom; 829 without) → coefficients confirmed, Emp Rejuv applied to the bloom. **Tree
aura confirmed** as +healing on the target (Rejuv +21/tick, Lifebloom +7/tick, bloom +32 = 70
Spirit through the normal path), dynamic on running HoTs. **Rejuvenation ran ~3% high** (445 vs
431/tick) while Lifebloom was exact → a flat +50 on Rejuvenation only, i.e. Idol of
Rejuvenation. Added `SD.relics` (Idol of Rejuvenation, Harold's Broach, Emerald Queen, Avian
Heart, Idol of Health, Raven Goddess — all but the first VERIFY) and `SD:Relic()` reading slot
18; RankMath adds flat to the base heal, per-tick to Lifebloom ticks, aura to the Tree aura;
dashboard line and `/md verify` show the relic. Awaiting the author's confirmation of the idol.

## 2026-09-03 (end of session) — State for the next session

**State:** master at v0.4.8 (+ docs commit), clean tree, `dist/main/` built. Phase 1a of
`docs/PLAN.md` is done except the clock-constant tuning, which needs `docs/TESTING.md` §5
(one real fight with logging on; author will do it later). The relic slot is confirmed
(Idol of Rejuvenation) and heal-side stacking is settled as multiplicative.

**Next session, in order:**
1. If a §5 log is available: read the `[tto]` lines vs what happened, tune `K_SIGMA` /
   `CV_STABLE` in `Engine/TTO.lua`, record in DECISIONS.
2. PLAN §1b: Nature's Grace (cast-time EV term), Innervate-aware clock (second figure),
   overheal-calibrated HPM (per-spell overheal from `UI/Summary.lua`), persisted fight
   history (last 20 per character in `MD.cdb`).
3. PLAN §1c: per-row dashboard tooltips (breakdown of every number), Simulate form/Moonglow
   inputs, shared tooltip builder, `/md profile`.
4. Then Phase 2 (Priest first) on the generic parts; testing via guildmates' pastes.

**Gotchas learned today:** a new build needs `/reload` before ElvUI datatexts re-register
(looked like a broken integration once); tooltips on this client show base heal only, so
formula checks go through the `heal` debug category; the user reads `.logs/*.txt` back to
me — ask for them instead of guessing.

## 2026-09-03 (design session) — v0.5 design and architecture

No code. The author deferred the `docs/TESTING.md` §5 combat-log run and asked for the
detailed design of everything still planned. Wrote **`docs/DESIGN-v0.5.md`**, covering
`docs/PLAN.md` §1b (Nature's Grace, Innervate-aware clock, overheal-calibrated HPM,
persisted fight history), §1c (row tooltips, Simulate form/Moonglow, one tooltip
builder, `/md profile`) and §1d, plus the Phase 2 seams.

**Architecture decided:** `RankMath` splits into `Context()` / `RowFor(spell, ctx,
variant, explain)` / `Compute()` / `Explain()` so a row's intermediate terms are
reachable for tooltips and `/md profile` without churning tables on the 2s re-render;
`SD:StaticCost(id, ctx)` takes an override context and **sums** percent cost modifiers
(the client's behaviour, already recorded in the code comment) because the simulate
strip now depends on that path; new `Engine/Overheal.lua`, `Engine/ManaCooldowns.lua`
(class table, Innervate value shared by the clock and the advisor, Phase 2 stubs),
`UI/Tooltip.lua` (one `{l, r}` line builder for both datatexts, the minimap, the widget
— which gains a hover tooltip — and the dashboard); `UI/Summary.lua`'s two duplicate
combat-log handlers collapse to one; `UI/Dashboard.lua` splits into `_Rows` / `_Simulate`;
copy popup and verify snapshot extracted as `MD:ShowCopyPopup` / `MD:Snapshot`.

**Model calls:** Nature's Grace as the exact mixture `(1-p)*T0 + p*max(T0-0.5, 1.5)`
rather than `cast - 0.5*crit` floored (the floor clips wrongly), fed to HPS, HP5 and To
OOM; Innervate as `max(0, (5*S + G + U) - RM:Effective()) * 20 - cost`, i.e. the marginal
gain over what the clock already projects, suppressed while the buff is up; overheal
weighted by amount with a 150-event half-life, rank scope when it has 40 events else
family, and the Pareto/suggested rank deliberately left on raw values so a noisy
measurement can never fire a "rebind?" toast.

**Delivery order:** v0.5.0 architecture alone (the only step with regression risk),
then NG, then cooldowns, then overheal + history, then the UX step.

**Open for the author:** §11 of the design lists the five contested calls (`inn` on the
one-liner vs tooltip-only; overheal family-average vs rank-only; effective mode as a
toggle vs a column; Nature's Grace in the mana columns or HPS only; time/gear decay on
persisted overheal). Offered the usual Opus-party + Fable-judge debate on those before
v0.5.2. Two model assumptions ship with a debug line that settles them next play
session: the 0.5s Nature's Grace value (new `cast` category) and whether Innervate's
400% touches anything but the spirit share (`regen` line on buff gain/fade).

## 2026-09-03 (implementation) — v0.5.0 to v0.5.2

Author approved the design and said to start implementing. Three of the six planned
releases landed; `docs/DESIGN-v0.5.md` §9 is the remaining order (overheal + persisted
history, then the UX step, then docs).

**v0.5.0 — architecture, no intended behaviour change.** `RankMath` split into
`Context()` / `RowFor(spell, ctx, variant, explain)` / `Compute()` / `Explain()`;
`row.calc` is only allocated when asked, so the dashboard's 2s re-render churns nothing.
`SD:StaticCost(id, ctx)` takes an override context and now **sums** percent cost
modifiers, which is what the client does (the multiplicative fallback was a documented
~2% error). New `UI/Tooltip.lua` is the single `{l, r}` line builder behind both ElvUI
datatexts, the minimap button and the widget — the widget gained a hover tooltip and a
left-click shortcut, which needs mouse input on the frame, hence `db.widgetTooltip`.
`UI/Summary.lua` went from two combat-log handlers and three
`CombatLogGetCurrentEventInfo()` calls to one of each. `UI/Dashboard.lua` split into
`_Rows` / `_Simulate` on `MD.DashboardParts`. `MD:ShowCopyPopup` and `MD:Snapshot`
extracted for the coming `/md profile`.

**v0.5.1 — Nature's Grace.** `E[T] = (1−p)·T0 + p·max(T0−0.5, 1.5)`, the mixture rather
than `cast − 0.5·crit` floored (that form clips the wrong branch when `T0−0.5` lands on
the GCD). Throughput over a chain is `heal / E[T]` exactly, so averaging the cast time is
correct for a sustained column. Feeds HPS, the HP5 interval floor and To OOM — To OOM
goes slightly **down**, because a faster cast earns less regen, which is right. Grey `*`
in the Cast column, `db.naturesGrace` in Options > Model, and a new `cast` debug category
logging the client's own cast duration against the model — the thing that will settle the
0.5s and Naturalist, neither of which is in the spellbook tooltip.

**v0.5.2 — mana cooldowns.** `Engine/ManaCooldowns.lua` owns the class table (Druid live;
Priest/Shaman/Paladin stubs awaiting a value model and one log from that class) plus the
potions, and returns the **marginal** mana a source buys:
`max(0, (5·S + G + U) − RM:Effective()) × 20 − cost`. Suppressed entirely while the buff
is up, since `GetManaRegen` already reports the boosted rate then. The clock's secondary
segment shows `inn 2:10` instead of `rest` when the clock is ≤90s, the cooldown is ready
and it is worth ≥10% of the pool (`db.showCooldown`); the advisor's own rough 3.5×
estimate is gone, so the two can no longer disagree on screen. Results are cached for
0.4s because the advisor and the clock both ask every tick.

**Next:** v0.5.3 (`Engine/Overheal.lua`, effective mode, `cdb.fights` + zone-aware seed),
v0.5.4 (row tooltips wired to hover, Simulate form/Moonglow row, `/md profile`), v0.5.5
(TESTING/DECISIONS + release). Two assumptions ship with a debug line that proves them on
the author's next play session: the 0.5s Nature's Grace value (`cast` category) and
whether Innervate's 400% touches anything beyond the spirit share (`regen` category, on
buff gain/fade).

## 2026-09-05 — v0.5.3 to v0.5.5: overheal, row tooltips, /md profile, docs

Finished the `docs/DESIGN-v0.5.md` delivery order. **All of `docs/PLAN.md` §1b, §1c and
§1d is now shipped**; what is left in Phase 1 is the author's in-game logs.

**v0.5.3 — overheal + persisted history.** `Engine/Overheal.lua` measures overheal per
family and per rank from the combat log, weighted by amount (so a 4-tick Rejuvenation and
a Healing Touch count in proportion to the healing they did), decayed per event with a
150-event half-life, gated at 40 events, persisted in `MD.cdb.overheal`. An "Effective"
checkbox on the dashboard switches Heal/HPM/HPS/HP5 to `value × (1 − overheal)` and turns
those four headers the class colour; Mana, Cast and To OOM never move. A rank with no data
of its own keeps its raw value and gets a grey `?`. The Pareto filter and the suggested
rank stay on raw values deliberately (DECISIONS v0.5 §3).

While doing it, found and fixed a latent ambiguity: WoW documents `SPELL_HEAL`'s `amount`
both ways (gross vs net of overheal) and `UI/Summary.lua` had quietly assumed net. A full
overheal discriminates — gross reports `amount == overheal`, net reports `amount == 0` —
so the first unambiguous sample latches `db.healAmountGross` and `OH:Split()` feeds both
the dashboard and the fight summary's `overheal N%`. Net stays the default until proven,
so nothing moves on its own. `/md profile` prints which way it latched.

Fight history persists: `MD.cdb.fights`, last 20, with timestamp, zone and heal totals;
`MD.fightHistory` is bound straight to it so nothing else changed. The pull-time seed now
prefers the median of recent fights **in the current zone** when ≥2 exist — spend rate is
content, not character.

**v0.5.4 — the UX step.** Dashboard rows hover to the full derivation of every number
(`RankMath:Explain()` rebuilds one row on demand, so the 2s re-render still allocates
nothing). The Simulate strip gained a second row: form (Live/Caster/Tree — three states,
because "follow my real form" is a distinct answer from "caster") and a Moonglow box;
neither touches `MD:InTreeForm()`, and simulating either falls costs back to
`SD:StaticCost(id, ctx)`. `/md profile` and a "Copy profile" button put every input, the
max ranks' live-vs-static costs, the clock state and all settings into the copy popup.

**Layout fix found while testing the math.** The hint paragraph under the callout was
~265 characters in a 728px slot 18px above the table — it was already at risk of wrapping
onto the rows, and Nature's Grace made it longer. Replaced with one short line; the full
column glossary moved to a tooltip on the **header row**, which is a better home for it
anyway. Flagged in `docs/TESTING.md` §1 as the layout risk to look at.

**v0.5.5 — docs.** `docs/TESTING.md` rewritten for this build: a new §0 regression pass
(v0.5.0 rewrote four tooltips and the rank math internals with no intended number change),
and new §8 (Nature's Grace cast times via the `cast` category), §9 (Innervate's value via
the `regen` lines around the buff) and §10 (overheal over a raid night). §5 still
outstanding and now yields §9 as a by-product, so one good fight covers three tests.
`docs/DECISIONS.md` gained a v0.5 section recording the nine calls made without a debate
round, each with what would change my mind, plus a table of the four remaining assumptions
and the log line that settles each. `CLAUDE.md`'s file table updated for the four new files.

**State:** v0.5.4 built to `dist/combat-log-design-arch-ffb907/`, tree clean, branch
`claude/combat-log-design-arch-ffb907` (6 commits ahead of master, not merged).

**Next session:** whatever the author's logs say. In priority order — TESTING §0 (did
anything regress), §8 and §9 (turn two assumptions into measurements), §5 (`K_SIGMA` /
`CV_STABLE`), §10 (overheal after a night). Then Phase 2, Priest first, on the seams
`Engine/ManaCooldowns.lua` and `RankMath:Context()/RowFor()` now provide.

## 2026-09-05 (later) — First real dungeon log analysed; v0.6 designed

Author supplied `.logs/dungeon-BF-1.txt` — Blood Furnace, 28.8 min, 5600 lines, 30 pulls,
355 casts, on a **v0.5.x** build (it carries `cast` lines and the v0.5.2 cooldown
segment). **Caveat the author supplied and that runs through the whole design: it was a
level 61 dungeon on a level 64 druid.** Heroics and raids differ in duration and damage
pattern, so nothing from it is set in stone — which is itself the argument for
self-calibration.

**What the log proved**

- **A real display bug.** `OOM 0s vv` in red at 72-97% mana, 9+ times. `hold` sets
  `s.bound`, not `s.tto`; the mode latch holds `disp.mode == "oom"` for two ticks after the
  state improves, so the display reads `state.tto`, gets nil, and `v = v or 0` fabricates
  zero seconds straight into the critical band. v0.5.2's segment then appended `inn >10m`.
- **The combat log's `amount` is GROSS.** 561 events with `amount == overheal`, zero with
  `amount == 0`. So the pre-v0.5.3 fight-summary formula `o/(a+o)` understated: real
  overheal for the run is **38.0%**, not 27.5%. The v0.5.3 detector would have latched
  correctly within seconds. Detecting rather than assuming was the right call.
- **Per-spell overheal spans 5x**: Regrowth direct 10.8%, Swiftmend 25.7%, Lifebloom tick
  38.2%, Rejuv tick 45.0%, Lifebloom bloom 49.8%, Regrowth HoT tick 51.2%.
- **Cast mix**: Lifebloom 69% of casts / 54% of mana; Healing Touch **one cast in 29
  minutes** (Tree form). The dashboard opens on Healing Touch. ~7% of mana went to buffs,
  dispels and form shifts, invisible to every view.
- **The clock works when it matters.** My first read called it noise; the author corrected
  me ("most fights were easy, but there was one where I went full out"). On that pull —
  154 mana/s, -508 net mp5, 6.2k in 40s — it tracked `5:00 -> 3:00 -> 2:00 -> 1:00`
  monotonically and showed `inn 3:30` at 49% mana / 80s. The v0.5.2 cooldown segment
  validated in its first real test. `sigma/net` separates that pull (median 0.43) from
  everything else (median 1.01), which is the whole fix: gate the digits, don't retune.
- **Innervate never cast**, so its value model is still unverified; all four potion alerts
  ignored. Nature's Grace inconclusive — 27 cast lines, all Regrowth at exactly 2.00s, and
  Naturalist is 0 (the debug line would print 1.50s base otherwise).

**A correction worth recording.** I claimed TBC exposes no role API, having checked
`Cell/Utils.lua` and `Libs/LibGroupInfo.lua`. The author pushed back ("cell already renders
role icons"). They were right: `RaidFrames/UnitButton_Vanilla.lua` — the file
`Cell_TBC.toc` actually loads — calls `UnitGroupRolesAssigned(unit)` unguarded, and
`roleIcon` ships enabled by default in `Layout_Defaults_TBC_Vanilla.lua`. Bad inference
from absence: I checked the files I expected to hold it and stopped rather than following
the feature to the file that draws it. Role is now **read, not inferred**, with
`roleSource` carried into every report.

**Shipped meanwhile:** v0.5.6, fixing the debug console's category filters — adding a
ninth category (Cast) overflowed a chained single row (~603px in a 580px frame) and
collided with the "keep lines" box at the same y. Now a fixed 5-column grid whose row count
follows the category count, console 580x480 -> 700x560.

**Written this session:** `docs/DESIGN-v0.6.md` (452 lines: architecture, the C1
calibration design, the waste report's dimensions, delivery order v0.6.0-v0.6.6, open
questions), `docs/DECISIONS.md` §v0.6 (nine calls with what would change my mind), and
`docs/PLAN.md` Phase 1.5.

**Priority, set by the author:** C1 self-calibration -> A waste report -> D1 logging -> B1
pull budget -> D2 Cell (investigate; they have the upstream maintainer's ear). Logging
(v0.6.1) ships before the waste view because the role dimension rests on
`UnitGroupRolesAssigned` returning real values in the author's groups, and the roster log
line is what proves it.

**Next:** implement v0.6.0 (HP5 redefinition + the two clock fixes + small fixes). Nothing
in v0.6 touches `K_SIGMA` / `CV_STABLE`, which remain `docs/PLAN.md` §1a.


## 2026-09-05 (implementation) — v0.6.0 to v0.6.6 shipped

Author reviewed `docs/DESIGN-v0.6.md` (published as a page), made one change — **remove
HP5 rather than redefine it** ("it does not provide new insights": chain-casting in the
5SR it reduces to `5 x castingRegen x HPM`) — and said to proceed. Seven releases, in
the design's order, each luaparser-checked and built; nothing run in-game yet.

**v0.6.0** — the red `OOM 0s` is gone: the tick keeps the last shown value while the mode
latch holds `oom` over a `hold` state, and the display renders `OOM --` when there is
none; `v or 0` deleted. Digits gated on `sigma/net <= db.oomConfidence` (0.7, a
percentage slider with its provenance in the tooltip): above it the clock shows the bound
`OOM >2:00 =`, `rest` shows unconditionally, the cooldown segment stays off; digits return
after two confident ticks. Re-derived inside `oom` mode only: hard pull median 0.41, quiet
median 0.73 — 0.7 keeps all six hard samples and drops 55% of quiet digits (not the 80%
first claimed, which had mixed in `hold`). HP5 column removed. Dashboard opens on the
most-cast family (`MD.cdb.familyCasts`). Advisor names the richer cooldown it is holding.

**v0.6.1** — `Engine/Targets.lua`: roster with class, role and **roleSource**, role read
from `UnitGroupRolesAssigned` → `GetPartyAssignment` → class-implied → unknown. Logs:
Copy prepends `MD:Snapshot()`; `roster:` at each pull; `shown:` on every display change;
`cooldown used:`; the `cast` line applies Naturalist only to Healing Touch (it applied it
to everything — harmless at rank 0) and states the Nature's Grace rank. `/md export` TSV.

**v0.6.2** — `Engine/Calibration.lua`: observed / predicted per spell and event kind, crits
separated (rate checked independently), no decay (a ratio is gear-invariant), reset only on
a changed talent build (TALENTS_CHANGED fires at every login, so the summary string is
compared). Lifebloom stack fitted from x1/x2/x3, ambiguous ticks skipped and counted; events
within 2s of a form change skipped. 3% drift alert at n ≥ 30 — the Idol case was 3.2%, a
5% line would have missed it. `RankMath:EventPrediction()` on `Explain()`. `/md calibrate`.
**Caught before shipping:** the same `a and f() or b` truncation of `Overheal:Split` that
v0.5.3 fixed once already in `UI/Summary.lua`. Now in CLAUDE.md as a named trap.

**v0.6.3** — `Engine/Overheal.lua` rewritten: six dimensions (family, spell, spell:kind,
role, class, per-target), two stores (persisted decayed / session undecayed; targets only in
session, pruned on `ROSTER_CHANGED`), wasted-mana attribution per event kind (cost/ticks;
cost; hybrid half/half; AoE cost/(ticks×group); bloom 0). `UI/Dashboard_Waste.lua`: the
fifth tab, by Spell / Role / Class / Target, session or all; any class. Spend tracker keeps
per-family spend for session and fight, "other" catching buffs/dispels/forms; the fight
line gains `(LB 52%, RG 22%, ...)` and `~1.5k into full health`.

**v0.6.4** — Lifebloom rows weighted tick/bloom separately via `OH:KindFraction`; the
callout says "keep the stack rolling" or "let it bloom" with both fractions and effective
HPMs. Life Tap counted per member from `SPELL_CAST_SUCCESS`, shown as `Life Tap xN` in
Target mode.

**v0.6.5** — `Engine/PullBudget.lua`: median mana per pull in this zone → "2 more, or 4
after a drink", in the OOC tooltip and as the drink reminder's text.

**v0.6.6** — docs. `docs/TESTING.md` §0b (v0.6 regression), §11 calibration, §12 Waste +
the roster question (are roles actually assigned in the author's groups?), §13 pull
budget, §14 export. `CLAUDE.md` file table and conventions (calibration never feeds the
model; the multi-return trap; constants from one log are settings). `docs/DECISIONS.md`
§v0.6 items 10–13.

**State:** branch `claude/combat-log-design-arch-ffb907` at v0.6.6, 11 commits ahead of
master (master is at v0.5.5). `dist/combat-log-design-arch-ffb907/` built. **Nothing in
v0.6 has run in-game.** The two things I most want from the next logs, in order: the
`roster:` lines (does `UnitGroupRolesAssigned` return roles in a guild premade?) and
`/md calibrate` after a night (are the ratios 1.000 — and how many Lifebloom ticks were
skipped for stack ambiguity?).

**Still open from before:** `K_SIGMA` / `CV_STABLE` (§5), Nature's Grace 0.5s (§8 — needs a
Healing Touch in caster form), Innervate's value model (§9 — never cast), haste (unmodelled).

**v0.6.7 (same day)** — relics. Author: "can't we just check if it's equipped?" — we do,
and the framing was wrong: the slot check applies a known idol exactly; calibration is for
the *value* when it was never measured. `verify` is now data; the drift alert names the
equipped relic and solves for its true value. Looked every ID up instead of trusting memory
and found two wrong entries (Idol of Health is a cast-time relic; Emerald Queen is +88 to
the HoT total, not +47/tick) and one wrong ID (Budding Life is 33508, not 33076). Added the
TBC cost-only idols (Budding Life, Crescent Goddess) and cast-time relics as kinds. Sources
in `Data/SpellData.lua`.

## 2026-09-05 (evening) — First regression logs on v0.6.7; v0.6.8

Author ran `/md verify`, a `/reload`, `/md profile` and `/md spamtest` (`.logs/regression/`).
**A respec happened between the two sessions**: the talent line now reads Intensity 3,
Dreamstate 3, Lunar Guidance 3, Moonglow 3, Nature's Grace 1 / Gift of Nature 1, Improved
Rejuvenation 3, Naturalist 5 — a Dreamstate build, **no Tree of Life**. Everything Tree-
specific is dormant; calibration's reset-on-build-change is exactly for this.

**Passed:** verify (0 cost mismatches), spamtest (13 predicted, 13 measured), the snapshot
header on every Copy, the overheal convention latching GROSS on the first heal, the
shown-string and cooldown log lines, `Drink.` falling back correctly with no fights recorded.
**Nature's Grace confirmed:** two casts after a crit at `live 1.50s`, the rest 2.00s.

**Calibration caught a real error on its first run.** Regrowth R9 direct: observed 1282
(11 non-crit), model 1488, ratio 0.862. Two things at once: (1) the model was reading the
Simulate strip — the implied simulated +healing is exactly 2400, a round number the author
had typed for TESTING §7 — so `EventPrediction` now uses `Context({ live = true })`; (2) with
live inputs the model was 1172, still 9% low, and the one HoT tick (209 observed vs 232
predicted) pointed at the split: **Regrowth's +healing is split by base amounts
(0.286 / 0.701), not by coefficients (0.166 / 0.994)** — the amount-weighted split predicts
the tick at 209.3. Switched; DECISIONS §15. A +3.7% residual on the direct remains and is
not the idol.

**Also fixed:** `GetSpellCooldown` returns the GCD for 1.5s after any cast, so "cooldown
used: Innervate" fired on every Regrowth (≤1.6s now means ready); the author's own heals
were filed under role UNKNOWN when solo (now `HEALER (self)`); `/md verify` compares against
the model's cast time so Naturalist no longer counts as 13 mismatches. **Relic:** the author
wears Communal Idol of Life (186054), an Anniversary green: +15 Rejuvenation, added,
unverified. **Open:** the `/md profile` paste was a 0-byte file — bug or paste failure
unknown (TESTING §2b).

**Still to test:** §0b, §2b, §12 roster in a group (the biggest unknown), §5, §9, §11 after
a night, §13, §14. Committed as v0.6.8 and fast-forwarded into local master; not pushed.

## 2026-09-05 (night) — v0.7 designed: combat simulation and fight review

Author asked for a combat simulator: presets for party size, incoming damage and starting
situation, overrides per target, and a search for the cheapest human-castable strategy that
keeps everyone alive. Wrote `docs/DESIGN-v0.7.md` (published as a page for review).

**Author's review reframed it.** Three points: (1) "wait" is a valid action — in a
non-heroic 5-man the less you drink the faster the run; (2) **replay is the killer
feature** — analysing real dungeon logs and suggesting improvements, so the healer
self-improves with each iteration; (3) the made-up damage numbers get replaced by presets
generated from recorded fights, and the hard-coded ones improved from logs over time.

**Rev 2 of the design** puts recording first: `Engine/FightRecorder.lua` captures per fight
every hit the group took, every heal anyone *else* landed (negative damage on the timeline
— which dissolves the "other healers" problem for replays), the healer's own casts and mana,
and HP snapshots; persisted, last 12 fights, capped at 4,000 events each. The simulator
takes damage as a **timeline** (recorded) or **analytic** (rate + pulse), both just events.
Review pane: **Validate** (real casts must reproduce the real mana and HP curves — the
engine is proven before any planner work) and **Coach** (the search on the real damage, then
each actual cast classified against the best plan's rules with six labels: fine / overheal /
rank / spell / early / idle; summed over fights into **habits** with their mana). Presets
from recordings carry provenance. Delivery: recording first (it needs runs to gather
material), engine + replay second, planner third, synthetic setup last.

**Open before implementation:** whether `UNIT_SPELLCAST_SUCCEEDED` carries the target on
this client (assumed not; cast→first-heal matching with a reported match rate); whether
`SWING_DAMAGE`'s amount is after absorbs; recording size in practice; the six labels'
sufficiency. Eleven contested calls in §12 — the author's debate round is on offer.

## 2026-09-05 (late) — v0.7 debated, decided, specified

Author: run the debate, make every crucial decision, produce a spec a fresh Opus session can
implement from. Also pointed at Details! for combat-log parsing.

**Details settled two recorder questions before the debate:** `SPELL_CAST_SUCCESS` carries
`destGUID` (the cast's target — no cast→first-heal matching), and `amount` on damage is HP
actually lost, `absorbed` separate, full absorbs as `*_MISSED ABSORB`; exact arg layouts in
`docs/SPEC-v0.7.md` §1.

**The debate:** two Opus parties (theorycrafter / healer pragmatist), rebuttals, Fable judge —
all six papers preserved in `docs/debates/v0.7-sim/`. The parties converged on most calls; the
judge ruled the rest and verified both parties' log numbers (gates pass 18/25/13 of 30; median
pull 24.6 s, 6 casts; LB→LB gap median 5.02 s; inter-cast gap p10/p25 1.50/1.52 s). The three
corrections that mattered most: the planner must be **causal** (B — otherwise it sells
prophecy as advice), **cast commitment** (B — the design's re-decide loop gave the sim a free
option), and the design's simulation cost was **10× optimistic** (A). Two log-proven traps:
HoTs ticking 19 s before the pull (initial state), and 10 form shifts = 3.3k mana plus a
healing multiplier the sim was blind to. Everything else is in DECISIONS §v0.7.

**Written:** `docs/SPEC-v0.7.md` (file-by-file: the `kind` enum, capture list, stream layout,
retention, `SpellKit`, `Run` and its zero-allocation rule, the causality invariant text, the
plan schema with parameter domains, the lexicographic score, the six gates with settings and
provenance, the label rules and precedence, the card template, self-tests, `.toc` positions, a
crosswalk to the judge's 28-item checklist) and **`Data/SimFixture_BF1.lua`**, generated from the
log — 19 casts, 90 mana samples, 5 form events, initial state — so the engine's mana half can be
validated before any fight is recorded.

**State:** branch at the spec commit, fast-forwarded into local master, not pushed. **Next
session:** implement v0.7.0 from `docs/SPEC-v0.7.md` §2; nothing in v0.7 re-opens a ruled call
without new in-game evidence.

## 2026-09-06 — v0.7.0: HP-at-cast, the pre-pull ring, plan-free labels

Author: "now as we have the specs — implement them." First step of `docs/SPEC-v0.7.md` §0.

**What shipped (spec §2, all of it in `UI/Summary.lua` plus two one-line settings):**

- **Own-cast capture.** The single combat-log handler now also takes `SPELL_CAST_SUCCESS`
  from the player and records `{ t, spellID, cost, tgt, hpAtCast, form, kind }`. The cast's
  target comes from the prefix `destGUID`/`destName` (settled against Details!, spec §1), so
  there is no cast→heal matching anywhere. `kind` is `shift` (seven shapeshift IDs), `heal`
  (`SD.families` member) or `utility` (everything else priced — Innervate, buffs, dispels).
  **Anything unreadable is −1, never 0** — the OOM-clock bug that fabricated a zero is the
  reason that rule exists.
- **The 20 s ring** (`MD.Recorder.ring`), pruned on append, copied into `fight.precasts` at
  `PLAYER_REGEN_DISABLED`. The log's proven trap — HoTs ticking 19 s before the pull — is now
  visible to the addon at the moment the pull starts.
- **HoT tick ownership.** A Rejuvenation/Regrowth/Lifebloom cast record owns the ticks that
  follow it (`ticksSeen`, `tickGross`, `tickOver`, keyed `guid\029family`). That makes both
  derived labels measurements rather than guesses: `early` is "≥2 ticks were still pending"
  and `prehot` is "its pre-pull ticks were ≥50% overheal". Lifebloom is tracked but exempt
  from `early` — refreshing it before the bloom is the play, which is the correction the
  debate made to the original design.
- **Plan-free labels** at `PLAYER_REGEN_ENABLED`, precedence `utility → shift → early →
  overheal → ok`, one per cast, with the identity `sum(labels) == fight spend` printed in the
  new **`sim`** debug category and shouted as `label identity BROKEN` past a 2%/50-mana
  tolerance. The two figures come from different sources on purpose (combat log vs
  `UNIT_SPELLCAST_SUCCEEDED`), so the check is real.
- **The summary line**, exactly the spec's format:
  `14 of 19 casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 -
  utility/shifts 1.6k - buffed in combat: Mark of the Wild at 0:39`, plus a second line when
  anything was pre-HoTted onto a full-health target.
- **History to 200 rows** with `labels`, `labelCasts`, `hpBuckets`, `prehot`, `lowestMana`,
  `ownCasts` (`foreignShare`/`streamID` wait for v0.7.2), and a new gate: a fight under four
  own casts is no longer recorded at all — it says nothing about how the healer played and
  would poison both the spend seed and the habit counts.
- `db.simFullHp = 0.85` (a setting with provenance, not a constant) and the `sim` debug
  category in the console grid.

**Two judgement calls the spec left open.** The "N of M above 85%" clause counts *health at
cast*, independent of which label won the precedence, so an early refresh on a full tank is
counted in both places — the alternative made the headline number depend on label ordering.
And `hpBuckets` counts heal casts only; a shapeshift's "target health" is the player's and
means nothing.

**Verification:** syntax-checked (no Lua interpreter here; the harness is the python
checker). The real check is in-game and is written up as **TESTING §15** — it depends on §12
(roster/`UnitGroupRolesAssigned` in a group), because `hpAtCast` resolves through
`Targets.byGUID[guid].unit`. Solo, only the player's own health resolves.

**Next:** v0.7.1 — `RankMath:SpellKit`, `Engine/SimModel.lua` (mana half), `/md simrun`
self-tests, `/md simreplay fixture` against the already-generated `Data/SimFixture_BF1.lua`.

## 2026-09-06 — v0.7.1: the simulation engine, and a real test harness

**The biggest thing that happened is not in the addon.** There is now
`tools/run.sh tools/simcheck.lua`: a WoW API stub (`tools/wowstub.lua`) plus a real Lua 5.1
that `tools/run.sh` downloads and builds into `tools/.lua` on first use. It loads the actual
non-UI files and runs `/md simrun` and `/md simreplay fixture` outside the game. The repo has
never had a way to execute its own logic before, and it immediately earned its keep — see the
sample-ordering bug below. Keep `tools/harness.lua`'s file list in step with the `.toc`.

**Shipped (spec §3):**

- `RankMath:SpellKit(opts)` — every known rank of every family flattened to plain numbers,
  once per form, from `Context({ live = true, healer = ... })`. This is the only boundary
  between the rank math and the engine; the engine never calls `RowFor`. Crit is stripped
  from `direct` on purpose (the engine decides expectation vs roll). Swiftmend is valued off
  the highest known Rejuvenation/Regrowth; Tranquility is carried with `dataMissing = true`
  because `Data/SpellData.lua` has no heal values for it and a planner must not invent them.
- `Context(opts)` gained `opts.healer`, applied exactly where the Simulate strip's overrides
  are and nowhere else.
- `Engine/SimModel.lua` — the engine. Binary heap over parallel arrays keyed `(t, prio, seq)`
  for ticks, expiries, committed casts and decisions; recorded timelines (damage, foreign
  heals, forms, rates, script) read by **cursor**, never copied, so a 1,500-event fight costs
  three integers of state; per-run scratch from a reused pool slot. Scripted runs (replay,
  self-tests) and deciding runs (v0.7.4) share one code path.
- `/md simrun` — ten assertions, all passing: heal amount against the dashboard row, chain
  casts against `CastsToOOM`'s closed form, ticks dropped on refresh, one bloom per Lifebloom
  stack, Swiftmend eating Regrowth before Rejuvenation, nothing landing on a corpse, the 5SR
  switching rates at exactly 5.0, the GCD holding two instants 1.5 s apart, and Run's cost
  being flat in the timeline length.
- `/md simreplay fixture` — replays `Data/SimFixture_BF1.lua` and prints **three** numbers.

**Three spec corrections, all from evidence, all written up in DECISIONS §v0.7.1:** mana
leaves (and the 5SR restarts) when a cast *succeeds*, not when it starts — the log's `[mana]`,
`[spend]` and `5SR start` lines share the `UNIT_SPELLCAST_SUCCEEDED` timestamp; regen is
integrated continuously rather than in 2 s ticks; and a recorded sample sitting exactly on an
event's timestamp is read after **every** event at that instant. That last one was a genuine
bug the harness caught — a cast sharing its timestamp with a form change was sampled before it
had paid for itself, which put the fixture's worst error at 13.7%. Fixed: **2.8%**.

**Fixture result:** spend reproduced exactly (6169 vs 6169), `measured` mean **1.3%** / max
**2.8%** of pool — inside spec §3.9's 2% / 5% gate.

**And a finding worth more than the engine.** The fixture cannot be reproduced by the regen
model alone: over 40 s continuously in the five-second rule the player gained 2072 mana while
`GetManaRegen` accounts for 1141. The missing 931 (23 mana/s, **116 mp5**) arrives as two
clean periodic streams visible in the log — exactly 17 every 2.00 s, and bursts of 13-15 on a
~3 s cycle. Dreamstate is ruled out (no points in it). Blessing of Wisdom from the party's
paladin fits the first stream and would be invisible to `GetManaRegen` for the same reason
drinking is. Nothing has been added to the model: `docs/TESTING.md` **§16** is the in-game
test that settles it, and it is now the most valuable thing on the testing list.

**Drive-by:** `lbHot` / `lbBloom` in `RowFor` were globals — correct by luck, but `_G` writes
on a path the dashboard runs every 2 s.

**Next:** v0.7.2 — `Engine/FightRecorder.lua` (full streams) and the `/md export` recording
section.

## 2026-09-06 — v0.7.2: the fight recorder

`Engine/FightRecorder.lua` (spec §4). The full stream of one pull as parallel arrays of
numbers: damage on tracked targets (minus overkill), full absorbs, foreign heals, own casts,
own heals and ticks with the crit flag, cast starts with a synthesized `CANCEL` when no
success follows, form changes, mana samples every 2 s, HP snapshots every 5 s, deaths, the
initial aura scan and the 20 s pre-pull ring. Indexed by the **same session roster the v0.7.0
cast records use**, so a precast's `tgt` and a damage event's `tgt` mean the same person with
no translation anywhere.

Tracked is the party in a 5-man and the player's subgroup plus main tanks in a raid; nothing
about an untracked unit is recorded at all. Gate `dur >= 20 and ownCasts >= 5`; eight streams
kept, and the one that goes is the cheapest fight that is neither pinned nor one of the three
most recent — mana spent is the proxy for "did this pull have anything to teach". `/md export`
gained the `# recording n` blocks (roster, initial, precasts, ev, hp, mana).

`UI/Summary.lua`'s single handler now unpacks the 11-field prefix plus ten generic payload
slots and forwards them; the recorder decides what is worth keeping. That keeps the promise of
one `CombatLogGetCurrentEventInfo()` call per event.

**`tools/reccheck.lua`** drives a whole fake pull — a party of five, damage on the tank and the
mage, own casts including a utility buff, a Rejuvenation refreshed with ticks pending, a
Lifebloom on a full-health target, a foreign heal, a death, pre-pull HoTs that all overheal —
through the real handler, and asserts twenty things about the stream, the labels, the summary
row and `/md export`. All twenty pass. It found two real bugs while being written:

- `FightRecorder:Start` snapshotted the roster **before** the tracked set assigned indices to
  group members nobody had healed yet, so every stream's roster had one entry.
- and (in the test itself, which is worth recording because it is the trap CLAUDE.md names)
  splicing a helper's eleven return values into a non-final argument position truncated them
  to one, silently swallowing every scripted combat-log event.

**Next:** v0.7.3 — the HP half of replay, the six gates, `/md simreplay [n]`, Validate.

## 2026-09-06 — v0.7.3: replay, and eight gates a fight must pass to be coached from

`SM.ScenarioFromRecording(rec, kit)` turns a recorded fight into a scenario: everything the
healer did becomes a script (the recorded casts at their recorded costs, in the recorded
forms, against the recorded regen rates), everything that happened to the group stays the
recorded timeline. **The engine ignores the recorded own-heal events entirely and generates
its own from the spell kit** — that is the whole point. If the model's Rejuvenation is wrong,
the health bars will not come back, and the gates say so instead of the Coach quietly building
on a bad model.

The engine gained a second sample cursor so health is sampled on the recorder's own 5 s
schedule while mana keeps its 2 s one; merging them would invent readings neither stream has.

`SM:Validate(rec)` runs the eight gates from spec §7, each printing the **provenance of its own
threshold**: mana mean (2% of pool) and max (5%), health per target (5% mean / 15% worst of
max health), no tracked death, foreign share (25%), model calibration (3% drift on any spell
worth ≥ 10% of the fight's spend; "not yet calibrated" is printed, not failed), and spend
coverage (≥ 90% of the mana on spells the model prices). `/md simreplay [n]` prints the lot
with a verdict; `MD:ValidationReport` is what the Review tab's tooltip will show.

Two judgement calls while writing it, both tightening the gates:

- **A target that misses is excluded, not fatal.** One pet-heavy warlock should not
  disqualify the tank's timeline. The health gate passes if at least one damaged target
  reproduces, and names the ones that did not.
- **A target that took no damage is not scored at all.** It reproduces itself perfectly and
  proves nothing; the first cut counted two untouched party members as passes, which made the
  health gate meaningless. `tools/reccheck.lua` caught it.

`Engine/Calibration.lua` gained `CAL:Drift(spellID)` — worst |ratio − 1| over event kinds with
enough samples, `nil` when uncalibrated. `nil` means "unknown", not "fine", and the gate says
so.

**Verified:** `tools/run.sh tools/reccheck.lua` now 25 assertions, all passing, including that
the scripted pull — which has a death and 69% foreign healing — is **rejected**. A gate suite
that passed everything would be worth nothing.

**Next:** v0.7.4 — `Engine/SimPlanner.lua`, the rules plan, the classifier and the card.

## 2026-09-06 — v0.7.4: plans, the classifier, and the card

`Engine/SimPlanner.lua`. The causality invariant from spec §5.2 is pasted at the top of the
file, and the code keeps it: `Plan:Decide` reads the present state plus exactly one derived
input, each target's trailing-5 s damage, which the engine now maintains as a fixed circular
buffer per target (allocation-free after warm-up). The engine also grew spell cooldowns
(Swiftmend's 15 s) and a `plan:Reset()` call, so a plan that caches its anchor cannot carry it
between two runs the search is comparing.

A plan is five bound spells and five rules in a fixed order, with small parameter domains.
That is a deliberate constraint, not a simplification: "rank 7 here, rank 9 there" is not a
strategy a person can execute in a heroic, and the point of a card is that it can be followed.
Binds default to the ranks the player actually cast in that recording.

Score is the lexicographic tuple `(deaths, floorSeconds, manaSpent, -heldOn, #binds,
overhealSim)`, compared element-wise. Nothing is blended into a scalar — a plan that lets
somebody die is not redeemed by saving mana, and no weight exists that says otherwise.

The classifier runs the best plan **in lockstep** with the replay: at each real cast the engine
calls back with the recording's own state and the plan is asked what it would have done then.
Eight of the ten labels come from that. Two cannot — `late` and `idle` are about moments the
plan wanted and the player did not act — so they come from running the plan alone and
comparing timelines. **The card says so in its caveat line** rather than blurring the two.

The card leads with a verdict that is allowed to say *"you had 2.1k headroom — nothing here
needed to change"*, because most pulls do not need coaching and a card that always finds
something is a card nobody trusts twice. `SP.Mark` / `SP.Progress` close the loop per zone:
after three later fights there, the Review tab can say what actually changed.

`/md coach [n]` — and it **refuses** a fight that failed §18's gates, listing which ones;
`force` overrides and puts the failures in the caveat line.

**Verified:** `tools/reccheck.lua` is 30 assertions. The classifier's mana identity holds
exactly (2199 labelled vs 2199 spent) and the coach's refusal path is tested as well as the
card, because silence on a bad fight is the more important behaviour.

**Next:** v0.7.5 — the coordinate-descent search.

## 2026-09-06 — v0.7.5: the search

Coordinate descent from four seeds (max-rank baseline, HoTs-only, the player's binds with
default thresholds, one random point), sweeping one parameter at a time over its small domain
and accepting improvements until a full pass changes nothing. At most 300 evaluations, with
the incumbent's mana as an early-abort bound on every candidate. Alternates within 5% of the
winner with fewer binds are collected for the card's tooltip. Full-grid enumeration was
rejected in the debate and stays rejected; coordinate descent can stop on a ridge, so the
alternates are listed rather than hidden.

**The bug worth recording: `GetTime()` does not advance inside a frame.** It is the frame's
timestamp, so slicing the coroutine on it (`while GetTime() - started < 8ms`) would have run
the entire search in one frame and frozen the client for seconds — in exactly the moment the
feature is wanted, between two pulls. The search now slices on `debugprofilestop()`, the
sub-frame clock, with a fixed resume count as the fallback when it is missing. Both paths are
exercised by the harness.

Two more corrections the harness forced:

- **The physical-floor assertion only holds when nobody died.** A plan that let a target die
  did not have to heal the damage that target took, so the bound does not apply; the first run
  printed `IMPOSSIBLE, engine is wrong` about a plan that was merely allowed to lose someone.
- **Binds are the five families a rule can use.** They were being built from every family in
  the spell table, which put Tranquility in the count (6 binds, and the score's tie-break
  cares) — and Tranquility has no heal values in `Data/SpellData.lua` at all, so no plan may
  spend mana on it.

`/md coach [n]` now searches before drawing the card, across frames, with `/md coach cancel`.
`heldOn` — whether the winning plan also survives the other retained recordings — is computed
after the search, because that is the difference between a strategy and a curve fitted to one
pull.

**Verified:** `tools/reccheck.lua` is 34 assertions. The search finishes inside its budget,
beats the max-rank baseline it was seeded with, and yields across frames.

**Next:** v0.7.6 — the Review tab.

## 2026-09-06 — v0.7.6: the Review tab

Sixth dashboard tab after Waste, following `Dashboard_Waste.lua`'s pattern (constructor on
`MD.DashboardParts`, shown when `currentFamily == "Review"`). One row per recorded fight —
when, zone, duration, targets, casts, spend, mana low-water mark read back out of the recorded
samples — and a **validate** column that is blank until asked, because replaying is not free.

The validate column is the point of the tab. A fight the engine cannot reproduce is greyed,
shows the first gate that failed, and has its **Coach button disabled with the reason in its
tooltip**. Advice from a fight the model gets wrong is worse than no advice, and the UI should
say that rather than quietly produce a card anyway. The row tooltip carries all eight gate
results, the foreign share, and which targets were excluded and why.

Below the list: habits over every summary that carries labels (top three by mana, `ok` never
counts), and the since-your-last-card line once three fights in that zone have happened.
Pin protects a recording; Export is `/md export`.

Also `/md options` → General → **Fight recording**: the record toggle, "let Coach change
ranks" (off by default — a card that silently rebinds everything is somebody else's strategy),
and the two thresholds a player might reasonably move. The gate thresholds and the search's
internals stay in `Core.lua`'s DEFAULTS with their provenance comments, because a slider
invites tuning and those numbers are meant to be argued with. The General tab is 470px tall
now to fit the fourth pane.

Two API notes for future UI work here: `Enable()`/`Disable()` rather than `SetEnabled`, and
`MD.Tip:Show(frame, anchor, lines)` takes the anchor as its second argument — both were got
wrong first time and only a careful read caught them, since no harness covers UI.

**Next:** v0.7.7 — `UI/SimWindow.lua`, `Data/SimPresets.lua`, `FromRecordings`, Monte Carlo.

## 2026-09-06 — v0.7.7: the Simulation window, and the end of the v0.7 spec

`Data/SimPresets.lua` (party / incoming damage / situation, plus `BuildScenario` which turns a
preset into events on a 1 s grid), `SimPlanner.FromRecordings`, `SimPlanner.MonteCarlo` and
`UI/SimWindow.lua` (`/md sim`).

**The header of the presets file is the important part:** every number in it is a placeholder,
one healer's impression of what a 5-man feels like, written down so the window has something
to run before any fight has been recorded. The window says so in grey, and **From recordings**
replaces them with `FromRecordings` measurement — per target, tagged by role, splitting a
steady rate from "big hits" (a second's damage worth ≥ `db.simBigHit` of that target's max
health) with p50/p90 sizes and the provenance string printed next to it.

Monte Carlo runs in the synthetic window and nowhere else — not inside the search, not on a
replay card, both of which the debate rejected. Thirty replicates with damage perturbed and
**crits rolled**, answering one question: how often does this plan lose somebody when the
fight is not exactly average? The first run answered it usefully — the mana-optimal plan on
the dungeon preset holds everyone deterministically and violates the floor in **every**
replicate. A plan that only works on average crits is a bad plan, and this is the only place
that shows it.

That test also exposed that `critMode = "roll"` had never been implemented (it silently
returned the non-crit amount). It now rolls a seeded LCG, so a replicate is reproducible on
any client and `math.random`'s global state is never touched.

`tools/simwindow.lua` covers the synthetic path: all 120 preset combinations build a scenario
with sorted events, the search completes on one, the winner is no worse than the baseline it
was seeded with, the replicates run, and — the assertion worth having — **the replicates
restore the damage array they perturbed**, since the scenario is reused by the caller.

**v0.7 is now complete**: v0.7.0 labels, v0.7.1 engine, v0.7.2 recorder, v0.7.3 replay and
gates, v0.7.4 plans and the card, v0.7.5 search, v0.7.6 Review tab, v0.7.7 simulation. Three
offline harnesses (`simcheck` 10, `reccheck` 34, `simwindow` 8) all pass. Everything that
remains is in-game: TESTING §15-§21, and §16 (the 116 mp5 the regen API does not report) is
still the single most valuable one.

## 2026-09-06 — the second mana stream has a name

The author, who was in that party: *"second mana stream was probably shadow priest."* That is
checkable, so it was checked — against the whole 28-minute `dungeon-BF-1.txt`, not just the
one pull the fixture was cut from.

It holds, and the check produced something better than an identification. The 116 mp5
`GetManaRegen` does not report is **two sources of completely different kinds**:

**A — exactly 17, every 2.00 s, 497 times, never once a different value.** In combat and out
of it in the same proportion as the time (380 / 117). This is the mp5 bucket: gear, an idol,
or Blessing of Wisdom — all `MOD_POWER_REGEN`, all landing on the server's 2 s mana tick,
none of it in `GetManaRegen`. 8.45 mana/s = **42 mp5 that belongs to the character**.

**B — 13-15 at a time, on a 3.00 s beat.** The signature is unambiguous: **55% of its 378
events have a partner exactly 3.00 s later**, against a 9% baseline at 3.5 / 4 / 5 s, with one
to four phases overlapping (a burst of five inside 0.3 s, then the same burst 3.00 s later).
**373 of the 378 are in combat** although combat is only 57% of the log. And per pull it
yields between **0.0 and 17.6 mana/s** — exactly zero in two of the thirty.

5% of a shadow DoT ticking every 3 s is precisely that shape, which is Vampiric Touch, which
is the shadow priest. The log records names only — no classes — so this is corroboration
rather than proof, and the one thing that does not fit is that Vampiric Touch is a level-70
spell.

**The ruling does not depend on naming the spell**, and that is the part worth keeping:

- **A is a number about you** and may enter `RM:Unreported()` one day, by the same route
  Dreamstate did: an in-game measurement, never a guess.
- **B must never enter the model.** It is not yours, it is not in every group, and it is zero
  in two of the thirty pulls in the only log we have. A clock that quietly assumes a shadow
  priest is wrong precisely on the pull where being wrong costs someone their life. The
  recorder's treatment — measure it per fight, replay what was measured — is the only correct
  one.

Changed: `Data/SimFixture_BF1.lua` no longer presents 23.1 mana/s as one number with one
cause, and its roster classes are now marked **unverified** (they had been carried over from a
mockup table in `docs/DESIGN-v0.6.md`; the log has no class data, and at least one of them is
wrong). `docs/DECISIONS.md` §v0.7.1 carries the ruling. `docs/TESTING.md` §16 is rewritten as
a three-step test that separates A from B — solo, then with a paladin, then with and without a
shadow priest.

`/md regentest` gained a **tick histogram**: gain sizes clustered within ±1, each with its
count and its beat — the reported spirit tick, a 2 s beat (printed as the mp5 it implies) and
a 3 s beat ("a party energize, not yours"). A size is what a source gives; a cadence is which
source it is. That is the whole decomposition above, on one chat line, in 30 seconds, instead
of a script over a 400 KB log.

The beat is measured the way the log was read by hand — the share of a cluster's events that
have a partner exactly one period later — and **not** as a median spacing, because a median
is exactly what fails here: four overlapping 3.00 s phases read as ~1 s apart. `tools/
regencheck.lua` (new, 8 assertions) drives `/md regentest` against a scripted stream of that
shape and asserts the histogram recovers it.

No model behaviour changed. All harnesses pass (simcheck 10, reccheck 34, simwindow 8,
regencheck 8) and the fixture still replays at mean 1.3% / max 2.8%.

## 2026-09-06 — v0.8 specified: a replay that plays

The author's next feature, in their words: a replay window that renders two sets of unit
frames — what actually happened, and what the math suggested — "stupid simple" first (HP
bar, where each cast went), indicators added per iteration. Cell's layout preview as the look.

Three calls made in conversation, no debate round needed (it is a renderer over v0.7's
decided machinery): **one window, two columns, one clock**; **both columns from the engine**,
with the recorder's real 5 s HP snapshots drawn as ticks on the left bars so the
reconstruction's error is visible at every moment; **Play without a plan allowed** — the left
column is class-agnostic and works for any healer on day one.

`docs/SPEC-v0.8.md` written in the v0.7 shape: delivery order with a verifiable-by line per
version, the trace format (`SM.TK` kinds, fixed 0.25 s grid, drained strictly before the next
event — the v0.7.1 sample-ordering bug named so a second sampler cannot re-introduce it),
`Engine/ReplayTrace.lua` as a frame-free state machine so playback is harness-testable
(*seek == step* is the assertion), `SP.Replay` as the one call that builds both columns, the
window layout, the per-cast labels, and the recorder extension for defensive cooldowns and
debuffs (recorded, rendered, **never modelled** — the damage they changed was recorded as it
happened). A rejected list, so nothing gets re-proposed. `docs/PLAN.md` Phase 1.8 and
`docs/DECISIONS.md` §v0.8 carry the calls.

Nothing implemented yet; harnesses unchanged and green.

## 2026-09-06 — v0.8.0: the trace and the replay state machine

The engine can now write down what it did. `SM:Run(..., { trace = { dt = 0.25 } })` records
mana, form and each tracked target's HP on a fixed grid plus the discrete things between grid
points — cast start / succeed / cancel, HoT apply / end (with the bloom), deaths, form
changes, and the plan's waits — every one stamped with the `Plan:Decide` rule that caused it
(`why`; 0 on the recorded side, whose reasons are not on record). The grid is a third sampler
under the same rule as the recorded ones: drained strictly before the next event, so a grid
point on a cast's timestamp shows the mana *after* the cast paid — the v0.7.1 bug, asserted so
it cannot come back. Damage is not in the trace: it is identical in both columns by
construction and the window reads it from the scenario.

`Engine/ReplayTrace.lua` is the state machine the window will paint from, with no frames in
it: `Seek(t)` rescans from zero with the callback suppressed, `Advance(dt)` fires it for every
event crossed, and `Hp` / `Hot` / `Casting` / `Waiting` / `Score` answer for the moment.
Two rules stated in the file: nothing is interpolated (a heal is a jump), and events at t = 0
are initial state — a pre-pull HoT is in the state a fresh machine reports and never flashes.

`SP.Replay(rec, opts)` builds both columns in one call — the recorded casts on the left, the
plan on the right (the one passed in, else the one Coach now caches per fight in `SP.plans`,
so Play never searches), the classifier's per-cast labels (`cls.casts`, new) and the
recorder's real HP snapshots as fractions for the ticks.

`tools/replaycheck.lua` (27 assertions) drives the scripted pull — now shared with `reccheck`
as `tools/fakepull.lua` — and asserts the trace's shape, every own cast at its time, the
post-cast rule, the death, the fixture's pre-pull HoTs at t = 0, the grid agreeing with the
gate's own sampler to 1e-6, the right column's rules and wait lengths, and *seek == step* for
every accessor at ten times on both columns. Two of its first three failures were the
harness's own assumptions (the stub has no auras; t = 0 is initial state) — the third became
the rule above.

One thing seen and left alone: on the scripted pull the classifier labels a Lifebloom on a
full-health target `fine` when the plan wanted a Lifebloom on the anchor at that moment. The
v0.7.4 order says "same family, different target" before "target above 85%", which reads
wrong here; it is unchanged pending real pulls (the card's counts have not been seen in-game
yet), and the per-cast labels in the window will make it visible when it matters.

## 2026-09-06 — v0.8.1: the replay window

`UI/ReplayWindow.lua`: `/md replay [n]`, and **Play** on the Review row next to Coach. One
window, two columns of unit frames on one clock — ACTUAL on the left (the recorded casts
through the engine), SUGGESTED on the right (the plan Coach cached in `SP.plans`; without one
the window is a single narrower column and the hint says why). Per frame: role letter, name in
class colour, HP bar with the percentage, `dead` in grey. A cast flashes the target's border in
the family colour and prints `Regrowth R9` above the bar for a second; a foreign heal flashes
white; recorded damage washes the bar red in proportion to the hit — identical on both sides,
because the damage is. The recorder's real 5 s snapshots are **white ticks on the left bars**,
fading until the next one: the health gate's number, seen. The healer strip carries the mana
bar, the cast bar filling over the cast time (the right column shows `waiting 1.2s` while the
plan holds), and the running `spent / lowest / dead` line, which at the end equals the card.
A scrubber with markers (deaths red, big hits orange, the left column's casts as faint ticks),
play / pause, 1× 2× 4×, the clock. Position and speed persist (`db.replayPos`,
`db.replaySpeed`); the ticks can be hidden (`db.replayTicks`).

The file only paints. Every fact comes from `Engine/ReplayTrace.lua`; both states advance the
same `dt` from one `OnUpdate`; a seek clears every short-lived effect, because those belong to
events crossed while playing. No interpolation, no opening in combat, no search from Play.

**The window has an offline test**, the first UI file to get one: `tools/replayui.lua` loads
`UI/Style.lua`, `UI/Tooltip.lua` and the window under the stub — whose frames now store
text, values and colours, and whose no-op fallback is restricted to UpperCamelCase method
names so a frame can carry state fields — opens the scripted pull, plays it to the end one
0.1 s frame at a time, seeks, and reads back what was painted: five rows tank-first, the cast
text appearing on the tank, the pulse on the mage, the warlock reading `dead`, the strip's
`spent` equal to the recording's, no bare pipe in any painted string, the tick drawn on the
left and never on the right, the markers, the single-column path, the refusal in combat.
23 assertions. Three stub gaps surfaced on the way (fonts without `GetFont`, frames without
`GetFrameLevel`, and the fallback-eats-fields one); none were window bugs, all are the kind
that would have been a nil error on the first press of Play in-game.

Six suites green: simcheck 10, reccheck 34, simwindow 8, regencheck 8, replaycheck 27,
replayui 23. What only the game can answer is TESTING §23 — whether it *reads* at 1×.

## 2026-09-06 — v0.8.2: indicators and labels

The frames now carry what a healer's eye looks for. Three **HoT squares** under the role
letter — Rejuvenation, Regrowth, Lifebloom in the family colours — counting down their last
nine seconds as a digit; Lifebloom shows its stacks, brightens per stack, and goes **white in
its last second**, the bloom's warning. An orange **Swiftmend-ready dot** after them while
there is something to eat and the cooldown is up (`State:Ready`, from the trace's own casts
and `SM.SPELL_CD`, now exported). The classifier's **label under each left cast** as it
lands — `late` red, `overheal` orange, `early` / `stack` yellow — and the scrubber's cast
ticks in the same colours, so the fight's shape reads before play is pressed. On the right,
a **grey band** over the cast bar while the plan waits, and **hovering the bar names the
rule** behind the current cast (`rule 3: keep Lifebloom rolling on the anchor`) or says why
it is waiting — the `why` column from v0.8.0, rendered for the first time and the smallest
possible start of the coach-in-replay highlights the author reserved.

`tools/replayui.lua` grew to 33 assertions: during the play-through it sees the `early` label
on its cast, a Lifebloom square counting `1`, a Rejuvenation digit, the dot, a `why` on the
right bar, the band while waiting; the tooltip script runs without error; a labelled tick sits
on the scrubber; a seek clears the labels and no square shows at t = 0.

Six suites green. What only the game can answer is TESTING §24 — and the one question that
matters there: **did any label look wrong**, because that is how the classifier gets fixed.

## 2026-09-06 — v0.8.3: defensive cooldowns and debuffs, recorded and drawn

The recorder keeps two more things on tracked targets. **Defensive cooldowns** from a
whitelist (`Data/AuraList.lua`: Shield Wall, Last Stand, Barkskin, Evasion, Divine Shield,
Pain Suppression, every rank of Power Word: Shield, ...) — the author's example was a rogue
under Evasion, who is not urgent. And **every debuff**, capped at four per target and a tenth
of the stream's event budget, after which debuffs stop and `auraTruncated` says so while
defensives keep going. `K.AURA = 12`, appended; `x` carries the spell id plus a flag for
buffs, `amt` the stacks or -1 on removal. Every id in the list is from memory and marked
VERIFY: a wrong one costs an icon, never a number.

**Nothing in the engine reads them.** `ScenarioFromRecording` passes them through and the
loop ignores the kind: the damage a Shield Wall prevented was recorded as prevented. They
explain the dip; they do not cause it in the model. What they are the prerequisite for is
the reserved decision input in `docs/SPEC-v0.8.md` §7 — a plan that does not drop everything
for a target whose defensive is up — which waits for a recording that shows the case.

`Engine/ReplayTrace.lua` tracks them from the scenario's timeline (`State:Auras(ti)`, oldest
first, state whether or not visuals fire, cleared and rebuilt on a seek like everything else).
The window draws the first defensive as an icon with the accent border in front of the name
and up to three debuffs over the bar's right end with their stacks, `GetSpellTexture` under
`pcall` with a lettered grey square as the fallback, and a hover tooltip naming the aura, when
it was applied and for how long. `/md export`'s `# recording` line ends with the aura count.

The shared scripted pull gained a Shield Wall (kept), a Fortitude (not whitelisted, dropped),
a debuff on the mage stacking to two, and a debuff on a mob (untracked, dropped); `reccheck`
asserts exactly those four events, `replaycheck` that the state machine sees the Shield Wall at
5 s and not at 14 s and the debuff at two stacks, seek and step agreeing, and `replayui` that
the icons are drawn and hidden at the right times with their tooltips running clean.

**v0.8 is complete**: v0.8.0 trace, v0.8.1 window, v0.8.2 indicators and labels, v0.8.3
auras. Six suites green. TESTING §22–§25 are what only the game can answer, and the two
questions that matter most there are §24's "did any label look wrong" and §25's "would seeing
the tank's cooldown have changed what you cast".

## 2026-09-06 — v0.8.4: the first in-game replay, and what it corrected

The author recorded a 1v1 against an open-world mob and sent two screenshots. Four things:

- **Clarity.** The frame's cast text was anchored above the bar and collided with the strip's
  score line; the hint had no width and ran under the "ticks" checkbox; 11 px text on a 30 px
  row. Columns are 360 wide and rows 38 high now, names and numbers in the 13 px font, the
  **cast text and its label drawn inside the HP bar** (as Cell does), the scrubber on its own
  full-width row, the hint on its own line.
- **Instants blinked.** The spec said "flash the bar once" — wrong, and unreadable. An
  instant still costs the 1.5 s GCD, so the bar now **sweeps the GCD in grey** with the
  spell's name, and **the name stays, dimmed, until the next cast**. The strip answers "what
  was I doing", not "is a bar moving".
- **Real casts did not progress.** A bug: a recorded `CAST_START` carries no cast time, so
  the bar jumped to full and vanished. The trace is complete, so the state machine now takes
  the duration from the `CAST` (or `CANCEL`) that follows the start — the *recorded* cast
  time, for any spell, Insect Swarm included. The scripted pull gained a real cast start for
  its Regrowth so the harness can see the bar move.
- **Slow speeds.** 1/4× and 1/2× next to 1× 2× 4×.

Two smaller things from the same screenshots: "Lifebloom R1" (one rank; the rank is shown
only for families with more than one) and a lettered square where a Barkskin icon should be —
`GetSpellTexture` returned nothing on this client for that id, so the icon now also tries
`GetSpellInfo`'s third return and logs the id when both fail.

`tools/replayui.lua` asserts the bar progressing during the Regrowth, the GCD sweep after an
instant, the name persisting after the fight, and the five speeds. Six suites green.

## 2026-09-06 — v0.8.5: icons that sweep, like Cell

The author: "use icons, and instead of duration text a duration animation like Cell does" —
the top-to-bottom dimming over the icon. Done for the three HoT indicators (the spell's own
icon, 14 px, the elapsed share dimmed from the top with a 1 px spark at the edge; Lifebloom's
stacks bottom-right, its border white in the last second) and, since the recording knows when
every aura came off, for the defensive and debuff icons too — `State:Auras` now carries
`until_` from a look-ahead to the removal, so a Shield Wall's icon sweeps for exactly the
14 s it was up. Cell does it with a reverse-filled vertical StatusBar masking a desaturated
copy; ours is a plain overlay whose height the paint loop sets, which comes to the same
picture without mask textures. One icon builder serves all three kinds; textures are cached
per spell with the `GetSpellInfo` fallback and a debug line when neither resolves.
`tools/replayui.lua` now asserts the Rejuvenation icon's overlay partway down the icon while
it runs (42). Six suites green.

## 2026-09-06 — v0.8.6: the frames are the author's Cell frames

Two more screenshots and the real point: a row per unit cannot hold 25 people twice, and the
author's raid frames already exist. "Mimic what is in my saved settings; no need to read Cell
at runtime." So the layout was read once, from `WTF/.../Cell.lua` in the parent checkout,
into one `CELL` table at the top of `UI/ReplayWindow.lua` with its provenance: 66 × 46
buttons, vertical, five per column, 3 px spacing, `sortByRole` off; bar in the class colour
over a loss area at class × 0.2 (Cell's `class_color_dark`), a 2 px power strip; name centred
at 75% width; health text bottom-right as a short deficit; the 11 px role icon top-left from
Blizzard's role atlas; the author's `indicator1` "Healers" slot (top-right, 13 px, right to
left — Rejuvenation, Regrowth, Lifebloom first in its aura list) for the HoT icons;
`defensiveCooldowns` 12 × 20 on the left edge; `debuffs` bottom-left, 13 px, three; the
bottom status strip for the landed cast's name, then its label, or `dead`. A raid's tracked
set fills the next columns; two grids side by side.

**The one addition Cell has no slot for: the cast target.** The spell in flight to a unit is
drawn in Cell's `statusIcon` slot (top centre, 18 px) with the vertical sweep of its cast time,
the button's border in the family colour meanwhile, and the icon held a moment after it lands.
Foreign heals still flash the border white.

`tools/replayui.lua` now asserts roster order, Cell-sized buttons and the cast-target icon
sweeping on the tank during the Regrowth (43). Six suites green.

## 2026-09-06 — v0.8.7: frame levels

The first in-game look at the Cell-shaped buttons: solid class colour with a bare stack count
on top and no status strip. Not a texture problem — two children of one button (the health
bar and an icon) share a frame level by default, and the later-drawn bar covered the icons'
textures and the text drawn on the button, while font strings on the OVERLAY layer showed
through. Cell gives the bar level 1 and its indicators 5 and 10; the window now does the same
(bars +1, HoT and debuff icons +5, defensives +10, the cast-target icon +15, text and the
role icon on an overlay frame at +20). The hint is one short line now instead of wrapping
into the controls in a single-column window. Not something the stub can see; noted here so
the next indicator gets a level from the start.

## 2026-09-06 — v0.8.8: room, scale, and the cast target where it reads

Two more screenshots. The "ticks" checkbox fell off the right edge of a one-column window —
the control row was wider than the column; the window is wider now (a column is at least 420,
larger buttons, the scrubber row and the hint each on their own line) and the dashboard is 20%
bigger (912 × 617) at the author's request, since not everything fit there either. The cast
target loses its icon: no room in a 66 × 46 button, and the author liked the name in the bottom
strip — so the spell in flight is named there in the family colour, with the border to match,
and the strip draws no background when it has nothing to say. **Frames scale with the
head-count**: one person ×3.5 both ways, a party ×1.6 tall and stretched across the column,
up to ten ×1.25 in two columns, a raid at Cell's own size five per column — every slot keeps
its Cell position, offsets and icons grow with the scale, the bar and the name stretch with
the width (`f.Resize(W, H, s)`). `tools/replayui.lua` asserts the stretched party buttons and
the in-flight name with its border (43). Six suites green.

## 2026-09-06 — v0.8.9: four screenshots, five bugs

The solo replay at ×3.5, and what it showed. **A brown band across the lower third of the
button**: the status strip's black-at-60% background over orange, drawn with no text —
`GetText()` on an empty font string is *nil* on this client, so `~= ""` was always true. The
stub returns `""`, which is why forty assertions never saw it; the strip's text now lives in a
field the window owns (`f.castText`, `f.labelText`) and the harness asserts the background is
hidden when idle. **"Regrowth / R9" on two lines over the name**: no `SetWordWrap(false)` on
the status strings, and a status font scaled ×3.5 with the button; status, deficit and stack
fonts now stop growing at ×2 (`CELL.textScaleMax`), the name keeps scaling. **The HoT icons
over the score line**: Cell's slot sits 3 px above the button's top, ×3.5 = 10 px, and the
grid began right under the strip; the gap is the overhang now. **A dark power strip on the
healer's own button**: the healer was matched by `MD.player.name`, which does not exist —
the recorder's roster carries the guid now and the window matches on it (older recordings:
`UnitName("player")`); the harness asserts the healer is recognised and the strip shows mana.
And the strip's GCD sweep was too light under white text.

`tools/replayui.lua` 46. Six suites green.

## 2026-09-06 — v0.8.10: the two unlabeled things

The author asked what the white line at the right edge and the orange square were. The
snapshot tick and the Swiftmend dot — both intentional, neither explained itself. The dot is a
Swiftmend **icon** now, under the HoT row: full while it is ready and has a HoT to eat,
sweeping its cooldown otherwise (`State:CooldownUntil`, new), with a tooltip either way. The
tick has an 8 px hover frame and a tooltip: the recorded HP and when it was read, the engine's
reconstruction at this moment, and whether the two are within the health gate's 5% — the
sentence that says what the line is *for*. `tools/replayui.lua` 49. Six suites green.

## 2026-09-06 — v0.8.11: packed HoT icons, the deficit off the strip, a smaller Swiftmend

Two screenshots. A lone Lifebloom floated mid-button: the three HoT slots were fixed by
family, so it sat in the third with two empty ones to its right. Cell's icon indicators pack
from the anchor; ours do now (placed in `PaintFrame`, cached per slot). "Lifebloom -102": the
deficit and the status strip shared the bottom-right corner; the deficit steps up above the
strip while it has text. The Swiftmend icon is 9 px at Cell's size (31 px at ×3.5), at the
right edge under the HoT row, where it clears the name at ×1. `tools/replayui.lua` 50.

## 2026-09-06 — v0.8.12: the loop closes offline, and stream A is yours

`tools/import.lua`: the game's SavedVariables — the only file an addon can write — loaded as
the addon's own database under the stub, and the same engine the Review tab runs on the real
recordings without the game: `list` with a validate verdict per fight, `validate N`,
`replay N` (every own cast with its target and label, each target's lowest health), `coach N
[force]` (the search pumped through stub frames, the card), `export N` (the `/md export` text
into `.logs/recordings/`). The author's install path is the default; `--file` / `$MD_SAVEDVARS`
/ `.logs/ManaDemon.lua` otherwise. The kit is the harness's (the profile is not in the file),
which the tool says on every run: costs are exact, heals are the model at those stats.

**The first run answered TESTING §16.** Three solo recordings from this afternoon, no party:
recorded mana runs ahead of the two-rate model by +5.4 / +6.2 / +6.8 mana/s — 27–34 mp5 —
and the 2 s samples show gains of +49 where the casting tick is 35: a constant ~14 per 2 s
beside the spirit tick, with nobody there to bless anyone. That is the character's own mp5
bucket, today's gear. It is why the 87 s fight fails the mana gate (+410 by its end) and would
pass with it modelled. The ruling holds — it does not enter the model as a constant, because
it is gear — and `docs/DECISIONS.md` carries the two honest ways in (measure it with the
regentest histogram per character, or read it off equipped-item tooltips) for the author to
choose between.

Three small things the run exposed: `%%` printed literally (the tool's own `Say`), the stub
reporting version 0.7.1 (it reads the `.toc` now), and a card saying *waited 101% of the
fight* (the last wait's span ran past the end; clamped). And the "ticks" checkbox is anchored
from the window's right edge with its label's width, so it cannot fall off a one-column
window a third time; a column is 460 wide.

## 2026-09-06 — v0.9 specified: runs, the measured character, the drink

"You can plan and make specs for v0.9.x." `docs/SPEC-v0.9.md`, in the v0.7/v0.8 shape. Five
versions in an order that keeps each honest: **v0.9.0** the character as it is — the mp5 the
API omits measured by `/md regentest` and stored with its date (three solo recordings behind
it now), the profile persisted so the offline engine sees this druid and not the BF-1 build;
**v0.9.1** the run recorder — manual checkpoints, every pull plus the gaps (drinks with their
measured rate, deaths, mana every 2 s, the clock), two runs kept in SavedVariables, auto-stop
on leaving, `runcheck`; **v0.9.2** the Review tab's run selector; **v0.9.3** the run in the
engine — pulls chained with mana carried over, a gap model that drinks by a policy at the
run's own measured rate, a score that puts **time before mana** (`addedTime`, `drinks`, then
mana), and the card that says "you drank 4x (3:10); this plan needs 2x (1:20)"; **v0.9.4**
the run strip in the replay window. Six calls in `docs/DECISIONS.md` §v0.9, a rejected list
(no file writing, no preset drink rate, no blended score, no run-level play-through), and the
author questions with defaults (measure vs read the mp5: measure; drinks vs added time in the
score: added time first). Auto-start stays reserved behind a setting that ships off.

## 2026-09-06 — v0.9.0: the character the engine replays is now yours

"Go, implement v0.9.x." First of five, `docs/SPEC-v0.9.md` §2: the engine stops replaying a
stand-in druid.

**The measured mp5.** `/md regentest` already *named* the beat the API omits — a constant
size on a 2.00 s cadence next to the spirit tick. It now **stores** it: `cdb.mp5 = { perSec,
mp5, at, source, ticks, level, hint, solo }`, and only from a clean window (nothing spent, no
drink, out of the five-second rule throughout, at least 5 beats, the beat constant to within
±1 mana). A dirty window prints which of those it failed and changes nothing. `RM:Unreported()`
is now `RM:Dreamstate() + RM:MeasuredMp5()`, so the measurement lands in both rates exactly
the way the talent does; `RM.dreamstate` / `RM.measured` keep the split, and the dashboard,
the tooltip and `/md profile` name both terms instead of saying "Dreamstate".

**Into the recordings.** `FightRecorder:Start` writes `initial.energize` — everything the API
omits for this character, as measured *at that pull* — so a fight recorded before a
re-measurement still replays against what was true then. `ScenarioFromRecording` passes it
through, and for recordings that predate the measurement entirely it applies the current one
and flags the scenario `energizeAssumed`; every validation report says which of the two it
used. That flag is the whole point of the version: with 31 mp5 applied, the author's 87 s
Hellfire fight moves from `mana mean 3.3%` (FAIL, limit 2%) to **0.8%** — the fight that
could not be coached from can be. `spend coverage` (69%, the utility hole) is still its
remaining gate.

**The profile.** `MD:WriteProfile()` persists `cdb.profile` — level, class, +healing, crit,
spirit, intellect, pool, the raw API regen rates, every talent `RankMath` reads, the relic and
the form — at login (twice: once immediately, once after 5 s when the stat APIs have settled),
on a talent change and on a gear change. `tools/import.lua` applies it to the stub before
building the kit and prints `kit: the character's (profile of ...)`; without one it says the
file carries no profile and keeps the harness's BF-1 stand-in. A gear change also reminds the
author once per session, out of combat, that the measurement predates the gear — an old
measurement is still a measurement, so nothing is invalidated automatically.

**Harness.** `regencheck` 8 → 18: a clean scripted window stores the beat with its
provenance, the model adds it to both rates, a new recording carries it, a window with a spend
in it refuses and leaves the old value alone, and a window with no beat refuses too. One
harness artifact fixed on the way: assigning `S.mana` without firing the power event made the
model see the drop at the next *gain*, which put five seconds of the measurement window inside
the five-second rule — exactly what the new code refuses to store from. `replaycheck` 31 → 33:
energize moves the mana curve by exactly `energize × t`, and the run result must be read out
of its pooled slot before the next run reuses it.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 18, replaycheck 33, replayui 50.

## 2026-09-06 — v0.9.1: a dungeon is a run, and the gaps are half of it

`docs/SPEC-v0.9.md` §3. `Engine/RunRecorder.lua` (new, 380 lines): `/md run start [name]`,
`/md run stop`, `/md run status`. Manual, as decided — `Start(reason)` takes a reason and
`db.runAutoStart` ships `false`, so auto-start on entering a five-man is one `if` away.

**The container.** While a run is active `FightRecorder:Finish` hands every finished pull to
the run **instead of** the ring of 8 — a run is pinned, replaced and reviewed as one thing —
and that includes pulls under the 20 s / 5 casts gate, marked `short`. The gate never went
away; it is about what may be *coached from*, and a dungeon is mostly pulls that fail it. A run
also overrides `db.recordFights`: turning single-fight recording off is a statement about the
ring, not about a dungeon the author explicitly asked to record.

**The gaps**, which is the half a fight stream cannot hold: mana every 2 s across the whole
run, in and out of combat; each drink with the mana either side of it; deaths and the time
spent dead; zone changes; Innervates (the cast) and potions (the item leaving the bags, which
needs no spell id nobody has verified on this client). The **drink rate is measured across the
drink's interior** — first to last poll that was still inside it — because the buff goes up and
comes down between two 0.5 s polls and guessing at either end is 2% of a 25 s drink. `runcheck`
holds it to within 2% of a scripted 120 mana/s and gets 120.0.

**Limits.** Two runs in `cdb.runs`, one pinnable; starting a third when both are pinned is
refused *before* recording, with the reason. Auto-stop on leaving the instance (30 s of grace,
because a corpse run leaves and returns — and returning cancels it), on logout, and at
`db.runMaxMinutes` (90). Two budgets, not one: `MAX_RUN_EV` (30 000, the pulls' streams
included) stops *recording* further pulls, while the run's own timeline has its own
`MAX_GAP_EV` — the first version squeezed the gap events out as soon as the pulls filled the
budget, and a pull the run only summarised then lost even the fact that it happened. It is
counted now: `stats.summarised`, and its length still counts as combat time.

**Export.** The per-recording dump is now a shared `DumpRecording`, used by the ring of 8 and
by each pull of a run (tagged `run <id> pull <k>`), under new `# run` / `# run ev` /
`# run mana` sections.

**Harness.** `tools/runcheck.lua` (new, 49 assertions): three pulls with a drink, a death and a
release between them; the short pull kept and flagged; the ring of 8 untouched; the PULL mana
fractions; the drink rate; `stats`; the budget forcing a summarised pull; the auto-stop with
its grace and the return that cancels it; the retention refusal when both runs are pinned;
`db.recordRuns` off; the command's name keeping its case (the slash handler lower-cased
everything, so `/md run start Blood Furnace` used to hand back a name the author never typed);
and the `# run` export. The stub gained `UnitBuff` and `IsInInstance`.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 18, replaycheck 33, replayui 50,
runcheck 49.

## 2026-09-06 — v0.9.2: one address for a pull, wherever it lives

`docs/SPEC-v0.9.md` §4. A run's pulls are now reachable everywhere a single fight is, under one
address: **`run:pull`**. `MD:GetRecording(spec)` resolves `"3"` to the third single recording
and `"2:7"` to the seventh pull of the second run, and everything that took a recording by
number now goes through it — `/md coach`, `/md simreplay`, `/md replay`, the Review tab's
buttons and the import tool's `--run`.

**The Review tab** gained a source selector above the list: `[Fights]`, then one button per
stored run (labelled with the run's name, `*` when pinned). Selecting a run lists its pulls in
order, with the `when` column showing the offset into the run (`+12:41`) instead of a wall
clock. A pull under the recording gate is greyed with `short - under the recording gate` and
its Coach button is disabled, with a tooltip that says why it is kept anyway: a dungeon is
mostly those. **Pin** becomes **Pin run** while a run is shown, because a run is kept or dropped
whole. **Start run / Stop run** sits at the left of the button row and follows the recorder's
state. The run's line is printed above the list; with no run selected, the live run's status is
there instead.

**`tools/import.lua`**: `runs` lists the stored runs with their stats and says how to address
their pulls; `--run K` points `list` / `validate` / `replay` / `coach` / `export` at that run;
`export --run K` writes the whole run (header, gap events, mana samples and every pull's stream)
to `.logs/runs/<id>.txt`, while `export N --run K` writes one pull. One bug found on the way and
worth remembering: loading the addon over the real database runs its login path, and that path
now *writes* `cdb.profile` — with the stub's stats, over the character's own. The tool captures
the file's profile and measured mp5 before the harness loads and puts them back. It reads the
game's database; it does not get to invent one.

**`tools/reviewui.lua`** (new, 23 assertions): the Review tab painted under the stub. It records
a scripted run, clicks the run's button and its rows the way a mouse would, and reads back the
cells, the greyed `short` pull, which buttons the pane disabled, that Pin pinned the run and not
the pull, and that Play opened the replay window on `1:1` with the run named in its header. The
stub grew three things to make that possible: `Enable`/`Disable` now store state instead of
being no-ops, font strings and textures are registered alongside frames so a harness can read
every painted string, and `UnitBuff` / `IsInInstance` exist.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 18, replaycheck 33, replayui 50,
runcheck 49, reviewui 23.

## 2026-09-06 — v0.9.3: the run in the engine, and mana measured in seconds

`docs/SPEC-v0.9.md` §5. A pull's score answers "did the healer hold the group up for this
mana". A run's answers "how long did the dungeon take, and how much of that was standing still
drinking" — which is the question mana actually decides in a five-man, and it is only answerable
if the gaps are in the simulation. A plan that spends 20% less does not bank the mana; it skips
a drink.

**`SM.ChainRun(run, kit, opts)`**: every pull in order, mana carried across, with a gap model
between them. What is the healer's and therefore simulated: the plan, and the **drink policy**
(`below`, `upTo`). What is recorded and therefore fixed: the damage, the other healers, the
deaths of others, how long each gap was, and the drink rate — measured on this run, never a
preset. Seconds inside a gap that the group actually spent in a pull the run only summarised are
subtracted: that is combat, not a gap. A drink that does not fit its gap does not vanish — the
run gets longer by the excess (`addedTime`). Potions apply at their table value. **An Innervate
in a gap is counted and reported but not modelled**, a deliberate deviation from the spec's "as
recorded": its value is 400% of the *spirit share* of regen and a recording carries the total
rate, not the split, so modelling it would be a guess. Both sides of every comparison see the
same recorded gaps, so the comparison stays fair.

**The score** (`SP.ChainScore`), lexicographic as always, with time in front of mana:
`(deaths, floorSeconds, addedTime, drinks, manaSpent, -heldOn, #binds, overheal)`. `drinks`
ranks above mana because each is most of a minute of five people standing still even when it
fits; mana ranks last because in a dungeon it is only worth the time it saves.

**`SP.SearchRun`**: the v0.7.5 coordinate descent over the five plan parameters *plus* `below`
and `upTo`, one plan for the whole dungeon, evaluated by `ChainRun`. The evaluation budget
scales down with the number of pulls (thirty pulls at 300 evaluations would be nine thousand
fight simulations); it still slices on `debugprofilestop()`. **`SP.RunGates`** validates each
pull once — not per evaluation — so the card can say how much of the health side it is standing
on. **`SP.RunCard`**: the two rows above, the plan and its binds, the suggested drink policy
next to the one read back out of the recording (`RR:DrinkPolicy` — `below` is the highest mana
fraction the healer actually sat down at, `upTo` the median they got up at), the pulls where the
two differ most, and the caveats.

Reachable from `/md coachrun [n]` (with `cancel`), from **Coach run** on the Review tab — where
Coach becomes Coach run while a run is shown and a second **Coach pull** button keeps the
single-fight card — and offline from `tools/run.sh tools/import.lua coach --run K`.

**Harness.** `runcheck` 49 → 69: mana carried across the gaps exactly (each gap starts where the
previous pull ended and ends where the next begins), the run's own measured rate used and named,
a gap that regenerates when nobody drinks, a greedy policy forcing `addedTime` and a longer
wall clock, a policy that never drinks adding nothing, the score's two orderings, a cheaper plan
that spends 1.0k against 7.9k and drinks 0 times against 1, the recorded policy read back, and
the search driven to a card. One thing the harness taught on the way: the scripted pull's damage
(5000 on a tank at 3000) killed the tank in every simulation, which made every plan score the
same for the wrong reason — the assertions were passing on a dead tank. The scripted damage is
survivable now.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 18, replaycheck 33, replayui 50,
runcheck 69, reviewui 26.

## 2026-09-06 — v0.9.4: the run strip, and the map a dungeon needs

`docs/SPEC-v0.9.md` §6, the last of v0.9. When the pull in the replay window belongs to a run,
a strip appears under the header: the whole run on one line, each pull a block as wide as it was
long (the one playing bright, the ones under the recording gate grey), drinks in blue, deaths as
red marks, and the gaps left as gaps. Hover a block for its number, length, position in the run,
casts and mana; click it and the window re-opens on that pull with the same clock controls.

The strip pushes the columns down by its own height and nothing else moves: a single fight has
no strip and the window is the size it was in v0.8. `/md replay run 2` opens run 2 at its first
pull, and the Review tab's Play does the same when a run is shown.

**The next pull follows on its own.** Playing a pull to the end inside a run opens the next one
and keeps going (`db.replayNextPull`, default on) — the author's default answer to the spec's
open question, because pull-by-pull *is* the way through a dungeon and stopping to click at
every boundary makes it a chore. There is still no run-level play-through: half an hour at 1×
is not review, and the strip is the map instead.

`tools/reviewui.lua` 26 → 31: the strip is drawn for a pull inside a run and not for a single
fight, its blocks are proportional to the pulls' lengths, clicking one opens that pull, and
`/md replay run 1` opens the first.

**v0.9 is complete**: the measured character (v0.9.0), the run recorder (v0.9.1), the Review tab
and the tools (v0.9.2), the run in the engine with the drink model and a time-first score
(v0.9.3), and the strip (v0.9.4). What it needs now is a dungeon: TESTING §27 to §31, in order.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 18, replaycheck 33, replayui 50,
runcheck 69, reviewui 31.

### v0.9 tidy-up (same day)
The two run settings reached the options window (`Allow run recording`, `Replay: next pull
follows`), which pushed the General tab from 470 to 520 tall — a pane that does not fit is a
setting nobody finds. `docs/DECISIONS.md` §v0.9 gained four addenda from the implementation: the
assumed energize on older recordings, the Innervate that is counted but not modelled and why,
Coach-run versus Coach-pull, and the answered auto-advance question.

## 2026-09-06 — v0.9.5: the measured mp5 was measuring the whole tick

The author, with a debug dump: "some of your last fixes seem to include out-of-casting regen as
something out of the API, and now I see a 556 regen datatext, which is far from true." Correct,
and the log says exactly where it went wrong.

**What happened.** `/md regentest` stored `279 mp5` on a character whose client reports 244, so
the model ran at 111.11/s — 556 mp5 for a druid regenerating 279. The histogram had labelled the
one and only regen tick (111 mana every 2 s) as "a 2 s beat the API does not report", and
v0.9.0 stored the size of that tick. On a druid with Dreamstate there is *one* tick: the server
folds the talent into the same regen tick as spirit and gear, so the tick reads ~14% above the
raw API rate, falls outside the histogram's 12% "this is the spirit tick" window, and gets
called a separate stream. A term the API does not report can only ever be what is **left over**
after everything it does report; storing a tick double counts by construction.

**The fix.** What is stored is now `observed - GetManaRegen - Dreamstate - any 3 s party
stream`, printed as one line so it can be checked by eye:

```
regentest: observed 55.77/s = API 48.76 + Dreamstate 6.52 + unreported +0.49 (+2 mp5)
```

Three supporting changes, each with its own reason:
- the histogram compares a tick against the rate the **model** expects (API + Dreamstate), not
  the raw API rate, so the true tick is named "the regen tick the model expects";
- rates come from **between the first and last tick of a stream**, not from the window's edges.
  A window edge is worth up to a whole tick — 111 mana over 30 s is 3.7/s, bigger than the
  leftover being measured. Interleaved phases of one source drop as many ticks as they have
  phases, which is how the BF-1 log's four overlapping 3 s streams read correctly;
- a leftover under **5 mp5** stores nothing *and clears* any previous measurement, because "the
  model already accounts for everything the client regenerates" is a result, and a stale number
  would hide it. `RM:MeasuredMp5()` also refuses any stored value larger than what the client
  reports, saying so once, so a database written before this fix cannot keep lying.
  `/md regentest clear` forgets one on demand.

**And the finding underneath it: stream A was Dreamstate.** The v0.7.1 addendum read three solo
recordings as missing 27–34 mp5 of item mp5. Dreamstate 3 on 326 intellect is 33 mp5. The
recordings looked short because the replay scenario carried only `apiBase`, the raw client rate,
and nothing ever added Dreamstate to a replay. Re-validating the 87 s Hellfire fight with
Dreamstate alone and **no measured mp5 at all** takes its mana gate from 3.3% to **1.0%**,
inside the 2% limit. The same log agrees from the other side: its in-combat ticks are +48/+49
per 2 s (24.3/s) against API casting 17.58 + Dreamstate 6.52 = 24.10/s. So v0.9.0's real fix —
recording `RM:Unreported()` as each pull's `initial.energize` — was right, and its *measured*
half was measuring nothing. `docs/DECISIONS.md` §v0.7.1 carries the correction; BF-1's
17-per-2 s next to a 138 spirit tick, on a build with no Dreamstate, stays a genuine second
stream and the fixture keeps it.

`regencheck` 18 → 27, including the bug itself as a regression test: one tick with Dreamstate
inside it must be named as the model's own tick, must store nothing, must clear what was there,
and must leave the model at API + Dreamstate; plus the refusal of an over-large stored value and
`/md regentest clear`.

Suites: simcheck 10, reccheck 38, simwindow 8, regencheck 27, replaycheck 33, replayui 50,
runcheck 69, reviewui 31.

## 2026-09-07 — v0.9.6: forcing the suggested column

The author, on the three solo recordings that fail their gates: "I want to have a force replay
with coach (second column) option." Until now `/md coach N force` printed a card and cached its
plan, but the replay window re-checked validation and dropped the right column, so the forced
plan had nowhere to be seen.

A forced coach is now **remembered** (`SP.forced[rec.id]`): forcing is a deliberate act, and
making the author repeat it at the Play button would be a second lock on a door they had already
opened. Play draws both columns afterwards, with `FORCED - this fight does not replay` beside
the column title so it is never mistaken for a validated one. Two explicit ways in as well:
`/md replay 2 force`, and shift-clicking Play on the Review tab. Forcing without a coached plan
says exactly that and points at `/md coach N force` — the replay window still never searches.

The disabled Coach button's tooltip now names both steps instead of only the reason.

`reviewui` 31 → 38: the scripted fight really does fail its gates, no right column without force,
force draws it, the title says so, a forced coach stays forced, and shift-clicking Play does the
same from the tab. The stub grew `IsShiftKeyDown` (a harness sets `S.shift`).

## 2026-09-07 — v0.10 specified: the casts that are not heals

The author, on the three solo recordings the gates reject: assisting the damage dealers and
casting a lot of CC are healer decisions, and a 90% "mana spent on heals" gate calls them a
defect. Right — and the gate was measuring the wrong thing anyway. The mana curve reproduces
without it (recording 2 is at 1.0% on the mana gate with a third of its spend unpriced), because
the recorder stores each cast's real cost. What the threshold stood in for is the plan side:
`RunPlan` drops the recorded script, so the simulated healer never casts the Moonfires and starts
with their mana in hand against an unchanged damage timeline — 2043 mana of free money in
recording 2.

`docs/SPEC-v0.10.md`, in three versions. **v0.10.0** the addon knows what it cast: a seed table
of non-healing druid spells, `MD:ClassifyCast`, a `cdb.spellbook` the addon learns from
`GetSpellInfo` rather than from a website, and per-stream spell names so a recording is readable
offline. **v0.10.1** fixed points: every non-healing cast happens in the suggested column at the
same moment, at the same cost, taking the same global cooldown and restarting the same
five-second rule, and `spend coverage` becomes "mana the engine reproduces" rather than "mana the
healing kit prices" (the author's three recordings go 0% / 69% / 67% to 100%). **v0.10.2** what
the damage casts cost: their mana plus the spirit regen lost to the five-second rule they
restarted, measured as the difference between two runs and always printed with its
counterfactual — the fight would not have been the same fight without them.

**The five unknown ids are identified**, and the identification is corroborated rather than
looked up: 26987 Moonfire rank 11 (430 base, recorded 391 = 430 x 0.91 with Moonglow 3), 25298
Starfire (340 -> 309, the same -9%), 24977 Insect Swarm (155, which Moonglow does not touch),
9853 Entangling Roots (125) and 17329 Nature's Grasp (free, as recorded). Four independent costs
and one talent multiplier all consistent. Cyclone (33786) is in the table unverified until a
recording carries it. Every row stays `-- VERIFY` until a recording proves it.

Author questions with defaults in §8: a fixed cast preempts an in-flight plan cast (cancelling
it, which costs no mana) rather than being delayed; utility casts are fixed on the same rule;
fixed points are drawn in the suggested column in their own colour; `unknown` casts do not count
towards coverage.

## 2026-09-07 — v0.9.7: a Swiftmend the healer does not have

From the author's screenshots of a forced replay: "the icon showed in the replay even though I
don't have it." True — their build has one point in Gift of Nature, so Swiftmend was never
trained, and the replay window drew its indicator anyway. The dot was gated only on "a
Rejuvenation or Regrowth is up", which is half the question.

Recordings now say **which healing spells the player had at that pull**: `initial.known`, family
to highest known rank id, six numbers. A recording is replayed and coached long after it
happened, sometimes on a different talent build, and always offline against a harness that
pretends every spell is known — which is why `tools/import.lua` had been binding `Swiftmend R1`
into coached plans for a druid who cannot cast it. `SP.MaxRankBinds(known)` and
`SP.BindsFromRecording` now take the recording's word for it, the run search uses its first
pull's, and the replay window draws the dot only for a healer who has the spell (older
recordings fall back to what the player knows now).

The cooldown case the author also asked about was already right and stays: the icon appears only
when there is a HoT to eat, sweeps while Swiftmend is on cooldown with the seconds in its
tooltip, and is bright when it is ready.

`reccheck` 38 → 39, `replayui` 50 → 54.

### What the screenshots also showed, and where it went
The same forced replay spent 674 mana and ended at 45% where the author spent 3.9k and ended at
79%. The plan was not preferring Rejuvenation to Lifebloom on the merits: the search had turned
rule 3 off, bound Lifebloom and never cast it, and rule 5 read "otherwise wait — 95% of the
fight". Health above the flat 30% floor is worth nothing in the score, so the cheapest plan that
stays above it wins. Measured on this character's gear, Lifebloom left to bloom is the most
efficient heal in the book at 6.17 per mana (Regrowth R9 5.17, Rejuvenation R12 4.72) and the
worst at 2.55 if it is rolled and refreshed, because the bloom is 797 of its 1357 — and rule 4
can only bind Rejuvenation, so no plan expressible today can say "Lifebloom on whoever is hurt".
The author's framing of the fix is the one that made it into `docs/SPEC-v0.10.md` §6b: health
missing at the end is *mana not yet spent*, so charge for it; the danger line should be the
fight's own biggest hit rather than a constant; and eating time is the run's version of the same
debt. No weight anywhere — every term has a unit.

## 2026-09-07 — v0.9.8: shift-click coaches it anyway, and a bare pipe six versions old

"Let's also add a shift click for force coach." The obstacle was that the Coach button was
*disabled* on a fight the gates rejected, and a disabled button cannot be shift-clicked — it also
says nothing at all unless you happen to hover it. So the rule moved from the button's enabled
state into its behaviour: a rejected fight keeps a clickable **Coach\*** (starred), a plain click
still refuses and prints which gate failed, and **shift-click forces**. You cannot get a card
from a fight the engine gets wrong by accident; you can get one on purpose. Shift works on
**Coach pull** inside a run too, and a forced coach is remembered, so Play afterwards draws both
columns without a second modifier.

**The selected row is now validated on sight** — one simulation, cached, druid-only. Until now
the v0.7.6 rule ("a fight that does not replay has Coach disabled") only took effect *after* a
manual Validate, which is the one moment it was not needed: on first sight the button looked
ordinary, and clicking it produced a refusal.

Painting that verdict into the tab immediately found a bug six versions old. The mana gates'
text was `mean |d| 2.3% of pool` — a **bare pipe**, which the client reads as the start of an
escape sequence and eats what follows. It has been in every chat report since v0.7.3 and nobody
caught it, because `reviewui`'s no-bare-pipe scan only ever saw cells that had not been
validated. It now reads `mean off by 2.3% of pool` / `worst sample off by 9.4% of pool`. This is
the second time the "never a bare `|`" rule in CLAUDE.md has been broken by maths notation, and
the first time a test caught it.

`reviewui` 38 → 43.

## 2026-09-07 — v0.9.9: /md tooltip

"Remove the tooltip from the FULL/OOM bar — I place it in the middle of the screen and sometimes
move the mouse over it unintentionally." The setting already existed (`db.widgetTooltip`, a
checkbox in the options), but it was one window and three clicks away, and its help text did not
say the thing that matters for a mid-screen clock: turning it off makes the widget take **no**
mouse input at all, so it stops swallowing clicks inside its own 190x22 rectangle as well as
popping the tooltip. It stays draggable while unlocked either way.

So: `/md tooltip` toggles it from chat, alongside `/md rest`, `/md drink` and `/md mute`, and
both the chat line and the checkbox's help now say what "off" actually buys.

### v0.9.10, same day: saying which tooltip
"I want to keep the tooltip on datatext hover, or the addon minimap button, but hide it on that
separate bar." That is what `db.widgetTooltip` has always done -- it is read in `UI/Widget.lua`
and nowhere else -- but nothing said so, and "Tooltip on hover" reads like a global switch. The
checkbox is now "Tooltip on the clock", the chat line names the surface and adds "the minimap
button and the ElvUI datatexts keep theirs", and both of those files carry a comment saying they
are deliberately not gated by it: a clock is something you park and stop looking at, a minimap
button and a datatext are things you go to on purpose.


## 2026-09-07 — v0.10.0: the deficit is a debt, and the HoT that fits

The author, on a third screenshot of the same thing: "Still coach casts Rejuvenation and keeps
half HP. In my vision the better approach would be to cast Lifebloom when it is about a 1.1k
deficit, so when it blooms the full 1356 heal lands with no overheal — HP as high as possible
at minimal mana cost and no overheal." Three changes, all from `docs/SPEC-v0.10.md` §6b, shipped
ahead of the fixed-points work because this is what they kept seeing.

**The deficit is a debt.** Health missing at the end of a fight is not a saving, it is mana that
has not been spent yet. `SM:Run` reports `endDeficit` (measured to `db.simFullHp`, for the
living, with HoTs still rolling counted as healing already paid for), and `SP.Score`'s mana term
becomes `manaSpent + manaOwed`, the deficit priced at the best heal-per-mana the plan has bound.
Nothing is earned above the full line, so no plan is pushed into overheal to satisfy it. Without
this term the cheapest plan that clears the danger line wins, which on a light fight means barely
healing: 674 mana and a healer at 45% beat 3.1k and 93%.

**The danger line is measured.** `floorSeconds` counted seconds under a flat 30%, which says the
same thing about a quest mob hitting for 7% of your health and a boss hitting for a third of the
tank's. It is now the biggest hit that target actually took in that fight, times
`db.simDangerHits` (1 = one more hit kills). The maximum, not a percentile: that hit happened,
and a percentile discards exactly the tail the line is about. `db.simFloor` stays as the fallback
for synthetic scenarios, which have no recorded damage. The card prints the line it used.

**Rule 4 casts the HoT that fits.** It was hard-coded to Rejuvenation. It now takes the bound
HoT with the best heal per mana **whose whole value will land** — the deficit now, plus the
damage this target is taking over the HoT's own duration, which is the trailing-5s window the
causality invariant already allows. That is the author's rule exactly, and on their gear it picks
Lifebloom (6.17 health per mana with the bloom) over Rejuvenation (4.72). Re-coaching their
74 s Hellfire fight now opens `32s Lifebloom, 33s Rejuvenation` where it used to cast
Rejuvenation alone, and the card's rule line says so instead of naming Rejuvenation.

On that fight the plan still ends at 49% and that is now *explained* rather than assumed: the
biggest hit they took was 371 of 5053 health, so the danger line is 7% and 49% is six hits of
headroom. The card says which line it used and on whom.

`replaycheck` 33 → 43: the line is the biggest hit and only for targets that were hit; the run
reports its end deficit; the deficit prices at the plan's best rate; the score's ordering flips
when the debt is charged and does not when there is none; nothing above the full line is a debt.

## 2026-09-07 — v0.10.1: the addon knows what it cast

`docs/SPEC-v0.10.md` §2. Until now the engine could name a heal and nothing else: a third of the
author's mana went on ids no part of the addon had heard of, and offline the tools could not even
print their names.

**`Data/DruidSpells.lua`** holds the casts that are not heals, keyed by id, with a family and a
kind — `damage`, `cc`, `utility` or `shift`. Nothing in it is a heal value or a formula, so a
wrong row costs a label and a category and never a number; the cast's own cost comes from the
recording either way. Seeded from the TBC database and corroborated against the author's
recordings, which is the part that matters: four of the five ids reproduce their recorded cost
exactly, three only after Moonglow's -9%.

**The table does not have to be complete.** `MD:ClassifyCast` falls back to the spell's *name*
from the client and writes what it resolves into `cdb.spellbook`, so the map grows from the game
rather than from a website. The recorder stores a per-stream `names` map as it records, so a
recording is readable offline, where no client exists to ask.

Running it on the author's 74 s fight named everything except one id casting for 260 mana twice,
which the database says is Moonkin Form — so shapeshifts became their own kind rather than being
filed as utility. The fight reads: 61% damage, 23% healing, 13% shapeshift, 3% crowd control.
Nothing unclassified.

`/md verify` now groups the spells outside the healing model by kind and colours the
unclassified ones, which is the author's list to correct. `tools/import.lua spells N` prints the
same split offline, per spell.

`reccheck` 39 → 46. One harness gap fixed on the way: the stub only knows the healing table, so
`GetSpellInfo` could not name a Mark of the Wild and the classifier called it unknown — a
property of the harness, not of the addon. The ids the fixtures cast are named in
`tools/harness.lua` now.

## 2026-09-07 — v0.10.2: fixed points, and the gate that was measuring the wrong thing

`docs/SPEC-v0.10.md` §3, the change the author asked for on 2026-09-07: "treat CC casts as
necessary at that moment, so they are in the record and in the coach variant at the same place."

`ScenarioFromRecording` now splits the own casts. `script` stays complete — a replay is every
cast the healer made, byte for byte as before — and `fixed` is the subset the healing model does
not price. When a plan runs it drops `script` and **keeps `fixed`**: each of those casts happens
at its recorded moment, for its recorded mana, taking the global cooldown and restarting the
five-second rule, in the suggested column exactly as it did in the real fight. The plan decides
around them; it never gets the mana back.

A fixed cast **preempts** a plan cast in flight, cancelling it, which costs no mana — that is
what the healer did, interrupting themselves to press it. The two alternatives are worse:
delaying the fixed cast moves a recorded event, and letting the plan see it coming is
clairvoyance. Its trace carries `why = SM.WHY_FIXED`, a sixth value that is not a rule, so the
replay window can name it on hover.

**The gate now counts what the engine reproduces**, not what the healing kit prices. On the
author's four solo recordings that is 100%, 100%, 100% and 23%, and two of them pass every gate
and can be coached without forcing. Before this, a healer who assisted the damage dealers failed
a gate for playing their class.

Two bugs found while wiring it, both by output rather than by a syntax check:
- `local _, kind = MD.ClassifyCast and MD:ClassifyCast(id)` truncates the call to one value, so
  `kind` was always nil and everything read "unclassified". This is the exact Lua trap CLAUDE.md
  warns about, and it has now bitten three times in this repo. The `if` is written out.
- The fixed cast pushed its own decision event while the plan's chain was still alive, so two
  chains ran and every wait was counted twice: the card read "otherwise wait — 390% of the
  fight, longest gap 338s" on an 87 s fight. Exactly one chain may be alive; the pending one
  reschedules itself against a busy guard.

`replaycheck` 44 → 47: the plan pays for the casts it did not choose, waiting never exceeds the
fight, the longest wait fits inside it, and a preempted cast costs nothing.

## 2026-09-07 — v0.10.3 and v0.10.4: what damage costs, and four ways to read one search

**v0.10.3, the price of a damage cast** (`docs/SPEC-v0.10.md` §4). `SM.CostOfCasts(rec, kit,
kinds)` runs the recorded script twice, once whole and once with those casts removed, and reports
the difference: their own mana, the spirit regen lost to the five-second rules they restarted,
and whether the fight reaches the OOM line in one run and not the other. Measured rather than
estimated, because a per-cast "five seconds of regen" is wrong every time a heal follows within
five seconds and would have restarted the rule anyway — only the two runs know that. On the
author's 87 s fight: seven damage casts for 1.8k mana plus 123 of lost regen. The card prints the
counterfactual with it every time: the fight would not have been the same fight without them, so
this is what pressing them cost, never whether to press them.

**v0.10.4, four strategies from one search** (§6c), the author's idea: "make a few different
coach strategies which we simulate at the same time and then pick the one based on the result, or
let the user select and look at different ones". It costs no simulation at all — `SP.Search`
already evaluates up to 300 plans and keeps every one, so `SP.Winners` is a scan of that table.
Four objectives, each its own lexicographic tuple, **deaths leading all of them** so no objective
can trade a corpse for its own axis: safest (least time one hit from death), highest health
(least health missing over the fight), least mana (the standing tuple), most mana left (rewards
spacing casts out of the five-second rule rather than simply casting less). A new `deficitArea` —
the time-integral of missing health — gives "most healing done" a number that overhealing cannot
game, since topping up a target above the full line adds nothing to it.

The card gains a block with one row per strategy and **identical winners collapsed**: on a
one-target quest fight all four picked the same plan and it says so once, which is more useful
than the same row four times. `/md coach 3 health` makes that one the plan the replay draws,
without searching again.

`replaycheck` 47 → 62. One expectation of mine was wrong on the way and the harness was right:
the cheapest plan in a pool does *not* win "least mana" if it spent six seconds one hit from
death, because every objective ranks danger above its own axis. That is the design working, so
the test now asserts it directly.

A third bare pipe found and fixed: the card's hint read `<safe|health|cheap|regen>`, which the
client would have eaten from the first `|`.

## 2026-09-07 — v0.11.0: the navigation, before anything moves

`docs/SPEC-v0.11.md` §3. The author wants the dashboard, the simulator and the settings in one
window, on the settings palette, grouped the way ElvUI groups things: top-level categories down
the left, their views along the top, and deeper levels inside a box that repeats the rule.

This version ships **only the kit**, so nothing changed on screen. `UI.PALETTE` puts the colours
in one place — the author asked for the settings window's palette *everywhere*, and "everywhere"
only holds if there is a single thing to change. `UI.CreateNavFrame` is the navigation, written
once so the panes can stay dumb:

- **panes are built lazily and cached**: a druid who never opens Simulate never builds it, and
  clicking back to a view does not throw its frames away. That split cost one iteration —
  the first cut called one hook for both creating and showing, so returning to a tab rebuilt the
  pane. There are two hooks now, `onCreate` (once per view) and `onShow` (every selection, where
  a pane refreshes itself);
- one pane is visible at a time, and it is the selected one;
- a hidden view is refused rather than drawn, and an unknown group falls back instead of erroring;
- `nav:SetViews` replaces a group's views while the window is open, for Reports/Runs;
- the path is remembered in `db.uiPath`.

`UI.CreateNavBox` is the same code with a border and no header, for level 3. Nothing needs it
yet; it exists so the next thing that does is not a fourth window.

`tools/navui.lua` (new, 25 assertions) is the ninth suite. It goes in before anything is rebuilt
on top of the kit, which is the whole point of writing it first.

## 2026-09-07 — v0.11.1: the dashboard moves into the navigation

`/md` is now groups down the left and views along the top: **Spells** (the six families) and
**Reports** (Waste, Review). The eight-button top edge is gone, and with it the reason Review and
Waste sat beside Healing Touch as though they were spell ranks. Nothing about the panes changed —
they parent themselves to the nav's content frame and are built the first time their view is
selected, so a non-druid never builds a rank table and the Review tab never builds until asked.

The window is 1036 × 646 because the content area is kept at the 912 the panes were laid out for;
the navigation is added beside them rather than taken out of them. The remembered path
(`db.uiPath`) means `/md` reopens where you left it.

The Simulate strip gained a frame of its own so it can be shown with the Spells group and hidden
elsewhere. It had been drawing its widgets straight onto the dashboard, which is fine when there
is one view and wrong the moment there are two.

**`tools/dashui.lua` (new, 19 assertions)** is the dashboard's first offline test in the
project's history: it opens the window, clicks the groups and the views the way a mouse would,
and reads back what was painted and which panes exist. Writing it found three gaps in the stub
rather than in the addon, all of which had been hiding real coverage from every other UI suite:

- **`CreateFrame` never registered a named frame as a global.** The client does, and addon code
  looks itself up that way.
- **`Show()` and `Hide()` did not fire `OnShow` / `OnHide`.** A window that populates itself in
  `OnShow` — this one — opened empty under the stub.
- **`SetFormattedText` was falling through to the no-op fallback**, so every string written with
  it was invisible to the harnesses, including their bare-pipe scans. Two of the dashboard's
  three header lines are written that way.

Ten suites now: simcheck 10, reccheck 46, simwindow 8, regencheck 27, replaycheck 62, replayui
54, runcheck 69, reviewui 43, navui 25, dashui 19.

## 2026-09-07 — v0.11.2: settings stop being a second window

`MD.optionsFrame` is a **panel** now, not a window: the dashboard's navigation hosts it as its
fourth group and the two tab panes are untouched — they still parent themselves to it and still
show and hide themselves on the `ShowOptionsTab` callback. `UI/OptionsFrame.lua` went from 114
lines to 50, losing its tab strip, its header bar, its drag handling and its position saving,
because the window it decorated no longer exists.

`/md options` routes into the group through a new `MD:SelectView(group, view)`, which opens the
window if it is closed. That is the entry point `/md sim` will use in v0.11.3 and the minimap
button's right-click already does.

Three more stub gaps surfaced, each hiding coverage rather than breaking the addon:
`GetStringHeight` returned nil (the About tab measures its command list with it, and had never
been built offline before), and `SetShown` fell through to the no-op fallback so a hidden font
string still read as shown. The addon's own new code uses Show/Hide per CLAUDE.md's rule about
older clients; the stub understands both now.

And a **fourth bare pipe**, this time in the command list itself: `/md regentest [N|clear]` and
`/md run start|stop|status`, which the About tab paints and `/md help` prints. Both read with
slashes now. That rule has now been broken four times by three different kinds of notation —
maths, an alternation, and a usage string.

## 2026-09-07 — v0.11.3 and v0.11.4: three windows become one

**v0.11.3**: the simulator is a panel, hosted as the dashboard's third group. `/md sim` selects
it, and toggles the window only when Simulate is already what is showing — which is what the
command always meant. `UI/SimWindow.lua` lost its movable frame and kept everything else.

**v0.11.4**: **Runs** is its own Reports view, and it appears only once a run has been recorded —
a view that is always empty teaches nothing. `RUN_STORED` fires when the recorder stores one and
`nav:SetViews` puts the view there without a reload. The Review pane already knew how to list a
run's pulls, so the view is that pane with a run selected instead of the ring of fights.

The level-3 box is built and tested and still has no user. Nothing needed it, which is the right
reason not to use it.

One robustness fix the suite forced: `CreateDashboard` is idempotent. Firing `MD_READY` twice
built a second window whose buttons shadowed the first, and the only reason that was ever visible
is that `tools/dashui.lua` fires it — the assertion is in the suite now.

**v0.11 is complete.** One window, four groups, the settings palette throughout: Spells,
Reports, Simulate, Settings. Every entry point that used to open a window of its own now selects
a view: `/md`, `/md sim`, `/md options`, and the minimap button's right-click. The replay window
stays separate, as the spec ruled — it is a player, not a view.

Ten suites: simcheck 10, reccheck 46, simwindow 8, regencheck 27, replaycheck 62, replayui 54,
runcheck 69, reviewui 43, navui 25, dashui 39.

## 2026-09-07 — v0.11.5: one group's furniture over another's panel

Two screenshots from the author, Simulate reached from Spells and from Reports, both with the
Spells group's what-if strip, regen line, rank table and recap painted on top of the simulator.

`Refresh()` still assumed every group was the Spells group. It is the rank table's renderer and
it was running on every selection, re-showing the strip and repainting the header lines over
whatever panel the navigation had just put there. It now takes the current group: Spells and
Reports own that furniture, Simulate and Settings bring their own panel and get none of it.

A second bug, latent and about to bite: `ShowOnly` hid and showed in one pass, and the rank
table is registered as the pane for **every** spell family. Whichever key `pairs()` visited last
decided whether it ended up shown, so switching family could have left the table hidden. It hides
everything that is not the keeper and then shows the keeper.

The harness could not have caught either, because it could not see what the eye sees: hiding a
frame hides its children in the client, but the stub had no parent chain, so a hidden panel's
buttons still read as shown. Frames now record their parent, `IsVisible` walks it, and a new
frame starts shown as it does in the client. `tools/dashui.lua` asserts *visibility* rather than
the shown flag: no rank-table hint, regen line, recap or what-if strip over the simulator or the
settings, arriving from either group, and all of it back when Spells is selected.

dashui 39 → 49.

## 2026-09-07 — v0.11.6: a selector that would not stay clicked

The author, on the Runs view: "when I open Reports > Runs > Fights it switches automatically in
a second to the Hellfire subtab."

One second is the dashboard's render ticker. `Refresh()` was calling the Review pane's
`SetSource`, so every two seconds it put the run back on top of whatever the author had clicked.
The source belongs to a *view change*, not to a refresh: it is set once when the navigation
selects Runs or Review, and the pane's own selector owns it from then on.

The same screenshot showed a second bug that had nothing to do with it. A run with no pulls
printed its empty-state row with the header's columns still in it — `# when zone dur tgts casts
spent low mana validate` underneath `This run kept no pulls`. The row pool hands back a used row
and the empty state only sets one cell, so the previous render's text stayed in the rest. Rows
are cleared on acquisition now, scripts and highlight included.

dashui 49 → 53: clicking Fights inside the Runs view sticks across three ticker refreshes, and a
reused row carries no text from its last render.

## 2026-09-07 — v0.11.7 and v0.11.8: the strategy row, and waiting for the good spell

**v0.11.7, the selector the author could not find.** `docs/SPEC-v0.10.md` §6c.4 promised a row of
strategy buttons beside the SUGGESTED title and v0.10.4 shipped only the slash command. It is
there now: one button per objective that has a winner, each with what it optimises on hover.
Clicking one redraws the suggested column from that plan **and keeps the clock where it was** —
switching strategy is a redraw, never another search, because the window does not search
(SPEC-v0.8 §2.5). A recording with no strategies yet shows no row at all.

**v0.11.8, the author's second reading of the same card**: "the main problem is the Rejuvenation
casts — the recording was a lot of overheal, while the right column was 0% but inefficient
Rejuvenation." Right. Rule 4 took the best rate *available*, and when Lifebloom was already
rolling that meant Rejuvenation at 4.72 health per mana instead of waiting a few seconds for
Lifebloom at 6.17. It waits now: if the efficient HoT is on the target and only a worse one is
free, it casts nothing unless the target is under `directBelow`, where a worse heal beats no
heal. On the author's 74 s fight the plan went from Lifebloom-then-Rejuvenation to **four
Lifeblooms and nothing else**, 880 mana of healing, ending with no deficit at all.

replaycheck 62 → 66, replayui 54 → 60. One harness note: a hand-built plan state needs its damage
ring filled, because `RecentDamage` reads it by index and an empty one compares nil with a number.

## 2026-09-07 — v0.11.9: throughput, not health, and the invariant under test

The author on v0.11.8's gate: "in some cases I do apply Rejuvenation if I expect more incoming
damage than Lifebloom can heal, not just on an HP threshold, because a HoT will not heal them
directly. When I want to pop the HP right now I use Regrowth or Healing Touch."

That is a better rule than the one I shipped, and it moves the question. Whether to add a second,
less efficient HoT is about **throughput**: does the healing already on its way cover the damage
arriving over that HoT's own duration? Health *now* is a different question with a different
answer, and rule 2 — the direct heal — already owns it, which is why it sits above rule 4.

So rule 4 now computes `pending`, the healing in flight on that target (every rolling HoT's
remaining ticks, plus Lifebloom's bloom), and subtracts it from the room before choosing anything
— casting into healing that is already inbound is the overheal this rule exists to avoid. When
the efficient HoT is rolling and only a worse one is free, it is bought **only** if
`pending < rate x duration`. The health threshold is gone.

`replaycheck` now separates the three cases: a quiet fight waits for the efficient HoT, heavy
damage buys the worse one even at full health, and a badly hurt target in a quiet fight is
answered with a **direct heal** rather than a second HoT — the author's own rule, and the engine
already agreed.

**And the invariant is pinned.** The author: "be aware that a human cannot see the future like
the simulation does — a human can only guess by aggro, AoE or a target spell indication, plus the
tank is usually the one taking damage." That is exactly the plan's budget: the trailing 5 s *is*
the guess, and "the tank takes damage" is `Anchor`. Until now that was a comment at the top of
`Engine/SimPlanner.lua` and nothing checked it. There is a test now: the same fight run with and
without a burst of damage at 40 s must produce **identical casts before 40 s**, and different ones
after. It diverges at exactly the burst.

replaycheck 66 → 70.

## 2026-09-07 — v0.11.10: a frame without its backdrop template

Two Lua errors from the author, the second caused by the first. `UI/SimWindow.lua` created its
result box with `CreateFrame("Frame", nil, frame)` and then styled it — but the backdrop mixin
stopped being on every frame in 2.5.x, so `SetBackdrop` is nil without `"BackdropTemplate"` and
`UI.StylizeFrame` threw. That aborted `Build()` half way, `resultFS` was never created, and the
search's callback then failed six times over on a nil upvalue.

The line is as old as the simulator. It only became reachable now because v0.11.3 made Simulate a
tab the author would actually click, rather than a window they had never opened. One offender in
the whole codebase; every other styled frame already carried the template.

Two fixes and a guard: the template is there, `Render` returns early when the panel does not
exist (a search finishes across frames and can outlive its window), and the stub **stops
inventing the mixin**. `CreateFrame` installs `SetBackdrop`, `SetBackdropColor` and
`SetBackdropBorderColor` only on frames created with `"BackdropTemplate"`, and those three names
are excluded from the no-op fallback that used to answer for every UpperCamelCase call. Putting
the bug back now reproduces the author's exact error in `tools/dashui.lua`:
`Style.lua:109: attempt to call method 'SetBackdrop' (a nil value)`.

That is the eighth gap the stub has grown in two days, and the pattern is consistent: every one
of them was the harness being *more permissive* than the client, and every one hid a real bug
rather than causing a false one.

## 2026-09-07 — v0.11.11: the strategy chooser is a dropdown

"The strategy selector is out of the window. Also I suggest making it a dropdown, not buttons."
The screenshot shows all four labels overlapping each other and running past the edge: `Safest`,
`Highest health`, `Least mana` and `Most mana left` are long names, four buttons of them plus the
column title is wider than a column, and they grew rightward from the title with nothing to stop
them.

The kit had button groups and nothing else, which is right for two or three short labels and
wrong here. `UI.CreateDropdown(parent, width, height, onSelect)` is a button that says what is
selected and drops a list under it — `SetItems`, `SetValue`, `Value`, `Close`, a per-item
tooltip, and it closes itself when it is chosen from or when its parent hides. One control's
width whatever the labels say.

The replay window uses one, anchored to the window's **right edge** on the header line, so it
cannot run off however long the names are. A single-column replay has no suggested column and
therefore no chooser at all.

replayui 60 → 66: it is one control, the list holds a row per strategy, it says which is active,
the list opens on click and closes on choose, and choosing still swaps the plan without moving
the clock.

## 2026-09-07 — v0.11.12: three of the four strategies were reading nothing

The author: "it again cast a bloom at ~50% HP and then cast Rejuvenation right after. It looks
like it treats HoTs like direct heals — hold long, then cast one, and as a HoT does not heal
immediately, cast another. But healing with HoTs is a proactive play: at a 1.2k deficit with 350+
incoming, it is already time for one Lifebloom with 0% overheal."

Reproduced exactly, and it had two causes.

**The damage a rule reads was only the trailing five seconds**, which falls to zero between
swings on a mob that hits every few seconds. Nothing "fits" until the deficit alone is the size
of the spell, which is precisely "hold long, then cast". `SM.SeenDamage` adds what the target has
taken *since it was first hit* — applied events only, so the causality invariant holds — and rule
4 now reads whichever of the two is busier. A healer does not forget the last thirty seconds.
`hotBelow` also gained `1.00` to its search domain: whether a HoT is worth casting is the fit
rule's question, not a health threshold's.

**And the strategies were a lie.** `deficitArea` and `manaEnd` never made it into the search's
snapshots, so three of the four objectives read `nil`, ranked every plan equal on their own axis,
and collapsed onto the cheapest plan. Four rows on the card with one strategy behind them — which
is why they always agreed, and why the author's proactive play was never on offer. With the
fields carried through, the same fight now splits properly:

```
Safest = Highest health     6.1k mana   floor 93%   ends whole
Least mana = Most mana left 3.8k mana   floor 44%   owes 4
```

The proactive plan the author is describing is what **Highest health** picks: Lifebloom kept
rolling from the first second, never below 93%. The reactive one — wait, cast at 58%, add a
Rejuvenation at 51% — is what **Least mana** picks, and it is not wrong for what it optimises.
The chooser in the replay window is how you look at both.

`replaycheck` 70 → 71, with the regression pinned: every field an objective reads must survive
into the search's snapshots.

## 2026-09-07 — v0.11.13: "can they hold out until the good spell is free?"

Two from the author, one cosmetic and one not.

**The chooser redirected.** Picking "Highest health" showed "Safest", and "Most mana left" showed
"Least mana". Two objectives frequently win with the *same plan*, and the dropdown recovered its
value by asking which objective's winner matched the active plan — so it answered with whichever
came first in the list. The choice is remembered now (`SP.strategyPick`), and the plan is only
consulted when nothing has been chosen.

**And the Rejuvenation on top of a fresh Lifebloom is gone.** The author: "Least mana still waits
until HP drops to ~50%, casts a Lifebloom and a Rejuvenation, instead of casting a single
Lifebloom early, allowing it to bloom, and repeating."

v0.11.9 asked the wrong question. It bought the worse HoT when the healing in flight would not
cover the damage arriving over *that HoT's own duration* — twelve seconds for a Rejuvenation. The
real question is whether the target can hold out until the **efficient** spell is castable again:
a Lifebloom four seconds from blooming does not need a Rejuvenation underneath it, it needs four
seconds. The gate now measures against that window.

The pattern on the author's 74 s fight is now Lifebloom, bloom, Lifebloom again — at every
setting of the health gate — and **Least mana got cheaper doing it**, 3644 against 3761. The
author was right that the pair was strictly worse: the same coverage for 117 mana less.

replaycheck 71 → 72, replayui 66 → 68.

## 2026-09-07 — v0.11.14: overheal and regen in the replay, and v0.12 re-scoped

"I would like to see overheal % and mana regenerated overall in the replay, so I can estimate
strategy efficiency." Both are on the score line of each column now, beside spent and the floor:

```
spent 2.2k   regen 467   overheal 4%   lowest 44%   0 dead
```

The trace samples cumulative healing and overhealing on the same grid as the mana curve (two more
columns; the budget check already shrinks `dt` to fit), so `State:Overheal` and `State:Regen` cost
the state machine nothing and move with the clock like everything else. Regen is what came *back*
— the pool now, less the pool at the pull, plus everything spent — rather than what is in the
pool, because that is the number that separates two strategies. Overheal is a share of gross
healing, the convention everywhere else in the addon, and it reads `-` rather than `0%` until
something has actually been healed.

**And `docs/SPEC-v0.12.md` changed its rule.** The author: "you can keep the indicators that I
switched off. If there is an option to see it, then technically I could see it — if it is
switched off it means I prefer clarity, or maybe I do see those in another way." So the line is
what Cell *can* display, not what is displayed today; the on/off column stays as a record,
because it makes the explanations useful in the other direction — a card that reasons from
something they are not showing is a finding about their UI.

The spec gained **§6, why it cast that, there, then**: `Plan:Decide` returns a reason record with
the numbers that made the rule fire (deficit, incoming rate, healing in flight, the room, what
the spell heals, its rate per mana), rendered as a sentence under the cast in both columns —
including for a *wait*, which is a decision. The classifier's labels on the recorded casts get
the same treatment: not `overheal` but "target was at 92%, 1194 of 1592 wasted". With one rule
about what a reason may be: the inputs the rule read, in the author's units, never a
justification written afterwards and never a fact `Decide` was not given.

replayui 68 → 72.

## 2026-09-07 — v0.12.0: recording what the frames show

`docs/SPEC-v0.12.md` §3. Two new event kinds, neither of them modelled yet:

- **`K.THREAT`** — `UnitThreatSituation` per tracked target, sampled on the 2 s mana tick and
  written only when it changes. This is Cell's Aggro bar and border, which the author has on.
- **`K.ECAST`** — a hostile cast aimed at a tracked target, which is Cell's Targeted Spells. Not
  foresight: the bar is on screen, and reading it is reading the screen.

The combat log makes the second one harder than it looks. `SPELL_CAST_START` usually carries **no
destination**, because the mob has not committed to a target yet, and it never carries a cast
time. So the recorder writes the cast down as it starts and `ScenarioFromRecording` **pairs it
with the damage it did** — that gives the target it actually hit and the moment it landed. A cast
that never landed keeps no landing time at all: the author watched a bar that came to nothing,
and so does the plan. The pairing is post-hoc, which a recording always is; what the plan will be
given in v0.12.1 is only what the cast bar showed.

`db.recordThreat` (default on) turns the pair off. `reccheck` 46 → 53, with a scripted Shadow
Bolt that lands and one that does not.

One fixture lesson: the first cut inserted a two-second `advance` for the new cast, which moved
every timestamp after it and broke four aura assertions in two other suites. The events ride
inside an existing three-second step now, and the fixture's clock is where it was.

## 2026-09-07 — v0.12.1: the plan reads the frames

`docs/SPEC-v0.12.md` §4. Two entries join the causality budget, and both are present tense:

- **`S.threat[i]`** — `Anchor` now prefers whoever the mobs are actually on, after the tank role
  and before "whoever has taken the most". That is the aggro border saying the pack has left the
  tank, which nothing in the plan could previously see.
- **`S.incoming[i]`** — a hostile cast whose bar is up, with the moment it lands and what that
  spell really hit for **in this fight**. Rule 4 counts it towards the room when it will land
  inside the HoT's own life. A cast the fight has no sample of counts as nothing and the damage
  rate carries it, so an unknown spell can never inflate a decision.

A cast enters the state when its bar starts and leaves when it lands, so the plan sees exactly
the window the author saw the icon for.

**The line is now a test, not a claim.** Same fight, three ways: with nothing, with a 1500 hit at
40 s, and with that hit plus the cast bar that announced it at 38 s.

| scenario | first heal |
|---|---|
| burst at 40 s, no bar | 40.5 s, after the hit |
| the same burst, bar up at 38 s | 38.5 s, before it |

The burst alone changes nothing before it lands; the bar moves the heal in front of the damage.
That pair is the whole ethic of the version, and it sits beside v0.11.9's older half — a swing
with no bar may still change nothing.

Two Lua traps on the way, both the same shape as ones this repo has hit before. `CatchUpFrames`
closed over cursors declared *below* it, so it read globals and silently saw nothing — the same
upvalue-ordering bug as `HasSwiftmend` in v0.9.7. And a one-occurrence `replace` edited the older
causality test's plan instead of the new one, so the new test was gated at 90% health and could
never fire at 91%.

replaycheck 72 → 76.

## 2026-09-07 — v0.12.2: drawing what is coming

`docs/SPEC-v0.12.md` §5. The replay now draws the two indicators the plan reads, in the author's
own Cell positions: **Targeted Spells** as a 20 px icon at the frame's top-left, offset -4/+4,
one at a time, with the cast's remaining time sweeping over it and the spell named on hover; and
**Aggro (bar)** as a 20 × 4 bar above the top-left corner, yellow while somebody else holds it,
red when it is on this target.

Both appear on **both columns**, because both are watching the same fight: the suggested column
is answering the same cast bar the author was. They come off `rp` rather than out of the trace,
for the same reason — a cast bar is a fact about the fight, and the trace is per simulation.

A cast that never landed still shows for the three seconds its bar plausibly ran, then goes.
That is the honest rendering of a bar that came to nothing.

`replayui` 72 → 79: the icon appears while the cast is in the air on both columns, names the
spell and its landing time on hover, is gone once it has landed, and a cast with no landing is
still indexed.

## 2026-09-07 — v0.12.3: why it cast that, there, then

`docs/SPEC-v0.12.md` §6, the last piece of the version. Every decision the plan makes now carries
the numbers that made it: `Plan:Decide` fills a reused `reason` record (`Because(self, rule,
fields)`) on all five rules and on the wait, `SM:Run` copies it into the trace beside the event it
caused, `Engine/ReplayTrace.lua` answers `State:LastReason()`, and `SP.ReasonText` renders the
sentence.

```
14.50  Lifebloom R1   873 missing, 97/s coming in -> all 1.4k lands, none wasted;
                      6.2 healing per mana, the best this plan buys
 7.00  wait 8s        waiting: 262 missing at 51/s leaves room for 876, and the
                      smallest HoT heals 1620
```

A wait says which wait it is, which took three passes to get honest. "Too little for any HoT to
land whole" was being printed for three different situations: nothing fits, every bound HoT is
already rolling there, and *waiting on purpose* for the efficient one (rule 4's v0.11.13 branch,
which declines a cast and had no way to say so). Each now has its own sentence, and the near-miss
one prints whole numbers — rounded to "1.6k" on both sides, a 47-mana miss reads as a
contradiction.

The recorded casts get the same treatment from the other side (§6.2): `SP.CastWhy` turns the
classifier's one-word label into the recording's own numbers, and `Classify` now stores what the
sentence needs — stacks, ticks left, how late, the deficit and the cost. Every label carries a
number now, including the ones that did not (`stack`, `late`, `fine`, `utility`, `shift`).

The card gained the side-by-side of §6.3 — the first cast the plan would not have made, with both
explanations under it:

```
why, at 7s - the first cast the plan would not have made:
  you    Lifebloom R1 -> Penek
         overheal: target was at 95% (262 missing) and Lifebloom heals 1.4k: 1.1k wasted
  plan   wait
         waiting: nobody under the 60% line - the neediest is at 95% (262 missing)
```

**§6.4 is the rule and it is now a test, not a comment.** `replaycheck` wraps `Plan:Decide` over
two scenarios, and for every reason record asserts field by field that each number is
recomputable from the state `Decide` was handed at that instant: `hp` is that target's health now,
`deficit` is `maxHP - hp`, `rate` is the trailing 5 s or the fight so far, `pending` is what is
actually rolling on them, an inbound cast is one that has not landed yet, and any field not on the
allow-list fails. It caught a real bug immediately: `math.max(recent / 5, SM.SeenDamage(S, i, t))`
passes **both** of SeenDamage's returns to `math.max`, so the biggest single hit won and the wait
sentence reported 371/s where the rate was 137/s. That is the multi-return trap CLAUDE.md
documents, fourth occurrence, and this time in code whose whole job is to tell the truth about
numbers.

`replayui` asserts the other half: every cast that lands in either column has a sentence, and
every sentence has a number in it.

replaycheck 76 → 80, replayui 79 → 80. All ten suites green.

## 2026-09-08 — v0.13.0: a spell is a series of deposits

`docs/SPEC-v0.13.md`. The author, after seeing what the logs said:

> "you can consider each spell as a serial of heals ... this way you can make incoming
> damage estimate and calculate what is the best setup of casts to cover incoming damage
> as close as possible (minimal hp gap and minimal overhead) with the lowest mana
> investment ... it should be easy to find the solution instead of static trashhold rules"

That is the whole design. `Engine/SimSolver.lua` builds every spell as `{dt, amount}`
deposits out of `SpellKit` — which is to say out of **the user's own stats**, so the same
code schedules differently for a level 64 druid in Hellfire and a level 70 in Sunwell,
with no thresholds to re-tune. Against them stands the demand: health missing now plus
what the forecast says will go missing.

**The forecast may read only what a human can see** (`docs/SPEC-v0.12.md` §2). Scheduling
against the damage that actually arrives would make the coach clairvoyant, and
`tools/solvercheck.lua` holds the same line `replaycheck` does: a burst at 40s may not
change a cast made before it.

Every `(spell, target)` is scored by projecting the target twice and taking

```
saved = gap(without) - gap(with)        value = saved / mana
```

One number carries all three asks. The health gap is literally the integral. Overheal
needs no term: a deposit landing above full buys no reduction, so it scores itself down.
Mana is the denominator. And the timing falls out — a deposit landing late reduces the gap
less than the same one landing now, so a deep deficit pulls a direct heal and spread damage
pulls a HoT, from the same code. The tests assert exactly that, and it holds:

```
a deep deficit with no incoming pulls a direct heal   -> Healing Touch r12
a small deficit with damage coming pulls a HoT        -> Lifebloom
```

Safety stays first: anyone projected through the **measured** danger line takes the
cheapest cast that clears it before efficiency gets a vote.

**The control experiment** (`tools/solvercmp.lua`), five real recordings, same engine,
same lexicographic tuple:

```
rules (5 thresholds)              deaths 0   floor 0.0s   mana 21900
solver (minValue 15, horizon 18)  deaths 0   floor 0.0s   mana 12372     -43%
```

Two surprises from the sweep. **`minValue` is nearly inert** — anything under 10 changes
nothing, because every candidate already clears ten health-seconds per mana; the dial only
bites at 40, where it starts killing people and the tuple correctly rejects it. And
**horizon is not monotonic**: 12s leaves 2.1s under the danger line, 18s leaves none, 24s
leaves 1.4s. Too short and the dip is not seen coming; too long and a burst is smeared into
an average.

A bug worth writing down: `SM:Run` hands back a **pooled** result table, so scoring two
plans and then comparing compares one plan with itself. The first version of the
comparison reported five perfect ties.

The threshold planner stays as the control. Nothing is switched over yet: the solver has
no reasons in the replay, no search over its parameters, and the level 70 heal values it
would need to be judged against the logs are still wrong.

11 suites green (solvercheck 17 new).

## 2026-09-08 — v0.13.1: healer intuition

`docs/SPEC-v0.13.md` §8. The solver's forecast was blind exactly where a healer is not: at
the pull, nothing has been seen, so nothing is expected, so it waits — while anyone who has
run the place is already putting a Lifebloom on the tank.

`Engine/Intuition.lua` learns that from recordings, keyed by what is knowable before the
first hit: zone and role, an opening rate (first 10s) and a sustained rate, per head.

**The invariant is the whole feature.** `IN:Build(recs, excludeID)` takes the exclusion as
a required argument rather than an option, because a fight that teaches itself is
clairvoyance with extra steps. `solvercheck` asserts a fight held out of a corpus of one
leaves *no* prior; that one fight is an anecdote; and that the prior does not change any
cast made before a burst it never saw.

It learns the right thing. Over ten ranked Nightbane logs:

```
TANK    1463 / 668 per second (opening / sustained)
DAMAGER    6 /  85
HEALER     0 / 149
```

The tank eats 1463/s for ten seconds; the damagers take nothing at the pull and 85/s later,
which is the AoE phases. And the behaviour it exists for holds: **with no prior the solver
waits at the pull, with one it pre-casts Lifebloom on the tank before the first hit lands.**

**It ships off, because I could not show it helps.** On the author's five recordings,
leave-one-out costs +3.6% mana for nothing — those fights are effectively solo, so there is
no tank in the corpus to learn from and the prior only speculates on the healer. On the
ten-raid corpus the prior is right but both planners kill 29-50 people in fights where
nobody died, because the level 70 heal values are 1.6-1.8x low. That comparison measures
the broken kit, not the feature.

So: built, tested, safe, `prior` nil unless passed. Turning it on waits on v0.13.3.

Corpus: eight more ranked Nightbane fights imported (ten total, 3-13% foreign healing).

11 suites green (solvercheck 17 -> 26).

## 2026-09-08 — v0.13.2: blurred foresight, the explainer, and a menu

Three things, from one observation by the author: a prior learned from other fights "can be
totally irrelevant". A blurred memory of **this** fight cannot be — it is this fight.

**`Engine/Foresight.lua`.** Damage bucketed at 4s, smeared into neighbouring buckets,
perturbed by a deterministic hash, quantised to six levels, capped at 10s of sight, trusted
at 0.5. The shape survives; the numbers do not.

Reading it **is** foresight, and that is said rather than hidden: the strict causality
invariant does not hold for such a plan, `plan.foresees` is true, and every report prints
"NO - sees this fight" beside it. What is defended is that the degradation is real, and
each clause is asserted:

```
it knows a burst is coming before it lands   350/s at 34s vs 0/s at 10s
it cannot place the burst                    already lit 6s early
it cannot size it                            4900 vs 8200 = 40% off
it sees nothing beyond its horizon           0 at the pull for a burst at 40s
the same fight deforms the same way          seeded on the fight id
```

And it does its job: on a clean burst at 40s the blind solver first answers at 34.5s, the
foresighted one at 30.5s -- into the burst instead of after it.

**The explainer.** The solver decides on a number, so it names the number, through the same
`SP.ReasonText` path the replay and card already use:

```
1.2k missing, 350/s expected -> closes 3.4k health-seconds of the gap for 220 mana:
  15.5 per mana, the best on offer
waiting: the best cast buys 12.1 per mana now and 18.4 after one global cooldown, and
  nobody falls that far
```

**The menu.** `SP.STRATEGY_SET`: three forecasts (none / prior from old logs / blurred
foresight of this fight) plus two rule configurations and two solver dials, all built by
`SP.MakeStrategy` and run side by side by `tools/strategies.lua`. Leave-one-out for the
prior is enforced there, not merely available.

**On the author's own recordings, neither forecast helps:**

```
Rules: balanced                  deaths 0  floor 0.0s  mana 21900  98 casts  causal
Solver: no intuition             deaths 0  floor 0.0s  mana 12372  54 casts  causal
Solver: intuition from old logs  deaths 0  floor 0.0s  mana 12812  56 casts  causal
Solver: blurred foresight        deaths 0  floor 1.4s  mana 12769  56 casts  NOT causal
```

The blind solver wins. Both forecasts spend 3-4% more, and the foresighted one gives up
1.4s under the danger line having anticipated damage that arrived somewhere else. A small,
mostly-solo corpus is not a verdict on the idea, and the raid corpus cannot settle it while
the level 70 heal values are 1.6-1.8x low. Both stay selectable; neither is default.

11 suites green (solvercheck 26 -> 46).

## 2026-09-09 — v0.13.3: four forecasts, and a prior from other people's raids

The author asked for a fourth solver variant: intuition merged from "lots of external logs
... 10+ logs of different raid, transform into our format, merge all and blur - so its like
intuition from different experience collected over time".

Twelve more fights fetched, one per encounter, across Karazhan, Gruul/Magtheridon, SSC/TK
and BT/Hyjal; with the ten Nightbane parses that is **22 fights across 13 encounters**.
`tools/buildintuition.lua` folds them into one blurred profile and writes
`Data/Intuition_TBC.lua`.

**The change that makes any of it work: rates are fractions of max health, not damage.**
The corpus is level 70 raids and the author is level 64 in Hellfire. A prior in raw damage
would tell a 4k-health warrior taking 400 a second that they are fine, because the Sunwell
tank it learned from has 13k. In fractions the same prior reads 360/s on a 4k tank and
1170/s on a 13k one, which is asserted.

What 22 fights say, blurred to the nearest half percent:

```
TANK      9.0% of health per second opening, 5.5% sustained   (spread 5.1x)
HEALER    0.0% opening, 1.5% sustained                        (spread 23.5x)
DAMAGER   0.0% opening, 1.5% sustained                        (spread 5.0x)
```

A fair summary of raiding: the tank is the one being hit, hardest at the pull, and nobody
else takes anything until the fight develops. The spread rides along so the prior can be
doubted.

The four now selectable: `solver-blind`, `solver-prior` (your own records, leave-one-out),
`solver-corpus` (the shipped one), `solver-sight` (blurred foresight of this fight, the
only one that is not causal).

**On the author's recordings the corpus prior changes nothing at all**, and that is right
rather than broken: their fights are effectively solo, the damage lands on the *healer*,
and a corpus of raids has learned that healers take nothing at the pull. A prior built from
raiding does not transfer to solo play because the roles do not mean the same thing. The
mechanism is asserted on its own instead — given a party with a real tank, the blind solver
waits at the pull and the corpus-primed one opens on it.

Two bugs worth recording. `SP.MakeStrategy` set the corpus prior and then the next branch
overwrote it with the own-logs one, so the two variants scored identically to the digit --
which is what gave it away. And `tools/run.sh` passes the checkout root as `arg[1]`; the
other tools get away with reading from `arg[1]` only because their parsers happen to reject
a path, and a new tool that did not immediately tried to `dofile` a directory.

11 suites green (solvercheck 47 -> 58).

## 2026-09-09 — v0.13.4: ranking on a held-out fight found the wait rule was broken

The author asked to rank the models on a new Warcraft Logs fight. Prince Malchezaar,
`waFx9B1kNQJWP3hq` #103, Samwellx, 10-man, 129s, 6% foreign healing — an encounter none of
the 22 corpus fights come from, so out of sample for the shipped prior as well.

Two obstacles before a table could mean anything. The **kit is wrong at level 70 and
unevenly so** (Lifebloom 1.55x low, Regrowth tick 1.66x, Rejuvenation 1.78x, Regrowth direct
1.39x on this fight's own log), and strategies differ in spell mix, so the error biases the
ranking and not just the scores. `tools/strategies.lua --calibrate` now scales the kit by
what the log says each spell actually healed — correcting **the experiment, never the
shipped model**. And the **fight does not replay**: health curves fail and the simulation
kills people who lived, so any table from it is suggestive at best.

**What the attempt actually found is a real bug.** The human cast 82 times and nobody died;
every solver variant cast 26. Dropping `minValue` to zero changed nothing, which ruled out
the efficiency floor and pointed at the wait rule:

`Best(S, t, mana, form, atT)` moved the whole projection window to `atT`. "Cast now" was
scored over `[t, t+18]` and "wait" over `[t+1.5, t+19.5]` — **the gap suffered while waiting
was never counted**. Under sustained damage the later window always wins, because the same
spell fills more gap once the target has fallen further, so the solver deferred almost
indefinitely. On the author's light dungeon pulls it hardly showed; on a raid it starves.

`delay` now shifts only the candidate's deposits, and both options are integrated over the
same window. Casts on the held-out fight 26 -> 52, deaths 2 -> 1. **On the author's own
recordings the saving against the rules drops from 43% to 33%**, because part of the old
margin was the solver simply not casting. That number is corrected everywhere it was quoted.

The ranking, with the caveat standing: on a hard raid fight the threshold rules edge the
solver — everyone loses one person and the rules keep people further off the floor — which
is the reverse of the author's dungeon pulls. Blurred foresight comes last and loses an
extra person. Neither prior helps.

A clean verdict still needs the level 70 heal values fixed so the fight replays at all.

11 suites green.

## 2026-09-09 — v0.13.5: the control row, and a retraction

The author restated the preference: "we prefer top up people health, minimal overheal is
good, but underheal is bad, also new death is unacceptable."

The score already orders that way -- deaths first and absolutely, then `floorSeconds`
(time under the measured danger line, which *is* the underheal metric), then mana. What was
missing was in the solver's decision, and two changes were tried. **`sag`** weights the gap
integral so a missing point counts more the lower the target already is; it is implemented,
tunable, and **measured inert** -- identical results at 0, 1, 2, 4 and 8 on the author's
recordings and noise on the raid fight -- so it ships at 0 and is documented as unproven
rather than quietly switched on. **`AtRisk`** now treats a target already under the danger
line as at risk whatever the trailing damage rate says; the old test projected forward from
the current rate, so somebody at a tenth of their health with the burst over read as safe.

A third change, capping how often the plan may defer, made the raid fight strictly worse
(one death became two) and was reverted.

**And then the control, which should have been run first.** Replaying the human's OWN casts
through our engine on the held-out raid fight kills one person -- in a fight where the log
records zero deaths. Every strategy also loses one. So that death is the engine's floor, not
any planner's decision, and **v0.13.4's "the threshold rules edge the solver on a hard raid
fight" is retracted**: no ranking on the deaths column meant anything there.

Every strategy table now leads with that control row:

```
held-out raid fight, kit corrected -- the log records ZERO deaths
the recorded casts     deaths 1  floor 11.3s  mana 24281  82 casts   <- the CONTROL
Rules: HoTs only       deaths 1  floor  2.2s  mana 11053  44 casts
Rules: balanced        deaths 1  floor  3.2s  mana 15835  52 casts
Solver: no intuition   deaths 1  floor  5.7s  mana 12923  52 casts
```

Read against the control, every planner beats the recorded play on both readable columns --
a quarter of the time under the danger line, half the mana. Three changes were made chasing
a phantom before that row existed; two were reverted, and the one that survived (v0.13.4's
window fix) had been verified independently on fights that do replay.

11 suites green.

## 2026-09-09 — v0.13.7: the run's gaps get health, and the chooser gets the planners

The author overruled v0.9.4's "there is no run-level play-through": the run feature exists to
record a dungeon and watch it non-stop, gaps included, with the run strip as the timeline for
skipping to a fight. That is right and the old call was wrong -- people finish a pull at 40%,
drink, and walk into the next one full, and none of that was watchable.

**The blocker was data, not the window.** The run recorded only the healer's mana between
pulls; there was no party health at all, so a continuous replay would have frozen every bar
the moment a pull ended. `RR:SampleHealth` now samples the party on the same 2s beat as mana
for the whole run, keyed by NAME rather than roster index because a run outlives any one
pull's roster, stored as a fraction to two places. `runcheck` (69 -> 74) holds that it keeps
sampling after the last pull ends, which is the case the feature exists for.

New data, so the author's Underbog run has none of it: a continuous replay of a run recorded
before today can only draw the bars it has.

**The continuous replay itself is specified, not built** (`docs/SPEC-v0.13.md` §16.2, planned
as v0.14.0). The window plays a pull -- one trace, one clock. A run needs the run's clock and
three states: inside a pull, inside a gap (health and mana from `run.hp` / `run.mana`, drinks
and deaths from the run's events), and the boundary. That is a version's work and half of it
would be worse than none.

Two smaller things in the same breath. **The strategy chooser listed only the four readings
of the last search** -- the planners added since v0.13 were nowhere in the UI. It now lists
every entry in `SP.STRATEGY_SET` first and the search objectives after, prefixed "Search:",
and picking a planner builds its plan on the spot, so the chooser is useful before Coach has
ever run. `replayui` 80 -> 84.

**Validating a whole run already existed and was unfindable.** `/md coachrun 1` searches one
plan for the entire dungeon and `SP.RunGates` gates every pull as part of it; offline that is
now `tools/import.lua gates --run K`. On the author's Underbog:

```
The Underbog 08:46: 34 pull(s) validated, 6 failed
  82% of the run's pulls are safe to coach from
  mana mean            failed on 4 pull(s)
  health curves        failed on 2 pull(s)
```

11 suites green.

## 2026-09-09 — v0.13.8: a coached run had nothing to show

The author: "you say there is a coach run, but in my case it does nothing ... when i open
replay after i dont see coach column in most of the combats."

`SP.CoachRun` worked. Driven against the real Underbog run it finished in 24 frames and
produced a proper card -- you drank 6x and spent 86.7k, the best plan drinks none and spends
69.3k, the drink policy differs (under 40% up to 95% against the author's under 68% up to
100%), and pull 34 alone is worth 2.0k.

What it did not do was write `SP.plans[rec.id]`. It stored the plan in `SP.runPlans[run.id]`
and nowhere else, and that is not what the replay window reads. So every one of the 36 pulls
had an empty suggested column -- while the card printed "Play one to see it: /md replay
<run>:<pull>".

One plan for the whole dungeon is the point of coaching a run, so every pull in it now gets
that plan: 0 of 36 before, 28 of 36 after. The eight without are 2 under the recording gate
and 6 that do not replay -- the same rule a single fight has followed since v0.9.6 -- and
`/md coachrun 1 force` takes it to 34.

`runcheck` 74 -> 78 holds both branches: a run whose pulls all fail their gates is not
coached silently, and forced it coaches everything that is not under the gate.

Coaching still does not open the replay. The card names the pulls worth looking at, and now
following it shows something.

11 suites green.

## 2026-09-09 — v0.13.9: one command

The author: "I would like to make it simplier, it a cumbersome to run validate then coach
then play." It was, and two of those three commands existed only because the third had
nothing to draw.

**Opening a replay now coaches it.** `MD:CoachOnOpen` fires when the window opens on a fight
with no plan: validation happens inside the search, the window opens immediately with the
left column ready, and the suggested column appears when the frame-sliced search finishes.
Cached per recording, so it happens once per fight, and never in combat. `db.replayAutoCoach`
turns it off.

The v0.9.6 rule survives -- a fight that does not replay is not coached silently, because
advice the engine got wrong is worse than none -- but the refusal now carries everything
needed to act on it:

```
does not replay (mana mean) - /md replay 12 force coaches it anyway
```

**And a real interaction bug the suites caught**: opening the window starts a background
search, so pressing Coach in the Review tab was answered with "already searching" -- our
automatic search blocking the author's explicit one. Theirs wins now; ours is cancelled.
That is exactly the kind of regression an offline UI suite exists for, and `reviewui` failed
on it within a minute of the change.

replayui 84 -> 87, reviewui 43 -> 44. 11 suites green.

## 2026-09-09 — v0.13.10: the classifier assumed a rules plan

A live error from the author, with the whole stack and every local:

```
SimPlanner.lua:877: attempt to compare nil with number
plan = { kind = "solver", minValue = 15, horizon = 18, ... }
```

`SP.Classify` labels a Lifebloom `stack` when the target already holds the plan's roll
target, and read `plan.rollStacks` for it -- a threshold-rules parameter the solver does not
have. v0.13.7 put the planners in the replay's chooser, which made `Classify` reachable with
a solver plan for the first time, and picking one crashed the window. `plan.rollStacks or 0`.

**Writing the regression test taught more than the fix.** The first version called
`SP.Classify(rec, plan, kit)`; the signature is `(rec, scenario, plan, kit)`, so the plan
landed in the scenario slot, nothing was classified, and eight assertions -- one per strategy
-- passed vacuously. A test that cannot fail is worse than none, because it is counted.

With the arguments right it still did not bite: the shared fixture casts Lifebloom once, so
it never lands on a live one and the branch is never entered. The recording has to roll it --
four casts inside one seven-second duration, which is what the author's log had at three
stacks. Only then did the suite reproduce the exact error, and only then was the fix worth
anything.

The discipline that got there: run the suite against the UNFIXED engine every time, and
refuse to believe a green result until it has gone red first.

solvercheck 58 -> 70. 11 suites green.

## 2026-09-09 — v0.14.1: the run plays end to end

`/md replay run 2` now plays the whole dungeon on one clock. Crossing out of a pull no longer
stops: **the gaps are played too**, which on the author's Underbog is 51% of the run.

Run mode is a layer over the per-pull replay rather than a rewrite of it. `runT` is the run's
time, `RunSeek` puts it somewhere, and the existing pull machinery draws whatever pull that
time lands in. In a gap there is no trace, so `PaintGap` owns the frames: health from the
run's own 2s samples keyed by name, mana from the same beat, and everything that belongs to a
fight -- cast bars, HoT icons, labels, borders -- cleared, because nothing is happening and
the last pull's leftovers would be a lie. The strip says what the run's events say: drinking,
dead, back up, moving, Innervate, potion.

One bug worth keeping: the first version called `PaintGap()` and then `Paint()`, and `Paint`
repainted every frame from the last pull's trace -- undoing the gap's bars in the same frame.
`Paint` now knows about the gap instead of being called alongside it.

**The clock is the run's.** `12:04 / 45:44   pull 17`, or `between pulls`. A clock that reset
to 0:00 at every pull is what made a dungeon feel like thirty-six separate videos, and the
scrubber spans the whole run.

`replayui` 87 -> 98: run mode opens on the run's clock, starts in the gap before the first
pull, crosses into the pull and keeps going into the gap after it without stopping, reaches
the end of the RUN rather than of a pull, the bars move between combats (0.38 at 4s -> 1.00
at 100s), the drink is named, and the clock reads the run.

**Still to do**, and stated rather than glossed: the frames are rebuilt at each pull boundary,
because `RunSeek` reaches the next pull through `OpenReplay`. Playback does not stop, but the
window re-lays out. Fixing it means one set of frames for the whole run with each pull's
roster mapped onto them by name, and `PaintFrame` is 190 lines bound to the trace and the
scenario's target table -- its own piece of work, queued as v0.14.2 with the in-place
strategy redraw.

12 suites green.

## 2026-09-10 — v0.14.2/.3: two HoT bugs worth a third of a druid's healing

The session began by documenting what was outstanding and planning v0.14.x (`docs/PLAN.md`
Phase 1.15). The first item was the one blocking everything above it: the engine generated
42-70% of the healing a recording said happened, from the identical script.

`tools/reproduce.lua` grew a per-family breakdown, and the single number split into three:

```
family          log      engine   share
?             44946           0      0%
Lifebloom    166094       81182     49%
Regrowth      49944       26387     53%
Rejuvenation  27366       11868     43%
Swiftmend     13185           0      0%
```

**The "?" was spell 33778** — Lifebloom's bloom is a *different spell id* from its HoT
(33763), so a fifth of all the Lifebloom in the fight was credited to nothing. `SD.alias` and
`SD:Resolve(id)` fix the attribution at every heal-attribution site; they are aliases rather
than rows in `SD.spells`, because a second rank-1 Lifebloom would enter `SD.all` and corrupt
the known-rank index that decides which rank the dashboard suggests.

**Then two real engine bugs**, both found by micro-testing one cast at a time (a single
Lifebloom reproduced at ratio 1.00, two at 0.82, four rolling at **0.55**):

- The bloom landed `st.bloom` where the ticks beside it land `st.tick * st.stacks`. A rolled
  Lifebloom therefore under-healed by up to twice its bloom. The log agrees it scales: blooms
  there range 1653-3477 against a flat 528 tick, and a 2.1x spread in one spell's direct heal
  is stack scaling.
- **A refresh restarted the tick timer.** TBC's periodic effect keeps its own cadence across
  a refresh; re-anchoring `nextTick` pushed the next tick back by however far into the
  interval the refresh landed. On a Lifebloom rolled every 1.5s against a 1s tick that is two
  ticks in three -- and 67% was exactly the share of the log's tick count the parse
  reproduced. `>=` rather than `>` on the boundary test, because rolling a HoT on the global
  cooldown lands on a tick boundary constantly.

Result, on the author's own recordings: **47/52/70/42% -> 58/66/74/48%**. Swiftmend went 0%
to 13% once its HoTs existed to consume, confirming it was downstream.

**Not closed, and said plainly**: a raid parse still reproduces 255 of the log's 366 ticks.
The next measurements are queued as v0.14.4 -- which targets the missing ticks belong to (the
scenario tracks 8 of that parse's 10 players, so casts on the other two land nowhere), and
whether the cast times leave room for 82 casts in 129 seconds.

Both fixes were written test-first and each was checked against the unfixed engine: 4b
reported "3 stacks heal 1217 more than 1" (the extra tick stacks, no extra blooms) and 4c
"10 ticks, expected 11". simcheck 10 -> 12 self-tests. 12 suites green.
