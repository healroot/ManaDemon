-- Simulation engine (docs/SPEC-v0.7.md 3). One event-driven loop over one
-- scenario, driven either by a recorded script (replay) or by a plan that
-- decides what to cast (v0.7.4). It is the only place healing, mana and time
-- are advanced, so a replayed fight and a hypothetical plan are scored by
-- exactly the same code -- which is the whole point: a suggestion the engine
-- cannot reproduce on the real fight is not a suggestion, it is a guess.
--
-- The rank math never runs inside the loop. RankMath:SpellKit() flattens every
-- known rank into plain numbers once, per form, before Run() starts.
--
-- "Zero allocation" means the LOOP allocates nothing: the heap, the per-target
-- scratch and the result arrays all come from a reused pool slot, and the
-- recorded timelines are read by index and never copied. Run itself still
-- builds its handful of local closures once per call -- a few hundred bytes,
-- which the self-test's 4 KB budget covers -- because the alternative is a
-- flat function soup nobody can check by reading. The result and every array
-- on it belong to the slot: read them before the next Run.
--
-- Two conventions worth stating because they are NOT arbitrary:
--
--  * Mana leaves, and the five-second rule restarts, when a cast SUCCEEDS, not
--    when it starts. That is what the client does and what the logs show
--    (.logs/dungeon-BF-1.txt: "[mana] -460" and "[spend] Regrowth cost 460"
--    carry the same timestamp as "5SR start"). docs/SPEC-v0.7.md 3.6 wrote
--    "at cast start"; the log wins. A plan is still charged at the moment the
--    cast lands, so it can never spend mana it would not have had.
--  * Regen is integrated continuously rather than in 2s ticks. Over a 40s pull
--    that is worth at most one tick of phase error (~1% of a 7k pool) and it
--    removes an arbitrary tick alignment the engine has no way to know.
local _, MD = ...

local SM = {}
MD.SimModel = SM

-- Event kinds in a recorded stream (Engine/FightRecorder.lua, the fixtures and
-- this engine all use these numbers -- do not renumber).
SM.K = {
    DMG = 1, FHEAL = 2, OWNCAST = 3, OWNHEAL = 4, OWNTICK = 5, CASTSTART = 6,
    CANCEL = 7, FORM = 8, DIED = 9, ABSORB = 10, CD = 11,
    AURA = 12,   -- v0.8.3: a defensive buff or a debuff on a tracked target; x = spellID
                 -- (+ AURA_BUFF_FLAG for a buff), amt = stacks, -1 on removal. The engine
                 -- ignores it: the damage it changed was recorded as changed.
    -- v0.12.0, the two things a healer can see coming (docs/SPEC-v0.12.md §2).
    -- Both are present-tense facts about the world, not future events: aggro is
    -- on the frame now, and a cast bar is a promise the game is already making.
    THREAT = 13, -- tgt = roster index, amt = UnitThreatSituation 0..3, recorded on change
    ECAST = 14,  -- a hostile cast aimed at a tracked target. tgt = that target (-1 when the
                 -- log did not carry one), x = spellID, amt = seconds until it landed
                 -- (0 until ScenarioFromRecording pairs it with the damage it did)
}
SM.AURA_BUFF_FLAG = 1000000

-- The three families that leave something ticking on a target. Everything else
-- resolves the instant it lands.
SM.HOT_INDEX = { Rejuvenation = 1, Regrowth = 2, Lifebloom = 3 }
SM.HOT_NAME = { "Rejuvenation", "Regrowth", "Lifebloom" }
local HOT_INDEX = SM.HOT_INDEX

-- Trace event kinds (docs/SPEC-v0.8.md 2.1): what a run writes down for the
-- replay window when opts.trace asks for it. Distinct from SM.K, which are the
-- RECORDED kinds; neither table is ever renumbered.
SM.TK = { CAST_START = 1, CAST = 2, CANCEL = 3, HOT = 4, HOT_END = 5, DEATH = 6, FORM = 7, WAIT = 8 }
-- The trace's `why` is the Plan rule that caused a cast, 1..5. A sixth value
-- means no rule caused it: it is one of the healer's own non-healing casts,
-- replayed into the suggested column because the plan does not get to remove it
-- (v0.10.2). SP.RULE_NAMES carries its line.
SM.WHY_FIXED = 6
local TK = SM.TK
SM.TRACE_MAX_NUMBERS = 30000

local EMPTY = {}
local LIFEBLOOM_MAX_STACKS = 3
-- Spell cooldowns the engine has to respect. Only the ones a plan can choose;
-- Innervate and potions are recorded events, not decisions (spec 13).
local SPELL_CD = { [18562] = 15 }   -- Swiftmend
SM.SPELL_CD = SPELL_CD              -- read by Engine/ReplayTrace.lua for the Swiftmend-ready dot
-- Trailing damage per target, kept as a small circular buffer. This is the ONE
-- derived input a plan is allowed (see the causality note in SimPlanner).
local DMG_RING = 32
local GCD = 1.5
local FSR = 5

--------------------------------------------------------------------------------
-- Internal heap events, in the tie-break order docs/SPEC-v0.7.md 3.3 fixes for
-- equal timestamps. Timeline events (damage, foreign heals) are not in the heap
-- at all -- they are read straight out of the recorded arrays by a cursor, so a
-- 3,000-event fight costs three integers of state instead of 3,000 heap pushes.
--------------------------------------------------------------------------------
local E_TICK, E_EXPIRE, E_LAND, E_DECIDE = 1, 2, 3, 4

--------------------------------------------------------------------------------
-- Binary heap over parallel arrays, keyed (t, prio, seq). Never allocates once
-- it has grown: Push writes into slots the previous Run left behind.
--------------------------------------------------------------------------------
local function HeapNew()
    return { t = {}, prio = {}, seq = {}, a = {}, b = {}, c = {}, n = 0, seqN = 0 }
end

local function HeapLess(h, i, j)
    local ti, tj = h.t[i], h.t[j]
    if ti ~= tj then return ti < tj end
    if h.prio[i] ~= h.prio[j] then return h.prio[i] < h.prio[j] end
    return h.seq[i] < h.seq[j]
end

local function HeapSwap(h, i, j)
    h.t[i], h.t[j] = h.t[j], h.t[i]
    h.prio[i], h.prio[j] = h.prio[j], h.prio[i]
    h.seq[i], h.seq[j] = h.seq[j], h.seq[i]
    h.a[i], h.a[j] = h.a[j], h.a[i]
    h.b[i], h.b[j] = h.b[j], h.b[i]
    h.c[i], h.c[j] = h.c[j], h.c[i]
end

local function HeapPush(h, t, prio, a, b, c)
    local n = h.n + 1
    h.n, h.seqN = n, h.seqN + 1
    h.t[n], h.prio[n], h.seq[n] = t, prio, h.seqN
    h.a[n], h.b[n], h.c[n] = a, b, c
    while n > 1 do
        local p = math.floor(n / 2)
        if HeapLess(h, n, p) then HeapSwap(h, n, p); n = p else break end
    end
end

local function HeapPop(h)
    local n = h.n
    if n == 0 then return nil end
    local t, prio, a, b, c = h.t[1], h.prio[1], h.a[1], h.b[1], h.c[1]
    HeapSwap(h, 1, n)
    h.n = n - 1
    n = h.n
    local i = 1
    while true do
        local l, r, m = i + i, i + i + 1, i
        if l <= n and HeapLess(h, l, m) then m = l end
        if r <= n and HeapLess(h, r, m) then m = r end
        if m == i then break end
        HeapSwap(h, i, m)
        i = m
    end
    return t, prio, a, b, c
end

--------------------------------------------------------------------------------
-- Slot pool. Two slots is enough: the search runs one candidate while holding
-- the incumbent's result, and nothing else calls Run re-entrantly.
--------------------------------------------------------------------------------
SM.pool = {}

local function NewSlot()
    return {
        busy = false,
        heap = HeapNew(),
        nT = 0, hp = {}, maxHP = {}, dead = {}, tracked = {}, role = {},
        danger = {},      -- [target] = the health fraction one recorded hit would take them through
        -- v0.12.1: the two things the healer's frames show them coming. Both are
        -- present-tense: the aggro on the frame now, and the cast bar that is up.
        threat = {},      -- [target] = UnitThreatSituation 0..3 as of t
        incoming = {},    -- [target] = { at, amount, spellID } -- the soonest cast aimed there
        hots = {},        -- [target][hotIndex] = state table (reused)
        cd = {},          -- spellID -> time it is ready again
        dmg = {},         -- [target] = { t = {}, a = {}, head = 0 } circular, DMG_RING wide
        byFamily = {}, healByFamily = {}, ohByFamily = {},
        -- deaths as parallel arrays and one reused "lowest" table: a search
        -- runs Run thousands of times and a per-run table is pure garbage.
        deaths = { n = 0, tgt = {}, t = {} },
        lowest = { tgt = nil, hp = 1, t = 0 },
        manaCurve = {}, hpCurve = {},
        result = {},
    }
end

local function Acquire()
    for i = 1, #SM.pool do
        if not SM.pool[i].busy then SM.pool[i].busy = true; return SM.pool[i] end
    end
    local s = NewSlot()
    s.busy = true
    SM.pool[#SM.pool + 1] = s
    return s
end

local function Release(s) s.busy = false end

local function HotState(S, ti, fi)
    local row = S.hots[ti]
    if not row then row = {}; S.hots[ti] = row end
    local st = row[fi]
    if not st then
        st = { active = false, spellID = 0, tick = 0, tickPeriod = 3, ticksLeft = 0,
               expires = 0, stacks = 0, bloom = 0, gen = 0 }
        row[fi] = st
    end
    return st
end

--------------------------------------------------------------------------------
-- Run
--   scenario  see docs/SPEC-v0.7.md 3.2, plus scenario.kit (RankMath:SpellKit)
--   plan      nil / { script = {...} } for a scripted run, or an object with
--             :Decide(S, t) -> spellID, target  for a deciding run
--   opts      { critMode = "ev" | "roll", seed, abortAbove, trace,
--               refreshKeepsTicks }
--------------------------------------------------------------------------------
function SM:Run(scenario, plan, opts)
    opts = opts or EMPTY
    local startClock = (GetTime and GetTime()) or 0
    local S = Acquire()
    local h = S.heap
    h.n, h.seqN = 0, 0

    local kit = scenario.kit
    local init = scenario.initial or {}
    local pool = scenario.pool or 0
    local mana = init.mana or pool
    local form = init.form or "caster"
    local baseRate = init.apiBase or 0
    local castingRate = init.apiCasting or 0
    -- Periodic energize the client's regen API does not report (a paladin's
    -- Blessing of Wisdom, a drink, anything else that hands out mana on a
    -- timer). Carried by the scenario with its own provenance; zero unless a
    -- recording measured one. See docs/DECISIONS.md v0.7 "unreported energize".
    local energize = init.energize or 0
    local floor = scenario.floor or (MD.db and MD.db.simFloor) or 0.30
    local fullAt = scenario.fullHp or (MD.db and MD.db.simFullHp) or 0.85
    local grace = scenario.grace or 6
    local dur = scenario.dur or 0
    local refreshKeepsTicks = opts.refreshKeepsTicks or false
    local onCast = opts.onCast
    local critMode = opts.critMode or "ev"
    local crit = (kit and kit.crit) or 0

    -- targets
    local nT = 0
    if scenario.targets then
        nT = #scenario.targets
        for i = 1, nT do
            local tg = scenario.targets[i]
            S.maxHP[i] = tg.maxHP or 1
            S.hp[i] = tg.hp0 or S.maxHP[i]
            S.dead[i] = false
            S.tracked[i] = tg.tracked ~= false
            S.role[i] = tg.role
            -- v0.10.3: "in danger" is ONE HIT FROM DEATH, measured. A flat 30%
            -- means the same thing to a quest mob hitting for 7% of your health
            -- and to a boss hitting for a third of the tank's. The line is the
            -- biggest hit this target actually took in this fight (p90 when
            -- there are enough of them to have an outlier), times
            -- db.simDangerHits. A synthetic scenario has no recorded damage and
            -- keeps the flat floor.
            S.danger[i] = tg.danger or floor
            S.threat[i], S.incoming[i] = 0, nil
            local row = S.hots[i]
            if row then for fi = 1, 3 do local st = row[fi]; if st then st.active = false end end end
            local ring = S.dmg[i]
            if not ring then ring = { t = {}, a = {}, head = 0 }; S.dmg[i] = ring end
            for j = 1, DMG_RING do ring.t[j], ring.a[j] = -1000, 0 end
            ring.head, ring.total, ring.hits, ring.biggest, ring.firstAt = 0, 0, 0, 0, nil
        end
        for k in pairs(S.cd) do S.cd[k] = nil end
    end

    S.nT = nT
    for k in pairs(S.byFamily) do S.byFamily[k] = nil end
    for k in pairs(S.healByFamily) do S.healByFamily[k] = nil end
    for k in pairs(S.ohByFamily) do S.ohByFamily[k] = nil end
    S.deaths.n = 0
    for i = #S.manaCurve, 1, -1 do S.manaCurve[i] = nil end
    for i = 1, nT do
        local c = S.hpCurve[i]
        if not c then c = {}; S.hpCurve[i] = c end
        for j = #c, 1, -1 do c[j] = nil end
    end

    local t = 0
    local manaSpent, casts, lowestMana, oomAt = 0, 0, mana, nil
    local healed, overhealed, floorSeconds = 0, 0, 0
    local tickCount, bloomCount = 0, 0
    local waitTime, busyUntil = 0, 0
    local deficitArea = 0
    local waitRun, maxWaitRun, maxWaitAt = 0, 0, 0
    -- A healer who was idle does not start the next cast the instant the model
    -- says to. The delay applies ONLY coming out of a wait: the BF-1 log's
    -- inter-cast gaps (p10/p25 = 1.50/1.52s) show chaining happens at the GCD
    -- with no delay at all.
    local reaction = (MD.db and MD.db.simReaction) or 0.5
    local lastWasWait = false
    local fsrUntil = init.fsrUntil or -1
    local lowestTgt, lowestHp, lowestHpT = nil, 1, 0

    ----------------------------------------------------------------------------
    -- Trace (docs/SPEC-v0.8.md 2). Allocated fresh, owned by the caller, never
    -- in the search: the pool slot is reused, the trace is not.
    ----------------------------------------------------------------------------
    local trace, gridDt, gridN, gridI = nil, 0, 0, 1
    if opts.trace then
        gridDt = opts.trace.dt or 0.25
        while (nT + 4) * (dur / gridDt + 1) > SM.TRACE_MAX_NUMBERS do gridDt = gridDt * 2 end
        gridN = math.floor(dur / gridDt + 1e-9) + 1
        -- v0.11.14: healing and overhealing on the same grid, so the replay can
        -- show a RUNNING overheal share and the mana regenerated so far. Two
        -- arrays; the budget check above counts nT + 2 columns and these make
        -- it nT + 4, which the same loop already shrinks dt to fit.
        trace = { dt = gridDt, n = gridN, dur = dur, nT = nT, mana = {}, form = {}, hp = {},
                  healed = {}, overhealed = {}, mana0 = mana,
                  -- v0.12.3: the numbers the rule read, one snapshot per traced
                  -- decision. The plan reuses its record, so it is copied here;
                  -- a trace is only built for the replay, never in the search.
                  reasons = {},
                  ev = { t = {}, kind = {}, tgt = {}, a = {}, b = {}, why = {} }, nEv = 0 }
        for i = 1, nT do if S.tracked[i] then trace.hp[i] = {} end end
        if gridDt ~= (opts.trace.dt or 0.25) then
            MD:Debug("sim", "trace: dt %.2f -> %.2f to stay under %d numbers", opts.trace.dt or 0.25, gridDt, SM.TRACE_MAX_NUMBERS)
        end
    end
    local pendingWhy = 0        -- the rule behind the cast being committed (plan runs)
    local pendingReason = nil   -- and the numbers it read (v0.12.3)
    local waitEv = nil          -- index of the open WAIT event, patched when it ends
    local function Trace(kind, tgt, a, b, why)
        if not trace then return end
        local n = trace.nEv + 1
        trace.nEv = n
        local e = trace.ev
        e.t[n], e.kind[n], e.tgt[n], e.a[n], e.b[n], e.why[n] = t, kind, tgt or 0, a or 0, b or 0, why or 0
        if pendingReason then
            local copy = {}
            for k, v in pairs(pendingReason) do copy[k] = v end
            trace.reasons[n] = copy
        end
        return n
    end
    local function TakeGrid()
        local k = gridI
        trace.mana[k] = mana
        trace.form[k] = (form == "tree") and 1 or 0
        trace.healed[k], trace.overhealed[k] = healed, overhealed
        for i = 1, nT do
            local c = trace.hp[i]
            if c then c[k] = S.dead[i] and 0 or (S.hp[i] / S.maxHP[i]) end
        end
    end
    local function EndWait()
        if waitEv then
            trace.ev.a[waitEv] = t - trace.ev.t[waitEv]
            waitEv = nil
        end
    end

    ----------------------------------------------------------------------------
    -- Healing
    ----------------------------------------------------------------------------
    local function Land(ti, amount, family)
        if not ti or ti < 1 or ti > nT or S.dead[ti] or amount <= 0 then return end
        local maxHP = S.maxHP[ti]
        local room = maxHP - S.hp[ti]
        local eff = amount < room and amount or room
        if eff < 0 then eff = 0 end
        S.hp[ti] = S.hp[ti] + eff
        healed = healed + eff
        overhealed = overhealed + (amount - eff)
        S.healByFamily[family] = (S.healByFamily[family] or 0) + eff
        S.ohByFamily[family] = (S.ohByFamily[family] or 0) + (amount - eff)
    end

    local function Damage(ti, amount)
        if not ti or ti < 1 or ti > nT or S.dead[ti] then return end
        local hp = S.hp[ti] - amount
        if hp <= 0 then
            S.hp[ti] = 0
            S.dead[ti] = true
            local d = S.deaths
            d.n = d.n + 1
            d.tgt[d.n], d.t[d.n] = ti, t
            Trace(TK.DEATH, ti, 0, 0)
        else
            S.hp[ti] = hp
        end
        local ring = S.dmg[ti]
        if ring then
            local head = ring.head % DMG_RING + 1
            ring.head = head
            ring.t[head], ring.a[head] = t, amount
            -- What this target has taken SO FAR (v0.11.12). The trailing 5s is
            -- a twitchy number on a mob that swings every few seconds, and a
            -- healer does not forget the last thirty. Everything here comes from
            -- events already applied, so the causality invariant holds.
            ring.total = (ring.total or 0) + amount
            ring.hits = (ring.hits or 0) + 1
            if amount > (ring.biggest or 0) then ring.biggest = amount end
            if not ring.firstAt then ring.firstAt = t end
        end
        local frac = S.hp[ti] / S.maxHP[ti]
        if S.tracked[ti] and frac < lowestHp then lowestTgt, lowestHp, lowestHpT = ti, frac, t end
    end

    local function ScheduleHot(ti, fi, st)
        st.gen = st.gen + 1
        HeapPush(h, st.nextTick, E_TICK, ti, fi, st.gen)
        HeapPush(h, st.expires, E_EXPIRE, ti, fi, st.gen)
    end

    -- Applying a HoT. TBC drops whatever was left when a HoT is refreshed
    -- (opts.refreshKeepsTicks flips that in one place if the client disagrees);
    -- Lifebloom instead adds a stack and resets its 7s.
    local function ApplyHot(ti, fi, e, spellID)
        local st = HotState(S, ti, fi)
        local isLB = (fi == HOT_INDEX.Lifebloom)
        local wasActive = st.active
        if isLB and wasActive then
            st.stacks = math.min(LIFEBLOOM_MAX_STACKS, st.stacks + 1)
        else
            st.stacks = 1
        end
        st.active = true
        st.spellID = spellID
        st.tick = e.tick or 0
        st.tickPeriod = e.tickPeriod or 3
        st.bloom = e.bloom or 0
        st.family = e.family
        if refreshKeepsTicks and wasActive and not isLB then
            st.ticksLeft = math.max(st.ticksLeft, e.ticks or 0)
        else
            st.ticksLeft = e.ticks or 0
        end
        -- v0.14.2: a refresh extends a HoT; it does NOT restart its tick timer.
        -- The periodic effect keeps its own cadence in TBC, so re-anchoring
        -- nextTick here pushed the next tick back by however far into the
        -- interval the refresh landed. On a Lifebloom rolled every 1.5s against
        -- a 1s tick that is two ticks in three -- and 67% is exactly the share
        -- of the log's tick count a real parse reproduced.
        -- `>=`, not `>`: a refresh landing exactly on a tick boundary would
        -- otherwise re-anchor and swallow that tick, and rolling a HoT on the
        -- global cooldown lands on the boundary constantly.
        if not (wasActive and st.nextTick and st.nextTick >= t) then
            st.nextTick = t + st.tickPeriod
        end
        st.expires = t + (e.duration or (st.ticksLeft * st.tickPeriod))
        ScheduleHot(ti, fi, st)
        Trace(TK.HOT, ti, fi, st.stacks)
    end

    -- Crits. "ev" multiplies by the expectation, which is right for comparing
    -- plans; "roll" rolls a seeded generator, which is what the Monte Carlo
    -- replicates need -- a plan that only holds on average crits is a plan that
    -- loses somebody one fight in five. The generator is a plain LCG so a seed
    -- reproduces a replicate exactly, on any client, without touching
    -- math.random's global state.
    local rngState = (opts.seed or 1) * 2654435761 % 2147483647
    local function Roll()
        rngState = (rngState * 1103515245 + 12345) % 2147483648
        return rngState / 2147483648
    end
    local function DirectAmount(e)
        local d = e.direct or 0
        if d <= 0 then return 0 end
        local p = e.directCrit or crit
        if critMode == "roll" then
            return Roll() < p and d * 1.5 or d
        end
        return d * (1 + 0.5 * p)
    end

    -- One cast landing. Instants land the moment they are cast; everything else
    -- lands when its cast bar finishes.
    local function LandCast(spellID, ti)
        local e = kit and kit[form] and kit[form][spellID]
        if not e then return end
        -- no target (a self-buff, a shapeshift, a recorded cast whose target
        -- the log did not carry) and no corpse: the mana is still spent.
        if not ti or ti < 1 or ti > nT or S.dead[ti] then return end
        if e.type == "direct" then
            Land(ti, DirectAmount(e), e.family)
        elseif e.type == "hybrid" then
            Land(ti, DirectAmount(e), e.family)
            ApplyHot(ti, HOT_INDEX.Regrowth, e, spellID)
        elseif e.type == "hot" then
            ApplyHot(ti, HOT_INDEX.Rejuvenation, e, spellID)
        elseif e.type == "lifebloom" then
            ApplyHot(ti, HOT_INDEX.Lifebloom, e, spellID)
        elseif e.type == "instant" then
            -- Swiftmend eats Regrowth first, else Rejuvenation.
            local row = S.hots[ti]
            local rg = row and row[HOT_INDEX.Regrowth]
            local rj = row and row[HOT_INDEX.Rejuvenation]
            if rg and rg.active and e.swiftmendRegrowth then
                Land(ti, e.swiftmendRegrowth, e.family)
                rg.active = false
            elseif rj and rj.active and e.swiftmendRejuv then
                Land(ti, e.swiftmendRejuv, e.family)
                rj.active = false
            end
        end
    end

    ----------------------------------------------------------------------------
    -- Casting. Mana leaves and the 5SR restarts when the cast succeeds.
    ----------------------------------------------------------------------------
    local function Succeed(spellID, ti, cost)
        local e = kit and kit[form] and kit[form][spellID]
        if cost == nil then cost = (e and e.cost) or 0 end
        if cost > 0 then
            mana = mana - cost
            if mana < 0 then mana = 0 end
            manaSpent = manaSpent + cost
        end
        fsrUntil = t + FSR
        if SPELL_CD[spellID] then S.cd[spellID] = t + SPELL_CD[spellID] end
        casts = casts + 1
        local fam = (e and e.family) or "other"
        S.byFamily[fam] = (S.byFamily[fam] or 0) + 1
        if mana < lowestMana then lowestMana = mana end
        if not oomAt and pool > 0 and mana <= pool * 0.02 then oomAt = t end
        -- Lockstep hook: the classifier asks a plan what it would have done at
        -- this instant, with the REPLAY's state rather than the plan's own.
        if onCast then onCast(S, t, spellID, ti, mana, form) end
        if trace then
            EndWait()
            Trace(TK.CAST, ti, spellID, cost, pendingWhy)
            pendingWhy, pendingReason = 0, nil
        end
        LandCast(spellID, ti)
    end

    -- v0.12.1: threat changes and hostile casts, applied by cursor like every
    -- other recorded timeline. A cast enters S.incoming when its BAR STARTS and
    -- leaves when it lands (or when it should have): the plan sees exactly the
    -- window the author saw the icon for.
    local threatT = scenario.threat
    local threatN, threatI = threatT and #threatT or 0, 1
    local incomingT = scenario.incoming
    local incomingN, incomingI = incomingT and #incomingT or 0, 1
    ----------------------------------------------------------------------------
    -- Time. Regen is integrated over the interval, splitting it at the moment
    -- the five-second rule lapses so a single long gap is still exact.
    ----------------------------------------------------------------------------
    -- Everything the healer's frames show, brought up to date. Applied before
    -- any decision at t, and only from entries whose time has come.
    local function CatchUpFrames(nt)
        while threatT and threatI <= threatN and threatT[threatI].t <= nt do
            local e = threatT[threatI]
            if e.target and e.target > 0 then S.threat[e.target] = e.status or 0 end
            threatI = threatI + 1
        end
        while incomingT and incomingI <= incomingN and incomingT[incomingI].t <= nt do
            local c = incomingT[incomingI]
            if c.target and c.target > 0 then S.incoming[c.target] = c end
            incomingI = incomingI + 1
        end
        -- a cast that has landed is off the frame: the icon goes when the bar does
        for i = 1, nT do
            local c = S.incoming[i]
            if c and (not c.at or c.at <= nt) then S.incoming[i] = nil end
        end
    end

    local function AdvanceTo(nt)
        local dt = nt - t
        if dt <= 0 then t = nt > t and nt or t; return end
        local gain
        if fsrUntil > t and fsrUntil < nt then
            gain = castingRate * (fsrUntil - t) + baseRate * (nt - fsrUntil)
        elseif fsrUntil > t then
            gain = castingRate * dt
        else
            gain = baseRate * dt
        end
        mana = mana + gain + energize * dt
        if mana > pool then mana = pool end
        if mana < lowestMana then lowestMana = mana end
        if not oomAt and pool > 0 and mana <= pool * 0.02 then oomAt = t end
        if nt > grace then
            local from = t > grace and t or grace
            local span = nt - from
            if span > 0 then
                for i = 1, nT do
                    if S.tracked[i] and not S.dead[i] then
                        local frac = S.hp[i] / S.maxHP[i]
                        if frac < (S.danger[i] or floor) then floorSeconds = floorSeconds + span end
                        -- v0.10.4: "how much health was missing, for how long",
                        -- in fraction-seconds. "Most healing done" as a number
                        -- overhealing cannot game: topping up a target who is
                        -- already above the full line adds nothing to it.
                        if frac < fullAt then deficitArea = deficitArea + span * (fullAt - frac) end
                    end
                end
            end
        end
        t = nt
    end

    ----------------------------------------------------------------------------
    -- Cursors over the recorded arrays. Nothing here is copied.
    ----------------------------------------------------------------------------
    local ev = scenario.ev
    local evN = ev and #ev.t or 0
    local evi = 1
    local forms, formN, formI = scenario.forms, scenario.forms and #scenario.forms or 0, 1
    local rates, rateN, rateI = scenario.rates, scenario.rates and #scenario.rates or 0, 1
    local script = plan and plan.script or scenario.script
    local scriptN, scriptI = script and #script or 0, 1
    -- v0.10.2: the casts a plan may not remove. A replay runs them out of
    -- `script` like everything else, so they are only a separate cursor when a
    -- plan is deciding.
    local fixed = plan and scenario.fixed or nil
    local fixedN, fixedI = fixed and #fixed or 0, 1
    local inFlight = false      -- the plan has a cast committed and not yet landed
    local samples, sampleN, sampleI = scenario.sampleT, scenario.sampleT and #scenario.sampleT or 0, 1
    local hpT, hpN, hpI = scenario.hpSampleT, scenario.hpSampleT and #scenario.hpSampleT or 0, 1
    local deciding = plan and plan.Decide and true or false

    ----------------------------------------------------------------------------
    -- Initial state
    ----------------------------------------------------------------------------
    if init.auras then
        for _, a in ipairs(init.auras) do
            local sd = MD.SpellData.spells[a.spellID]
            local fi = sd and HOT_INDEX[sd.family]
            local e = kit and kit[form] and kit[form][a.spellID]
            if fi and e then
                local st = HotState(S, a.target, fi)
                st.active, st.spellID = true, a.spellID
                st.tick, st.tickPeriod = e.tick or 0, e.tickPeriod or 3
                st.bloom, st.family = e.bloom or 0, e.family
                st.stacks = a.stacks or 1
                local remaining = a.remaining or 0
                st.expires = remaining
                st.ticksLeft = math.max(1, math.floor(remaining / st.tickPeriod + 0.5))
                st.nextTick = remaining - (st.ticksLeft - 1) * st.tickPeriod
                if st.nextTick < 0 then st.nextTick = 0 end
                ScheduleHot(a.target, fi, st)
                Trace(TK.HOT, a.target, fi, st.stacks)
            end
        end
    end
    if deciding then
        -- a plan may cache anything it likes WITHIN a run (the anchor, say);
        -- across runs it must start clean or the search compares plans that
        -- remember different fights
        if plan.Reset then plan:Reset() end
        HeapPush(h, 0, E_DECIDE, 0, 0, 0)
    end

    local function TakeSample()
        S.manaCurve[#S.manaCurve + 1] = mana
    end

    -- HP is sampled on its own schedule: the recorder writes mana every 2s and
    -- health every 5s, and merging them would invent readings neither stream has.
    local function TakeHpSample()
        for i = 1, nT do
            local c = S.hpCurve[i]
            c[#c + 1] = S.hp[i]
        end
    end

    ----------------------------------------------------------------------------
    -- Main loop
    ----------------------------------------------------------------------------
    local aborted = false
    while true do
        -- The next thing that happens, in the priority order equal timestamps
        -- resolve by: rates and form first (they must be in effect for the
        -- event at that instant), then the recorded timeline, then the script,
        -- then the heap.
        local nt, src = dur, 0
        if rates and rateI <= rateN and rates[rateI][1] < nt then nt, src = rates[rateI][1], 1 end
        if forms and formI <= formN and forms[formI][1] < nt then nt, src = forms[formI][1], 2 end
        if ev and evi <= evN and ev.t[evi] < nt then nt, src = ev.t[evi], 3 end
        if script and scriptI <= scriptN and script[scriptI][1] < nt then nt, src = script[scriptI][1], 4 end
        if fixed and fixedI <= fixedN and fixed[fixedI][1] < nt then nt, src = fixed[fixedI][1], 6 end
        if h.n > 0 and h.t[1] < nt then nt, src = h.t[1], 5 end

        -- Samples strictly before the next event. A sample that sits exactly ON
        -- an event's timestamp is therefore taken on a LATER pass, once every
        -- event at that instant has been applied -- which is what a recorded
        -- mana sample means: the log's line at a cast's timestamp is the mana
        -- AFTER the cast paid for itself.
        -- The trace grid (v0.8) is a third sampler under the same rule.
        while true do
            local ms = (samples and sampleI <= sampleN) and samples[sampleI] or nil
            local hs = (hpT and hpI <= hpN) and hpT[hpI] or nil
            local gs = (trace and gridI <= gridN) and ((gridI - 1) * gridDt) or nil
            local pick, which = nil, 0
            if ms and ms < nt then pick, which = ms, 1 end
            if hs and hs < nt and (not pick or hs < pick) then pick, which = hs, 2 end
            if gs and gs < nt and (not pick or gs < pick) then pick, which = gs, 3 end
            if not pick then break end
            AdvanceTo(pick)
            if which == 1 then TakeSample(); sampleI = sampleI + 1
            elseif which == 2 then TakeHpSample(); hpI = hpI + 1
            else TakeGrid(); gridI = gridI + 1 end
        end

        AdvanceTo(nt)
        if src == 0 then break end

        if src == 1 then
            baseRate, castingRate = rates[rateI][2], rates[rateI][3]
            rateI = rateI + 1
        elseif src == 2 then
            form = forms[formI][2]
            formI = formI + 1
            Trace(TK.FORM, 0, form == "tree" and 1 or 0, 0)
        elseif src == 3 then
            local k, tg, amt, x = ev.kind[evi], ev.tgt[evi], ev.amt[evi], ev.x[evi]
            evi = evi + 1
            if k == SM.K.DMG then
                Damage(tg, amt)
            elseif k == SM.K.FHEAL then
                Land(tg, amt, "foreign")
            elseif k == SM.K.FORM then
                form = (amt == 1) and "tree" or "caster"
                Trace(TK.FORM, 0, amt == 1 and 1 or 0, 0)
            elseif k == SM.K.CASTSTART then
                Trace(TK.CAST_START, tg, x, 0)
            elseif k == SM.K.CANCEL then
                Trace(TK.CANCEL, tg, x, 0)
            elseif k == SM.K.CD then
                if amt and amt > 0 then
                    mana = mana + amt
                    if mana > pool then mana = pool end
                end
            elseif k == SM.K.DIED then
                if tg and tg >= 1 and tg <= nT and not S.dead[tg] then
                    S.dead[tg] = true
                    S.hp[tg] = 0
                    local d = S.deaths
                    d.n = d.n + 1
                    d.tgt[d.n], d.t[d.n] = tg, t
                    Trace(TK.DEATH, tg, 0, 0)
                end
            end
            -- ABSORB, OWNHEAL, OWNTICK and OWNCAST are read by the recorder's
            -- own validation, not by the engine: the engine generates its own
            -- heals and is charged by the script. CASTSTART and CANCEL only
            -- reach the trace (the replay window's cast bar).
        elseif src == 4 then
            local c = script[scriptI]
            scriptI = scriptI + 1
            Succeed(c[2], c[4] or -1, c[3])
        elseif src == 6 then
            -- A cast the healer made that no healing plan gets to choose: the
            -- damage, the crowd control, the shapeshift. It costs its recorded
            -- mana, restarts the five-second rule and takes the global
            -- cooldown, in the suggested column exactly as it did in the real
            -- fight. It PREEMPTS a plan cast in flight -- that is what the
            -- healer did, interrupting themselves to press it, and a cancelled
            -- cast costs no mana. Delaying the fixed cast instead would move a
            -- recorded event, and letting the plan see it coming would be
            -- clairvoyance.
            local c = fixed[fixedI]
            fixedI = fixedI + 1
            if inFlight then
                inFlight = false
                if trace then Trace(TK.CANCEL, 0, 0, 0) end
            end
            -- no reason: the plan did not choose this one, it worked around it
            pendingWhy, pendingReason = SM.WHY_FIXED, nil
            Succeed(c[2], c[4] or -1, c[3])
            -- the global cooldown it takes, and NO new decision event: exactly
            -- one decision chain may be alive, and the pending one will hit the
            -- busy guard below and reschedule itself. Pushing here as well made
            -- two chains, and the plan's waiting was counted twice -- a card
            -- reading "waited 390% of the fight" is how that showed up.
            busyUntil = t + GCD
        elseif src == 5 then
            local et, prio, a, b, aux = HeapPop(h)
            if prio == E_TICK then
                local st = S.hots[a] and S.hots[a][b]
                if st and st.active and st.gen == aux and st.ticksLeft > 0 and not S.dead[a] then
                    Land(a, st.tick * st.stacks, st.family or "hot")
                    tickCount = tickCount + 1
                    st.ticksLeft = st.ticksLeft - 1
                    if st.ticksLeft > 0 then
                        st.nextTick = et + st.tickPeriod
                        HeapPush(h, st.nextTick, E_TICK, a, b, aux)
                    end
                end
            elseif prio == E_EXPIRE then
                local st = S.hots[a] and S.hots[a][b]
                if st and st.active and st.gen == aux then
                    local bloomed = 0
                    if b == HOT_INDEX.Lifebloom and st.bloom > 0 and not S.dead[a] then
                        -- v0.14.2: the bloom is the STACK's, exactly as the ticks
                        -- beside it are `st.tick * st.stacks`. Landing one
                        -- application's worth made every rolled Lifebloom
                        -- under-heal by up to twice the bloom, and Lifebloom is
                        -- around 70% of a resto druid's healing -- which is most
                        -- of why a recording only reproduced 42-70% of the
                        -- healing the log recorded (tools/reproduce.lua).
                        -- The log agrees: blooms there range 1653-3477 against a
                        -- flat 528 tick, and a 2.1x spread in one spell's direct
                        -- heal is stack scaling.
                        Land(a, st.bloom * (st.stacks or 1), st.family or "Lifebloom")
                        bloomCount = bloomCount + 1
                        bloomed = 1
                    end
                    st.active = false
                    Trace(TK.HOT_END, a, b, bloomed)
                end
            elseif prio == E_LAND then
                -- only one cast is ever in flight, so a cleared marker means a
                -- fixed cast preempted this one: it never happened, and a
                -- cancelled cast costs nothing
                if inFlight then
                    inFlight = false
                    Succeed(a, b, aux)   -- aux carries the committed cast's cost
                end
            elseif prio == E_DECIDE and deciding then
                CatchUpFrames(t)
                -- Still casting, or inside a fixed cast's global cooldown: ask
                -- again when the healer is free. Only one decision chain may be
                -- alive at a time, or the plan would commit two casts at once.
                -- (repeat/until true is Lua 5.1's `goto`.)
                repeat
                if t < busyUntil - 1e-9 then
                    HeapPush(h, busyUntil, E_DECIDE, 0, 0, 0)
                    break
                end
                local spellID, ti, rule = plan:Decide(S, t, mana, form)
                pendingReason = trace and plan.reason or nil
                if spellID and lastWasWait and reaction > 0 then
                    -- Coming out of idle: pay the reaction delay, then ask
                    -- again. Asking again rather than committing now keeps the
                    -- plan causal -- it may well have a better answer by then.
                    lastWasWait = false
                    HeapPush(h, t + reaction, E_DECIDE, 0, 0, 0)
                elseif spellID then
                    local e = kit and kit[form] and kit[form][spellID]
                    local castTime = (e and e.cast) or GCD
                    local instant = e == nil or e.type == "hot" or e.type == "lifebloom"
                        or e.type == "instant"
                    waitRun = 0
                    -- Cast commitment: once started, the cast is locked in and
                    -- the plan is not asked again until it has landed.
                    local succeedAt = instant and t or (t + castTime)
                    pendingWhy = rule or 0
                    if instant then
                        Succeed(spellID, ti, e and e.cost or nil)
                    else
                        if trace then EndWait(); Trace(TK.CAST_START, ti, spellID, castTime, pendingWhy) end
                        inFlight = true
                        HeapPush(h, succeedAt, E_LAND, spellID, ti, e and e.cost or nil)
                    end
                    busyUntil = succeedAt > t + GCD and succeedAt or (t + GCD)
                    HeapPush(h, busyUntil, E_DECIDE, 0, 0, 0)
                else
                    -- waiting is a real action; ask again at the next thing
                    -- that could change the answer, and never later than 0.5s
                    lastWasWait = true
                    if trace and not waitEv then waitEv = Trace(TK.WAIT, 0, 0, 0) end
                    pendingReason = nil
                    local nextT = h.n > 0 and h.t[1] or (t + 0.5)
                    if nextT > t + 0.5 then nextT = t + 0.5 end
                    if nextT <= t then nextT = t + 0.5 end
                    local span = nextT - t
                    if t + span > dur then span = dur - t end   -- "101% of the fight" otherwise
                    if span < 0 then span = 0 end
                    waitTime = waitTime + span
                    waitRun = waitRun + span
                    if waitRun > maxWaitRun then maxWaitRun, maxWaitAt = waitRun, t + span end
                    if nextT < dur then HeapPush(h, nextT, E_DECIDE, 0, 0, 0) end
                end
                until true
            end
        end

        if opts.abortAbove and manaSpent > opts.abortAbove then aborted = true; break end
    end

    while (samples and sampleI <= sampleN) or (hpT and hpI <= hpN) or (trace and gridI <= gridN) do
        local ms = (samples and sampleI <= sampleN) and samples[sampleI] or nil
        local hs = (hpT and hpI <= hpN) and hpT[hpI] or nil
        local gs = (trace and gridI <= gridN) and ((gridI - 1) * gridDt) or nil
        local pick, which = ms, 1
        if hs and (not pick or hs < pick) then pick, which = hs, 2 end
        if gs and (not pick or gs < pick) then pick, which = gs, 3 end
        AdvanceTo(pick)
        if which == 1 then TakeSample(); sampleI = sampleI + 1
        elseif which == 2 then TakeHpSample(); hpI = hpI + 1
        else TakeGrid(); gridI = gridI + 1 end
    end
    if trace then EndWait() end

    local r = S.result
    r.ok = (S.deaths.n == 0) and floorSeconds == 0 and not aborted
    r.aborted = aborted
    r.deaths = S.deaths
    r.floorSeconds = floorSeconds
    r.manaSpent, r.manaEnd, r.lowestMana, r.oomAt = manaSpent, mana, lowestMana, oomAt
    r.healed, r.overhealed = healed, overhealed
    r.casts, r.byFamily = casts, S.byFamily
    r.ticks, r.blooms = tickCount, bloomCount
    r.healByFamily, r.ohByFamily = S.healByFamily, S.ohByFamily
    r.manaCurve = S.manaCurve
    r.hpCurve = S.hpCurve
    S.lowest.tgt, S.lowest.hp, S.lowest.t = lowestTgt, lowestHp, lowestHpT
    r.lowest = S.lowest
    -- v0.10.3: the health the fight ENDS with, as a deficit. Health missing at
    -- the end is not a saving, it is mana that has not been spent yet -- the
    -- healer will put it back before the next pull or carry the risk into it.
    -- Counted only up to `fullAt` (a target at 85% is not hurt), and only for
    -- the living: a corpse is the deaths term's business. HoTs still rolling
    -- are healing already paid for, so their remaining ticks (and Lifebloom's
    -- bloom) come off the deficit before it is measured.
    local endDeficit = 0
    for i = 1, nT do
        if S.tracked[i] and not S.dead[i] and S.maxHP[i] > 0 then
            local pending = 0
            local row = S.hots[i]
            if row then
                for fi, st in pairs(row) do
                    if st.active then
                        pending = pending + (st.ticksLeft or 0) * (st.tick or 0) * (st.stacks or 1)
                        if fi == HOT_INDEX.Lifebloom then pending = pending + (st.bloom or 0) end
                    end
                end
            end
            local hp = S.hp[i] + pending
            if hp > S.maxHP[i] then hp = S.maxHP[i] end
            local want = S.maxHP[i] * fullAt
            if hp < want then endDeficit = endDeficit + (want - hp) end
        end
    end
    r.endDeficit = endDeficit
    r.deficitArea = deficitArea

    r.waitFraction = dur > 0 and (waitTime / dur) or 0
    r.maxWaitRun, r.maxWaitAt = maxWaitRun, maxWaitAt
    r.evals = 1
    r.trace = trace   -- nil unless asked for; the pool result is reused, so it is set every run
    r.ms = ((GetTime and GetTime()) or 0) - startClock
    -- The result and its arrays belong to the pool slot: read them before the
    -- next Run, or copy what you need. That is the price of the zero-allocation
    -- rule and it is stated here rather than discovered later.
    Release(S)
    return r
end

--------------------------------------------------------------------------------
-- What a plan may read (see Engine/SimPlanner.lua's causality note).
--------------------------------------------------------------------------------

-- Damage this target took over the trailing `window` seconds, from events the
-- engine has ALREADY applied. Nothing here can see the future.
-- The damage this target has taken since it was first hit, as a rate. It is
-- what a healer has actually watched happen, and it is the number that makes a
-- HoT proactive: the trailing five seconds go to zero between swings, and a
-- plan that only reads those waits until somebody is half dead before it can
-- justify a Lifebloom. Causal by construction -- applied events only.
function SM.SeenDamage(S, ti, t)
    local ring = S.dmg and S.dmg[ti]
    if not ring or not ring.firstAt or (ring.hits or 0) < 2 then return 0, 0 end
    local span = t - ring.firstAt
    if span < 1 then span = 1 end
    return (ring.total or 0) / span, ring.biggest or 0
end

function SM.RecentDamage(S, ti, t, window)
    local ring = S.dmg and S.dmg[ti]
    if not ring then return 0 end
    local cutoff = t - (window or 5)
    local sum = 0
    for j = 1, DMG_RING do
        if ring.t[j] >= cutoff and ring.t[j] <= t then sum = sum + ring.a[j] end
    end
    return sum
end

function SM.Ready(S, spellID, t)
    local at = S.cd and S.cd[spellID]
    return at == nil or at <= t
end

--------------------------------------------------------------------------------
-- Plans
--------------------------------------------------------------------------------

-- Replay: cast exactly what was cast, when it was cast, at the recorded cost.
-- rec.casts entries are { t, spellID, cost, tgt }.
function SM.ReplayPlan(rec)
    return { script = rec.casts, replay = true }
end

-- Chain-cast one spell as long as it is affordable. Used by the self-tests to
-- reproduce the dashboard's "To OOM" column inside the engine.
function SM.ChainPlan(spellID, target, kit, form)
    return {
        -- plan:Decide(S, t, mana, form) -- the colon call passes the plan first
        Decide = function(_, _, _, mana)
            local e = kit[form or "caster"][spellID]
            if not e or mana < e.cost then return nil end
            return spellID, target
        end,
    }
end

-- Cast a fixed list of { t, spellID, cost, tgt } -- the scripted form, shared
-- with replay so the self-tests exercise the same code path.
function SM.ScriptPlan(list)
    return { script = list }
end

--------------------------------------------------------------------------------
-- Replay: a recorded fight as a scenario the engine can run.
--
-- Everything the healer did is a script (the recorded casts at their recorded
-- costs); everything that happened TO the group is the recorded timeline. The
-- engine ignores the recorded own-heal events entirely and generates its own
-- from the spell kit -- that is the point: if the model's Rejuvenation is
-- wrong, replaying the fight will not reproduce the health bars, and the gates
-- below will say so instead of the Coach quietly building on a bad model.
--------------------------------------------------------------------------------
function SM.ScenarioFromRecording(rec, kit)
    if not rec then return nil end
    local K = SM.K
    local roster = rec.roster or {}
    local trackedSet = {}
    for _, idx in ipairs(rec.tracked or {}) do trackedSet[idx] = true end

    -- the biggest hit each target took, which is what "one hit from death"
    -- means for them in this fight. The MAXIMUM, not a percentile: that hit
    -- happened, and one more like it takes them from the line to the floor.
    -- A percentile would quietly discard exactly the tail the line is about.
    local hits = {}
    do
        local ev, K2 = rec.ev or {}, SM.K
        for i = 1, (rec.n or 0) do
            if ev.kind[i] == K2.DMG then
                local ti = ev.tgt[i]
                hits[ti] = hits[ti] or {}
                hits[ti][#hits[ti] + 1] = ev.amt[i] or 0
            end
        end
        for _, list in pairs(hits) do table.sort(list) end
    end
    local dangerHits = (MD.db and MD.db.simDangerHits) or 1

    local hp = rec.hp or {}
    local targets = {}
    for i = 1, #roster do
        local maxHP = roster[i].maxHP or -1
        local hp0 = -1
        if hp.max and hp.max[i] and hp.max[i][1] and hp.max[i][1] > 0 then maxHP = hp.max[i][1] end
        if hp.hp and hp.hp[i] and hp.hp[i][1] and hp.hp[i][1] >= 0 then hp0 = hp.hp[i][1] end
        if maxHP <= 0 then maxHP = 1 end
        local list = hits[i]
        local danger
        if list and #list > 0 and maxHP > 0 then
            danger = math.min(1, (list[#list] * dangerHits) / maxHP)
        end
        targets[i] = { name = roster[i].name, role = roster[i].role, maxHP = maxHP,
                       danger = danger,
                       hp0 = hp0 >= 0 and hp0 or maxHP,
                       -- a target with no health readings cannot be scored, and
                       -- pretending otherwise would count a flat line as a pass
                       tracked = trackedSet[i] and hp0 >= 0 or false }
    end

    -- v0.10.2: the own casts split in two. `script` is what the healing model
    -- prices, which a plan REPLACES when it runs. `fixed` is everything else --
    -- the damage, the crowd control, the shapeshifts, the buffs -- which a plan
    -- must WORK AROUND: same moment, same cost, same global cooldown, same
    -- five-second-rule restart. Dropping them would hand the simulated healer
    -- the mana back while leaving the damage timeline untouched, which is a
    -- third of this author's mana and the reason a plan looked cheap.
    local script, fixed = {}, {}
    local ev = rec.ev or {}
    for i = 1, (rec.n or 0) do
        if ev.kind[i] == K.OWNCAST then
            local id = ev.x[i]
            local cost = (ev.amt[i] or -1) >= 0 and ev.amt[i] or nil
            local entry = { ev.t[i], id, cost, ev.tgt[i] }
            -- `script` stays COMPLETE: a replay is every cast the healer made,
            -- byte for byte as before. `fixed` is the subset a plan may not
            -- remove, and it is only read when a plan is deciding (which is
            -- also when `script` is dropped).
            script[#script + 1] = entry
            if not MD.SpellData.spells[id] then
                -- `a and f()` truncates f() to one value (CLAUDE.md); the if
                -- has to be written out or `kind` is always nil
                local kind = "unknown"
                if MD.ClassifyCast then
                    local _, k = MD:ClassifyCast(id)
                    kind = k or "unknown"
                end
                fixed[#fixed + 1] = { ev.t[i], id, cost, ev.tgt[i], kind }
            end
        end
    end

    -- v0.12.0: what the healer could see coming. Threat is a state per target;
    -- an enemy cast is paired with the damage it did, because the combat log's
    -- SPELL_CAST_START usually carries no destination -- the mob has not
    -- committed to a target yet. The pairing is post-hoc (a recording is always
    -- post-hoc); what the PLAN is given is only ever the cast's start time, its
    -- target and when it landed, which is what the cast bar showed.
    --
    -- A cast that never landed keeps `at = nil`: the author watched a bar that
    -- came to nothing, and so does the plan.
    local incoming, threat = {}, {}
    do
        local evK = rec.ev or {}
        local open = {}          -- spellID -> index into `incoming`
        for i = 1, (rec.n or 0) do
            local kind = evK.kind[i]
            if kind == K.ECAST then
                incoming[#incoming + 1] = { t = evK.t[i], spellID = evK.x[i],
                                            target = (evK.tgt[i] or -1) > 0 and evK.tgt[i] or nil }
                open[evK.x[i]] = #incoming
            elseif kind == K.DMG then
                local j = open[evK.x[i]]
                if j then
                    local c = incoming[j]
                    c.at, c.amount = evK.t[i], evK.amt[i]
                    c.target = c.target or evK.tgt[i]
                    open[evK.x[i]] = nil
                end
            elseif kind == K.THREAT then
                threat[#threat + 1] = { t = evK.t[i], target = evK.tgt[i], status = evK.amt[i] }
            end
        end
    end

    local rates = {}
    local mn = rec.mana or {}
    for i = 1, #(mn.t or {}) do rates[i] = { mn.t[i], mn.base[i] or 0, mn.cast[i] or 0 } end

    -- v0.9.0: recordings made from now on carry `initial.energize` -- everything
    -- GetManaRegen omits for this character, measured at the pull. Older ones
    -- carry nothing, and replaying them without it is what put the author's
    -- 87s Hellfire fight 3.3% off its own mana curve. When the character HAS a
    -- measurement and the recording has none, the measurement is applied and
    -- the scenario is flagged: the replay then rests on an assumption (the
    -- gear was the same then), which every report that uses it states.
    local initial, assumed = rec.initial, false
    if initial and (initial.energize or 0) <= 0 and MD.Regen then
        local u = MD.Regen:Unreported()
        if u > 0 then
            local copy = {}
            for k, v in pairs(initial) do copy[k] = v end
            copy.energize, initial, assumed = u, copy, true
        end
    end

    return {
        dur = rec.dur or 0, pool = rec.pool or 0,
        initial = initial, energizeAssumed = assumed,
        targets = targets, ev = ev, rates = rates, fixed = fixed,
        incoming = incoming, threat = threat,
        sampleT = mn.t, hpSampleT = hp.t, kit = kit,
        floor = (MD.db and MD.db.simFloor) or 0.30,
        script = script,
    }
end

--------------------------------------------------------------------------------
-- The six gates (docs/SPEC-v0.7.md 7). A recording earns the right to be
-- coached from; it is not assumed. Each gate carries the provenance of its
-- threshold, printed with the result, because a number nobody can trace is a
-- number nobody can argue with.
--------------------------------------------------------------------------------
local GATES = {
    manaMean    = { setting = "simGateManaMean", default = 0.02,
                    why = "judge; server regen ticks quantise samples by ~2% of pool" },
    manaMax     = { setting = "simGateManaMax", default = 0.05,
                    why = "judge; same quantisation, worst single sample" },
    hpMean      = { setting = "simGateHpMean", default = 0.05,
                    why = "B; health is reconstructed through pets, absorbs and range" },
    hpMax       = { setting = "simGateHpMax", default = 0.15,
                    why = "B; same" },
    foreign     = { setting = "simForeignShare", default = 0.25,
                    why = "A's number; BF-1 measured 0%; a prior, not a measurement" },
}
SM.GATES = GATES

local function Threshold(name)
    local g = GATES[name]
    local v = MD.db and MD.db[g.setting]
    if v == nil then v = g.default end
    return v, g.why
end

local function MeanMax(sim, rec, n, scale)
    if not sim or not rec or n == 0 or scale <= 0 then return nil, nil end
    local sum, worst, at = 0, 0, 0
    local used = 0
    for i = 1, n do
        local a, b = sim[i], rec[i]
        if a ~= nil and b ~= nil and b >= 0 then
            local d = math.abs(a - b) / scale
            sum = sum + d
            used = used + 1
            if d > worst then worst, at = d, i end
        end
    end
    if used == 0 then return nil, nil end
    return sum / used, worst, at
end

-- Validate(rec) -> { ok, gates = { {name, ok, value, limit, why, text}, ... },
--                    excluded = { <target index> = reason }, result = <sim result> }
function SM:Validate(rec, kit)
    if not rec then return nil end
    kit = kit or MD.RankMath:SpellKit()
    local sc = SM.ScenarioFromRecording(rec, kit)
    local r = SM:Run(sc, nil, { critMode = "ev" })

    local out = { gates = {}, excluded = {}, ok = true, rec = rec,
                  energize = (sc.initial and sc.initial.energize) or 0,
                  energizeAssumed = sc.energizeAssumed or false }
    local function Gate(name, ok, text, value, limit, why)
        out.gates[#out.gates + 1] = { name = name, ok = ok, text = text,
                                      value = value, limit = limit, why = why }
        if not ok then out.ok = false end
    end

    -- 1 + 2: mana curve
    local mn = rec.mana or {}
    local pool = rec.pool or 0
    local mMean, mMax = MeanMax(r.manaCurve, mn.v, #(mn.t or {}), pool)
    local limMean, whyMean = Threshold("manaMean")
    local limMax, whyMax = Threshold("manaMax")
    if mMean then
        Gate("mana mean", mMean <= limMean,
            -- no bare "|" in a rendered string: the client reads it as the start
            -- of an escape sequence and eats what follows (CLAUDE.md). This said
            -- "mean |d|" from v0.7.3 until the Review tab started painting it.
            string.format("mean off by %.1f%% of pool (limit %.0f%%)", mMean * 100, limMean * 100),
            mMean, limMean, whyMean)
        Gate("mana max", mMax <= limMax,
            string.format("worst sample off by %.1f%% of pool (limit %.0f%%)", mMax * 100, limMax * 100),
            mMax, limMax, whyMax)
    else
        Gate("mana curve", false, "no mana samples recorded", nil, nil, whyMean)
    end

    -- 3 + 4: health per target. A target that misses is EXCLUDED, not fatal:
    -- one pet-heavy warlock should not disqualify the tank's timeline.
    local hp = rec.hp or {}
    local limHpMean, whyHp = Threshold("hpMean")
    local limHpMax = Threshold("hpMax")
    local scored, excluded = 0, 0
    local worstMean, worstTgt = 0, nil
    -- A target nothing happened to reproduces itself perfectly and proves
    -- nothing, so only targets that actually took damage are scored.
    local damageTaken = {}
    for i = 1, (rec.n or 0) do
        if (rec.ev.kind[i] == SM.K.DMG or rec.ev.kind[i] == SM.K.ABSORB) and rec.ev.tgt[i] > 0 then
            damageTaken[rec.ev.tgt[i]] = (damageTaken[rec.ev.tgt[i]] or 0) + 1
        end
    end
    for i, tg in ipairs(sc.targets) do
        if tg.tracked and not damageTaken[i] then
            out.excluded[i] = "took no damage"
            excluded = excluded + 1
        elseif tg.tracked and hp.hp and hp.hp[i] then
            local mean, max = MeanMax(r.hpCurve[i], hp.hp[i], #(hp.t or {}), tg.maxHP)
            if mean == nil then
                out.excluded[i] = "no health readings"
                excluded = excluded + 1
            elseif mean > limHpMean or max > limHpMax then
                out.excluded[i] = string.format("mean %.0f%% / worst %.0f%% of max health",
                    mean * 100, max * 100)
                excluded = excluded + 1
            else
                scored = scored + 1
                if mean > worstMean then worstMean, worstTgt = mean, i end
            end
        end
    end
    Gate("health curves", scored > 0,
        scored > 0 and string.format("%d damaged target(s) reproduced%s, %d excluded",
            scored,
            worstTgt and string.format(" (worst mean %.0f%% on %s)", worstMean * 100,
                sc.targets[worstTgt].name or "?") or "",
            excluded)
            or string.format("no target reproduced within %.0f%% mean / %.0f%% worst",
                limHpMean * 100, limHpMax * 100),
        nil, limHpMean, whyHp)

    -- 5: a death truncates the damage that would have followed
    Gate("no tracked death", #(rec.deaths or {}) == 0,
        #(rec.deaths or {}) == 0 and "nobody died"
            or string.format("%d death(s): damage after one is truncated in the log",
                #rec.deaths),
        nil, nil, "post-death damage truncation")

    -- 6: whose fight was this
    local limForeign, whyForeign = Threshold("foreign")
    local fs = rec.foreignShare or 0
    Gate("foreign healing", fs <= limForeign,
        string.format("%.0f%% of healing on your group was somebody else's (limit %.0f%%)",
            fs * 100, limForeign * 100),
        fs, limForeign, whyForeign)

    -- 7: is the model right about the spells that actually mattered here
    local spendBySpell, spend = {}, 0
    local ev = rec.ev or {}
    for i = 1, (rec.n or 0) do
        if ev.kind[i] == SM.K.OWNCAST and (ev.amt[i] or 0) > 0 then
            spendBySpell[ev.x[i]] = (spendBySpell[ev.x[i]] or 0) + ev.amt[i]
            spend = spend + ev.amt[i]
        end
    end
    local drifted, uncalibrated = nil, {}
    for spellID, mana in pairs(spendBySpell) do
        if spend > 0 and mana / spend >= 0.10 and MD.SpellData.spells[spellID] then
            local d = MD.Calibration and MD.Calibration:Drift(spellID)
            if d == nil then
                uncalibrated[#uncalibrated + 1] = GetSpellInfo(spellID) or spellID
            elseif d >= 0.03 then
                drifted = string.format("%s is %.0f%% off the model", GetSpellInfo(spellID) or spellID, d * 100)
            end
        end
    end
    Gate("model calibrated", drifted == nil,
        drifted or (#uncalibrated > 0
            and ("not yet calibrated: " .. table.concat(uncalibrated, ", "))
            or "every spell worth 10% of the spend is within 3%"),
        nil, 0.03, "Calibration ALERT_REL")

    -- 8: did the engine even know what the mana went on. v0.10.2: everything it
    -- REPRODUCES counts, not only what the healing model prices. A Cyclone is
    -- replayed as a fixed point -- same moment, same cost, same five-second-rule
    -- restart, in both columns -- so the engine is not guessing about it; a cast
    -- nobody can classify still is, and that is the hole this gate exists to
    -- notice. Before this, a healer who assisted the damage dealers failed the
    -- gate for playing their class.
    local form = rec.initial and rec.initial.form or "caster"
    local modelled, replayed, unclassified = 0, 0, 0
    for i = 1, #sc.script do
        local c = sc.script[i]
        local e = kit[form][c[2]] or kit.caster[c[2]]
        local cost = c[3] or (e and e.cost) or 0
        if e then
            modelled = modelled + cost
        else
            local kind
            if MD.ClassifyCast then local _, k = MD:ClassifyCast(c[2]); kind = k end
            if kind and kind ~= "unknown" then replayed = replayed + cost
            else unclassified = unclassified + cost end
        end
    end
    local coverage = spend > 0 and (modelled + replayed) / spend or 0
    Gate("spend coverage", coverage >= 0.90,
        string.format("%.0f%% of the mana is accounted for (%.0f%% healing, %.0f%% replayed as cast)%s",
            coverage * 100, spend > 0 and modelled / spend * 100 or 0,
            spend > 0 and replayed / spend * 100 or 0,
            unclassified > 0 and string.format("; %d mana on spells nothing can name", unclassified) or ""),
        coverage, 0.90, "12.6% utility hole in BF-1")

    out.result = r
    out.manaMean, out.manaMax = mMean, mMax
    return out
end

--------------------------------------------------------------------------------
-- What the casts that are not heals cost the healer (docs/SPEC-v0.10.md §4).
--
-- Measured, not estimated: the recorded script is run twice, once whole and
-- once with those casts taken out, and the difference is the answer. A per-cast
-- estimate of "five seconds of spirit regen" would be wrong every time a heal
-- followed within five seconds and would have restarted the rule anyway; only
-- the two runs know that.
--
-- The counterfactual is stated wherever this is shown: the fight would NOT have
-- been the same fight without them. The mob lives longer, the damage timeline
-- changes, the root that stopped a hit is gone. This answers "what did pressing
-- it cost my mana", never "should I have pressed it".
--------------------------------------------------------------------------------
function SM.CostOfCasts(rec, kit, kinds)
    if not rec then return nil end
    kit = kit or MD.RankMath:SpellKit()
    kinds = kinds or { damage = true }
    local sc = SM.ScenarioFromRecording(rec, kit)
    if not sc then return nil end

    local whole = SM:Run(sc, nil, { critMode = "ev" })
    local withMana, withEnd, withLow = whole.manaSpent, whole.manaEnd, whole.lowestMana
    local withOom = whole.oomAt

    local kept, taken = {}, {}
    for _, c in ipairs(sc.script or {}) do
        local drop = false
        if not MD.SpellData.spells[c[2]] and MD.ClassifyCast then
            local _, kind = MD:ClassifyCast(c[2])
            if kind and kinds[kind] then drop = true end
        end
        if drop then taken[#taken + 1] = c else kept[#kept + 1] = c end
    end
    if #taken == 0 then return nil end

    local saved = sc.script
    sc.script = kept
    local without = SM:Run(sc, nil, { critMode = "ev" })
    sc.script = saved

    local out = { casts = #taken, mana = withMana - without.manaSpent,
                  total = without.manaEnd - withEnd,
                  lowestWith = withLow, lowestWithout = without.lowestMana,
                  oomWith = withOom, oomWithout = without.oomAt,
                  pool = rec.pool or 0 }
    out.regen = out.total - out.mana        -- the rest is regen the 5SR restarts cost
    if out.regen < 0 then out.regen = 0 end

    -- how many of them were cast while the healer was already low, read off the
    -- recording's own mana samples
    local mn, pool = rec.mana or {}, rec.pool or 0
    local low, lowLine = 0, (MD.db and MD.db.simFloor) or 0.30
    if pool > 0 and mn.t then
        for _, c in ipairs(taken) do
            local v
            for i = 1, #mn.t do
                if mn.t[i] <= c[1] then v = mn.v[i] else break end
            end
            if v and v / pool < lowLine then low = low + 1 end
        end
    end
    out.whileLow, out.lowLine = low, lowLine
    return out
end

--------------------------------------------------------------------------------
-- ChainRun (docs/SPEC-v0.9.md 5.1): a whole RUN through the engine -- every
-- pull in order, mana carried across, and the gaps between them modelled.
--
-- A pull's score answers "did the healer hold the group up for this mana". A
-- run's answers "how long did the dungeon take, and how much of that was
-- standing still drinking", which is the question mana actually decides in
-- five-man content. That is only answerable if the gaps are in the simulation:
-- a plan that spends 20% less does not bank the mana, it skips a drink.
--
-- What is the healer's, and therefore simulated: the plan (per pull) and the
-- DRINK POLICY (drink below `below`, drink up to `upTo`). What is recorded, and
-- therefore fixed: the damage, the other healers, the deaths of others, how
-- long each gap was, and the drink rate -- measured on this run, never a preset
-- (docs/DECISIONS.md v0.9).
--
-- A drink that does not fit its gap does not vanish: the run gets LONGER by the
-- excess (`addedTime`), which is the term the run score ranks above mana.
--
-- NOT modelled, and said on the card: an Innervate in a gap. Its value is 400%
-- of the SPIRIT share of regen, and a recording carries the total rate, not the
-- split -- so counting it would be a guess. Potions are applied at their table
-- value (Engine/ManaCooldowns.lua). Both sides of a comparison see the same
-- recorded gaps, so the comparison stays fair either way.
--------------------------------------------------------------------------------
SM.DRINK_POLICY = { below = 0.60, upTo = 0.95 }

-- Where a run's drink rate comes from, in order of how much it is worth.
function SM.DrinkRate(run, given)
    if given and given > 0 then return given, "given" end
    local r = run and run.stats and run.stats.drinkRate
    if r and r > 0 then return r, "measured on this run" end
    local fill = MD.Regen and MD.Regen:ObservedFill() or 0
    if fill > 0 then return fill, "this session's observed fill - no drink in the run" end
    return nil, "unknown - no drink in the run and none observed this session"
end

-- Seconds inside [a, b] that the group spent in a pull the run did not record
-- (it was summarised: over the event budget, or fight recording was off). That
-- time is combat, not a gap, so nothing regenerates out of the five-second rule
-- in it and nobody drinks through it.
local function BusyIn(run, a, b)
    local busy, ev = 0, run.ev or {}
    local K = MD.RunRecorder and MD.RunRecorder.K
    if not K then return 0 end
    for i = 1, #(ev.t or {}) do
        if ev.kind[i] == K.PULL_END and (ev.a[i] or 0) == 0 then
            local e, d = ev.t[i], ev.b[i] or 0
            local s = e - d
            local lo, hi = math.max(s, a), math.min(e, b)
            if hi > lo then busy = busy + (hi - lo) end
        end
    end
    return busy
end

local function PotionsIn(run, a, b)
    local gain, ev = 0, run.ev or {}
    local K = MD.RunRecorder and MD.RunRecorder.K
    local MC = MD.ManaCooldowns
    if not (K and MC) then return 0 end
    for i = 1, #(ev.t or {}) do
        if ev.kind[i] == K.POTION and ev.t[i] >= a and ev.t[i] <= b then
            for _, p in ipairs(MC.potions or {}) do
                if p.id == ev.a[i] then gain = gain + (p.value or 0) end
            end
        end
    end
    return gain
end

local function InnervatesIn(run, a, b)
    local n, ev = 0, run.ev or {}
    local K = MD.RunRecorder and MD.RunRecorder.K
    if not K then return 0 end
    for i = 1, #(ev.t or {}) do
        if ev.kind[i] == K.INNERVATE and ev.t[i] >= a and ev.t[i] <= b then n = n + 1 end
    end
    return n
end

-- opts: plan, policy {below, upTo}, drinkRate, recorded (the "you" row: each
-- pull starts at the mana it really started at, and the drinks are the ones
-- that really happened), maxPulls.
function SM.ChainRun(run, kit, opts)
    if not run then return nil end
    opts = opts or {}
    kit = kit or MD.RankMath:SpellKit()
    local pulls = run.pulls or {}
    local pool = run.pool or 0
    local policy = opts.policy or SM.DRINK_POLICY
    local rate, rateSource = SM.DrinkRate(run, opts.drinkRate)
    local plan = opts.plan

    local out = { pulls = {}, gaps = {}, deaths = 0, floorSeconds = 0, manaSpent = 0,
                  healed = 0, overhealed = 0, drinks = 0, drinkTime = 0, addedTime = 0,
                  innervates = 0, potionMana = 0, lowest = { hp = 1 }, oomPulls = 0,
                  policy = policy, drinkRate = rate, drinkRateSource = rateSource,
                  recorded = opts.recorded or false, pool = pool }
    if #pulls == 0 then return out end

    local mana = (pulls[1].initial and pulls[1].initial.mana) or pool
    for k, rec in ipairs(pulls) do
        ------------------------------------------------------------------------
        -- the gap before this pull
        ------------------------------------------------------------------------
        if k > 1 then
            local prev = pulls[k - 1]
            local a = (prev.runT0 or 0) + (prev.dur or 0)
            local b = rec.runT0 or a
            local len = b - a
            if len < 0 then len = 0 end
            local busy = BusyIn(run, a, b)
            local free = len - busy
            if free < 0 then free = 0 end
            local gap = { k = k, len = len, busy = busy, manaStart = mana, drank = false,
                          drinkTime = 0, added = 0 }

            local pot = PotionsIn(run, a, b)
            if pot > 0 then mana = math.min(pool, mana + pot); out.potionMana = out.potionMana + pot end
            out.innervates = out.innervates + InnervatesIn(run, a, b)

            if not opts.recorded and rate and pool > 0 and (mana / pool) < policy.below then
                local need = ((policy.upTo * pool) - mana) / rate
                if need > 0 then
                    gap.drank = true
                    local spent = need < free and need or free
                    -- the measured rate is the OBSERVED mana gain while drinking,
                    -- so the base regen for those seconds is already inside it
                    mana = mana + spent * rate
                    gap.drinkTime = spent
                    free = free - spent
                    if need > gap.drinkTime then
                        gap.added = need - gap.drinkTime
                        mana = policy.upTo * pool
                    end
                    out.drinks = out.drinks + 1
                    out.drinkTime = out.drinkTime + gap.drinkTime + gap.added
                    out.addedTime = out.addedTime + gap.added
                end
            end

            local init = rec.initial or {}
            local base = (init.apiBase or 0) + (init.energize or 0)
            mana = mana + base * free
            if mana > pool then mana = pool end
            gap.manaEnd = mana
            out.gaps[#out.gaps + 1] = gap
        end

        ------------------------------------------------------------------------
        -- the pull
        ------------------------------------------------------------------------
        local sc = SM.ScenarioFromRecording(rec, kit)
        if opts.recorded then
            mana = (rec.initial and rec.initial.mana) or mana
        end
        local init = {}
        for key, v in pairs(sc.initial or {}) do init[key] = v end
        init.mana = mana
        sc.initial = init
        local saved = sc.script
        if plan then sc.script = nil end
        local r = SM:Run(sc, plan, { critMode = "ev" })
        sc.script = saved

        local p = { k = k, dur = rec.dur or 0, short = rec.short or false,
                    manaStart = mana, manaEnd = r.manaEnd, manaSpent = r.manaSpent,
                    floorSeconds = r.floorSeconds, deaths = r.deaths.n,
                    lowest = { hp = r.lowest.hp, tgt = r.lowest.tgt },
                    oomAt = r.oomAt, zone = rec.zone }
        out.pulls[#out.pulls + 1] = p
        out.deaths = out.deaths + p.deaths
        out.floorSeconds = out.floorSeconds + p.floorSeconds
        out.manaSpent = out.manaSpent + p.manaSpent
        out.healed = out.healed + (r.healed or 0)
        out.overhealed = out.overhealed + (r.overhealed or 0)
        if p.oomAt then out.oomPulls = out.oomPulls + 1 end
        if p.lowest.hp < out.lowest.hp then
            out.lowest = { hp = p.lowest.hp, tgt = p.lowest.tgt, pull = k }
        end
        mana = r.manaEnd
    end

    if opts.recorded then
        -- the "you" row: the drinking that actually happened, not a policy
        local st = run.stats or {}
        out.drinks, out.drinkTime, out.addedTime = st.drinks or 0, st.drinkTime or 0, 0
    end
    out.wall = (run.stats and run.stats.wall or 0) + out.addedTime
    return out
end
