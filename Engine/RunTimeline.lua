local _, MD = ...

--------------------------------------------------------------------------------
-- The run's own clock (docs/SPEC-v0.14.md).
--
-- A run is one continuous 45 minutes, not 36 separate fights. This turns it into
-- a single timeline you can seek anywhere in, and answers, for any moment:
-- which pull is running (if any), how far into it, and -- in the gaps -- what
-- everybody's health and the healer's mana were.
--
-- The author, overruling v0.9.4's "half an hour at 1x is not review":
--
--   "I do want to have a 45min replay, and to see how hp bars has changed
--    inbetween of a combat. Thats why there is a full run feature - to record
--    full run, and watch it non-stop."
--
-- No frames and no client API here: what is true at time t is a pure function of
-- the run, which is what makes the whole thing testable offline. The window
-- draws what this returns.
--
-- Gap health needs v0.13.7's `run.hp` and is keyed by NAME, because a run
-- outlives any one pull's roster. Runs recorded before that have no gap health;
-- `HpAt` returns nil for them and the window holds the last pull's bars, which
-- is the honest rendering of "not recorded".
--------------------------------------------------------------------------------

local RT = {}
MD.RunTimeline = RT

-- Build the segment list: pulls where they happened, gaps in between.
function RT.Build(run)
    if not run then return nil end
    local segs = {}
    local pulls = run.pulls or {}
    -- pulls in run order; runT0 is set by RR:AddPull
    local order = {}
    for k, rec in ipairs(pulls) do order[#order + 1] = { k = k, rec = rec } end
    table.sort(order, function(a, b)
        return (a.rec.runT0 or 0) < (b.rec.runT0 or 0)
    end)

    local dur = run.dur or 0
    for _, e in ipairs(order) do
        local from = math.max(0, e.rec.runT0 or 0)
        local to = from + (e.rec.dur or 0)
        if to > dur then dur = to end
        segs[#segs + 1] = { kind = "pull", from = from, to = to, k = e.k, rec = e.rec }
    end
    -- the last sample of anything can sit past the last pull
    local mn = run.mana
    if mn and mn.t and #mn.t > 0 then dur = math.max(dur, mn.t[#mn.t]) end
    local hp = run.hp
    if hp and hp.t and #hp.t > 0 then dur = math.max(dur, hp.t[#hp.t]) end

    -- fill the gaps, including one before the first pull and after the last
    local full, at = {}, 0
    for _, s in ipairs(segs) do
        if s.from > at + 0.01 then
            full[#full + 1] = { kind = "gap", from = at, to = s.from }
        end
        full[#full + 1] = s
        at = math.max(at, s.to)
    end
    if dur > at + 0.01 then full[#full + 1] = { kind = "gap", from = at, to = dur } end

    return { run = run, dur = dur, segs = full,
             hasGapHealth = (hp and hp.t and #hp.t > 0) or false }
end

-- Which segment is running at t, and how far into it.
function RT.At(tl, t)
    if not tl then return nil, 0 end
    t = math.max(0, math.min(t or 0, tl.dur))
    for _, s in ipairs(tl.segs) do
        if t >= s.from and t < s.to then return s, t - s.from end
    end
    local last = tl.segs[#tl.segs]
    return last, last and (last.to - last.from) or 0
end

-- The next pull segment at or after t, for "skip to the next fight".
function RT.NextPull(tl, t)
    if not tl then return nil end
    for _, s in ipairs(tl.segs) do
        if s.kind == "pull" and s.from > (t or 0) + 0.01 then return s end
    end
    return nil
end

function RT.PrevPull(tl, t)
    if not tl then return nil end
    local best
    for _, s in ipairs(tl.segs) do
        if s.kind == "pull" and s.to < (t or 0) - 0.01 then best = s end
    end
    return best
end

function RT.PullSeg(tl, k)
    if not tl then return nil end
    for _, s in ipairs(tl.segs) do if s.kind == "pull" and s.k == k then return s end end
    return nil
end

-- The party's health at t, as { [name] = fraction }, or nil when the run never
-- recorded any (before v0.13.7). Samples are a step function: what was last
-- seen is what is true until the next sample, which is what a health bar does.
function RT.HpAt(tl, t)
    local hp = tl and tl.run and tl.run.hp
    if not (hp and hp.t and #hp.t > 0) then return nil end
    local idx
    for i = 1, #hp.t do
        if hp.t[i] <= t then idx = i else break end
    end
    if not idx then idx = 1 end
    local out = {}
    local names, fracs = hp.who[idx], hp.frac[idx]
    for i = 1, #(names or {}) do out[names[i]] = fracs[i] end
    return out, hp.t[idx]
end

-- The healer's mana at t, from the run's own 2s samples.
function RT.ManaAt(tl, t)
    local mn = tl and tl.run and tl.run.mana
    if not (mn and mn.t and #mn.t > 0) then return nil end
    local idx
    for i = 1, #mn.t do
        if mn.t[i] <= t then idx = i else break end
    end
    if not idx then idx = 1 end
    return mn.v[idx], mn.t[idx]
end

-- Everyone the run ever saw, in a stable order: the union of every pull's
-- roster plus anybody the gap samples know about. The window needs one row per
-- person for the WHOLE run -- rebuilding the frames per pull is the thing this
-- version exists to stop.
function RT.Roster(tl)
    if not tl then return {} end
    local seen, out = {}, {}
    local function add(name, class, role)
        if not name or seen[name] then
            if name and seen[name] and class and not seen[name].class then
                seen[name].class, seen[name].role = class, role
            end
            return
        end
        local e = { name = name, class = class, role = role }
        seen[name] = e
        out[#out + 1] = e
    end
    for _, s in ipairs(tl.segs) do
        if s.kind == "pull" then
            for _, r in ipairs(s.rec.roster or {}) do add(r.name, r.class, r.role) end
        end
    end
    local hp = tl.run.hp
    for i = 1, #((hp and hp.who) or {}) do
        for _, name in ipairs(hp.who[i]) do add(name) end
    end
    return out
end

-- What the run's own events say happened around t: a drink, a death, a zone
-- change. The window draws these in the gaps, where there is no cast to show.
function RT.EventAt(tl, t, window)
    local run = tl and tl.run
    local ev = run and run.ev
    if not (ev and ev.t) then return nil end
    window = window or 3
    local best
    for i = 1, #ev.t do
        local at = ev.t[i]
        if at <= t and at >= t - window then best = { t = at, kind = ev.kind[i], a = ev.a[i], b = ev.b[i] } end
    end
    return best
end

return RT
