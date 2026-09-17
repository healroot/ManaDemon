# ManaDemon — what to test now (v0.7.0)

**Status 2026-09-05 (evening), v0.6.8:** the author ran `/md verify`, a `/reload`, `/md
profile` and `/md spamtest` on v0.6.7 (`.logs/regression/`). Results: **§2 verify passed**
(0 cost mismatches; the 13 CAST lines were all Naturalist and the harness now knows that);
**§6 spamtest passed** (13 predicted, 13 measured); **§8 Nature's Grace CONFIRMED** — two
casts after a crit read `live 1.50s`, the rest 2.00s; **§11 calibration caught a real
model error on its first run** (Regrowth's +healing split, fixed — see DECISIONS §15) and
exposed a sim leak (fixed). Also found: a false "cooldown used: Innervate" on every cast
(the GCD; fixed) and the `/md profile` paste came out **empty** (see §2b).

**Still to do, in this order:** §0b · §2b · **§12 roster in a group** (the biggest unknown)
· **§15 (new in v0.7.0, and it depends on §12 working)** · **§16 (new in v0.7.1)** · §17 · §18 · §19 · §20 · §21 · §5 (needs a hard pull) · §9
(needs one Innervate) · §11 again after a dungeon night · §13 · §14. §1, §3, §4, §4b, §7
are regression-only.

Everything below is done on the druid, in-game, with the Debug Console open
(`/md options` → General → Misc → Debug Console → tick **Enable Debug Logging**).
After each test: **Copy** in the console, paste into a file under `.logs/`
(gitignored) named like the test. Three to five files per session is plenty. The console
keeps 1000 lines by default — the **keep lines** box (top right, saved) raises it to 20000;
a fight with the Mana category on produces roughly 3 lines per second.

Install: `make install WOW_ADDONS="/path/to/_anniversary_/Interface/AddOns"` (or copy
`dist/combat-log-design-arch-ffb907/ManaDemon`), then `/reload`.

> **v0.5 and v0.6 both changed a lot of plumbing.** §0 and §0b are ten minutes of "did
> anything break"; do them first, because everything after is worthless if something is
> broken underneath.

## 0. v0.5 regression pass (5 min) — DO THIS FIRST
The v0.5.0 architecture pass rewrote four tooltips and the rank math's internals with no
intended change to any number. What to confirm:
- **`/md verify`** — output must be **identical to before** (0 COST mismatches, no CAST
  lines but Naturalist). Paste it.
- **Dashboard numbers** — Heal/cast, HPM, HPS, HP5 and To OOM unchanged from v0.4.9 for
  the ranks you know by heart. The **Cast** column is the one exception: Healing Touch and
  Regrowth now read e.g. `2.9s*` instead of `3.0s` (§8).
- **Tooltips** — ElvUI datatext, minimap button and the **widget** (new: hover it) all show
  the same mana block. The widget now takes mouse input; if that gets in your way,
  Options → OOM Widget → untick **Tooltip on hover**.
- **Widget left-click** opens the dashboard (new).
- Watch for Lua errors throughout (`/console scriptErrors 1`).

## 0b. v0.6 regression pass (5 min) — NEW, DO THIS TOO
- **No red `OOM 0s`.** In the BF log it appeared nine times at 72–97% mana. It must never
  appear again; if it does, Copy the log around it.
- **`OOM >2:00 =` on quiet pulls.** When the projection's error is above 70% of its value
  the clock now shows a bound instead of digits (Options → Model → *OOM digits below
  error*). On an easy pull expect mostly `OOM >N:NN =  rest Ns`; on a hard one the digits
  come back and count down as before. Tell me if a pull you *felt* was hard showed only the
  bound — that is the 0.7 needing retuning.
- **HP5 column is gone**; Cast / To OOM / note shifted left. Nothing overlaps.
- **Dashboard opens on your most-cast spell** (Lifebloom), not Healing Touch, until you
  click a tab.
- **A fifth tab, `Waste`**, renders with four `by:` buttons and two `scope:` buttons.
  Before any healing it says "No heals recorded this session yet".
- The **advisor**, when it fires for the potion, now adds *"Innervate is ready too but worth
  ~N: hold it until you're down that far."*
- Debug Console: **ten** categories in two rows (new: `Calib`); nothing overlaps the "keep
  lines" box.

## 1. Smoke test of the UI (5 min)
- `/md options`: tabs switch, frame drags by the tab strip, position survives `/reload`,
  ESC closes. The General tab grew — check **nothing overlaps** at the bottom of the
  Model and Misc panes (new: *Average in Nature's Grace*, *Reset overheal data*,
  *Copy profile*, *Show mana cooldown*, *Tooltip on hover*).
- Half-life slider: drag, type a value in the box + Enter, value clamps to 5–60.
- `/md`: spell tabs highlight, Settings opens the options, the **two-row** Simulate strip
  fits inside the frame, the header/callout/hint lines above the table do **not** wrap onto
  the rows (this is the layout risk in this build — say so if any of them does).
- Debug Console: category checkboxes filter (there is a new **Cast** one), Clear empties,
  Copy popup selects all, Ctrl+C works, ESC closes it.
- Minimap button: left = dashboard, right = options, hover shows the clock.

## 2. Data checks (2 min)
- `/md verify` — expect **0 COST mismatches** (Innervate is skipped). Any CAST line other
  than Naturalist is a bug. Paste the output.
- **`/md profile`** (new) — opens a copy box with every model input, the max ranks'
  live-vs-static costs, the clock state and all settings. Paste it once so the baseline is
  on record; from now on this is the thing to attach to any "this number looks wrong".

## 2b. `/md profile` came out empty — NEW, 30s
The regression paste of `/md profile` was a 0-byte file. Either the copy box was empty (a
bug — was there a Lua error? `/console scriptErrors 1`), or the paste failed. Run it again;
if the box is empty, tell me what the chat line said. `/md verify`'s snapshot section is the
same content, so nothing is lost meanwhile.

## 3. Tree of Life aura on heals — DONE 2026-09-03 (confirmed; keep for regression)
Tooltips on this client show BASE values only (932 in and out of form), so use the
**Heal** log category: every heal / HoT tick you land is logged with amount, overheal and
`[tree]` when in form. Being at full health is fine (overheal is still reported).
1. Out of form: cast Rejuvenation R12 on yourself, wait for 2 ticks.
2. Shift to Tree of Life, cast it again on yourself, wait for 2 ticks.
3. Copy. Expected tick out of form = `(932 + 450 × 0.8 × 1.20) × 1.10 × 1.15 / 4`; in form,
   if the aura counts, +healing becomes 450 + 0.25 × Spirit for the same formula.

## 4. Empowered Rejuvenation on the Lifebloom bloom — DONE 2026-09-03 (confirmed)
1. Cast **one** Lifebloom on yourself out of combat, let it expire (7s). The log shows
   7 ticks and one non-tick "Lifebloom" line = the bloom.
2. Expected tick = `(273 + 450 × 0.5187 × 1.20) × 1.10 / 7`; bloom with EmpRejuv =
   `(600 + 450 × 0.3422 × 1.20) × 1.10`.

## 4b. Relic slot (1 min)
`/md verify` prints the equipped relic and whether the table knows it. If it says NOT in
the relic table, paste the idol's name and tooltip text.

## 5. One real fight with logging on (the clock's constants) — STILL OUTSTANDING
- Any dungeon boss or a long trash pull (≥ 90s) where you actually heal.
- Keep the widget visible; do not read it during the pull, just heal.
- Afterwards: Copy the log (all categories on). The `[tto]` lines every 5s show what was
  displayed vs the model's T. What I will check: was `OOM` roughly honest at the end, how
  often the shown number jumped, how long the `~` / warm-up state lasted. Your one-line
  impression next to the paste helps: "too jumpy", "too pessimistic", "fine".
- **New in this build:** the same log now also answers §9 and §10, so one good fight
  covers three tests. Use Innervate during it.

## 6. To OOM sanity (repeat only if something looks off)
- `/md spamtest`, then chain-cast one spell to OOM. Prediction vs measured on one line.

## 7. Simulate strip (2 min, partly new)
- Put next tier's +healing into **+heal** and see whether the gold row moves for Healing
  Touch and Regrowth. Set **mana** to 2000 and read To OOM. Clear.
- **New second row.** Set **form** to `Tree` while standing in caster form: HoT costs
  should drop ~20% and the stats line should say *costs from the static table while
  simulating form/talents*. Set **Moonglow** to 3 (or to 0 if you have 3): Healing Touch,
  Regrowth and Rejuvenation costs move 3% per rank. `Live` and `Clear` put everything back.
- The interesting question this answers: **does a Moonglow respec change your efficient
  rank?** Tell me if it does.

## 8. Nature's Grace cast times — CONFIRMED 2026-09-05 (Regrowth); Healing Touch still worth one look
The spam test settled it: casts right after a CRIT read `live 1.50s`, all others `2.00s`
(`.logs/regression/spam-test`). The 0.5s and the GCD floor are real on this client. What is
left is only Healing Touch in caster form — Naturalist 5 makes R1 read 1.0s live, under the
model's 1.5s GCD floor, which is expected but worth seeing once.
The model now assumes a spell crit takes **0.5s** off your next cast (floor 1.5s) and
averages that into the Cast column, HPS, HP5 and To OOM. Neither the 0.5s nor Naturalist's
effect is visible in a spellbook tooltip, so:
1. Debug Console → tick the new **Cast** category.
2. Stand still and cast **six Healing Touch R11** in a row on yourself.
3. Copy. Each line reads `live X.XXs - model base Y.YYs, after a crit Z.ZZs (table 3.5s)`.
4. What I check: do the non-crit casts match `model base` (that confirms Naturalist), and
   do the casts right after a crit match `after a crit` (that confirms the 0.5s)?
- Repeat with two or three **Regrowth** casts — with Improved Regrowth those crit almost
  every time, so nearly every cast should show the reduced time.
- If the numbers disagree: Options → Model → untick **Average in Nature's Grace** puts the
  Cast column back to the old behaviour while I fix it.

## 9. Innervate's value (1 min inside §5) — NEW, settles an assumption
The clock now shows `inn 2:10` when you are under 90s to OOM with Innervate ready, and the
advisor quotes the same number. Both assume the 400% multiplies **only the Spirit share**
of your regen, not flat mp5 or Dreamstate.
1. With the **Regen** category on, use Innervate mid-fight (§5 is the natural place).
2. The log prints one line as the buff goes up and one as it fades:
   `mana cooldown UP: GetManaRegen base X casting Y; model expects Z/s while up (...)`.
3. What I check: does the client's `casting` value while the buff is up match the model's
   `Z`? If it is higher, flat mp5 is being multiplied too and the value model is low.
- Also worth one sentence: **did `inn 2:10` replacing `rest 2:10` help or annoy you?**
  Options → OOM Widget → **Show mana cooldown** turns it off. This is the one call in this
  build I am least sure about.

## 10. Overheal-calibrated numbers (needs one real raid/dungeon night) — NEW
The dashboard learns your overheal per spell from the combat log and can apply it.
1. Play normally for a night. Nothing to do — it records in and out of combat.
2. Open `/md`, tick **Effective** (top right, next to Settings). Heal, HPM, HPS and HP5
   become overheal-adjusted and their headers turn your class colour. A grey `?` means
   that rank has no measurement of its own yet and is showing the raw number.
3. Hover a row: the tooltip says the fraction, how many events it is from, and whether it
   is *measured on this rank* or a *family average*.
4. Copy `/md profile` — it lists every family and rank with its fraction and sample count.
5. What I check: are the counts growing sensibly, and does the family-vs-rank split ever
   have enough per-rank data to be interesting? **Deliberately not applied** to the gold
   "efficient rank" or the "rebind?" toast — a noisy measurement should not move those.
- **Also worth a look:** the fight-summary line's `overheal N%`. If it looks obviously
  wrong (say, doubled or halved), the combat log's `amount` convention was latched the
  wrong way — `/md profile` prints which one it picked under *combat log 'amount'
  convention*. Tell me what it says.

## 11. Calibration — the model against your heals (one night, then 1 min) — NEW
The addon now compares every heal you land with what the model predicted for it, per
spell and event kind (tick / direct / bloom), non-crit only, and keeps the ratio.
1. Play a night. Nothing to do.
2. `/md calibrate` (or Options → Misc → *Copy profile*, which includes it). Paste it.
3. What I check: every row with n ≥ 30 should read **ratio 1.000 ± 0.03**. A `HIGH` or
   `LOW` row is a real finding — a relic the table does not know, a wrong coefficient, an
   unmodelled buff — and you will also have seen one yellow *calibration:* chat line about
   it during play (Options → Model → *Calibration drift alerts* turns those off).
4. The two skip counters at the bottom matter: *Lifebloom ticks with no clean stack fit*
   should be a small fraction of Lifebloom ticks; if it is large, tell me — that is the one
   weak spot in this design, on your most-cast spell.
5. **Relics.** If a drift alert fires on the family your idol affects, it now names the idol
   and says what value the data implies — e.g. *"You are wearing Harold's Rejuvenating
   Broach (table: +87, unverified); the data says about +50."* That number is the table
   correction; paste the line. Seven of the eight idols in the table are unverified.
6. The `crit` rows: observed crit rate vs what the model assumed. Regrowth with Improved
   Regrowth should sit near 25% + crit; a big gap there is a talent-model bug.

## 12. The Waste view and the roster (one dungeon, then 2 min) — NEW
1. After a run, `/md` → **Waste**. Try all four `by:` modes and both scopes.
2. **The question that matters:** in `by: Role`, are your party's roles TANK / HEALER /
   DAMAGER, or mostly `UNKNOWN`? And in `by: Target`, do names show a grey `?` after the
   role? The design assumes `UnitGroupRolesAssigned` returns the role people picked in the
   group finder. In a guild premade it may return nothing — the `roster:` line at each pull
   in the debug log (Combat category) says `NAME CLASS ROLE(source)` for everyone; paste one.
   If `(unknown)` is common, the fallback needs work and I want to know now.
3. Sanity: the tank should overheal ~40%, a mage's Water Elemental ~100% (Lifebloom on a
   pet), you yourself around 45%. A warlock who taps shows *Life Tap xN* next to the name.
4. The footer: *"X spent this session, ~Y (Z%) into targets at full health"* — the BF log
   was 24%. Your number, and whether it changes how you cast, is the whole point.
5. The fight summary line now carries *(LB 52%, RG 22%, RJ 14%, other 12%)* and *~1.5k into
   full health*. Check it reads sensibly against one pull you remember.

## 13. Pull budget (between two pulls, 30s) — NEW
Out of combat, hover the widget: two new lines, *Pull budget: N more, M after a drink* and
*a pull in <zone> costs ~X (median of n)*. The drink reminder now reads *"Drink? 62% --
recent pulls here cost ~2.3k -- 2 more, or 4 after a drink."* Does the count match what you
would have guessed? Too optimistic is the failure mode to report.

## 14. Export (1 min) — NEW
`/md export` opens a copy box of tab-separated fights, overheal buckets, roster and
calibration. Paste it once alongside the debug log; from now on I analyse this rather than
regexing prose. Also: **Copy in the Debug Console now prepends the full input snapshot**, so
a pasted log is self-describing — no need to add your talents by hand.

## 15. Cast labels and the new summary line (one pull, v0.7.0) — NEW
Turn on the **Sim** category in the Debug Console, then do one normal pull of 15 s or more
with at least four casts. Three chat lines now arrive at the end instead of one:

1. the usual fight line (`0:40 || net -85 mp5 || spent 3.8k (LB 52%, ...)`),
2. `N of M casts on targets above 85% (2.9k): Lifebloom 9, Rejuvenation 4, Regrowth 1 -
   utility/shifts 1.6k - buffed in combat: Mark of the Wild at 0:39`,
3. only if you pre-HoTted somebody at full health before the pull:
   `pre-pull HoTs on full targets: 0.4k in Lifebloom 2 (78% overheal)`.

What to check, and this is the whole test — **does line 2 match what you remember doing?**
If you rolled Lifebloom on a healthy tank the whole fight, most of your casts should be in
the "above 85%" count and Lifebloom should lead the list. If the count looks far too low,
health is not being read at cast time (see the `unknown` bucket below).

In the debug log, the **Sim** category prints one line per fight:
`labels: utility 300/2, shift 0/0, early 220/1, overheal 2900/14, ok 380/2 = 3800 (fight
spend 3800, delta +0)`. Two failure modes to report:
- a `label identity BROKEN` line — the labelled mana and the spend tracker disagree by more
  than 2%, which means casts are being missed or double counted;
- a large `unknown` HP bucket, visible as line 2 counting far fewer casts than you made —
  that is `UnitHealth` failing to resolve group members and it breaks everything in v0.7.

Also: history now keeps **200** fights instead of 20, and a fight with fewer than 4 of your
own casts is no longer recorded at all. After a dungeon night, `/md export` should list
many more fights than before.

## 16. The 116 mp5 the regen API does not report (5 min, v0.7.1) — NEW, and the most interesting
Replaying the BF-1 hard pull through the new engine turned up something the model does not
know about. Over those 40 seconds, continuously inside the five-second rule, you gained
**2072 mana**. `GetManaRegen` accounts for 1140 of it. The other **931 (23 mana/s, 116 mp5)**
is real, and taking the whole log apart on 2026-09-06 showed it is **two different things**:

| | cadence | size | where it appears | what it is |
|---|---|---|---|---|
| **A** | exactly **2.00 s**, 497 times, never varying | **17** (8.45/s = **42 mp5**) | in combat *and* out of it, all 28 minutes | a property of **your character**: the mp5 bucket — gear, an idol, or a paladin's Blessing of Wisdom |
| **B** | **3.00 s** (55% of its events have a partner exactly 3.00 s later; the baseline at 3.5/4/5 s is 9%), one to four phases overlapping | 13–15 each, ~14.7/s here | **373 of 378 events in combat**, and **0.0 to 17.6 mana/s** depending on the pull — exactly zero in two of the thirty | a property of **the group**: a party-wide periodic energize |

Stream B is very likely the **shadow priest** — 5% of a shadow DoT that ticks every 3 s is
precisely this shape (Vampiric Touch), and you remember one being in the party. The log
records no classes, so that is corroboration rather than proof, and Vampiric Touch is a
level-70 spell.

Neither is Dreamstate (no points in it). **Nothing is being added to the model on a guess** —
and note that A and B want opposite treatment: A is a constant of your character that the
clock could add once it is confirmed, while B is *not yours* and must never be modelled, only
measured per fight by the recorder.

What settles it, in this order:

1. **Solo, out of a group, no buffs, out of combat.** `/md regentest 30` standing still. The
   report now prints a **tick histogram** that does this decomposition for you — every gain
   size (clustered within ±1) with its count and its beat:

   ```
   regentest: tick histogram (size x count, cadence) -
         138 x 14   the reported spirit tick
          17 x 14   a 2s beat - 43 mp5 the API does not report
       13-15 x 36   a 3s beat - a party energize, not yours
   ```

   Solo, you should see the spirit tick and possibly one 2 s line. If a 2 s line appears, that
   is stream A and it is **yours** — check the mp5 it prints against the mp5 on your character
   sheet. If only the spirit tick appears, A is a buff rather than your gear, and step 2 says
   which.
2. **Same character, in a party with a paladin, Blessing of Wisdom on you.** Repeat. If A
   only appears here, it is the blessing.
3. **In a dungeon with a shadow priest, then one without.** Stream B should appear and vanish
   with them. This is the cheap version of the test; `/md export` on two recorded fights is
   the thorough one.

Copy the log either way. If a stream shows up in step 1 it is worth 116 mp5 on your own
character, which is more than most gear upgrades.

Also, for reference: `/md simrun` should print **10 tests, all ok**, and `/md simreplay
fixture` should print `spend ... (exact)` and a `measured ... -> PASS` line. Those two run
anywhere, including right after login, and are worth doing once after this update just to
confirm nothing about your talents breaks the engine.

## 17. Fight recording (one dungeon, v0.7.2) — NEW
Nothing to do but play. After a few pulls, `/md export` should carry `# recording 1` ..
`# recording 8` blocks, each with a roster, the initial auras, the pre-pull casts and the raw
event stream. Paste one export after a dungeon night.

What to look at yourself, in the Debug Console with **Sim** on:

- `recording started: N tracked, M initial aura(s), K precast(s)` at each pull. In a 5-man
  N should be 5. **If M is 0 while you had HoTs rolling, say so** — the aura scan is the one
  part of this that could not be tested offline.
- `stream <id> recorded: 40s, 312 events, 19 casts, 6169 mana, foreign 22%` at the end.
  *foreign* is how much of the healing on your group was somebody else's; in a 5-man with one
  healer it should be small. If it is over ~50%, replay of that fight will be fiction and the
  Review tab will say so.
- `stream discarded` for short pulls is normal (under 20 s or under 5 casts).

Size: eight streams is the cap and the cheapest non-recent, non-pinned pull is the one that
gets replaced. If your `ManaDemonDB` starts feeling large, tell me the file size — the budget
was ~180 KB for the streams and that is worth checking against reality. `db.recordFights =
false` turns recording off entirely; summaries keep working.

## 18. Does a real fight replay? (after §17, v0.7.3) — NEW
`/md simreplay 1` takes your most recent recorded pull, runs it back through the engine and
prints eight gates with a verdict. `/md simreplay 2` .. `8` for the older ones.

This is the question the whole Coach idea rests on: **can the model reproduce a fight you
actually played?** If it cannot, nothing will be suggested from that fight — by design.

Paste the output. The interesting failures, in order of what they would teach:

- **mana mean / max** over 2% / 5% of pool. On the BF-1 fixture this fails by exactly the
  116 mp5 from §16, so if it fails here too, §16 is the cause and the fix is there.
- **health curves**. Only targets that actually took damage are scored, and a target that
  misses is excluded rather than failing the fight. If every target is excluded, the model's
  heal values are wrong for the people you heal — which is what `/md calibrate` is for.
- **model calibrated**. Says "not yet calibrated" until a spell has 30 events; that is
  printed, not failed.
- **spend coverage** under 90% means mana went on spells the model does not price — in BF-1
  that was 12.6% of buffs, shifts and dispels.

A pull with a death, or with more than 25% of the healing coming from somebody else, is
rejected outright and that is correct: the log truncates damage after a death, and a fight
somebody else healed is not your fight to learn from.

## 19. The card (after a dungeon, v0.7.4) — NEW
`/md coach 1` on a recorded pull. If the fight did not pass §18's gates it **refuses and says
which gate failed** — that is the intended behaviour, not a bug; `/md coach 1 force` shows a
card anyway with the failures listed in its caveat line.

The card names the binds, the five rules with their thresholds, a mana comparison against
"max rank" and "HoTs only", and where your casts went relative to the plan (`early`, `rank`,
`spell`, `stack`, `late`, `overheal`, `unclassified`, plus `idle` moments).

Two things to judge, and they are the whole point:

1. **Is the advice followable?** If a rule reads like something you could not do while
   watching health bars, say so — a suggestion nobody can execute is worse than none.
2. **Is it right?** In particular the verdict line: *"you had 2.1k headroom — nothing here
   needed to change"* should appear on the easy pulls. If every card finds something to fix,
   the card is wrong, not you.

Also check the debug `sim` line `classifier: N labelled vs M spent` — those two must match.

**v0.7.5:** `/md coach` now searches for a better plan before drawing the card. It runs across
frames; `/md coach cancel` stops it. **Watch for a freeze** — if the client hitches at all when
you run it, say so: the slicing uses `debugprofilestop()` and if that behaves differently on
this client the whole search would land in one frame. The debug `sim` category prints
`search done: N evaluation(s)` with the winning tuple, and a physical-floor line that must
never say `IMPOSSIBLE` (that would mean the engine is healing for free).

## 20. The Review tab (v0.7.6) — NEW
`/md` → **Review** (sixth tab, after Waste). One row per recorded fight; click one to select it.

- The **validate** column is blank until you press **Validate** (replaying is not free). After
  that it says `ok` or names the first gate that failed, and a failed fight goes grey.
- Hover a row: the full gate list, foreign share, and which targets were excluded.
- **Coach** is disabled on a fight that failed, with the reason in its tooltip. That is
  deliberate.
- **Pin** protects a recording from being replaced (at most two).
- The bottom two lines are the habits over your summaries and, once you have three fights in a
  zone after a card, the since-your-last-card comparison.

Also new: `/md options` → General → **Fight recording** (left column, under Alerts) with the
record toggle, "let Coach change ranks", and the two thresholds. The options window is taller
now — check it still fits your screen.

Report anything that overlaps, overflows or reads wrong. This is the first new tab since v0.5
and none of it can be checked outside the game.

## 21. The Simulation window (v0.7.7) — NEW
`/md sim`. Pick a party size, a damage pattern and a starting state, set a length, press
**Run**. It runs the max-rank and HoTs-only baselines, then searches for a better plan, then
runs 30 randomised replicates of the winner.

**The damage numbers are made up.** The window says so in grey until you press **From
recordings**, which replaces them with what actually happened in your recorded fights, per
role, and prints how many fights and seconds it measured. Please do that once you have a few
recordings and tell me how far the placeholders were off — the presets are one healer's guess
written down so the window had something to run, and they are meant to be replaced.

What to judge:
1. Does the suggested plan look like something you would do?
2. The replicate line — *"someone below the floor 40% of the time"* — is the interesting one.
   A plan that is mana-optimal but only holds on average crits is a bad plan, and this is the
   only place that shows it.
3. Does the search freeze anything? (Same concern as §19.)

## 22. The trace (v0.8.0) — nothing to test in-game yet
v0.8.0 is engine-side only: the replay window arrives in v0.8.1. What exists is verified
offline by `tools/run.sh tools/replaycheck.lua` (27 assertions). The one thing worth doing
after this update is the usual `/md simrun` (10 tests, all ok) and `/md coach 1` on a
recorded fight, because `Plan:Decide` now returns a third value and Coach caches its plan
for the window — both are invisible if they work and loud if they do not.

## 23. The replay window (v0.8.1; Cell-shaped since v0.8.6) — one recorded pull, 5 min
The frames are your Cell `default` layout, copied from your saved settings (66 × 46, five per
column, your icon slots) — if anything sits differently from your raid frames, say what: the
whole layout is one table at the top of `UI/ReplayWindow.lua`. The one thing Cell has no slot
for is the **cast target**: the spell in flight appears in the top-centre icon slot with its
cast-time sweep and the button's border in the family colour; it holds a moment after landing.
Review tab → select a recorded fight → **Play** (or `/md replay 1`). Two columns if you have
pressed Coach on that fight, one if not — the header says which and why.

1. **Press play at 1×** (1/4× and 1/2× exist for the busy moments). A Healing Touch is a
   *jump*; a Rejuvenation is four steps 3 s apart; Lifebloom ticks every second. Nothing
   glides. If a bar slides smoothly, that is a bug.
   The cast bar: a real cast fills over its **recorded** time in the family colour; an instant
   sweeps the 1.5 s GCD in grey; the name stays, dimmed, until the next cast.
2. **The white tick on the left bars** is the recorder's real HP snapshot, fading over the 5 s
   until the next one. It should sit *inside* the bar's reconstruction most of the time; when
   it does not, note the target and the time — that is the health gate's number, seen.
3. **Scrub.** Drag back and forth; the frames must follow instantly and nothing must flash
   during a drag (flashes belong to events *crossed while playing*).
4. **4× to the end.** The strip's `spent` must equal the summary line's for that fight; a death
   greys the frame at the right moment and the scrubber shows it red.
5. **The right column** (after Coach): its damage pulses land at the same instants as the
   left's — the same red flashes, different green — and `waiting 1.2s` shows while the plan
   holds. Its `spent` should be below the left's; if it is not, the card said so too.
6. Close, reopen with `/md replay 2` (an older fight, no Coach yet): a single narrower column.

Report: the fight number, anything that glided, any tick that sat outside its bar for more
than one snapshot, and whether the window felt readable at 1× — that is the design question.

## 24. Indicators and labels in the replay (v0.8.2) — a coached pull, 5 min
Coach a fight, then Play it.

1. **HoT icons** under the role letter: Rejuvenation, Regrowth, Lifebloom, as their spell
   icons, dimming **from the top down** as they run out (Cell's vertical sweep). Lifebloom
   shows its stacks bottom-right and its border turns **white in its last second** — the bloom
   is coming. Watch one Lifebloom roll 1-2-3 and whiten; watch one Rejuvenation dim to the
   bottom and go. Defensives and debuffs sweep the same way, for exactly as long as they were
   up.
2. **The orange dot** after the squares: Swiftmend is ready *and* has something to eat. It
   should vanish for 15 s after every Swiftmend you cast.
3. **Labels** under the cast text on the left, in the card's colours: `late` red, `overheal`
   orange, `early` / `stack` yellow, `spell` / `rank` grey. The scrubber's cast ticks carry the
   same colours, so before pressing play you can see where the yellow and red are. Find the one
   `overheal` you remember and check it lands on that cast.
4. **The right column's waits**: a grey band over its cast bar and `waiting 1.2s` while the
   plan holds. **Hover the right cast bar**: it names the rule behind the current cast
   (`rule 3: keep Lifebloom rolling on the anchor`) or says why it is waiting.

Report: whether a label ever seemed wrong (say which cast and what you would call it — this
is how the classifier gets corrected), and whether the squares are readable at the frame's
size.

## 25. Defensive cooldowns and debuffs in the replay (v0.8.3) — one dungeon
The recorder now keeps two more things on tracked targets: **defensive cooldowns** from the
whitelist in `Data/AuraList.lua` (Shield Wall, Last Stand, Barkskin, Evasion, Divine Shield,
Pain Suppression, Power Word: Shield, ...) and **every debuff**, capped at 4 per target and
10% of the stream's event budget. Neither changes a number anywhere — the damage a Shield Wall
prevented was recorded as prevented — they *explain* the dips.

1. Record a pull where the tank presses something (or ask them to). Play it: the defensive
   shows as an icon with the accent border in front of the tank's name, for exactly as long
   as it was up; hover it for the name and the time.
2. A boss or caster debuff shows as a small icon on the right end of the bar, with its stack
   count. Hover it.
3. `/md export` → the `# recording` line now ends with `N auras`; a long raid-style fight
   says `(debuffs truncated)` rather than silently dropping anything.
4. **Every id in `Data/AuraList.lua` is from memory and marked VERIFY.** If a defensive you
   *saw* pressed does not show, note the class and the ability: the id is wrong or missing,
   and a wrong id costs an icon, never a number. If an icon appears without a texture (a grey
   square with a letter), the id resolved but `GetSpellTexture` did not — say so too.

Report: which defensives showed, which did not, and — the design question from the reserved
list — whether seeing the tank's cooldown up would have changed what you cast.

## 26. Nothing to do in-game: the import tool reads your recordings
`tools/run.sh tools/import.lua list` finds your SavedVariables (your install path is the
default), lists every recording with its validate verdict, and `validate N` / `replay N` /
`coach N force` / `export N` run the same engine on them offline. **Every recording you make
now reaches the engine without a paste.** The one thing that still needs you: `/reload` (or
logout) after a fight, because the client writes the file only then.

## 27. Measure what the API does not report (v0.9.0, corrected in v0.9.5)
**Solo** — out of a group, no buffs from anyone else, standing still, out of combat, and not at
full mana (spend a few hundred first):

```
/md regentest 30
```

The test now prints its arithmetic on one line:

```
regentest: observed 55.77/s = API 48.76 + Dreamstate 6.52 + unreported +0.49 (+2 mp5)
```

**Only the leftover is stored.** On a druid with Dreamstate the talent rides inside the same
server regen tick as spirit and gear, so there is normally one tick and nothing left over —
`nothing to store - the model already accounts for everything the client regenerates` is the
*correct* result, not a failure. Something is stored only when a genuinely separate stream shows
up in the histogram, above a 5 mp5 floor (the test cannot resolve less than that).

If it does store, the line reads `stored NN mp5 (x.xx/s left over after the API and Dreamstate)`.
It refuses, and says why, when mana was spent, a drink was up, part of the window was inside the
five-second rule, fewer than 6 ticks were seen, or **you were in a group** — somebody's blessing
would land in your own bucket.

`/md regentest clear` forgets a stored measurement.

Then `/reload` and, on the machine, `tools/run.sh tools/import.lua validate 2`. Two things to
check in the header and the gates:

1. `kit: the character's (profile of ...)` — the offline engine is using your stats, not a
   stand-in.
2. The 87 s Hellfire fight's **mana mean** should be around 1%, inside the 2% limit. It was 3.3%
   before v0.9.0, and the term that closed the gap is Dreamstate, which replays never added.

Report the `observed = ...` line and the `mana mean` line.

**If you are reading a regen number that looks too big**, that is the v0.9.0 bug: the first
version of this test stored the size of the whole tick rather than the leftover, so a character
regenerating 279 mp5 was modelled at 556. v0.9.5 refuses such a value, says so once, and a clean
re-run clears it.

## 28. Record a whole dungeon as one run (v0.9.1)
A boss is a pull; a five-man is thirty pulls and the gaps between them, and the gaps are where
the mana goes. Runs are **manual**, so at the instance door:

```
/md run start
```

It names itself after the zone and the time (`/md run start Ramparts fast` names it yourself).
Then play the dungeon normally. At the end, `/md run stop` — or just walk out and keep going:
the run stops itself 30 seconds after you leave the instance, and says so. `/md run status` at
any point prints the elapsed time, the pulls so far, the drinks and how much of the event
budget is spent.

What it records that a single fight does not: every pull including the short ones, the mana
every 2 seconds for the whole run, each drink with the mana either side of it, your deaths and
the time you spent dead, zone changes, Innervates and potions.

Report the stop line verbatim. It looks like:

```
run Blood Furnace 21:14: 30 pull(s), 28:50, combat 57%, drank 4x (3:10, 143 mana/s), mana at pull p50 71%, 1 death(s) (1:35 dead), 41200 mana spent
```

The three numbers worth checking against your memory of the run: **how many drinks**, **roughly
how long**, and **mana at pull p50** (the mana you typically opened a pack with). If the drink
count is wrong, say what the drink buff was called — the recorder watches for `Drink`,
`Refreshment` and `Food & Drink` by name.

Two things to try deliberately, once:
1. **Die**, release and run back. The dead time should appear in the stop line.
2. **Leave and come back** (a corpse run, or a quick step outside). The run should NOT stop —
   there are 30 seconds of grace, and returning cancels it.

Then `/reload` and, on the machine, `tools/run.sh tools/import.lua list` still lists your
single fights; the run itself reaches the tools in v0.9.2. `/md export` already carries it as a
`# run` section.

Limits worth knowing: two runs are kept (pin one on the Review tab from v0.9.2 to protect it),
a run stops itself after 90 minutes, and a very long run stops *recording* new pulls at 30 000
events while still counting them — the stop line says `STREAM FULL` if that happened.

## 29. Review a run: the tab, and the tools (v0.9.2)
After §28's dungeon, open `/md` → **Review**. Above the list there is now a row of buttons:
**Fights** (the eight single pulls, as before) and one button per stored run.

1. Click the run. The list becomes **its pulls, in order**, and the `when` column shows how far
   into the run each one started (`+12:41`). The run's line is printed above the list.
2. A pull under the recording gate is greyed and reads `short - under the recording gate`, with
   **Coach** disabled. It is *kept on purpose*: a dungeon is mostly those. Hover Coach to see it
   say so.
3. **Validate**, **Play** and **Coach** work on the selected pull exactly as they do on a single
   fight. Play should open the replay with the run's name and the pull number in its header.
4. **Pin** reads **Pin run** while a run is shown: a run is kept or dropped whole. Two runs are
   kept; pin the one you want to keep before the next dungeon.
5. **Start run / Stop run** is at the left of the button row, the same as the slash command.

The same address works from chat: `/md replay 1:3` plays the third pull of the first run, and
`/md coach 1:3` coaches it.

Then `/reload` and, on the machine:

```bash
tools/run.sh tools/import.lua runs
```

It lists the stored runs with their stats; `tools/run.sh tools/import.lua list --run 1` lists
that run's pulls, `validate 3 --run 1` is its third pull, and `export --run 1` writes the whole
run to `.logs/runs/<id>.txt`.

Report: whether the pulls in the tab match the pulls you remember (count and rough order),
anything greyed that you think should not be, and the `runs` output.

## 30. Coach a run (v0.9.3)
With a run recorded (§28), open `/md` → Review, select the run and press **Coach run** — or
`/md coachrun 1`. It searches one plan *and one drink policy* for the whole dungeon, with the
pulls chained (mana carried from each pull into the next) and the gaps simulated. It runs across
frames; `/md coachrun cancel` stops it.

The card's two rows are the point:

```
  you       drank 4x (3:10)        never forced      41.2k spent   lowest 18% (pull 12)
  best      drank 2x (1:20)        never forced      33.9k spent   lowest 31% (pull 7)
```

Report:
1. **The two `drank` lines.** Is the plan's drink count one you would believe of yourself? A
   plan that claims you never need to drink in a Ramparts run is telling you something is wrong
   with the model, not with your play.
2. **`where it differs`** names the pulls with the biggest gap between what you spent and what
   the plan would have. Open one with Play (`/md replay 1:7`) and say whether the difference is
   real — whether you would actually have made that call at that moment.
3. **`yours was: under X%, up to Y%`** is the drink policy read back out of your own run. If it
   looks nothing like how you play, the drink detection is off, so say what the buff was called.
4. Anything on the two "pulls not to trust" / "pulls that do not replay" lines that surprises
   you.

The score puts **added time first, then drinks, then mana**: a plan that saves mana but forces
the group to sit is worse than one that spends more and never does. If you disagree with that
order after seeing a card, say so — it is a decision, not a fact (`docs/DECISIONS.md` §v0.9).

Offline, the same thing without the game: `tools/run.sh tools/import.lua coach --run 1`.

## 31. Play a dungeon pull by pull (v0.9.4)
`/md replay run 1` (or Play on a run in the Review tab) opens the run's first pull with a new
**run strip** under the header: the whole dungeon on one line, each pull a block as wide as it
was long, the one you are watching bright, short pulls grey, drinks in blue, deaths as red
marks, and the gaps left as gaps.

1. Hover a block: pull number, length, where it sits in the run, casts and mana.
2. Click one: the window re-opens on that pull, same controls, same speed.
3. Let a pull play to the end. **The next pull opens and keeps playing** — that is the intended
   way through a dungeon. There is no "play the whole run": half an hour at 1x is not review.
4. A single fight (the Fights list) has no strip at all, and the window is the same height it
   was in v0.8.

Report: whether the strip's shape matches the run you remember (long boss pull in the right
place, drinks where you sat down), and whether auto-advance is welcome or annoying. It is one
setting (`db.replayNextPull`) either way.

## 32. Force the suggested column (v0.9.6, shift-click added in v0.9.8)
A fight that fails its gates has its Coach button disabled, and until now the replay window
would not draw the suggested column for it either — even after a forced coach. Now:

```
/md coach 2 force
```

**or shift-click Coach on the Review tab** — a fight that does not replay now keeps a clickable
Coach button marked with a star, and a plain click on it still refuses and names the failing
gate. Either way it prints the card anyway *and remembers* that you asked, so Play on that fight shows both columns
from then on, with `FORCED - this fight does not replay` next to the column's title. Two other
ways in: `/md replay 2 force`, and shift-clicking **Play** on the Review tab. If nothing has
been coached for the fight, forcing says so and tells you to coach it first — the replay window
never searches.

Report whether the second column on a forced fight looks like it is describing the same fight
you played, or obviously not.

## 33. Heal values on your spell tooltips (v0.14.9)
Hover any healing spell on your action bars or in the spellbook. Under the game's own text
there is now a **ManaDemon** block for *that exact rank*, at your current +healing and talents:

- **Rejuvenation:** each tick and how many, and the total over 12s.
- **Regrowth:** the direct heal's range and its crit range, each HoT tick, the HoT total, and
  the whole cast (with and without crits).
- **Lifebloom:** each tick at 1 stack and at 2 / 3, the HoT total, the bloom (and its crit),
  the total if you let it bloom, and what one refresh is worth when you roll it at 3 stacks.
- **Healing Touch:** the range, the crit range, the average.
- **Swiftmend:** how much it gives by eating your Rejuvenation or your Regrowth.
- A downranked spell says so and by how much its +healing is cut.
- If your overheal on that spell has been measured, what it heals after it.

**Hold Shift** while hovering for how each number is built (base heal, +healing times
coefficient, talents). Turn it off with `/md spelltip` or Settings -> General -> Misc.

Report: (1) any number that disagrees with what the spell actually does on a target that is
missing health (a Lifebloom tick at 1 stack and a non-crit Regrowth are the easiest to read
off the combat text); (2) any tooltip where the block appears twice or not at all -- action
bar, spellbook, a spell linked in chat, and with ElvUI's tooltip skin if you use it;
(3) whether Shift updates the tooltip without moving the mouse.

## Reporting
Paste the `.logs/*.txt` files (or their names if committed locally) and, for §3/§4, the
raw numbers. `/md profile` output is welcome with any report. I turn them into
`Data/SpellData.lua` / `Engine/*.lua` changes and record the outcome in
`docs/DECISIONS.md` + `docs/HISTORY.md`.
