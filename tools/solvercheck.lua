-- tools/run.sh tools/solvercheck.lua
--
-- The solver (docs/SPEC-v0.13.md): a spell is a series of deposits, and the
-- cast to make is the one that removes the most missing-health-seconds per
-- mana. These assertions are about the PROPERTIES the design claims, not about
-- particular numbers -- an overhealing cast must score below a clean one with
-- no overheal term anywhere in the code, and the same deficit must pull a
-- different spell depending only on how the damage is spread.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local SM, SP, SV = MD.SimModel, MD.SimPlanner, MD.SimSolver
local K = SM.K

-- the shared scripted pull, so there is a real recording to classify against
dofile(here .. "/fakepull.lua")(MD, _G.STUB)

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-46s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local kit = MD.RankMath:SpellKit({ live = true })
local binds = SP.MaxRankBinds()

--------------------------------------------------------------------------------
-- 1. Deposits
--------------------------------------------------------------------------------
do
    local caster = kit.caster
    local lb = caster[binds.Lifebloom]
    local dep, n = SV.Deposits(lb, nil)
    local total = 0
    for i = 1, n do total = total + dep[i][2] end
    local want = (lb.tick or 0) * (lb.ticks or 0) + (lb.bloom or 0)
    check("a spell's deposits sum to what it heals",
        math.abs(total - want) < 1, string.format("%.0f vs %.0f", total, want))
    check("every deposit lands after the cast finishes", (function()
        for i = 1, n do if dep[i][1] < (lb.cast or 1.5) - 1e-9 then return false end end
        return true
    end)())

    local rj = caster[binds.Rejuvenation]
    local d2, n2 = SV.Deposits(rj, nil)
    check("a HoT deposits once per tick", n2 == (rj.ticks or 0), string.format("%d of %d", n2, rj.ticks or 0))

    local rg = caster[binds.Regrowth]
    local d3, n3 = SV.Deposits(rg, nil)
    check("a hybrid deposits its direct heal first",
        n3 == (rg.ticks or 0) + 1 and math.abs(d3[1][2] - rg.direct) < 1,
        string.format("%d deposits, first %.0f", n3, d3[1][2]))

    -- a Lifebloom on top of two stacks deposits three stacks' worth
    local st = { active = true, stacks = 2, family = "Lifebloom" }
    local d4, n4 = SV.Deposits(lb, st)
    check("Lifebloom onto 2 stacks deposits 3 stacks' worth",
        math.abs(d4[1][2] - lb.tick * 3) < 1,
        string.format("%.0f vs %.0f", d4[1][2], lb.tick * 3))
end

--------------------------------------------------------------------------------
-- 2. The gap does the work three separate terms used to do
--------------------------------------------------------------------------------
do
    local maxHP = 10000
    -- a full target: every deposit is overheal, so it saves nothing
    local dep = { { 1.5, 3000 } }
    local full = SV.Gap(maxHP, maxHP, 0, nil, {}, 0, nil, 0, 0, 12)
    local fullWith = SV.Gap(maxHP, maxHP, 0, nil, {}, 0, dep, 1, 0, 12)
    check("a cast into a full target saves nothing", math.abs(full - fullWith) < 1e-6,
        string.format("%.0f vs %.0f", full, fullWith))

    -- the same cast into a real deficit saves the whole integral it fills
    local hurt = SV.Gap(4000, maxHP, 0, nil, {}, 0, nil, 0, 0, 12)
    local hurtWith = SV.Gap(4000, maxHP, 0, nil, {}, 0, dep, 1, 0, 12)
    check("the same cast into a deficit saves real health-seconds",
        hurt - hurtWith > 1000, string.format("%.0f saved", hurt - hurtWith))

    -- half of it overheals: it must save strictly less, with no overheal term
    local dep2 = { { 1.5, 12000 } }
    local overWith = SV.Gap(4000, maxHP, 0, nil, {}, 0, dep2, 1, 0, 12)
    local savedClean = hurt - hurtWith
    local savedOver = hurt - overWith
    check("an oversized cast saves less per point than a fitting one",
        savedOver / 12000 < savedClean / 3000,
        string.format("%.3f vs %.3f per point", savedOver / 12000, savedClean / 3000))

    -- a deposit that lands late is worth less than the same one landing now
    local now = SV.Gap(4000, maxHP, 0, nil, {}, 0, { { 0.5, 3000 } }, 1, 0, 12)
    local late = SV.Gap(4000, maxHP, 0, nil, {}, 0, { { 9.0, 3000 } }, 1, 0, 12)
    check("a deposit landing sooner saves more than the same one landing late",
        (hurt - now) > (hurt - late), string.format("%.0f vs %.0f", hurt - now, hurt - late))
end

--------------------------------------------------------------------------------
-- 3. The decision: same deficit, different damage shape, different spell
--------------------------------------------------------------------------------
local function state(hp, rate, seenFor)
    local S = { nT = 1, tracked = { true }, dead = {}, hp = { hp }, maxHP = { 10000 },
                hots = { {} }, dmg = {}, threat = {}, incoming = {} }
    local ring = { t = {}, a = {}, total = 0, hits = 0, firstAt = 0, biggest = 0 }
    for i = 1, 64 do ring.t[i], ring.a[i] = -100, 0 end
    if rate > 0 then
        local per = rate * 1.0
        for i = 1, 5 do
            ring.t[i], ring.a[i] = (seenFor or 5) - i, per
            ring.total = ring.total + per
            ring.hits = ring.hits + 1
            if per > ring.biggest then ring.biggest = per end
        end
        ring.firstAt = 0
    end
    S.dmg[1] = ring
    return S
end

do
    local plan = SV.NewPlan(binds, { minValue = 0.1, horizon = 12 }, kit)
    -- deeply hurt, nothing incoming: the gap is NOW, so a direct heal wins
    local hurtQuiet = state(3000, 0)
    local id1 = plan:Decide(hurtQuiet, 10, 99999, "caster")
    local sd1 = id1 and MD.SpellData.spells[id1]
    check("a deep deficit with no incoming pulls a direct heal",
        sd1 ~= nil and (sd1.family == "Regrowth" or sd1.family == "HealingTouch"
                        or sd1.family == "Swiftmend"),
        sd1 and (sd1.family .. " r" .. sd1.rank) or tostring(id1))

    -- barely hurt but bleeding: the gap is AHEAD, so a HoT wins
    local trickle = state(9200, 300)
    local id2 = plan:Decide(trickle, 10, 99999, "caster")
    local sd2 = id2 and MD.SpellData.spells[id2]
    check("a small deficit with damage coming pulls a HoT",
        sd2 ~= nil and (sd2.family == "Lifebloom" or sd2.family == "Rejuvenation"),
        sd2 and (sd2.family .. " r" .. sd2.rank) or tostring(id2))
    check("the two answers differ on demand alone, not on a threshold",
        id1 ~= id2, string.format("%s vs %s", tostring(id1), tostring(id2)))

    -- full and quiet: nothing is worth casting
    local calm = state(10000, 0)
    check("nobody hurt, nothing coming: it waits",
        plan:Decide(calm, 10, 99999, "caster") == nil)

    -- the efficiency floor is the mana dial
    local greedy = SV.NewPlan(binds, { minValue = 0.01, horizon = 12 }, kit)
    local stingy = SV.NewPlan(binds, { minValue = 1000, horizon = 12 }, kit)
    local weak = state(9700, 40)
    check("a low floor spends on a thin target", greedy:Decide(weak, 10, 99999, "caster") ~= nil)
    check("a high floor keeps the mana", stingy:Decide(weak, 10, 99999, "caster") == nil)
end

--------------------------------------------------------------------------------
-- 4. Causality: the solver may not see the future either
--------------------------------------------------------------------------------
do
    local function scenarioWithBurst(burst)
        local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
        local n = 0
        local function add(at, amt)
            n = n + 1
            ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = at, K.DMG, 1, amt, 0
        end
        for at = 2, 38, 4 do add(at, 300) end
        if burst then for at = 40, 48 do add(at, 1200) end end
        return { dur = 60, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = ev,
                 targets = { { name = "T", role = "TANK", maxHP = 10000, hp0 = 10000, tracked = true } } }
    end
    local function castsOf(sc)
        local out = {}
        SP.RunPlan(sc, SV.NewPlan(binds, { minValue = 0.5, horizon = 12 }, kit),
            { critMode = "ev", onCast = function(_, at, id)
                out[#out + 1] = string.format("%.2f:%d", at, id) end })
        return out
    end
    local quiet, loud = castsOf(scenarioWithBurst(false)), castsOf(scenarioWithBurst(true))
    local diverged
    for j = 1, math.min(#quiet, #loud) do
        local at = tonumber(quiet[j]:match("^([%d%.]+)"))
        if quiet[j] ~= loud[j] then diverged = diverged or at end
    end
    check("the solver casts something", #quiet > 0, string.format("%d casts", #quiet))
    check("a burst at 40s changes nothing the solver does before it",
        diverged == nil or diverged >= 39.9,
        diverged and string.format("diverged at %.1fs", diverged) or "identical until the burst")
end

--------------------------------------------------------------------------------
-- 5. Healer intuition: a prior from OTHER fights, never from this one
--------------------------------------------------------------------------------
do
    local IN = MD.Intuition
    -- three fake recordings in one zone: the tank eats 400/s from the pull
    local function fakeRec(id, tankDps)
        local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
        local n = 0
        for at = 1, 30 do
            n = n + 1
            ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = at, K.DMG, 1, tankDps, 0
        end
        return { id = id, zone = "Test Keep", dur = 30, n = n, ev = ev,
                 roster = { { name = "T", role = "TANK", maxHP = 4000 },
                            { name = "H", role = "HEALER", maxHP = 4000 } } }
    end
    local recs = { fakeRec(1, 400), fakeRec(2, 400), fakeRec(3, 400) }

    local prior = IN:Build(recs, nil)
    -- the prior speaks in FRACTIONS of max health: 400/s on a 4000hp tank is 10%
    local r = IN:Rate(prior, "Test Keep", "TANK", 0)
    check("the prior learns the tank takes damage from the pull",
        r > 0.05 and r < 0.2, string.format("%.1f%% of health per second", r * 100))
    check("the prior is a fraction, so it travels to another character",
        math.abs(r * 12000 - 1200) < 200,
        string.format("%.0f/s on a 12k tank vs %.0f/s on the 4k one it learned from",
            r * 12000, r * 4000))
    check("it says nothing about a role nobody recorded",
        IN:Rate(prior, "Test Keep", "DAMAGER", 0) == 0)

    -- THE invariant: a fight may not teach itself
    local held = IN:Build(recs, 2)
    check("holding a fight out drops it from the prior",
        held.fights == 2 and held.skipped == 1,
        string.format("%d used, %d held", held.fights, held.skipped))
    local only = IN:Build({ recs[2] }, 2)
    check("a fight held out of a corpus of one leaves NO prior",
        IN:Rate(only, "Test Keep", "TANK", 0) == 0,
        string.format("%.0f", IN:Rate(only, "Test Keep", "TANK", 0)))

    -- one fight is an anecdote
    local single = IN:Build({ recs[1] }, nil)
    check("one fight is not enough to be a prior",
        IN:Rate(single, "Test Keep", "TANK", 0) == 0)

    -- the prior fades as the fight provides real evidence
    local far = IN:Rate(prior, "Test Keep", "TANK", 60)
    check("the prior still answers later in the fight", far > 0,
        string.format("%.1f%%", far * 100))

    -- and it must not make the solver clairvoyant: same scenario, same answer,
    -- whether or not a burst it never saw is coming
    local function scen(burst)
        local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
        local n = 0
        local function add(at, amt)
            n = n + 1
            ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = at, K.DMG, 1, amt, 0
        end
        for at = 2, 38, 4 do add(at, 300) end
        if burst then for at = 40, 48 do add(at, 1200) end end
        return { dur = 60, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = ev,
                 targets = { { name = "T", role = "TANK", maxHP = 10000, hp0 = 10000, tracked = true } } }
    end
    local function castsOf(sc)
        local out = {}
        SP.RunPlan(sc, SV.NewPlan(binds, { minValue = 0.5, horizon = 12,
            prior = prior, zone = "Test Keep" }, kit),
            { critMode = "ev", onCast = function(_, at, id)
                out[#out + 1] = string.format("%.2f:%d", at, id) end })
        return out
    end
    local quiet, loud = castsOf(scen(false)), castsOf(scen(true))
    local diverged
    for j = 1, math.min(#quiet, #loud) do
        if quiet[j] ~= loud[j] then
            diverged = diverged or tonumber(quiet[j]:match("^([%d%.]+)"))
        end
    end
    check("a prior does not make the solver clairvoyant",
        diverged == nil or diverged >= 39.9,
        diverged and string.format("diverged at %.1fs", diverged) or "identical until the burst")

    -- the point of the whole thing: it acts at the pull, before any hit lands
    local blind = SV.NewPlan(binds, { minValue = 0.5, horizon = 12 }, kit)
    local wise = SV.NewPlan(binds, { minValue = 0.5, horizon = 12,
                                     prior = prior, zone = "Test Keep" }, kit)
    local S0 = { nT = 2, tracked = { true, true }, dead = {}, hp = { 10000, 10000 },
                 maxHP = { 10000, 10000 }, hots = { {}, {} }, dmg = {}, danger = {},
                 role = { "TANK", "HEALER" }, threat = {}, incoming = {}, danger = {} }
    for i = 1, 2 do
        local ring = { t = {}, a = {}, total = 0, hits = 0, firstAt = nil, biggest = 0 }
        for j = 1, 64 do ring.t[j], ring.a[j] = -100, 0 end
        S0.dmg[i] = ring
    end
    check("with no prior the solver waits at the pull",
        blind:Decide(S0, 0, 99999, "caster") == nil)
    local id, tgt = wise:Decide(S0, 0, 99999, "caster")
    check("with a prior it pre-heals the tank before the first hit",
        id ~= nil and tgt == 1,
        id and ((MD.SpellData.spells[id] or {}).family or tostring(id)) or "still waited")
end

--------------------------------------------------------------------------------
-- 6. Deformed foresight: it must SEE the burst and must NOT see it clearly
--------------------------------------------------------------------------------
do
    local FS = MD.Foresight
    -- one clean burst: 8000 damage in a single second at t=40, nothing else
    local ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
    local n = 0
    local function add(at, amt)
        n = n + 1
        ev.t[n], ev.kind[n], ev.tgt[n], ev.amt[n], ev.x[n] = at, K.DMG, 1, amt, 0
    end
    for at = 2, 60, 4 do add(at, 200) end
    add(40, 8000)
    local sc = { dur = 70, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = ev,
                 targets = { { name = "T", role = "TANK", maxHP = 10000, hp0 = 10000, tracked = true } } }

    local fs = FS.Build(sc, { seed = 7 })
    check("foresight builds from the fight", fs ~= nil and fs.nT == 1)

    -- it knows something is coming: the rate ahead of the burst beats a quiet spot
    local before = FS.Rate(fs, 1, 34, 12)
    local quiet = FS.Rate(fs, 1, 10, 12)
    check("it knows a burst is coming before it lands", before > quiet * 2,
        string.format("%.0f/s at 34s vs %.0f/s at 10s", before, quiet))

    -- ...and it cannot place it: the bucket before the burst is already lit
    local early = FS.Rate(fs, 1, 34, 4)
    check("it cannot place the burst inside its own second", early > quiet,
        string.format("%.0f/s already at 34s", early))

    -- ...and it cannot size it: the deformed peak is off the truth
    local peakBin = 0
    for b = 1, fs.nBins do if fs.bins[1][b] > peakBin then peakBin = fs.bins[1][b] end end
    local truth = 8000 + 200
    check("it cannot size the burst either", math.abs(peakBin - truth) / truth > 0.10,
        string.format("%.0f vs %.0f = %.0f%% off", peakBin, truth,
            100 * math.abs(peakBin - truth) / truth))

    -- nothing beyond sight
    check("it sees nothing beyond its horizon", FS.Rate(fs, 1, 0, 12) < before,
        string.format("%.0f at the pull", FS.Rate(fs, 1, 0, 12)))

    -- deterministic: a replay must reproduce
    local again = FS.Build(sc, { seed = 7 })
    local same = true
    for b = 1, fs.nBins do if math.abs(fs.bins[1][b] - again.bins[1][b]) > 1e-9 then same = false end end
    check("the same fight deforms the same way every time", same)
    local other = FS.Build(sc, { seed = 8 })
    local diff = false
    for b = 1, fs.nBins do if math.abs(fs.bins[1][b] - other.bins[1][b]) > 1e-9 then diff = true end end
    check("a different seed deforms differently", diff)

    -- the honest label: a plan with foresight admits it is not causal
    local blind = SV.NewPlan(binds, { minValue = 15, horizon = 18 }, kit)
    local seer = SV.NewPlan(binds, { minValue = 15, horizon = 18, foresight = fs }, kit)
    check("a plan without foresight does not claim it", blind.foresees == false)
    check("a plan with foresight admits it", seer.foresees == true)

    -- and the point: it heals INTO the burst rather than after it
    local function firstCastAfter(plan, from)
        local at
        SP.RunPlan(sc, plan, { critMode = "ev", onCast = function(_, t2)
            if not at and t2 >= from then at = t2 end end })
        return at
    end
    local a = firstCastAfter(SV.NewPlan(binds, { minValue = 15, horizon = 18 }, kit), 30)
    local b = firstCastAfter(SV.NewPlan(binds, { minValue = 15, horizon = 18, foresight = fs }, kit), 30)
    check("foresight moves the answer earlier, not later",
        (a == nil and b ~= nil) or (a and b and b <= a + 1e-9),
        string.format("blind %s, foresighted %s", tostring(a), tostring(b)))
end

--------------------------------------------------------------------------------
-- 7. The explainer: the solver decided on a number, so it can name the number
--------------------------------------------------------------------------------
do
    local plan = SV.NewPlan(binds, { minValue = 0.1, horizon = 12 }, kit)
    local seen = {}
    local S1 = state(3000, 400)
    plan:Decide(S1, 10, 99999, "caster")
    seen[#seen + 1] = plan.reason
    local S2 = state(10000, 0)
    plan:Decide(S2, 10, 99999, "caster")
    seen[#seen + 1] = plan.reason
    local stingy = SV.NewPlan(binds, { minValue = 1e6, horizon = 12 }, kit)
    stingy:Decide(state(9700, 40), 10, 99999, "caster")
    seen[#seen + 1] = stingy.reason

    local allNumbered, anyPipe, rules = true, false, {}
    for _, r in ipairs(seen) do
        local txt = SP.ReasonText(r, {})
        rules[#rules + 1] = tostring(r.rule)
        if type(txt) ~= "string" or not txt:find("%d") then allNumbered = false end
        if txt and txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):find("|", 1, true) then
            anyPipe = true
        end
    end
    check("every solver decision renders a sentence with a number in it",
        allNumbered, "rules " .. table.concat(rules, ","))
    check("no bare pipe in a solver sentence", not anyPipe)
    check("the planner delegates the solver's rules to the solver",
        SP.ReasonText({ rule = 7, deficit = 1200, rate = 350, saved = 3400,
                        cost = 220, value = 15.5 }, {}):find("per mana") ~= nil,
        SP.ReasonText({ rule = 7, deficit = 1200, rate = 350, saved = 3400,
                        cost = 220, value = 15.5 }, {}))
    check("each solver rule has a name for the replay's hover",
        SP.RULE_NAMES[7] and SP.RULE_NAMES[8] and SP.RULE_NAMES[9] ~= nil)
    print("   " .. tostring(SP.ReasonText({ rule = 7, deficit = 1200, rate = 350,
        saved = 3400, cost = 220, value = 15.5 }, {})))
    print("   " .. tostring(SP.ReasonText({ rule = 8, deficit = 6600, rate = 900,
        below = 0.34, freeIn = 2.5, cost = 220 }, {})))
    print("   " .. tostring(SP.ReasonText({ rule = 9, target = 1, deficit = 400,
        value = 12.1, later = 18.4 }, {})))
end

--------------------------------------------------------------------------------
-- 8. The strategy set is what a human picks between
--------------------------------------------------------------------------------
do
    check("there are strategies to choose from", #SP.STRATEGY_SET >= 4,
        tostring(#SP.STRATEGY_SET))
    local kinds = {}
    for _, e in ipairs(SP.STRATEGY_SET) do kinds[e.kind] = true end
    check("both planners are represented", kinds.rules and kinds.solver)
    local sc = { dur = 20, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} },
                 targets = { { name = "T", role = "TANK", maxHP = 10000, hp0 = 10000, tracked = true } } }
    local built, labelled = 0, 0
    for _, e in ipairs(SP.STRATEGY_SET) do
        local plan = SP.MakeStrategy(e, binds, kit, { scenario = sc, seed = 1 })
        if plan then built = built + 1 end
        if e.why and #e.why > 10 then labelled = labelled + 1 end
    end
    check("every strategy builds a plan", built == #SP.STRATEGY_SET,
        string.format("%d of %d", built, #SP.STRATEGY_SET))
    check("every strategy says what it is for", labelled == #SP.STRATEGY_SET)
    local sight = SP.Strategy("solver-sight")
    local plan = SP.MakeStrategy(sight, binds, kit, { scenario = sc, seed = 1 })
    check("the foresighted strategy is flagged as not causal", plan.foresees == true)
    local plain = SP.MakeStrategy(SP.Strategy("solver-blind"), binds, kit, { scenario = sc, seed = 1 })
    check("the others are not", plain.foresees == false)
end

--------------------------------------------------------------------------------
-- 9. The shipped prior: somebody else's experience, in fractions of health
--------------------------------------------------------------------------------
do
    local IN = MD.Intuition
    local t = MD.IntuitionTBC
    check("a prior ships with the addon", t ~= nil and (t.fights or 0) >= 10,
        t and string.format("%d fights, %d encounters", t.fights or 0, t.encounters or 0) or "missing")
    check("it was merged from many encounters, not one raid",
        (t.encounters or 0) >= 8, tostring(t.encounters))
    check("it is blurred, not exact", (t.blurred or 0) > 0,
        string.format("quantised to %.1f%% of health per second", (t.blurred or 0) * 100))
    check("a tank opens harder than the fight sustains",
        t.all.TANK.open > t.all.TANK.rest,
        string.format("%.1f%% then %.1f%%", t.all.TANK.open * 100, t.all.TANK.rest * 100))
    check("nobody but the tank is expected to take damage at the pull",
        t.all.DAMAGER.open == 0 and t.all.HEALER.open == 0)
    check("it carries how much it varies, so it can be doubted",
        (t.all.TANK.spread or 0) > 1, string.format("%.1fx between encounters",
            t.all.TANK.spread or 0))

    local prior = IN:Load(t)
    check("the shipped prior loads into the same shape Build makes",
        IN:Rate(prior, nil, "TANK", 0) > 0.02,
        string.format("%.1f%% of health per second", IN:Rate(prior, nil, "TANK", 0) * 100))

    -- it lands on a character it never saw: a 4k tank and a 13k tank
    local frac = IN:Rate(prior, nil, "TANK", 0)
    check("the same prior scales to any character",
        math.abs(frac * 4000 - 340) < 120 and math.abs(frac * 13000 - 1170) < 400,
        string.format("%.0f/s on a 4k tank, %.0f/s on a 13k one", frac * 4000, frac * 13000))

    -- and it does the job: pre-heal the TANK at the pull, with no damage yet
    local function pullState()
        local S = { nT = 2, tracked = { true, true }, dead = {}, hp = { 12000, 8000 },
                    maxHP = { 12000, 8000 }, hots = { {}, {} }, dmg = {}, danger = {},
                    role = { "TANK", "HEALER" }, threat = {}, incoming = {} }
        for i = 1, 2 do
            local ring = { t = {}, a = {}, total = 0, hits = 0, firstAt = nil, biggest = 0 }
            for j = 1, 64 do ring.t[j], ring.a[j] = -100, 0 end
            S.dmg[i] = ring
        end
        return S
    end
    local sc = { dur = 30, pool = 9000, initial = { mana = 9000, apiBase = 10, apiCasting = 4 },
                 kit = kit, floor = 0.30, ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} },
                 targets = { { name = "T", role = "TANK", maxHP = 12000, hp0 = 12000, tracked = true } } }
    local blind = SP.MakeStrategy(SP.Strategy("solver-blind"), binds, kit, { scenario = sc })
    local wise = SP.MakeStrategy(SP.Strategy("solver-corpus"), binds, kit, { scenario = sc })
    check("the corpus strategy carries the shipped prior", wise.prior ~= nil)
    check("it is still causal -- it never reads this fight", wise.foresees == false)
    check("with the shipped prior the solver opens on the tank",
        blind:Decide(pullState(), 0, 99999, "caster") == nil
        and select(2, wise:Decide(pullState(), 0, 99999, "caster")) == 1,
        (function()
            local id, tgt = wise:Decide(pullState(), 0, 99999, "caster")
            return id and string.format("target %s, %s", tostring(tgt),
                (MD.SpellData.spells[id] or {}).family or id) or "waited"
        end)())
end

--------------------------------------------------------------------------------
-- 10. The classifier must survive a solver plan (v0.13.10)
--
-- SP.Classify labels recorded casts against a plan, and it read plan.rollStacks
-- -- a THRESHOLD-RULES parameter the solver does not have. Since v0.13.7 the
-- replay's chooser can hand it a solver plan, and it took the window down live
-- with "attempt to compare nil with number".
--------------------------------------------------------------------------------
do
    local rec = MD.FightRecorder:Get(1)
    check("there is a recording to classify", rec ~= nil)
    if rec then
        for _, entry in ipairs(SP.STRATEGY_SET) do
            local kit2 = MD.RankMath:SpellKit({ live = true })
            local sc = SM.ScenarioFromRecording(rec, kit2)
            local plan = SP.MakeStrategy(entry, SP.MaxRankBinds(), kit2,
                { scenario = sc, seed = rec.id or 1 })
            local okRun, err = pcall(SP.Classify, rec, sc, plan, kit2)
            check("Classify survives " .. entry.key, okRun, tostring(err))
        end
        -- The exact shape that crashed live: control reaches the rollStacks
        -- test only when the plan wants NOTHING at that cast (so every earlier
        -- branch misses) and a Lifebloom is already rolling on the target. A
        -- bare table with a Decide that returns nil is the minimal plan that
        -- does it -- and it has no rollStacks at all, which is the point: the
        -- classifier must not assume the fields of the threshold rules.
        do
            local kitX = MD.RankMath:SpellKit({ live = true })
            local nothing = { Decide = function() return nil end,
                              BindCount = function() return 0 end,
                              Reset = function() end, binds = {}, kit = kitX }
            -- the fixture casts Lifebloom once, so it never lands on a live
            -- one. Roll it: four casts inside a single Lifebloom's seven
            -- seconds, which is what the author's log had (stacks = 3).
            local rec2 = {}
            for k, v in pairs(rec) do rec2[k] = v end
            rec2.ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} }
            for i = 1, rec.n do
                rec2.ev.t[i], rec2.ev.kind[i] = rec.ev.t[i], rec.ev.kind[i]
                rec2.ev.tgt[i], rec2.ev.amt[i], rec2.ev.x[i] =
                    rec.ev.tgt[i], rec.ev.amt[i], rec.ev.x[i]
            end
            rec2.n = rec.n
            local lb = SP.MaxRankBinds().Lifebloom
            local last = rec.ev.t[rec.n] or 0
            for i = 1, 4 do
                rec2.n = rec2.n + 1
                rec2.ev.t[rec2.n] = last + i * 1.5
                rec2.ev.kind[rec2.n] = K.OWNCAST
                rec2.ev.tgt[rec2.n], rec2.ev.amt[rec2.n], rec2.ev.x[rec2.n] = 1, 220, lb
            end
            rec2.dur = math.max(rec.dur or 0, last + 8)
            local scX = SM.ScenarioFromRecording(rec2, kitX)
            local okS, clsOrErr = pcall(SP.Classify, rec2, scX, nothing, kitX)
            check("Classify survives a plan with no rollStacks at all",
                okS, tostring(clsOrErr))
            local labels = {}
            for _, c in ipairs((okS and clsOrErr and clsOrErr.casts) or {}) do
                labels[#labels + 1] = c.label
            end
            -- (a "stack" label would only appear for a plan that HAS a roll
            -- target; the point here is that a plan without one does not crash)
            check("...and it really did classify the casts", #labels >= 3,
                string.format("%d cast(s): %s", #labels, table.concat(labels, ",")))
        end

        -- and the whole replay path, which is what actually broke
        local kit2 = MD.RankMath:SpellKit({ live = true })
        local sc = SM.ScenarioFromRecording(rec, kit2)
        SP.plans[rec.id] = SP.MakeStrategy(SP.Strategy("solver-blind"),
            SP.MaxRankBinds(), kit2, { scenario = sc, seed = rec.id or 1 })
        local okRep, err2 = pcall(SP.Replay, rec, { dt = 0.25, force = true })
        check("SP.Replay survives a solver plan", okRep, tostring(err2))
        SP.plans[rec.id] = nil
    end
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
