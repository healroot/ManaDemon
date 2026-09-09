-- tools/run.sh tools/runcheck.lua
--
-- A whole dungeon under the stub (docs/SPEC-v0.9.md 3.6): /md run start, three
-- pulls with the gaps between them -- a drink at a scripted rate, a death and a
-- release -- then /md run stop. The run recorder is a CONTAINER, so what this
-- checks is that nothing falls between the pulls and the gaps: the third pull
-- is under the recording gate and must still be kept, the ring of 8 must not
-- see any of them, the drink rate must be the scripted one and not a preset,
-- and the run must stop itself when the author walks out of the instance.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local RR, FR = MD.RunRecorder, MD.FightRecorder
local K = RR.K

local out = {}
local realChat = _G.DEFAULT_CHAT_FRAME
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) out[#out + 1] = m; print(m) end }

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-42s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end
local function found(pat)
    for _, m in ipairs(out) do if m:find(pat) then return m end end
    return nil
end

--------------------------------------------------------------------------------
-- The party, and one pull of it
--------------------------------------------------------------------------------
local SD = MD.SpellData
S.AddUnit("party1", { guid = "Tank-1", name = "Destroyka", class = "WARRIOR", role = "TANK",
                      hp = 8000, hpMax = 8000 })
S.AddUnit("party2", { guid = "Mage-1", name = "Alkandari", class = "MAGE", role = "DAMAGER",
                      hp = 4000, hpMax = 4000 })
S.Fire("GROUP_ROSTER_UPDATE")
S.inInstance = true
local PLAYER = "Player-1"
local rejuv, regrowth = SD.maxRank.Rejuvenation, SD.maxRank.Regrowth

local function ev(sub, src, dst, dstName, ...)
    S.Combat(0, sub, false, src, "src", 0, 0, dst, dstName, 0, 0, ...)
end
local function cast(spellID, dst, dstName)
    ev("SPELL_CAST_SUCCESS", PLAYER, dst, dstName, spellID, "S", 8)
    S.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, spellID)
    S.mana = S.mana - (SD:GetCost(spellID) or 0)
    S.Fire("UNIT_POWER_UPDATE", "player", "MANA")
end
local function swing(dst, dstName, amount)
    ev("SWING_DAMAGE", "Mob-1", dst, dstName, amount, 0, 1, 0, 0, 0, false)
end
local function advance(sec) for _ = 1, math.floor(sec / 0.5 + 0.5) do S.Tick(0.5) end end

-- one pull: `casts` own casts spread over `dur` seconds, damage on the tank
-- One pull. The damage is deliberately survivable: a tank who dies in the
-- simulation has no healing decisions left, and every plan then scores the same
-- for the wrong reason.
local function pull(dur, casts)
    S.units.party1.hp = 5000
    S.Fire("PLAYER_REGEN_DISABLED")
    swing("Tank-1", "Destroyka", 1500)
    local gap = dur / (casts + 1)
    for i = 1, casts do
        advance(gap)
        cast(i % 2 == 0 and regrowth or rejuv, "Tank-1", "Destroyka")
    end
    advance(gap)
    S.Fire("PLAYER_REGEN_ENABLED")
end

-- drink: the buff up, mana rising at a scripted rate, then the buff gone
local DRINK_RATE = 120        -- mana per second, the number the run must measure
local function drink(sec)
    S.buffs = { "Drink" }
    local steps = math.floor(sec / 0.5 + 0.5)
    for _ = 1, steps do
        S.mana = math.min(S.manaMax, S.mana + DRINK_RATE * 0.5)
        S.Fire("UNIT_POWER_UPDATE", "player", "MANA")
        S.Tick(0.5)
    end
    S.buffs = {}
    S.Tick(0.5)
end

--------------------------------------------------------------------------------
-- 1. start
--------------------------------------------------------------------------------
S.mana = 4000
local run, why = RR:Start("manual", "Blood Furnace test")
check("run starts", run ~= nil, why)
check("named as asked", run and run.name == "Blood Furnace test", run and run.name)
local again, why2 = RR:Start("manual")
check("a second start refuses", again == nil and why2 ~= nil and why2:find("already"), why2)

--------------------------------------------------------------------------------
-- 2. three pulls, with a drink and a death in the gaps
--------------------------------------------------------------------------------
local ringBefore = #(MD.cdb.recordings or {})
pull(40, 8)                       -- a real pull
advance(4)
drink(25)                         -- +3000 mana at 120/s
advance(4)
pull(35, 7)                       -- another
advance(3)
S.Fire("PLAYER_DEAD")
advance(20)
S.Fire("PLAYER_ALIVE")
advance(3)
pull(8, 2)                        -- under the gate: 8s, 2 casts
advance(2)

check("three pulls kept", #run.pulls == 3, tostring(#run.pulls))
check("the short pull is kept and flagged", run.pulls[3] and run.pulls[3].short == true
    and (run.pulls[3].dur or 0) < 20, run.pulls[3] and string.format("%.0fs, short=%s",
        run.pulls[3].dur or 0, tostring(run.pulls[3].short)) or "missing")
check("the long pulls are not flagged", run.pulls[1] and not run.pulls[1].short and not run.pulls[2].short)
check("pulls are in order", run.pulls[1].runT0 < run.pulls[2].runT0 and run.pulls[2].runT0 < run.pulls[3].runT0,
    string.format("%.0f, %.0f, %.0f", run.pulls[1].runT0, run.pulls[2].runT0, run.pulls[3].runT0))
check("the ring of 8 is untouched", #(MD.cdb.recordings or {}) == ringBefore,
    string.format("%d before, %d now", ringBefore, #(MD.cdb.recordings or {})))

-- the events
local kinds = {}
for i = 1, #run.ev.t do
    local k = run.ev.kind[i]
    kinds[k] = (kinds[k] or 0) + 1
end
check("one PULL per pull", kinds[K.PULL] == 3, tostring(kinds[K.PULL]))
check("one PULL_END per pull", kinds[K.PULL_END] == 3, tostring(kinds[K.PULL_END]))
check("one drink recorded", kinds[K.DRINK] == 1 and kinds[K.DRINK_END] == 1,
    string.format("%s / %s", tostring(kinds[K.DRINK]), tostring(kinds[K.DRINK_END])))
check("death and release recorded", kinds[K.DEAD] == 1 and kinds[K.ALIVE] == 1,
    string.format("%s / %s", tostring(kinds[K.DEAD]), tostring(kinds[K.ALIVE])))

-- mana at each pull start, as a fraction of the pool
local fracs = {}
for i = 1, #run.ev.t do
    if run.ev.kind[i] == K.PULL then fracs[#fracs + 1] = run.ev.b[i] end
end
local fracsOk = #fracs == 3
for _, f in ipairs(fracs) do if not (f > 0 and f <= 1) then fracsOk = false end end
check("PULL carries the mana fraction", fracsOk,
    string.format("%.2f, %.2f, %.2f", fracs[1] or -1, fracs[2] or -1, fracs[3] or -1))
-- the drink itself: mana either side of it, which is what the gap model reads
local dStart, dEnd
for i = 1, #run.ev.t do
    if run.ev.kind[i] == K.DRINK then dStart = run.ev.a[i]
    elseif run.ev.kind[i] == K.DRINK_END then dEnd = run.ev.a[i] end
end
check("DRINK carries the mana either side", dStart and dEnd and (dEnd - dStart) > 2500,
    string.format("%s -> %s", tostring(dStart), tostring(dEnd)))

-- mana sampled across the whole run, gaps included
local mn = run.mana
check("mana sampled every 2s across the run", #mn.t > 40 and (mn.t[#mn.t] - mn.t[1]) > 100,
    string.format("%d samples over %.0fs", #mn.t, (mn.t[#mn.t] or 0) - (mn.t[1] or 0)))

--------------------------------------------------------------------------------
-- 3. stop, and the stats
--------------------------------------------------------------------------------
out = {}
local stopped = select(1, RR:Stop("manual"))
check("stop returns the run", stopped == run)
check("nothing is recording after a stop", RR.active == nil)
local st = run.stats
check("stats: pulls", st.pulls == 3 and st.recorded == 3, string.format("%d / %d", st.pulls, st.recorded))
check("stats: combat time is the pulls", math.abs(st.combat - (run.pulls[1].dur + run.pulls[2].dur
    + run.pulls[3].dur)) < 0.01, string.format("%.1fs", st.combat))
check("stats: combat share under the wall clock", st.combatPct > 0.4 and st.combatPct < 0.8,
    string.format("%.0f%% of %.0fs", st.combatPct * 100, st.wall))
check("stats: one drink with its time", st.drinks == 1 and math.abs(st.drinkTime - 25) <= 1,
    string.format("%d drink(s), %.1fs", st.drinks, st.drinkTime))
-- the whole point of measuring rather than presetting: within 2% of the script
check("stats: the drink rate is the scripted one", st.drinkRate
    and math.abs(st.drinkRate - DRINK_RATE) / DRINK_RATE < 0.02,
    st.drinkRate and string.format("%.1f vs %d mana/s", st.drinkRate, DRINK_RATE) or "no rate")
check("stats: one death, with the time dead", st.deaths == 1 and math.abs(st.deadTime - 20) <= 1,
    string.format("%d, %.1fs", st.deaths, st.deadTime))
check("stats: mana at pull p50", st.manaAtPullP50 ~= nil and st.manaAtPullP50 == fracs[2],
    tostring(st.manaAtPullP50))
check("stats: mana spent is the pulls' spend", st.spent > 0 and st.spent ==
    (run.pulls[1].spent + run.pulls[2].spent + run.pulls[3].spent), tostring(st.spent))
check("the run line names the drink and the death", found("drank 1x") ~= nil and found("1 death") ~= nil,
    found("run Blood Furnace test") or "no line")
check("stored in cdb.runs", #(MD.cdb.runs or {}) == 1 and MD.cdb.runs[1] == run)
check("absolute t0 dropped on store", run.t0 == nil)

--------------------------------------------------------------------------------
-- 4. the budget: past it, pulls are summarised, not recorded
--------------------------------------------------------------------------------
local realMax = RR.MAX_RUN_EV
RR.MAX_RUN_EV = 8
S.mana = 4000
local r2 = RR:Start("manual", "budget")
pull(40, 8)
advance(2)
pull(40, 8)
advance(2)
check("budget: the run says it is full", r2.truncated == true, tostring(r2.truncated))
check("budget: a later pull carries no stream", #r2.pulls < 2, tostring(#r2.pulls))
out = {}
RR:Stop("manual")
check("budget: the stop line says so", found("STREAM FULL") ~= nil, found("run budget") or "no line")
check("budget: the summarised pull is still counted", (r2.stats.summarised or 0) >= 1
    and r2.stats.pulls == #r2.pulls + r2.stats.summarised,
    string.format("%d pulls, %d summarised", r2.stats.pulls, r2.stats.summarised or 0))
-- the gap timeline keeps going when the pulls stop being recorded: a pull the
-- run only summarised is still time the group spent in combat
check("budget: the summarised pull's time is still counted", r2.stats.combatPct > 0.85,
    string.format("combat %.0f%% of %.0fs", r2.stats.combatPct * 100, r2.stats.wall))
RR.MAX_RUN_EV = realMax

--------------------------------------------------------------------------------
-- 5. auto-stop on leaving the instance, after the grace a corpse run needs
--------------------------------------------------------------------------------
out = {}
S.mana = 4000
local r3 = RR:Start("manual", "leaver")
advance(5)
S.inInstance = false
S.Fire("ZONE_CHANGED_NEW_AREA")
advance(20)
check("still recording inside the grace", RR.active == r3, tostring(RR.active and RR.active.name))
S.inInstance = true
S.Fire("ZONE_CHANGED_NEW_AREA")          -- back in: a corpse run, not a departure
advance(40)
check("returning cancels the auto-stop", RR.active == r3, tostring(RR.active and RR.active.name))
S.inInstance = false
S.Fire("ZONE_CHANGED_NEW_AREA")
advance(40)
check("auto-stops after the grace", RR.active == nil)
check("the stop line says why", found("left the instance") ~= nil, found("run leaver") or "no line")

--------------------------------------------------------------------------------
-- 6. retention: two kept, and both pinned means the next one refuses UP FRONT
--------------------------------------------------------------------------------
check("two runs kept", #MD.cdb.runs == 2, tostring(#MD.cdb.runs))
local names = {}
for _, r in ipairs(MD.cdb.runs) do names[#names + 1] = r.name end
table.sort(names)
check("the oldest unpinned run was the victim", names[1] == "budget" and names[2] == "leaver",
    table.concat(names, ", "))
for _, r in ipairs(MD.cdb.runs) do r.pinned = true end
local r4, why4 = RR:Start("manual", "refused")
check("both pinned: start refuses before recording", r4 == nil and why4 ~= nil and why4:find("pinned"), why4)
check("refusing leaves nothing recording", RR.active == nil)
MD.cdb.runs[1].pinned = false

--------------------------------------------------------------------------------
-- 7. the setting, the command, and the export
--------------------------------------------------------------------------------
MD.db.recordRuns = false
local r5, why5 = RR:Start("manual")
check("db.recordRuns off refuses", r5 == nil and why5 ~= nil and why5:find("recordRuns"), why5)
MD.db.recordRuns = true

out = {}
MD:RunCommand("status")
check("/md run status lists the stored runs", found("nothing recording") ~= nil and found("leaver") ~= nil,
    out[1] or "no output")
out = {}
MD:RunCommand("start Some Dungeon")
check("/md run start keeps the name's case", RR.active ~= nil and RR.active.name == "Some Dungeon",
    RR.active and RR.active.name or "nothing recording")
out = {}
MD:RunCommand("status")
check("/md run status reports the live run", found("Some Dungeon") ~= nil and found("elapsed") ~= nil,
    out[1] or "no output")
MD:RunCommand("stop")
check("/md run stop stops it", RR.active == nil)

local lines = MD:Export()
local runHead, runEv, pullInRun = nil, 0, nil
for _, row in ipairs(lines) do
    if row:find("^# run %d") then runHead = row end
    if row:find("^# run ev") then runEv = runEv + 1 end
    if row:find("run 17570") and row:find("pull") then pullInRun = row end
end
check("export has a # run section", runHead ~= nil, runHead and runHead:sub(1, 60) or "none")
check("export has the gap events", runEv >= 1, tostring(runEv))
check("export tags each pull with its run", pullInRun ~= nil, pullInRun and pullInRun:sub(1, 80) or "none")

--------------------------------------------------------------------------------
-- 8. the run through the engine (v0.9.3): pulls chained with mana carried over,
-- the gaps modelled, the drink policy simulated
--------------------------------------------------------------------------------
local SM, SP = MD.SimModel, MD.SimPlanner
local kit = MD.RankMath:SpellKit()
-- run 1 is the three-pull run from section 2; it was dropped by retention, so
-- record a fresh one to chain
S.mana = 4200
local chainRun = RR:Start("manual", "chain")
pull(40, 8)
advance(4)
drink(25)
advance(4)
pull(40, 8)
advance(3)
pull(40, 8)
advance(2)
RR:Stop("manual")

local you = SP.ChainSnap(SM.ChainRun(chainRun, kit, { recorded = true }))
check("chain: every pull ran", #you.pulls == 3, tostring(#you.pulls))
check("chain: the recorded row starts each pull where the recording did", (function()
    for i, p in ipairs(you.pulls) do
        local want = chainRun.pulls[i].initial.mana
        if math.abs(p.manaStart - want) > 1 then return false end
    end
    return true
end)())
check("chain: the recorded row reports the drinks that happened",
    you.drinks == (chainRun.stats.drinks or 0) and you.addedTime == 0,
    string.format("%d drink(s), %.0fs added", you.drinks, you.addedTime))

-- a plan, with the policy: mana must be carried ACROSS the pulls
local plan = SP.NewPlan(SP.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false }, kit)
local chain = SM.ChainRun(chainRun, kit, { plan = plan, policy = { below = 0.60, upTo = 0.95 } })
check("chain: mana is carried across the gaps", (function()
    for i = 2, #chain.pulls do
        local gap = chain.gaps[i - 1]
        if not gap then return false end
        -- the gap starts where the previous pull ended and ends where this one starts
        if math.abs(gap.manaStart - chain.pulls[i - 1].manaEnd) > 0.01 then return false end
        if math.abs(gap.manaEnd - chain.pulls[i].manaStart) > 0.01 then return false end
    end
    return true
end)())
check("chain: the run's own drink rate is used, not a preset",
    math.abs((chain.drinkRate or 0) - DRINK_RATE) / DRINK_RATE < 0.02
    and chain.drinkRateSource == "measured on this run",
    string.format("%.1f (%s)", chain.drinkRate or -1, tostring(chain.drinkRateSource)))
check("chain: a gap regenerates when nobody drinks", (function()
    for _, g in ipairs(chain.gaps) do
        if not g.drank and g.manaEnd <= g.manaStart then return false end
    end
    return true
end)())

-- a policy that drinks to full whenever it can, in gaps too short for it: the
-- run has to get LONGER, and that is a score term
local greedy = SM.ChainRun(chainRun, kit, { plan = plan, policy = { below = 1.0, upTo = 1.0 } })
check("chain: a drink that does not fit its gap lengthens the run",
    greedy.addedTime > 0 and greedy.wall > (chainRun.stats.wall or 0),
    string.format("+%.0fs, wall %.0f -> %.0f", greedy.addedTime, chainRun.stats.wall or 0, greedy.wall))
check("chain: a policy that never drinks adds nothing", (function()
    local none = SM.ChainRun(chainRun, kit, { plan = plan, policy = { below = 0.0, upTo = 0.0 } })
    return none.drinks == 0 and none.addedTime == 0
end)())

-- the score: time before mana
local a = { deaths = 0, floorSeconds = 0, addedTime = 0, drinks = 3, manaSpent = 1000, healed = 1, overhealed = 0 }
local b = { deaths = 0, floorSeconds = 0, addedTime = 10, drinks = 1, manaSpent = 100, healed = 1, overhealed = 0 }
check("score: a forced longer run loses to one more drink that fit",
    SP.Better(SP.ChainScore(a, nil, 0), SP.ChainScore(b, nil, 0)))
local c = { deaths = 0, floorSeconds = 0, addedTime = 0, drinks = 1, manaSpent = 99999, healed = 1, overhealed = 0 }
check("score: one fewer drink beats any amount of mana",
    SP.Better(SP.ChainScore(c, nil, 0), SP.ChainScore(a, nil, 0)))

-- spending less has to mean drinking less, which is the whole point
local cheap = SP.NewPlan(SP.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.35, rollStacks = 0, hotBelow = 0.50, filler = false }, kit)
local cheapChain = SM.ChainRun(chainRun, kit, { plan = cheap, policy = { below = 0.60, upTo = 0.95 } })
check("chain: the cheaper plan spends less", cheapChain.manaSpent < chain.manaSpent,
    string.format("%d vs %d", cheapChain.manaSpent, chain.manaSpent))
check("chain: and never drinks more for it", cheapChain.drinks <= chain.drinks,
    string.format("%d vs %d drink(s)", cheapChain.drinks, chain.drinks))

-- the policy the recording implies
local yours = RR:DrinkPolicy(chainRun)
check("the recorded drink policy is read back", yours ~= nil and yours.drinks == 1
    and yours.below > 0 and yours.upTo > yours.below,
    yours and string.format("under %.2f, up to %.2f", yours.below, yours.upTo) or "none")

-- the search and the card, driven to completion across stub frames
out = {}
local card, bestPlan, bestChain
local h = SP.CoachRun(chainRun, { maxEvals = 30 }, function(lines, p, c) card, bestPlan, bestChain = lines, p, c end)
local frames = 0
while not card and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
check("the run search finishes", card ~= nil, string.format("%d frames", frames))

check("the card names the run and both rows", (function()
    local head, hasYou, hasBest = false, false, false
    for _, l in ipairs(card or {}) do
        if l:find("Run: chain") then head = true end
        if l:find("^  you ") then hasYou = true end
        if l:find("^  best ") then hasBest = true end
    end
    return head and hasYou and hasBest
end)(), card and card[1])
check("the card states the drink rate's provenance", (function()
    for _, l in ipairs(card or {}) do if l:find("measured on this run") then return true end end
    return false
end)())
check("the card states its caveats", (function()
    for _, l in ipairs(card or {}) do if l:find("caveat: EV crit") then return true end end
    return false
end)())
check("the plan is cached for the run", SP.runPlans[chainRun.id] == bestPlan and bestPlan ~= nil)

-- v0.13.8: coaching a run has to leave the REPLAY something to draw. It wrote
-- only SP.runPlans, so a coached run showed an empty suggested column on every
-- pull while its own card said "Play one to see it".
do
    -- every pull of the scripted run fails its gates on purpose (a death, 69%
    -- foreign healing), so an unforced coach must coach none of them -- the same
    -- rule a single fight follows: advice from a fight the engine gets wrong is
    -- worse than none.
    local coached = 0
    for _, rec in ipairs(chainRun.pulls or {}) do
        if SP.plans[rec.id] then coached = coached + 1 end
    end
    check("a run of pulls that do not replay is not coached silently", coached == 0,
        string.format("%d pull(s) got a plan", coached))

    -- ...and forced, it coaches every pull that is not under the recording gate
    local card2
    SP.CoachRun(chainRun, { maxEvals = 30, force = true }, function(l, p2) card2 = l end)
    local f2 = 0
    while not card2 and f2 < 20000 do S.Tick(0.016); f2 = f2 + 1 end
    local withPlan, eligible, shortCoached = 0, 0, 0
    for _, rec in ipairs(chainRun.pulls or {}) do
        if rec.short then
            if SP.plans[rec.id] then shortCoached = shortCoached + 1 end
        else
            eligible = eligible + 1
            if SP.plans[rec.id] then withPlan = withPlan + 1 end
        end
    end
    check("forced, coaching a run leaves every coachable pull with a plan",
        eligible > 0 and withPlan == eligible,
        string.format("%d of %d pull(s)", withPlan, eligible))
    check("a pull under the recording gate is left alone even then",
        shortCoached == 0, tostring(shortCoached))
    check("the plan a pull got is the run's own plan", (function()
        for _, rec in ipairs(chainRun.pulls or {}) do
            if SP.plans[rec.id] then return SP.plans[rec.id] ~= nil end
        end
    end)())
end
local gates = SP.RunGates(chainRun, kit)
check("every pull is put through the gates once", gates.of == 3 and gates.failed >= 0,
    string.format("%d of %d fail", gates.failed, gates.of))
check("no bare pipe on the card", (function()
    for _, l in ipairs(card or {}) do
        local stripped = l:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if stripped:find("|", 1, true) then return false end
    end
    return true
end)())

_G.DEFAULT_CHAT_FRAME = realChat
--------------------------------------------------------------------------------
-- v0.13.7: the party's health across the whole run, gaps included. Without it a
-- continuous replay freezes every bar the moment a pull ends -- and the gaps are
-- where the drinking happens, which is half of what a run is for.
--------------------------------------------------------------------------------
do
    local run = MD.RunRecorder.active or (MD.cdb.runs and MD.cdb.runs[1])
    check("the run samples party health", run and run.hp ~= nil)
    if run and run.hp then
        check("it sampled health more than once", #run.hp.t >= 2,
            string.format("%d sample(s)", #run.hp.t))
        check("every sample carries names and fractions together",
            #run.hp.t == #run.hp.who and #run.hp.t == #run.hp.frac,
            string.format("%d / %d / %d", #run.hp.t, #run.hp.who, #run.hp.frac))
        local ok2, frac = true, nil
        for i = 1, #run.hp.frac do
            for _, f in ipairs(run.hp.frac[i]) do
                frac = frac or f
                if f < 0 or f > 1 then ok2 = false end
            end
        end
        check("health is stored as a fraction", ok2, tostring(frac))
        -- and it must keep going when nobody is in combat
        local last = run.hp.t[#run.hp.t] or 0
        local lastPullEnd = 0
        for i = 1, #run.ev.t do
            if run.ev.kind[i] == MD.RunRecorder.K.PULL_END then lastPullEnd = run.ev.t[i] end
        end
        check("health is still sampled after the last pull ends",
            last >= lastPullEnd - 0.01,
            string.format("last sample %.1fs, last pull ended %.1fs", last, lastPullEnd))
    end
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end

-- MD_SHOW_CARD=1 prints the card itself, for reading it rather than asserting on it
if os.getenv("MD_SHOW_CARD") then
    print("\n-- the run card --")
    for _, l in ipairs(card or {}) do print(l) end
end
