local _, MD = ...

--------------------------------------------------------------------------------
-- The solver (docs/SPEC-v0.13.md).
--
-- A spell is a series of DEPOSITS: {dt, amount}. A direct heal is one deposit at
-- the end of the cast, a HoT is one per tick, Lifebloom is its ticks plus the
-- bloom, Swiftmend is one deposit now that removes the remaining deposits of the
-- HoT it eats. Nothing else about a spell reaches the decision.
--
-- The amounts come from RankMath:SpellKit(), which is to say from THE USER'S OWN
-- STATS. The same code run by a level 64 druid in Hellfire and a level 70 druid
-- in Sunwell schedules differently because their deposits differ. There is no
-- table of health thresholds to re-tune per character; that was the point.
--
-- Against the deposits stands the DEMAND: health missing now, plus health the
-- forecast says will go missing. THE FORECAST MAY READ ONLY WHAT A HUMAN CAN SEE
-- (docs/SPEC-v0.12.md §2) -- the present, the trailing damage, threat, and an
-- enemy cast already in the air. Scheduling against the damage that actually
-- arrives would make this clairvoyant and its advice unreproducible.
--
-- Every candidate is scored by projecting the target twice, with the cast and
-- without it, and measuring the missing-health integral it removes per mana:
--
--     saved = gap(without) - gap(with)          value = saved / mana
--
-- That one number carries all three things asked of it. Health gap: it is the
-- integral. Overheal: a deposit landing above full buys no reduction, so it
-- scores itself down with no penalty term. Mana: it is per mana. And the timing
-- falls out -- a deposit landing late reduces the gap less than the same deposit
-- landing now, so a deeply hurt target pulls a direct heal and spread damage
-- pulls a HoT, with no rule saying so.
--------------------------------------------------------------------------------

local SV = {}
MD.SimSolver = SV

local SM
local STEP = 0.5            -- the projection's resolution, seconds
local MAX_DEPOSITS = 12

-- Reused buffers: Decide runs tens of thousands of times inside a search.
local depBuf, flightBuf = {}, {}

--------------------------------------------------------------------------------
-- 1. Deposits
--------------------------------------------------------------------------------

-- The schedule a cast of `e` on a target would deposit, relative to now.
-- `st` is what is already on that target of the same family (Lifebloom stacks).
-- Returns the buffer and how many entries are live in it.
function SV.Deposits(e, st, out)
    out = out or {}
    local n = 0
    if not e then return out, 0 end
    local cast = e.cast or e.gcd or 1.5
    local function put(dt, amount)
        if amount and amount > 0 and n < MAX_DEPOSITS then
            n = n + 1
            out[n] = out[n] or {}
            out[n][1], out[n][2] = dt, amount
        end
    end
    if e.type == "instant" then
        -- Swiftmend: the amount depends on which HoT it eats, and the caller
        -- takes the eaten HoT's remaining deposits away.
        put(cast, e.swiftmendAmount or 0)
        return out, n
    end
    if (e.direct or 0) > 0 then put(cast, e.direct) end
    local ticks, period = e.ticks or 0, e.tickPeriod or 3
    if ticks > 0 and (e.tick or 0) > 0 then
        local stacks = 1
        if e.type == "lifebloom" then
            stacks = math.min(3, ((st and st.active) and (st.stacks or 1) or 0) + 1)
        end
        for k = 1, ticks do put(cast + k * period, e.tick * stacks) end
    end
    if (e.bloom or 0) > 0 then
        -- flat, NOT `* stacks`: v0.14.4 paired every bloom in the corpus with
        -- the tick before it and the bloom is the same at 1, 2 and 3 stacks
        put(cast + (e.duration or (ticks * period)), e.bloom)
    end
    return out, n
end

-- What is already on its way to this target: every rolling HoT's remaining
-- ticks and Lifebloom's bloom, as absolute times.
function SV.InFlight(S, i, t, out, skipFamily)
    out = out or {}
    local n = 0
    local row = S.hots and S.hots[i]
    if not row then return out, 0 end
    for fi, st in pairs(row) do
        if st.active and not (skipFamily and st.family == skipFamily) then
            local period = st.tickPeriod or 3
            local at = st.nextTick or (t + period)
            for k = 1, (st.ticksLeft or 0) do
                if n < 64 then
                    n = n + 1
                    out[n] = out[n] or {}
                    out[n][1] = at + (k - 1) * period
                    out[n][2] = (st.tick or 0) * (st.stacks or 1)
                end
            end
            if (st.bloom or 0) > 0 and n < 64 then
                n = n + 1
                out[n] = out[n] or {}
                out[n][1], out[n][2] = st.expires or t, (st.bloom or 0)
            end
        end
    end
    return out, n
end

--------------------------------------------------------------------------------
-- 2. The forecast -- present tense only
--------------------------------------------------------------------------------

-- What this target is expected to be taking, per second. Observation first; the
-- prior only ever RAISES the floor, and only until observation has something to
-- say. A healer who has run the place before does not wait for the first hit to
-- believe the tank is about to be hit -- but once the hits are landing, what is
-- actually happening beats what usually happens.
function SV.Rate(S, i, t, plan)
    SM = SM or MD.SimModel
    local seen = SM.SeenDamage(S, i, t)
    local observed = math.max(SM.RecentDamage(S, i, t, 5) / 5, seen)
    -- v0.13.2: deformed foresight of THIS fight, when the plan was given any.
    -- It is blurred, quantised, short-sighted and half-believed, but it is this
    -- fight, so a plan carrying it is NOT causal and says so (plan.foresees).
    local guess = 0
    if plan and plan.foresight then
        guess = MD.Foresight.Rate(plan.foresight, i, t, plan.horizon)
        if guess > observed then return guess end
    end
    local prior = plan and plan.prior
    if not prior then return observed end
    -- the prior speaks in fractions of max health, so it lands on any character
    guess = MD.Intuition:Rate(prior, plan.zone, S.role and S.role[i], t)
             * (S.maxHP[i] or 0)
    if guess <= 0 then return observed end
    -- Confidence in the guess decays as the fight gives us real evidence: at the
    -- pull it is all we have, and by the time the trailing window is full it is
    -- worth nothing. This is what keeps a prior from overriding the fight.
    local w = 1 - math.min(1, t / (plan.priorFades or 15))
    return math.max(observed, guess * w)
end

--------------------------------------------------------------------------------
-- 3. The gap: missing health integrated over the horizon
--------------------------------------------------------------------------------

-- hp0 now, damage at `rate` a second, an inbound lump, plus two deposit lists
-- (what is already flying, and the candidate). Returns health x seconds missing,
-- WEIGHTED so that being low hurts more than being slightly hurt.
--
-- v0.13.5, the author: "we prefer top up people health, minimal overheal is
-- good, but underheal is bad. also new death is unacceptable."
--
-- A flat integral cannot say that. A target parked at 95% for a hundred seconds
-- and one at 50% for ten score the same area, and the second is the one who dies
-- to the next hit. So each missing point is weighted by how much of the bar is
-- already gone:
--
--     weight = 1 + bias * (missing / maxHP)
--
-- At bias 2 a target at half health counts twice per missing point against one
-- that is nearly full, and topping somebody up beats shaving the last 5% off
-- somebody who is fine. Overheal needs no term of its own and still gets none: a
-- deposit above full buys no reduction, which is "minimal overheal is good"
-- without pretending it is as bad as leaving somebody low.
--
-- Deaths are not priced here at all. They are the first element of the
-- lexicographic tuple and no amount of mana or health-seconds trades for one.
local function Gap(hp0, maxHP, rate, inbound, flight, fn, dep, dn, t, horizon, bias)
    bias = bias or 0
    local hp = hp0
    local gap = 0
    local steps = math.floor(horizon / STEP + 0.5)
    for s = 1, steps do
        local from, to = t + (s - 1) * STEP, t + s * STEP
        hp = hp - rate * STEP
        if inbound and inbound.at and inbound.at > from and inbound.at <= to then
            hp = hp - (inbound.amount or 0)
        end
        for j = 1, fn do
            local d = flight[j]
            if d[1] > from and d[1] <= to then hp = hp + d[2] end
        end
        for j = 1, dn do
            local at = t + dep[j][1]
            if at > from and at <= to then hp = hp + dep[j][2] end
        end
        if hp > maxHP then hp = maxHP end
        if hp < 0 then hp = 0 end
        local missing = maxHP - hp
        if bias > 0 and maxHP > 0 then
            missing = missing * (1 + bias * (missing / maxHP))
        end
        gap = gap + missing * STEP
    end
    return gap
end
SV.Gap = Gap

--------------------------------------------------------------------------------
-- 4. The decision
--------------------------------------------------------------------------------

-- Order only decides ties; every one of them is scored every time.
SV.FAMILIES = { "Swiftmend", "Regrowth", "HealingTouch", "Lifebloom", "Rejuvenation" }

local Solver = {}
Solver.__index = Solver
SV.Solver = Solver

function SV.NewPlan(binds, params, kit)
    SM = SM or MD.SimModel
    return setmetatable({
        kind = "solver",
        binds = binds, kit = kit,
        minValue = params.minValue or 0.5,   -- health-seconds per mana to bother
        horizon = params.horizon or 12,
        -- how much worse a low target is than a lightly hurt one, per missing
        -- point (v0.13.5). 0 is the flat integral; 2 makes half health count
        -- twice. This is "underheal is bad" as a number.
        sag = params.sag or 0,
        -- v0.13.1: the prior, built from OTHER recordings (Engine/Intuition.lua).
        -- Absent, the solver is exactly as blind at the pull as before.
        prior = params.prior, zone = params.zone,
        -- v0.13.2: a deformed view of THIS fight. Setting it forfeits the
        -- causality invariant on purpose; `foresees` is what the card reports.
        foresight = params.foresight, foresees = params.foresight ~= nil,
        priorFades = params.priorFades or 15,
        reason = nil,
    }, Solver)
end

function Solver:Reset() end

function Solver:BindCount()
    local n = 0
    for _, id in pairs(self.binds) do if id then n = n + 1 end end
    return n
end

function Solver:Params()
    return { minValue = self.minValue, horizon = self.horizon,
             sag = self.sag, priorFades = self.priorFades }
end

-- Every (spell, target) the healer can afford, scored.
--
-- `delay` is how long from now the cast would actually start -- 0 for casting
-- now, one global cooldown for the "should I wait" question. THE PROJECTION
-- WINDOW DOES NOT MOVE WITH IT. Both options are judged over the same
-- [t, t + horizon], so waiting is charged for the gap it suffers while waiting.
--
-- v0.13.4: it used to move the window with the delay, which compared the next
-- 18 seconds against a different 18 seconds. Under continuous damage the later
-- window always looked better -- the same spell fills more gap when the target
-- has fallen further -- so the solver deferred almost indefinitely. On a raid
-- fight where the healer cast 82 times it cast 26 and let two people die.
function Solver:Best(S, t, mana, form, delay)
    local kit = self.kit[form] or self.kit.caster
    local HOT_INDEX = SM.HOT_INDEX
    local bestV, bestID, bestTgt, bestSaved, bestCost, bestRate, bestDef = -1
    local horizon = self.horizon
    for i = 1, S.nT do
        if S.tracked[i] and not S.dead[i] and (S.maxHP[i] or 0) > 0 then
            local hp = S.hp[i]
            local maxHP = S.maxHP[i]
            local rate = SV.Rate(S, i, t, self)
            local deficit = maxHP - hp
            -- nothing missing and nothing coming: no cast can buy anything
            if deficit > 0 or rate > 0 then
                local inbound = S.incoming and S.incoming[i] or nil
                local flight, fn = SV.InFlight(S, i, t, flightBuf)
                local base = Gap(hp, maxHP, rate, inbound, flight, fn, nil, 0, t,
                                 horizon, self.sag)
                for _, fam in ipairs(SV.FAMILIES) do
                    local id = self.binds[fam]
                    local e = id and kit[id]
                    if e and mana >= (e.cost or 0) then
                        local fi = HOT_INDEX[fam]
                        local st = fi and S.hots[i] and S.hots[i][fi]
                        local eaten = nil
                        if e.type == "instant" then
                            -- Swiftmend eats a HoT; without one it does nothing
                            local rj = S.hots[i] and S.hots[i][HOT_INDEX.Rejuvenation]
                            local rg = S.hots[i] and S.hots[i][HOT_INDEX.Regrowth]
                            if rj and rj.active then
                                e.swiftmendAmount, eaten = e.swiftmendRejuv, "Rejuvenation"
                            elseif rg and rg.active then
                                e.swiftmendAmount, eaten = e.swiftmendRegrowth, "Regrowth"
                            else
                                e.swiftmendAmount = nil
                            end
                        end
                        if not (e.type == "instant" and not e.swiftmendAmount) then
                            local dep, dn = SV.Deposits(e, st, depBuf)
                            if (delay or 0) > 0 then
                                for j = 1, dn do dep[j][1] = dep[j][1] + delay end
                            end
                            local f2, fn2 = flight, fn
                            if eaten then
                                f2, fn2 = SV.InFlight(S, i, t, {}, eaten)
                            end
                            local withGap = Gap(hp, maxHP, rate, inbound, f2, fn2,
                                                dep, dn, t, horizon, self.sag)
                            local saved = base - withGap
                            local cost = e.cost or 1
                            local v = saved / (cost > 0 and cost or 1)
                            if v > bestV then
                                bestV, bestID, bestTgt = v, id, i
                                bestSaved, bestCost, bestRate, bestDef = saved, cost, rate, deficit
                            end
                        end
                    end
                end
            end
        end
    end
    return bestV, bestID, bestTgt, bestSaved, bestCost, bestRate, bestDef
end

-- The lowest health a target reaches over the horizon if nothing is cast. The
-- danger line is MEASURED (v0.10.3): the biggest hit that target actually took
-- in this fight, times db.simDangerHits.
function Solver:AtRisk(S, t, i)
    local maxHP = S.maxHP[i] or 0
    if maxHP <= 0 or S.dead[i] then return nil end
    local line = (S.danger and S.danger[i] or 0) * maxHP
    if line <= 0 then return nil end
    -- Already there. A target sitting at a tenth of their health with the burst
    -- that put them there over has a trailing damage rate of zero, and the
    -- projection below would call them safe -- which is exactly the reading the
    -- author rejects: "underheal is bad, a new death is unacceptable". Being
    -- under the line is not a forecast, it is a fact.
    if S.hp[i] <= line then return line, 0 end
    local rate = SV.Rate(S, i, t, self)
    local inbound = S.incoming and S.incoming[i] or nil
    if rate <= 0 and not inbound then return nil end
    local flight, fn = SV.InFlight(S, i, t, flightBuf)
    local hp, steps = S.hp[i], math.floor(self.horizon / STEP + 0.5)
    for k = 1, steps do
        local from, to = t + (k - 1) * STEP, t + k * STEP
        hp = hp - rate * STEP
        if inbound and inbound.at and inbound.at > from and inbound.at <= to then
            hp = hp - (inbound.amount or 0)
        end
        for j = 1, fn do
            local d = flight[j]
            if d[1] > from and d[1] <= to then hp = hp + d[2] end
        end
        if hp > maxHP then hp = maxHP end
        if hp <= line then return line, to - t end
    end
    return nil
end

function Solver:Decide(S, t, mana, form)
    SM = SM or MD.SimModel

    -- SAFETY FIRST, as it always has been. If somebody is projected through the
    -- danger line inside the horizon, efficiency is not the question any more:
    -- take the cheapest cast that keeps them above it. Only when nobody is
    -- falling does the value comparison below get to choose.
    for i = 1, S.nT do
        if S.tracked[i] and not S.dead[i] then
            local line, when = self:AtRisk(S, t, i)
            if line then
                local kit = self.kit[form] or self.kit.caster
                local pick, pickCost, pickLow
                for _, fam in ipairs(SV.FAMILIES) do
                    local id2 = self.binds[fam]
                    local e = id2 and kit[id2]
                    if e and mana >= (e.cost or 0) and e.type ~= "instant" then
                        local fi = SM.HOT_INDEX[fam]
                        local st = fi and S.hots[i] and S.hots[i][fi]
                        local dep, dn = SV.Deposits(e, st, depBuf)
                        local flight, fn = SV.InFlight(S, i, t, flightBuf)
                        local rate = SV.Rate(S, i, t, self)
                        local inbound = S.incoming and S.incoming[i] or nil
                        -- the lowest point with this cast in flight
                        local hp, low = S.hp[i], S.hp[i]
                        local steps = math.floor(self.horizon / STEP + 0.5)
                        for k = 1, steps do
                            local from, to = t + (k - 1) * STEP, t + k * STEP
                            hp = hp - rate * STEP
                            if inbound and inbound.at and inbound.at > from and inbound.at <= to then
                                hp = hp - (inbound.amount or 0)
                            end
                            for j = 1, fn do
                                local d = flight[j]
                                if d[1] > from and d[1] <= to then hp = hp + d[2] end
                            end
                            for j = 1, dn do
                                local at = t + dep[j][1]
                                if at > from and at <= to then hp = hp + dep[j][2] end
                            end
                            if hp > (S.maxHP[i] or 0) then hp = S.maxHP[i] end
                            if hp < low then low = hp end
                        end
                        local better = low > (pickLow or -1)
                        if low > line then
                            -- it clears the line: cheapest wins
                            better = (not pick or pickLow <= line) or (e.cost or 0) < (pickCost or 1e9)
                        end
                        if better then pick, pickCost, pickLow = id2, e.cost or 0, low end
                    end
                end
                if pick then
                    self.reason = { rule = 8, target = i, deficit = (S.maxHP[i] or 0) - S.hp[i],
                                    rate = SV.Rate(S, i, t, self), below = (S.danger and S.danger[i]) or nil,
                                    cost = pickCost, freeIn = when }
                    return pick, i, 8
                end
            end
        end
    end

    local v, id, tgt, saved, cost, rate, deficit = self:Best(S, t, mana, form, 0)
    if not id or v < self.minValue then
        self.reason = { rule = 9, target = tgt, deficit = deficit, rate = rate,
                        value = v > 0 and v or nil, floor = self.minValue,
                        watched = S.nT }
        return nil
    end
    -- Waiting is a candidate: the same question one global cooldown later, when
    -- the forecast has added deficit and a HoT may have freed up. If later is
    -- worth more, hold -- this is v0.11.13's "can they hold out until the
    -- efficient spell is free" as a consequence rather than a branch.
    local gcd = 1.5
    local lv = self:Best(S, t, mana, form, gcd)
    -- A deferral has to TERMINATE. Delaying a HoT on a nearly-full target always
    -- trims a little overheal, so "one global cooldown later" keeps winning by a
    -- hair and the plan dithers forever: on a raid fight where the healer cast 82
    -- times this ended at 82% mana with somebody dead (v0.13.5). One deferral per
    -- target is a decision; two in a row is not waiting for a better moment, it is
    -- refusing to heal. The author: "minimal overheal is good, but underheal is
    -- bad" -- so when the two are close, the cast wins.
    if lv > v * 1.05 then
        self.reason = { rule = 9, target = tgt, deficit = deficit, rate = rate,
                        value = v, later = lv, floor = self.minValue }
        return nil
    end
    self.reason = { rule = 7, target = tgt, deficit = deficit, rate = rate,
                    saved = saved, cost = cost, value = v }
    return id, tgt, 7
end


--------------------------------------------------------------------------------
-- 5. The explainer. The solver decides on a number, so its sentence can name
--    the number -- which is more than a threshold rule could ever say. The
--    units are health-seconds of gap removed per mana, which is the only
--    quantity the solver compares anything on.
--------------------------------------------------------------------------------

local function K1(v)
    v = v or 0
    if v >= 1000 then return string.format("%.1fk", v / 1000) end
    return string.format("%d", v + 0.5)
end

function SV.ReasonText(r, names)
    if not r then return nil end
    if r.rule == 7 then
        local parts = { string.format("%s missing", K1(r.deficit)) }
        if (r.rate or 0) > 0 then
            parts[#parts + 1] = string.format("%d/s expected", (r.rate or 0) + 0.5)
        end
        return string.format("%s -> closes %s health-seconds of the gap for %d mana: "
            .. "%.1f per mana, the best on offer",
            table.concat(parts, ", "), K1(r.saved), r.cost or 0, r.value or 0)
    elseif r.rule == 8 then
        return string.format("%s missing at %d/s: they cross the danger line%s in %.1fs, "
            .. "and this is the cheapest cast that holds it (%d mana)",
            K1(r.deficit), (r.rate or 0) + 0.5,
            r.below and string.format(" (%d%% of health)", (r.below or 0) * 100 + 0.5) or "",
            r.freeIn or 0, r.cost or 0)
    elseif r.rule == 9 then
        if not r.target then
            return string.format("waiting: none of the %d is hurt and nothing is expected",
                r.watched or 0)
        end
        if r.later then
            return string.format("waiting: the best cast buys %.1f per mana now and %.1f "
                .. "after one global cooldown, and nobody falls that far",
                r.value or 0, r.later or 0)
        end
        if r.value then
            return string.format("waiting: the best cast buys %.1f per mana, under the %.1f "
                .. "floor -- the mana is worth more later", r.value, r.floor or 0)
        end
        return string.format("waiting: %s missing, nothing worth casting into it", K1(r.deficit))
    end
    return nil
end

return SV
