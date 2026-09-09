# v0.13 — the solver: a spell is a series of deposits

## 1. Why

Five rules with five thresholds (`swiftmendBelow`, `directBelow`, `rollStacks`,
`hotBelow`, `filler`) is a fixed shape fitted to one healer at one gear level. Every
correction the author has made since v0.11.9 has been the same shape of complaint:
*the threshold is not the question*.

> "healing with hots is a proactive play, when there is 1.2k deficit and 350+ incoming
> its already the time to cast one lifebloom with 0% overheal"

> "in some cases I do apply rej if I expect more incoming damage then lifebloom can heal,
> not just on hp trashhold"

And the logs said it independently (v0.13 research, `tools/wclrules.py`): the #1 ranked
resto druid picks his spell by the **damage rate on the target**, not by its health.
Health medians across his four spells barely separate (80 / 73 / 58 %); the trailing
damage separates by seven times (872 / 2030 / 4993 / 6206).

A threshold cannot express that. A budget can.

## 2. The model

**Every spell is a series of deposits: `{ dt, amount }`.** A direct heal is one deposit
at the end of the cast. A HoT is one deposit per tick. Lifebloom is its ticks plus the
bloom at the end. Swiftmend is one deposit now that *removes* the remaining deposits of
the HoT it eats. Nothing else about a spell matters to the decision.

The amounts come from `RankMath:SpellKit()` — that is, from **the user's own stats**.
The same solver run by a level 64 druid in Hellfire and a level 70 druid in Sunwell
produces different schedules from identical code, because their deposits differ. There
is no table of thresholds to re-tune per character, which is the whole point.

## 3. The demand

Against the deposits stands the **demand**: the health that is missing now, plus the
health the forecast says will go missing over the horizon.

The forecast may read **only what §2 of `docs/SPEC-v0.12.md` allows** — the present, the
trailing damage, threat, and an enemy cast already in the air. It is a guess a human
could make from their own frames, and the causality test in `tools/replaycheck.lua`
continues to hold it to that. Scheduling against the damage that *actually* arrives
would make the coach clairvoyant and its advice unreproducible.

```
demand_i(tau) = deficit_i(t) + rate_i * (tau - t) + inbound lumps
rate_i        = max(trailing 5s / 5, damage seen this fight / elapsed)     -- SM.SeenDamage
```

## 4. The decision

Every candidate is a `(spell, target)` pair the healer can afford, plus **wait**. Each
one is scored by projecting the target's health over the horizon twice — with the cast
and without it — and measuring:

```
gap      = integral of missing health over the horizon      (health x seconds)
saved    = gap(without) - gap(with)                          -- what the cast BUYS
value    = saved / mana
```

`saved` is one number that already contains all three things the author asked for:

- **minimal hp gap** — it is literally the integral being reduced;
- **minimal overheal** — a deposit landing above full buys no gap reduction, so an
  overhealing cast scores itself down without a separate penalty term;
- **lowest mana** — it is per mana.

It also gets the timing right for free: a deposit that lands late reduces the gap less
than the same deposit landing now, so a deeply hurt target pulls a direct heal and
spread damage pulls a HoT, with no rule saying so.

**Safety comes first, as it always has.** If the projection has a target crossing the
measured danger line (`SM` danger, v0.10.3) inside the horizon, only candidates that
prevent that are considered, cheapest first. `deaths` and `floorSeconds` stay ahead of
mana in the lexicographic score; the solver changes how a cast is *chosen*, never how a
plan is *judged*.

**Waiting is a candidate with a value, not a fallback.** The same target is scored one
global cooldown later, with the deficit the forecast will have added and any HoT that
frees up by then. If waiting scores higher and nobody crosses the danger line meanwhile,
the plan waits — which is v0.11.13's "can they hold out until the efficient spell is
free" as a special case rather than a hand-written branch.

## 5. What survives

- `SP.OBJECTIVES` and the four strategies are unchanged: they read the same pool.
- `SM.ChainRun`, the gates, the replay, the trace and the reason records are unchanged.
- The reason a cast carries (v0.12.3) gets *better*, because the solver knows the number
  it decided on: `1.2k missing and 350/s coming -> Lifebloom lands 1357 of 1357 inside
  the gap, 6.2 health-seconds per mana; Rejuvenation buys 4.1`.
- The old threshold planner stays, as `plan.kind = "rules"`, so the two can be scored
  against each other on the same recording. It is the control.

## 6. What is tunable

The solver has **two** parameters where the rules had five:

- `minValue` — the efficiency floor under which it would rather wait and keep the mana.
  This is the mana-budget dial, and it is what the four strategy objectives move.
- `horizon` — how far ahead the forecast is taken seriously. Long enough for a HoT to
  land whole, short enough that the guess is still a guess. Ships at 12s (Rejuvenation's
  own duration) and the search may move it.

`SP.Search` is unchanged in shape: coordinate descent over whatever parameters the plan
declares.

**Measured on the author's five recordings (2026-09-08), against the rules as the control:**

```
rules (5 thresholds)                 deaths 0   floor 0.0s   mana 21900
solver, minValue 15, horizon 18      deaths 0   floor 0.0s   mana 14711     -33%
```

Two things the sweep said that the design did not predict. **`horizon` is the parameter
that matters and `minValue` is nearly inert** -- anything below 10 changes nothing at all,
because every candidate the solver looks at already clears ten health-seconds per mana.
And **a longer horizon is not monotonically better**: 12s leaves 2.1s under the danger
line, 18s leaves none, 24s leaves 1.4s. Too short and the dip is not seen coming; too long
and the forecast smears a burst into an average and under-reacts to it.

## 7. Harness

- `solvercheck`: a spell's deposits sum to the kit's total healing; Swiftmend's deposit
  removes the eaten HoT's remaining ones.
- `solvercheck`: an overhealing cast scores below a non-overhealing one of the same mana,
  with no overheal term in the code.
- `solvercheck`: a deeply hurt target with no incoming damage pulls a direct heal; the
  same deficit spread over the horizon pulls a HoT. Same code, same kit, different demand.
- `replaycheck`: the causality test passes for the solver as it does for the rules — a
  burst at 40 s may not change a cast made before it.
- The comparison, printed and not asserted: solver against rules on every real recording,
  same lexicographic score. The solver has to win or tie to replace anything.


## 8. Healer intuition (v0.13.1)

The forecast in §3 is honest and blind at the moment it matters most. At the pull nothing
has been seen, so the rate is zero, so the demand is zero, so the plan waits — while any
healer who has run the place before is already putting a Lifebloom on the tank, because
**the tank is about to get hit**.

That is not clairvoyance. It is memory of *other* pulls. The author:

> "it should not know the exact future but at least know that some damage is going to be
> in (like the fight start - tank will probably get damage, or aoe is coming) ... as we
> look logs retrospectively we could make some intuition simulation, that add a bit of
> performance for the solver without making it future aware"

`Engine/Intuition.lua` learns a prior from recordings, keyed by the two things that are
knowable before the first hit lands: **the zone you are standing in and the role of the
person**. Each role gets an *opening* rate (the first 10s) and a *sustained* rate, per
head, so a raid of eight damagers does not read as eight times the danger one is in.

**The rule that makes it not cheating: a fight is never in its own prior.**
`IN:Build(recs, excludeID)` takes the exclusion as a required argument, not an option, and
`solvercheck` asserts that a fight held out of a corpus of one leaves *no* prior at all.
Learn from the fight you are replaying and you have re-invented seeing the future with
extra steps. One fight is an anecdote (`MIN_FIGHTS = 2`), and the prior's weight decays to
zero by 15s, so observation beats reputation the moment there is any observation.

### 8.1 What it learned, and what that is worth

Over ten ranked Nightbane logs the prior is exactly the thing the author described:

```
TANK    1463 / 668 per second (opening / sustained)
DAMAGER    6 /  85
HEALER     0 / 149
```

The tank eats 1463 a second for the first ten seconds; the damagers take almost nothing at
the pull and 85/s later, which is the AoE phases. `solvercheck` confirms the behaviour it
is for: **with no prior the solver waits at the pull; with one it pre-casts Lifebloom on
the tank before the first hit lands.**

**Whether it is worth anything is not yet known, and it ships off.** Two measurements, both
inconclusive for the same underlying reason:

- On the author's five recordings, leave-one-out costs **+3.6% mana** for no safety gain.
  Those fights are effectively solo — the corpus has no tank taking damage to learn from,
  so all the prior does is speculate on the healer themselves.
- On the ten-raid corpus the prior is right, but *both* planners kill 29-50 people in
  fights where nobody died, because the level 70 heal values are 1.6-1.8x low
  (`tools/wclcheckkit.lua`). A comparison run on a model that broken measures the model,
  not the feature.

So the mechanism is built, tested and safe, and `prior` is nil unless passed. It gets
turned on when there is evidence it helps, which needs §7 of the plan — the `-- VERIFY`
rows in `Data/SpellData.lua` — done first.


## 9. Deformed foresight, and the three things a forecast may know (v0.13.2)

§8's prior has a flaw the author named at once:

> "the problem with prior records is that they can be totally irrelevant. So I would like
> to use the current fight, but with some deformation, so it does not know exactly numbers
> and patterns and does not trust it, but has a small correction"

A memory of *other* fights can be about a different boss with a different group. A blurred
memory of *this* fight cannot be irrelevant — it is this fight. The price is that reading
it, however blurred, **is foresight**: the strict causality invariant of
`docs/SPEC-v0.12.md` §2 does not hold for a plan built with it. That is stated, not hidden.
`plan.foresees` is true, `tools/strategies.lua` prints **"NO - sees this fight"** next to it,
and it is never the default.

What *is* defended is that the foresight is genuinely degraded, and every clause is
asserted in `tools/solvercheck.lua` rather than claimed:

| deformation | measured |
|---|---|
| time bucketed at 4s and smeared into its neighbours | a single-second burst lights the bucket 6s early |
| magnitude perturbed by a deterministic hash, then quantised to 6 levels | the peak reads 4900 against a true 8200 — **40% off** |
| nothing beyond `sight` (10s) is visible | the rate at the pull for a burst at 40s is 0 |
| what survives is trusted at 0.5 and loses to observation | observation is taken whenever it is higher |

It is seeded on the fight's own id, so a replay reproduces exactly, and a different seed
deforms differently. And it does the thing it is for: on a clean burst at 40s the blind
solver first answers at **34.5s** and the foresighted one at **30.5s** — into the burst
rather than after it.

### 9.1 Three forecasts, chosen by the reader

The author asked for all three, side by side, rather than one on trust:

- **`solver-blind`** — the present only. Causal.
- **`solver-prior`** — a prior per zone and role from *other* fights (§8). Causal, and
  leave-one-out is enforced in `SP.MakeStrategy`, not just available.
- **`solver-sight`** — a blurred, half-trusted view of *this* fight. **Not causal.**

`SP.STRATEGY_SET` holds these plus the two rule configurations and two solver dials;
`SP.MakeStrategy(entry, binds, kit, ctx)` builds any of them, and `tools/strategies.lua`
runs the lot over a corpus and ranks them on the same tuple.

**On the author's five recordings, neither kind of intuition helps:**

```
Rules: balanced                  deaths 0   floor 0.0s   mana 21900   98 casts   causal
Solver: no intuition             deaths 0   floor 0.0s   mana 12372   54 casts   causal
Solver: intuition from old logs  deaths 0   floor 0.0s   mana 12812   56 casts   causal
Solver: blurred foresight        deaths 0   floor 1.4s   mana 12769   56 casts   NOT causal
```

The blind solver wins. Both forecasts spend 3-4% more and the foresighted one gives up
1.4s under the danger line, having anticipated damage that then arrived somewhere else.
That is a real result on a small, mostly-solo corpus and not a verdict on the idea; the
raid corpus cannot settle it while the level 70 heal values are 1.6-1.8x low (§7 of the
plan). Both stay selectable and neither is default.

## 10. The explainer (v0.13.2)

A threshold rule can only ever say which threshold it crossed. The solver decided on a
number, so its sentence names it — same `SP.ReasonText` path the replay and card already
use, delegating rules 7-9 to `SV.ReasonText`:

```
1.2k missing, 350/s expected -> closes 3.4k health-seconds of the gap for 220 mana:
  15.5 per mana, the best on offer
6.6k missing at 900/s: they cross the danger line (34% of health) in 2.5s, and this is
  the cheapest cast that holds it (220 mana)
waiting: the best cast buys 12.1 per mana now and 18.4 after one global cooldown, and
  nobody falls that far
```

`solvercheck` asserts every solver decision renders a sentence carrying a number, and that
none of them contains a bare pipe.


## 11. Four forecasts (v0.13.3)

The author asked for all four, selectable, so they can be judged by looking rather than by
being told:

| strategy | what the forecast knows | causal |
|---|---|---|
| `solver-blind` | the present only | yes |
| `solver-prior` | a prior from **your own** past recordings, leave-one-out | yes |
| `solver-corpus` | a prior merged from **22 logged fights across 13 encounters** | yes |
| `solver-sight` | a blurred view of **this** fight | **no** |

### 11.1 Rates are fractions of health, or nothing transfers

The corpus is level 70 raids; the author is level 64 in Hellfire. A prior in raw damage
would tell a 4k-health warrior eating 400 a second that they are about to be fine, because
the Sunwell tank it learned from has 13k and eats 1400. **So the prior is stored as a
fraction of that target's max health per second** and multiplied by `S.maxHP[i]` at the
call site. That one change is what makes somebody else's raid say anything about your pull,
and it is asserted: the same prior reads 360/s on a 4k tank and 1170/s on a 13k one.

### 11.2 What 22 fights across 13 encounters actually says

`Data/Intuition_TBC.lua` is generated by `tools/buildintuition.lua` and blurred to the
nearest half percent, because a number read off it is not a fact about anybody's next pull:

```
TANK      9.0% of health per second opening, 5.5% sustained   (spread 5.1x)
HEALER    0.0% opening, 1.5% sustained                        (spread 23.5x)
DAMAGER   0.0% opening, 1.5% sustained                        (spread 5.0x)
```

Which is a fair summary of raiding: the tank is the one being hit, hardest at the pull;
nobody else takes anything until the fight develops. The `spread` is carried so the prior
can be doubted — a role that swings five times between encounters is worth less than one
that does not. Per-encounter rows are kept where there are at least two fights (Nightbane,
ten).

### 11.3 The result, which is again not an endorsement

```
Rules: balanced                    deaths 0  floor 0.0s  mana 21900  98 casts  causal
Solver: no intuition               deaths 0  floor 0.0s  mana 12372  54 casts  causal
Solver: intuition from old logs    deaths 0  floor 0.0s  mana 12812  56 casts  causal
Solver: intuition from many raids  deaths 0  floor 0.0s  mana 12372  54 casts  causal
Solver: blurred foresight          deaths 0  floor 1.4s  mana 12769  56 casts  NOT causal
```

The corpus prior changes **nothing at all** on the author's fights, and that is the correct
behaviour rather than a bug: their recordings are effectively solo, so the damage lands on
the *healer*, and a corpus of raids has learned that healers take nothing at the pull. A
prior built from raiding does not transfer to solo play, because the roles do not mean the
same thing. The mechanism is asserted separately instead: given a party with an actual
tank, the blind solver waits at the pull and the corpus-primed one opens on the tank.

All four ship selectable. The blind solver is still the default, because on the only corpus
where our spell values are trustworthy it is still the one that wins.


## 12. Ranking the strategies on a held-out fight (v0.13.4)

A strategy table built from the fights a strategy was tuned on is worth little, so: Prince
Malchezaar, `waFx9B1kNQJWP3hq` #103, Samwellx, 10-man, 129s, **6% foreign healing** — an
encounter none of the 22 corpus fights come from, so it is out of sample for the shipped
prior too.

Two things had to be dealt with before the table meant anything.

**The kit is wrong at level 70, unevenly.** Measured against this fight's own log:
Lifebloom tick 1.55x low, Regrowth tick 1.66x, Rejuvenation tick 1.78x, Regrowth direct
1.39x. Strategies differ in spell mix, so an uneven error biases the *ranking*, not just the
scores. `tools/strategies.lua --calibrate` scales the kit by what the log says each spell
actually healed. **This corrects the experiment and never the shipped model** — nothing is
written back, and `Engine/Calibration.lua` still never feeds `RankMath`.

**The fight does not replay.** Health curves fail their gate and the simulation kills people
who lived. So the table below is suggestive, not a verdict.

### 12.1 What it found instead: the wait rule was broken

The human cast **82 times and nobody died**. Every solver variant cast **26**. Sweeping
`minValue` down to zero changed nothing, which ruled out the efficiency floor and pointed at
the wait rule:

`Best(S, t, mana, form, atT)` moved the whole projection window to `atT`, so "cast now" was
scored over `[t, t+18]` and "wait" over `[t+1.5, t+19.5]`. **The gap suffered while waiting
was never counted.** Under continuous damage the later window always looks better — the same
spell fills more gap once the target has fallen further — so the solver deferred almost
indefinitely.

Now `delay` shifts only the candidate's deposits and both options are integrated over the
same `[t, t+horizon]`. Casts on the held-out fight went 26 -> 52 and deaths 2 -> 1; on the
author's own recordings the saving against the rules drops from 43% to **33%**, because part
of the old margin was simply not casting.

### 12.2 The table, with that caveat standing

```
Rules: HoTs only                   deaths 1  floor 2.2s  mana 11053  44 casts  causal
Rules: balanced                    deaths 1  floor 3.2s  mana 15835  52 casts  causal
Solver: reactive                   deaths 1  floor 3.4s  mana 15076  56 casts  causal
Solver: frugal                     deaths 1  floor 5.7s  mana 12703  51 casts  causal
Solver: no intuition               deaths 1  floor 5.7s  mana 12923  52 casts  causal
Solver: intuition from old logs    deaths 1  floor 5.7s  mana 12923  52 casts  causal
Solver: intuition from many raids  deaths 1  floor 7.7s  mana 14023  57 casts  causal
Solver: blurred foresight          deaths 2  floor 5.6s  mana 15377  53 casts  NOT causal
```

**This table was read wrongly at first, and the correction is §13.**


## 13. The control row (v0.13.5)

§12 concluded that the rules "edge the solver" on a raid because every solver variant lost a
person. That conclusion was wrong, and the thing that would have caught it immediately is
now the first row of every table: **the recorded casts through the same engine.**

```
held-out raid fight, kit corrected -- the log itself records ZERO deaths
the recorded casts     deaths 1  floor 11.3s  mana 24281  82 casts   <- the CONTROL
Rules: HoTs only       deaths 1  floor  2.2s  mana 11053  44 casts
Rules: balanced        deaths 1  floor  3.2s  mana 15835  52 casts
Solver: reactive       deaths 1  floor  3.4s  mana 15076  56 casts
Solver: no intuition   deaths 1  floor  5.7s  mana 12923  52 casts
Solver: blurred foresight  deaths 2  floor 5.6s  mana 15377  53 casts
```

**Replaying what the human actually did kills one person too, in a fight where nobody
died.** So that death is the engine's floor, not any planner's decision, and no ranking on
the deaths column means anything here. Every planner in fact beats the recorded play on both
of the columns that can be read: half the time under the danger line, and half the mana.

Without the control row a planner's failures cannot be told apart from the simulation's, and
three separate changes were made chasing that phantom before the control was run. Two of
them were reverted; the one that survived is §12.1's window fix, which was verified
independently on the author's own recordings, and which is real.

## 14. What "underheal is bad" cost, and what it bought (v0.13.5)

> "we prefer top up people health, minimal overheal is good, but underheal is bad, also new
> death is unacceptable"

The score already orders exactly that way — `deaths` first and absolutely, then
`floorSeconds` (time spent under the measured danger line, which *is* the underheal metric),
then mana. Nothing trades against a death.

What was missing was in the solver's *decision*, and two changes were tried:

- **`sag`** — the gap integral weighted so a missing point counts more the lower the target
  already is: `weight = 1 + sag * (missing / maxHP)`. At `sag = 2` half health counts twice.
  It is implemented, tunable, and **measured inert**: identical results at 0, 1, 2, 4 and 8
  on the author's recordings, and noise on the raid fight. It ships at 0 and is documented
  as unproven rather than quietly enabled.
- **`AtRisk` on the present, not only the forecast** — a target already at or below the
  measured danger line is at risk whatever the trailing damage says. The old test projected
  forward from the current rate, so somebody sitting at a tenth of their health with the
  burst already over read as safe. That is plainly wrong under "underheal is bad" and is
  fixed, though this corpus does not exercise it.

A third change — capping how often the plan may defer — made the raid fight strictly worse
(one death became two) and was reverted.


## 15. Why there is a death in the replay when there was none in the log (v0.13.6)

Traced, and the answer moves the roadmap.

The tank, Handirel, dies at 49.4s in our replay. The log has him at 63% at t=45 and 69% at
t=50 — he was never close. Over the whole fight he took 158,435 damage and received 186,247
healing on a 15,004 health pool.

`tools/reproduce.lua` asks the one question the health-curve gate never did: **replaying the
recorded casts, how much of the recorded healing does the engine actually generate?**

```
Prince Malchezaar   log 301535   engine 131517   44%   deaths 0 -> 1
```

**With the per-tick magnitudes calibrated to the log exactly.** The calibrated Lifebloom is
176 a stack, so 528 at three stacks, which is the log's median tick to the point. So the
shortfall is not spell values, not talents, not +healing. From the same 82 casts and the
same 24,281 mana the engine simply makes half the healing.

And it is not a level 70 problem, which is what this was blamed on for several versions:

```
the author's own level 64 recordings, no calibration, spell data verified in game
Hellfire Peninsula   log  23742   engine 11156   47%
Hellfire Peninsula   log  45760   engine 23945   52%
Hellfire Peninsula   log   7834   engine  5469   70%
Hellfire Peninsula   log   5512   engine  2330   42%
```

Between 42% and 70% everywhere. The author's fights pass their gates only because they have
enough slack to survive it; a raid does not.

Lifebloom is 70% of the healing on the held-out fight — 59 casts, **324 tick events**, 3,577
gross per cast — and a full three-stack Lifebloom in our model is worth 6,654, so the model
over-values a cast that runs its whole duration while under-producing across the fight. That
points at the **HoT lifecycle** — how many ticks survive a refresh, and how many HoTs are
allowed to roll at once — rather than at what a tick is worth.

**This supersedes "the `-- VERIFY` heal values block everything".** They are still wrong and
still worth fixing, but they are not what stops a recording reproducing. `tools/reproduce.lua`
is the measurement to work against.


## 16. The run, watched end to end (v0.13.7 and v0.14)

The author, overruling v0.9.4's "there is no run-level play-through":

> "So I do want to have a 45min replay, and to see how hp bars has changed inbetween of a
> combat. Thats why there is a full run feature - to record full run, and watch it non-stop.
> If I want to skip to the next combat there is a timeline bar on top to jump to the exact
> fight."

That is right and the old call was wrong. The gaps are half of a dungeon -- people finish a
pull at 40%, drink, and walk into the next one full -- and the run strip is already the
timeline for skipping.

### 16.1 What was missing, and is now recorded (v0.13.7)

**The run recorded only the healer's mana between pulls.** No party health at all, so a
continuous replay would have frozen every bar the moment a pull ended. `RR:SampleHealth`
now samples the party on the same 2s beat as mana, for the whole run, keyed by **name**
rather than roster index -- a run outlives any one pull's roster. Health is stored as a
fraction to two places, which is a health bar; more is noise.

`runcheck` holds it: sampled more than once, names and fractions the same length, every
value inside [0, 1], and **still sampling after the last pull ends**, which is the case the
whole feature exists for.

This is new data. Runs recorded before v0.13.7 -- the author's Underbog among them -- have
no gap health, and a continuous replay of one can only show the bars it has.

### 16.2 What is still to build (v0.14)

The replay window plays *a pull*: one trace, one clock, and at the end it opens the next
pull. A continuous run needs a different clock -- the **run's** clock -- with three states
rather than one: inside a pull (drive from the trace, as now), inside a gap (drive health
and mana from `run.hp` / `run.mana`, with drinks and deaths from the run's own events), and
the boundary between them. The run strip becomes the scrubber for that clock rather than a
row of buttons, with a cursor that moves through the gaps.

That is a version's work, not an afternoon's, and it is specified here rather than half
built.

### 16.3 The chooser, and the whole run at once (v0.13.7)

Two smaller things the author asked for in the same breath.

**The replay's strategy chooser listed only the four readings of the last search.** It now
lists every planner in `SP.STRATEGY_SET` first -- the rules, and the solver in each of its
four forecasts -- and the search's objectives after them, prefixed `Search:`. A planner
needs no search behind it: picking one builds the plan on the spot, which is what makes the
chooser useful before Coach has ever run.

**Validating and coaching a whole run already existed and was not findable.**
`/md coachrun 1` searches one plan for the entire dungeon, drink policy included, and
`SP.RunGates` puts every pull through the gates once as part of it. Offline that is now
`tools/import.lua gates --run K`:

```
The Underbog 08:46: 34 pull(s) validated, 6 failed
  82% of the run's pulls are safe to coach from
  mana mean            failed on 4 pull(s)
  health curves        failed on 2 pull(s)
```


## 17. Coaching a run left the replay nothing to draw (v0.13.8)

> "so you say there is a coach run, but in my case it does nothing. it does not open replay
> and when i open replay after i dont see coach column in most of the combats"

`SP.CoachRun` worked -- on the author's Underbog it finished in 24 frames and produced a
real card. What it did **not** do was write `SP.plans[rec.id]`. It stored the run's plan in
`SP.runPlans[run.id]` and nowhere else, and the replay window draws its suggested column
from `SP.plans[rec.id]`. So a coached run left **all 36 pulls with an empty right column**
while its own card said "Play one to see it: /md replay <run>:<pull>".

The plan for the whole dungeon is the point of coaching a run, so every pull now gets it:

```
before   pulls with a plan afterwards:  0 of 36
after    pulls with a plan afterwards: 28 of 36     (34 with force)
```

The eight without are 2 under the recording gate and 6 that do not replay, which is the rule
a single fight has followed since v0.9.6 -- advice from a fight the engine gets wrong is
worse than none. `/md coachrun 1 force` coaches them anyway, and a pull under the recording
gate is left alone either way.

`runcheck` (74 -> 78) holds both branches: a run whose pulls all fail their gates is not
coached silently, and forced it coaches every pull that is not under the gate.

Coaching does not open the replay, and still does not -- the card names the pulls worth
looking at ("pull 34 saves 2.0k") and `/md replay 1:34` now actually shows something when
you follow it.


## 18. One command (v0.13.9)

> "I would like to make it simplier, it a cumbersome to run validate then coach then play"

It was. Three commands answered one question, and two of them existed only because the third
had nothing to draw:

```
before   /md simreplay 12      does it replay?
         /md coach 12          search, store a plan
         /md replay 12         watch it
after    /md replay 12
```

**Opening a replay coaches it.** `MD:CoachOnOpen` runs when the window opens on a fight with
no plan: validation happens inside the search, the window opens immediately with the left
column ready, the hint says *"coaching this fight - the suggested column fills in when the
search finishes"*, and the right column appears when it does. The search is frame-sliced and
cached per recording, so it happens once per fight and never in combat.

**A fight that does not replay is still not coached silently.** That rule is v0.9.6's and it
survives, because handing out advice the engine got wrong is worse than handing out none.
What changed is that the refusal now says everything needed to act on it in one line:

```
does not replay (mana mean) - /md replay 12 force coaches it anyway
```

`db.replayAutoCoach` turns it off.

**And an explicit coach beats the automatic one.** Opening the window starts a background
search, and pressing Coach in the Review tab used to be answered with "already searching" --
the automatic search blocking the author's own. Theirs wins: ours is cancelled.
`reviewui` (43 -> 44) holds it.

For a whole run the shape is unchanged: `/md coachrun N [force]` searches one plan for the
dungeon, because a run's plan is a different question from a pull's, and (v0.13.8) it now
hands that plan to every pull so the replay draws it.
