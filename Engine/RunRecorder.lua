-- A RUN: one dungeon, start to finish, instead of one pull (docs/SPEC-v0.9.md
-- §3). A boss fight is a pull; five-man content is thirty pulls and the gaps
-- between them, and the gaps are where the mana goes -- the drinking, the
-- corpse runs, the mana you were carrying when the next pack came. None of
-- that exists in a single fight's stream, so none of it could be coached on.
--
-- What this file owns: the container. Every pull recorded while a run is
-- active is handed here by Engine/FightRecorder.lua INSTEAD of the ring of 8
-- (a run is pinnable as a whole), including the pulls under the recording gate
-- -- they are what a dungeon is made of, and they are marked `short` so the
-- Review tab can grey them out rather than coach from them. Between pulls this
-- file records mana every 2s, the drink buff with the mana either side of it
-- (so the run measures its OWN drink rate; there is no preset), deaths and the
-- time spent dead, zone changes, Innervates and potions.
--
-- Runs are MANUAL: /md run start, /md run stop. Auto-start on entering an
-- instance is reserved -- Start() takes a reason and db.runAutoStart ships
-- false, so it is one `if` away when the author asks for it.
--
-- Nothing here is modelled. v0.9.3 chains the pulls through the engine and
-- scores the run; this file only writes down what happened.
local _, MD = ...

local RR = {}
MD.RunRecorder = RR

-- Recorded event kinds. Do not renumber: they are in the SavedVariables.
RR.K = { PULL = 1, PULL_END = 2, DRINK = 3, DRINK_END = 4, DEAD = 5, ALIVE = 6,
         ZONE = 7, INNERVATE = 8, POTION = 9 }
RR.KIND_NAMES = { "pull", "pull end", "drink", "drink end", "died", "alive",
                  "zone", "innervate", "potion" }

-- The whole run's budget, its pulls' events included. A 30-pull Blood Furnace
-- at BF-1's event density is around 9 000, so this is roughly a three-dungeon
-- ceiling on one run and it exists to bound the SavedVariables, not to shape
-- what is kept.
RR.MAX_RUN_EV = 30000
-- The run's OWN events (pulls, drinks, deaths, zones) have their own, separate
-- allowance. They are the gaps -- the half of a dungeon a fight stream cannot
-- hold -- and a few hundred of them cost nothing next to one pull's stream, so
-- they must not be squeezed out by the pulls filling the budget above. A
-- 90-minute run with thirty pulls and ten drinks uses about a hundred.
RR.MAX_GAP_EV = 4000
local MAX_RUNS, MAX_PINNED_RUNS = 2, 1
local MANA_SAMPLE = 2.0     -- seconds between mana samples, in and out of combat
local ZONE_GRACE = 30       -- seconds outside the instance before a run auto-stops
local INNERVATE = 29166
local DRINK_NAMES = { "Drink", "Refreshment", "Food & Drink" }

RR.active = nil

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local function Now(run) return (GetTime() or 0) - (run.t0 or 0) end

local function Median(t)
    if #t == 0 then return nil end
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    table.sort(c)
    local n = #c
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

local function IsDrinking()
    for _, name in ipairs(DRINK_NAMES) do
        if MD:HasBuff(name) then return true end
    end
    return false
end

local function Mana() return UnitPower("player", 0) or 0 end

-- Every event this run has cost, its pulls' streams included. The pulls are
-- the expensive part by two orders of magnitude, which is why the budget counts
-- them rather than only the gaps.
function RR:Events(run)
    run = run or RR.active
    if not run then return 0 end
    local n = #(run.ev.t or {})
    for _, p in ipairs(run.pulls) do n = n + (p.n or 0) end
    return n
end

-- True once the run has spent its budget: further pulls are still SUMMARISED
-- (the fight history is untouched) but no longer recorded.
function RR:FullUp()
    local run = RR.active
    if not run then return false end
    return RR:Events(run) >= RR.MAX_RUN_EV
end

local function Push(run, kind, a, b)
    local ev = run.ev
    local n = #ev.t + 1
    if n > RR.MAX_GAP_EV then
        if not run.truncated then
            run.truncated = true
            MD:Debug("sim", "run: the gap timeline is full at %d events", RR.MAX_GAP_EV)
        end
        return
    end
    ev.t[n], ev.kind[n], ev.a[n], ev.b[n] = Now(run), kind, a or 0, b or 0
end

local function ZoneIndex(run, name)
    name = name or "?"
    for i, z in ipairs(run.zones) do if z == name then return i end end
    run.zones[#run.zones + 1] = name
    return #run.zones
end

local function InInstance()
    if not IsInInstance then return false end
    local ok, inside = pcall(IsInInstance)
    return ok and inside and true or false
end

--------------------------------------------------------------------------------
-- Retention: two runs, one of which may be pinned. A run is big (its pulls
-- carry their own streams), so the ceiling is low and the author chooses which
-- one survives rather than the addon guessing at "interesting" the way the ring
-- of 8 does.
--------------------------------------------------------------------------------
local function Runs()
    if not MD.cdb then return {} end
    MD.cdb.runs = MD.cdb.runs or {}
    return MD.cdb.runs
end

-- nil when there is room, else the reason there is not.
function RR:NoRoom()
    local list = Runs()
    if #list < MAX_RUNS then return nil end
    local pinned = 0
    for _, r in ipairs(list) do if r.pinned then pinned = pinned + 1 end end
    if pinned >= math.min(#list, MAX_RUNS) then
        return string.format("both stored runs are pinned - unpin one on the Review tab first (%d kept)", MAX_RUNS)
    end
    return nil
end

local function Store(run)
    local list = Runs()
    if #list < MAX_RUNS then
        list[#list + 1] = run
        return #list, nil
    end
    local victim
    for i, r in ipairs(list) do
        if not r.pinned and (not victim or (r.id or 0) < (list[victim].id or 0)) then victim = i end
    end
    if not victim then return nil, nil end
    local dropped = list[victim]
    list[victim] = run
    return victim, dropped
end

function RR:List()
    local list = {}
    for _, r in ipairs(Runs()) do list[#list + 1] = r end
    table.sort(list, function(a, b) return (a.id or 0) > (b.id or 0) end)
    return list
end

function RR:Get(n)
    return RR:List()[n or 1]
end

-- A pull inside a run, addressed the way the commands do: "2:7".
function RR:GetPull(runIdx, k)
    local run = RR:Get(runIdx)
    if not run then return nil, nil end
    return run.pulls[k], run
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
-- reason: "manual" today; "auto" is reserved for the instance event (see the
-- file header) and changes nothing except what the stop line says.
function RR:Start(reason, name)
    if RR.active then
        return nil, string.format("a run is already recording: %s (%s)", RR.active.name,
            RR:Clock(Now(RR.active)))
    end
    if not MD.cdb then return nil, "no character database yet" end
    if MD.db and MD.db.recordRuns == false then
        return nil, "run recording is off (db.recordRuns)"
    end
    local full = RR:NoRoom()
    if full then return nil, full end

    local zone = GetRealZoneText and GetRealZoneText() or "?"
    local t0 = GetTime() or 0
    local run = {
        v = 1, id = time(), name = name and name ~= "" and name or (zone .. " " .. date("%H:%M")),
        zone = zone, t0 = t0, dur = 0, pool = UnitPowerMax("player", 0) or 0,
        reason = reason or "manual",
        pulls = {},
        mana = { t = {}, v = {} },
        -- v0.13.7: the party's health across the WHOLE run, gaps included. The
        -- run existed to be watched end to end and the gaps are half of it --
        -- people finish a pull at 40%, drink, and walk in full. Without this the
        -- bars freeze at whatever the last pull left them on. Sampled on the same
        -- 2s beat as mana and keyed by name, because the roster is per pull and a
        -- run outlives it. Costs ~5 numbers a sample: a 45 minute run is ~1350
        -- samples, well inside MAX_GAP_EV's intent.
        hp = { t = {}, who = {}, frac = {} },
        ev = { t = {}, kind = {}, a = {}, b = {} },
        zones = { zone },
        truncated = false, pinned = false,
    }
    RR.active = run
    RR.sampleAcc = MANA_SAMPLE   -- sample immediately
    RR.drinkFrom = nil
    RR.deadFrom = nil
    RR.leftAt = nil
    RR.drinkRates = {}
    run.deadTime, run.drinkTime = 0, 0
    -- the pull in progress, if any, joins the run
    if MD.FightRecorder and MD.FightRecorder.active then
        MD:Debug("sim", "run: a pull is already in progress and joins the run")
    end
    MD:Debug("sim", "run started: %s (%s), pool %d", run.name, run.reason, run.pool)
    return run, nil
end

-- The party's health, as fractions, on the run's own clock. Names rather than
-- roster indices: a run spans many pulls and each pull builds its own roster.
function RR:SampleHealth(run, t)
    local hp = run.hp
    if not hp then return end
    if #hp.t >= RR.MAX_GAP_EV then return end
    local names, fracs = {}, {}
    local T = MD.Targets
    for _, e in pairs((T and T.byGUID) or {}) do
        local unit = e.unit
        if unit and not e.isPet and UnitExists and UnitExists(unit) then
            local cur, max = UnitHealth(unit) or 0, UnitHealthMax(unit) or 0
            if max > 0 then
                names[#names + 1] = e.name
                -- two decimal places is a health bar; more is noise
                fracs[#fracs + 1] = math.floor((cur / max) * 100 + 0.5) / 100
            end
        end
    end
    if #names == 0 then return end
    local n = #hp.t + 1
    hp.t[n], hp.who[n], hp.frac[n] = t, names, fracs
end

function RR:Clock(sec)
    sec = math.floor((sec or 0) + 0.5)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Everything the run line and the run card read. Computed once, at stop, from
-- what was recorded -- no estimate anywhere: a drink rate with no drink in the
-- run is nil, and the reader says so rather than substituting a number.
local function ComputeStats(run)
    local K = RR.K
    local s = { pulls = #run.pulls, recorded = 0, long = 0, combat = 0, spent = 0,
                drinks = 0, drinkTime = run.drinkTime or 0, deaths = 0,
                deadTime = run.deadTime or 0, innervates = 0, potions = 0,
                manaAtPull = {} }
    s.wall = run.dur or 0
    for _, p in ipairs(run.pulls) do
        if (p.n or 0) > 0 then s.recorded = s.recorded + 1 end
        if (p.dur or 0) >= 60 then s.long = s.long + 1 end
        s.combat = s.combat + (p.dur or 0)
        s.spent = s.spent + (p.spent or 0)
    end
    s.summarised = run.summarised or 0        -- pulls that happened but carry no stream
    s.pulls = s.pulls + s.summarised
    local ev = run.ev
    for i = 1, #ev.t do
        local k = ev.kind[i]
        if k == K.PULL_END and (ev.a[i] or 0) == 0 then
            -- a pull with no stream: its length is still time in combat
            s.combat = s.combat + (ev.b[i] or 0)
        elseif k == K.PULL then s.manaAtPull[#s.manaAtPull + 1] = ev.b[i]
        elseif k == K.DRINK then s.drinks = s.drinks + 1
        elseif k == K.DEAD then s.deaths = s.deaths + 1
        elseif k == K.INNERVATE then s.innervates = s.innervates + 1
        elseif k == K.POTION then s.potions = s.potions + 1 end
    end
    s.combatPct = s.wall > 0 and (s.combat / s.wall) or 0
    s.manaAtPullP50 = Median(s.manaAtPull)
    s.drinkRate = Median(RR.drinkRates or {})
    return s
end

-- The drink policy that reproduces the drinking that ACTUALLY happened -- the
-- "you" row of the run card, and the thing a suggested policy is compared with.
-- `below` is the highest mana fraction at which the healer sat down (they were
-- willing to drink at least that high), `upTo` the median fraction they got up
-- at. nil when the run has no drink in it: there is nothing to read.
function RR:DrinkPolicy(run)
    local starts, ends = {}, {}
    local ev = run and run.ev or {}
    for i = 1, #(ev.t or {}) do
        if ev.kind[i] == RR.K.DRINK then starts[#starts + 1] = ev.b[i] or 0
        elseif ev.kind[i] == RR.K.DRINK_END then ends[#ends + 1] = ev.b[i] or 0 end
    end
    if #starts == 0 then return nil end
    local below = starts[1]
    for _, v in ipairs(starts) do if v > below then below = v end end
    return { below = below, upTo = Median(ends) or below, drinks = #starts }
end

function RR:Line(run)
    local s = run.stats or {}
    local parts = {
        string.format("run %s: %d pull(s), %s, combat %d%%", run.name, s.pulls or 0,
            RR:Clock(s.wall or 0), (s.combatPct or 0) * 100 + 0.5),
    }
    if (s.drinks or 0) > 0 then
        parts[#parts + 1] = string.format("drank %dx (%s%s)", s.drinks, RR:Clock(s.drinkTime or 0),
            s.drinkRate and string.format(", %d mana/s", s.drinkRate + 0.5) or "")
    else
        parts[#parts + 1] = "no drink"
    end
    if s.manaAtPullP50 then
        parts[#parts + 1] = string.format("mana at pull p50 %d%%", s.manaAtPullP50 * 100 + 0.5)
    end
    if (s.deaths or 0) > 0 then
        parts[#parts + 1] = string.format("%d death(s) (%s dead)", s.deaths, RR:Clock(s.deadTime or 0))
    end
    if (s.innervates or 0) > 0 then parts[#parts + 1] = string.format("%d innervate(s)", s.innervates) end
    if (s.potions or 0) > 0 then parts[#parts + 1] = string.format("%d potion(s)", s.potions) end
    parts[#parts + 1] = string.format("%d mana spent", s.spent or 0)
    if run.truncated then parts[#parts + 1] = "STREAM FULL - later pulls summarised only" end
    return table.concat(parts, ", ")
end

function RR:Stop(reason)
    local run = RR.active
    if not run then return nil, "no run is recording" end
    RR.active = nil
    -- a drink still up at the stop closes here, at the mana it has now
    if RR.drinkFrom then
        local t, m, d = Now(run), Mana(), RR.drinkFrom
        run.drinkTime = (run.drinkTime or 0) + (t - d.t)
        Push(run, RR.K.DRINK_END, m, run.pool > 0 and m / run.pool or 0)
        if t - d.t > 1 and m > d.mana then
            RR.drinkRates[#RR.drinkRates + 1] = (m - d.mana) / (t - d.t)
        end
        RR.drinkFrom = nil
    end
    if RR.deadFrom then
        run.deadTime = (run.deadTime or 0) + (Now(run) - RR.deadFrom)
        RR.deadFrom = nil
    end
    run.dur = Now(run)
    run.stopReason = reason or "manual"
    run.stats = ComputeStats(run)
    run.t0 = nil   -- an absolute GetTime() means nothing in a later session

    local slot, dropped = Store(run)
    if not slot then
        MD:Print("run " .. run.name .. ": " .. RR:Line(run) ..
            " - |cffff4444not stored|r: both kept runs are pinned.")
        return run, "not stored"
    end
    MD:Print(RR:Line(run) .. (run.stopReason ~= "manual" and (" [" .. run.stopReason .. "]") or "") ..
        (dropped and string.format(" - replaced %s", dropped.name or "an older run") or ""))
    MD:Debug("sim", "run stored in slot %d: %d event(s) over %d pull(s)", slot, RR:Events(run), #run.pulls)
    MD:Fire("RUN_STORED", run)
    return run, nil
end

function RR:Status()
    local run = RR.active
    if not run then
        local list = RR:List()
        local out = { "run: nothing recording. " .. (#list > 0 and (#list .. " stored:") or "no runs stored.") }
        for i, r in ipairs(list) do
            out[#out + 1] = string.format("  %d. %s - %s%s", i, r.name, RR:Line(r), r.pinned and " [pinned]" or "")
        end
        return out
    end
    local s = ComputeStats(run)
    return {
        string.format("run %s: %s elapsed, %d pull(s) (%d recorded), %d drink(s), %d death(s), %d/%d events%s",
            run.name, RR:Clock(Now(run)), #run.pulls, s.recorded, s.drinks, s.deaths,
            RR:Events(run), RR.MAX_RUN_EV, run.truncated and " - FULL" or ""),
    }
end

--------------------------------------------------------------------------------
-- The pulls. Engine/FightRecorder.lua calls this instead of storing into the
-- ring of 8; `short` marks a stream under the recording gate (20s / 5 casts),
-- which is kept because a dungeon is mostly those, and greyed on the Review tab
-- because coaching from one would be advice about nothing.
--------------------------------------------------------------------------------
function RR:AddPull(stream, short)
    local run = RR.active
    if not run or not stream then return nil end
    stream.short = short or nil
    -- run-relative start. A pull that was already in progress when the run
    -- started has no PULL event of its own, so its start is worked back from
    -- its own length rather than pretended to be now.
    stream.runT0 = RR.pullStart or math.max(0, Now(run) - (stream.dur or 0))
    RR.pullStart = nil
    run.pulls[#run.pulls + 1] = stream
    local k = #run.pulls
    Push(run, RR.K.PULL_END, k, stream.dur or 0)
    MD:Debug("sim", "run: pull %d kept (%.0fs, %d event(s)%s)", k, stream.dur or 0, stream.n or 0,
        short and ", under the gate" or "")
    return k
end

-- A pull that happened but was not recorded (the run's budget is spent, or
-- fight recording is off). It stays in the run's own timeline -- the gap model
-- needs to know the group was in combat then -- with a = 0 saying "no stream".
function RR:PullSkipped(duration)
    local run = RR.active
    if not run then return end
    Push(run, RR.K.PULL_END, 0, duration or 0)
    run.summarised = (run.summarised or 0) + 1
end

-- Called by the recorder when a pull STARTS, so the mana the healer opened with
-- is on the record even if the pull itself is not kept.
function RR:PullStarted()
    local run = RR.active
    if not run then return end
    local m = Mana()
    RR.pullStart = Now(run)
    Push(run, RR.K.PULL, m, run.pool > 0 and m / run.pool or 0)
end

--------------------------------------------------------------------------------
-- The gaps
--------------------------------------------------------------------------------
MD:OnTick(function(dt)
    local run = RR.active
    if not run then return end
    local t = Now(run)

    -- mana, the whole run, in and out of combat
    RR.sampleAcc = (RR.sampleAcc or 0) + dt
    if RR.sampleAcc >= MANA_SAMPLE then
        RR.sampleAcc = 0
        local mn = run.mana
        local n = #mn.t + 1
        mn.t[n], mn.v[n] = t, Mana()
        RR:SampleHealth(run, t)
        -- a potion leaves the bags; the count is the only signal that does not
        -- need a spell id nobody has verified on this client
        if MD.ManaCooldowns and GetItemCount then
            for _, p in ipairs(MD.ManaCooldowns.potions or {}) do
                local have = GetItemCount(p.id) or 0
                RR.potionCount = RR.potionCount or {}
                local was = RR.potionCount[p.id]
                if was and have < was then Push(run, RR.K.POTION, p.id, Mana()) end
                RR.potionCount[p.id] = have
            end
        end
    end

    -- the drink, with the mana either side of it: this run's own rate
    local drinking = IsDrinking()
    if drinking then
        if not RR.drinkFrom then
            local m = Mana()
            RR.drinkFrom = { t = t, mana = m }
            Push(run, RR.K.DRINK, m, run.pool > 0 and m / run.pool or 0)
        else
            -- the last poll that was still inside the drink; the rate is
            -- measured across the drink's INTERIOR, because the buff went up
            -- and came down somewhere between two polls and half a second of
            -- guessing at either end is 2% of a 25s drink
            RR.drinkFrom.lastT, RR.drinkFrom.lastMana = t, Mana()
        end
    elseif RR.drinkFrom then
        local m, span = Mana(), t - RR.drinkFrom.t
        run.drinkTime = (run.drinkTime or 0) + span
        Push(run, RR.K.DRINK_END, m, run.pool > 0 and m / run.pool or 0)
        local d = RR.drinkFrom
        if d.lastT and d.lastT - d.t > 1 and d.lastMana > d.mana then
            RR.drinkRates[#RR.drinkRates + 1] = (d.lastMana - d.mana) / (d.lastT - d.t)
        end
        RR.drinkFrom = nil
    end

    -- out of the instance long enough that this is not a corpse run
    if RR.leftAt and t - RR.leftAt > ZONE_GRACE then
        RR:Stop("left the instance")
        return
    end
    local ceiling = (MD.db and MD.db.runMaxMinutes or 90) * 60
    if ceiling > 0 and t >= ceiling then
        RR:Stop(string.format("%d minute ceiling", ceiling / 60))
    end
end)

MD:On("PLAYER_DEAD", function()
    local run = RR.active
    if not run or RR.deadFrom then return end
    RR.deadFrom = Now(run)
    Push(run, RR.K.DEAD, Mana(), 0)
end)

local function Alive()
    local run = RR.active
    if not run or not RR.deadFrom then return end
    local t = Now(run)
    run.deadTime = (run.deadTime or 0) + (t - RR.deadFrom)
    RR.deadFrom = nil
    Push(run, RR.K.ALIVE, Mana(), 0)
end
MD:On("PLAYER_ALIVE", Alive)
MD:On("PLAYER_UNGHOST", Alive)

MD:On("ZONE_CHANGED_NEW_AREA", function()
    local run = RR.active
    if not run then return end
    local zone = GetRealZoneText and GetRealZoneText() or "?"
    Push(run, RR.K.ZONE, ZoneIndex(run, zone), 0)
    if InInstance() then
        RR.leftAt = nil
    elseif not RR.leftAt then
        RR.leftAt = Now(run)
        MD:Debug("sim", "run: left the instance (%s) - %ds of grace before it stops", zone, ZONE_GRACE)
    end
end)

MD:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" or spellID ~= INNERVATE then return end
    local run = RR.active
    if not run then return end
    Push(run, RR.K.INNERVATE, Mana(), 0)
end)

MD:On("PLAYER_LOGOUT", function()
    if RR.active then RR:Stop("logout") end
end)

--------------------------------------------------------------------------------
-- Slash command (/md run start [name] | stop | status)
--------------------------------------------------------------------------------
function MD:RunCommand(arg)
    arg = arg or ""
    local sub, rest = arg:match("^(%S*)%s*(.*)$")
    sub = sub:lower()
    if sub == "start" then
        local run, why = RR:Start("manual", rest)
        if not run then MD:Print("run: " .. why) return end
        MD:Print(string.format("run |cff33ff66%s|r recording - every pull and the gaps between them. " ..
            "|cffffff00/md run stop|r when you leave.", run.name))
    elseif sub == "stop" then
        local _, why = RR:Stop("manual")
        if why == "no run is recording" then MD:Print("run: nothing is recording.") end
    elseif sub == "status" or sub == "" then
        for _, line in ipairs(RR:Status()) do MD:Print(line) end
    else
        MD:Print("usage: /md run start [name] | stop | status")
    end
end
