# v0.14 — the run, played end to end

## 1. Why

> "So I do want to have a 45min replay, and to see how hp bars has changed inbetween of a
> combat. Thats why there is a full run feature - to record full run, and watch it non-stop.
> If I want to skip to the next combat there is a timeline bar on top to jump to the exact
> fight." — the author

v0.9.4 decided there would be no run-level play-through on the grounds that "half an hour at
1x is not review". That was wrong, and the author is the one who gets to say so. **51% of
their Underbog run is gap** — thirty-six stretches of walking, drinking and rezzing that the
replay could not show at all, and that is where half of a healer's mana decisions live.

## 2. The run's clock

`Engine/RunTimeline.lua` turns a run into one timeline and answers, for any moment: which
pull is running (if any), how far into it, and — in the gaps — everybody's health and the
healer's mana.

**No frames and no client API.** What is true at time t is a pure function of the run, the
same discipline `Engine/ReplayTrace.lua` follows for a pull, and it is what makes the whole
thing testable offline before a window is involved.

```
RT.Build(run)        -> a timeline: alternating pull and gap segments, covering [0, dur]
RT.At(tl, t)         -> the segment at t, and how far into it
RT.NextPull/PrevPull -> what the timeline bar skips to
RT.HpAt(tl, t)       -> { [name] = fraction }, or nil when the run never recorded any
RT.ManaAt(tl, t)     -> the healer's mana, from the run's own 2s samples
RT.Roster(tl)        -> everybody the run ever saw, so the window builds its rows ONCE
RT.EventAt(tl, t)    -> the drink, death or zone change to draw where there is no cast
```

Gap health is keyed by **name**, because a run outlives any one pull's roster, and it is a
**step function** — what was last sampled is what is true until the next sample, which is
what a health bar does.

## 3. What a run recorded before v0.13.7 can show

Nothing, in the gaps: `hasGapHealth` is false and `HpAt` returns nil rather than inventing a
number. The window holds the last pull's bars, which is the honest rendering of "not
recorded". The author's Underbog run is in this position; the next one will not be.

## 4. Run mode in the window (v0.14.1)

`/md replay run 2` now plays **the whole dungeon on one clock**. `2:7` still opens that one
pull, and `run 2 pull` opens the run's first pull the old way.

The per-pull machinery is untouched: run mode is a layer over it. `runT` is the run's time,
`RunSeek` puts it somewhere, and the pull replay draws whatever pull that time lands in.
Crossing out of a pull no longer stops -- **the gap is played too**.

In a gap there is no trace, so `PaintGap` owns the frames: health from the run's own 2s
samples keyed by name, mana from the same beat, everything that belongs to a fight (cast
bars, HoT icons, labels, borders) cleared because nothing is happening. The strip says what
the run's events say is going on -- drinking, dead, back up, moving, Innervate, potion.

`Paint` had to learn about the gap rather than PaintGap being called alongside it: painting
the frames from the last pull's trace immediately undid the gap's bars, which is exactly what
the first version did.

**The clock is the run's.** A clock that reset to 0:00 at every pull is what made a dungeon
feel like thirty-six separate videos; it now reads `12:04 / 45:44   pull 17` or
`between pulls`, and the scrubber spans the whole run.

## 5. Still to come in this version

- **The frames are still rebuilt at each pull boundary.** Playback no longer stops there, but
  `RunSeek` reaches the next pull through `MD:OpenReplay`, which re-lays the window out. The
  fix is one set of frames for the whole run built from `RT.Roster`, with each pull's roster
  mapped onto those rows by name. `PaintFrame` is 190 lines bound to the trace and the
  scenario's target table, so that is its own piece of work rather than a footnote to this
  one.
- The run strip drawn as the scrubber's own cursor, moving through the gaps.
- Changing the strategy redraws the suggested column in place; `RebuildSuggested` still calls
  `OpenReplay`.

## 6. Harness

`tools/replayui.lua` (87 -> 98) plays a run under the stub: run mode opens on the run's
clock, starts in the gap before the first pull, **crosses into the pull and keeps going into
the gap after it without stopping**, reaches the end of the run rather than the end of a
pull, the health bars move between combats (0.38 at 4s -> 1.00 at 100s), a drink in the gap
is named, and the clock reads the run with the pull number or "between pulls".

`tools/timeline.lua`, 27 assertions on the model alone: the segments alternate and cover the
run with no holes or overlaps; a seek lands in the right pull at the right offset; skipping
forward and back finds the right fight from inside a pull and from inside a gap; **health
changes across a gap**; somebody who was in no pull at all still has bars; mana is known in
the gaps; the roster is the union of every pull's; and a run from before v0.13.7 says it has
no gap health rather than pretending.
