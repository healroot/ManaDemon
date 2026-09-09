-- tools/run.sh tools/strategies.lua [--file <sv>] [--char <key>]
--
-- Every strategy in SP.STRATEGY_SET, over every recording in the file, through
-- the same engine and scored on the same lexicographic tuple. This is the table
-- the author asked for: pick one by looking at it, not by being told.
local here = arg[0]:match("^(.*)/[^/]+$")
local opts = {}
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--calibrate" then opts.calibrate = arg[i + 1]; i = i + 1
        elseif arg[i] == "--file" then opts.file = arg[i + 1]; i = i + 1
        elseif arg[i] == "--char" then opts.char = arg[i + 1]; i = i + 1 end
        i = i + 1
    end
end
local file = opts.file or ".logs/ManaDemon.lua"
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end end
if not exists(file) then
    local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"/*/SavedVariables/ManaDemon.lua 2>/dev/null')
    if p then for line in p:lines() do file = line; break end; p:close() end
end
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char or {}) do pre[k] = c.profile end

local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SM, SP = MD.SimModel, MD.SimPlanner

local function ApplyProfile(p)
    if not p then return end
    S.level = p.level or S.level
    if (p.intellect or 0) > 0 then S.stats[4] = p.intellect end
    if (p.spirit or 0) > 0 then S.stats[5] = p.spirit end
    S.manaMax = p.manaMax or S.manaMax; S.mana = S.manaMax
    local healing, crit = p.healing or 0, p.crit or 0
    _G.GetSpellBonusHealing = function() return healing end
    _G.GetSpellCritChance = function() return crit end
    local tal = p.talents or {}
    function MD:TalentRank(n) return tal[n] or 0 end
    MD.player.class = p.class or MD.player.class
    MD.player.isDruid = (p.class == "DRUID")
    MD.player.level = S.level
    if p.form == "tree" then function MD:InTreeForm() return true end
    else function MD:InTreeForm() return false end end
    if p.fromLog then
        local lvl = p.level or 70
        _G.IsSpellKnown = function(id)
            local sd = MD.SpellData.spells[id]
            return sd ~= nil and (sd.level or 0) <= lvl
        end
        _G.IsPlayerSpell = _G.IsSpellKnown
    end
    MD.SpellData:BuildKnown()
    MD.Regen:Refresh()
end

local allRecs = {}
-- --calibrate: scale the kit by what the LOG says each spell actually healed,
-- measured by tools/wclrules.py --observed. This exists because our level 70
-- heal values are known to be 1.4-1.8x low and the error is UNEVEN across
-- spells, so it biases a comparison between strategies that differ in spell
-- mix. It corrects the experiment, never the shipped model: nothing here is
-- written back, and Engine/Calibration.lua still never feeds RankMath.
local OBS = opts.calibrate and dofile(opts.calibrate) or nil
local function Calibrate(kit, who)
    local rows = OBS and OBS[who]
    if not rows then return kit, nil end
    local n, worst = 0, 1
    for _, form in pairs(kit) do
        if type(form) == "table" then
            for _, row in ipairs(rows) do
                local e = form[row.id]
                if e then
                    local model
                    if row.what == "tick" then model = (e.tick or 0) * (row.stacks or 1)
                    else model = (e.direct or 0) + (e.bloom or 0) end
                    if model and model > 0 then
                        local k = row.median / model
                        if row.what == "tick" then e.tick = (e.tick or 0) * k
                        else
                            e.direct = (e.direct or 0) * k
                            e.bloom = (e.bloom or 0) * k
                        end
                        n = n + 1
                        if k > worst then worst = k end
                    end
                end
            end
        end
    end
    return kit, (n > 0 and worst or nil)
end

local pool = {}
for key, c in pairs(realDB.char or {}) do
    for _, rec in ipairs(c.recordings or {}) do
        pool[#pool + 1] = { rec = rec, profile = pre[key], who = key }
    end
end
table.sort(pool, function(a, b) return (a.rec.id or 0) < (b.rec.id or 0) end)
for i, e in ipairs(pool) do allRecs[i] = e.rec end
if opts.char then
    local keep = {}
    for _, e in ipairs(pool) do if e.who == opts.char then keep[#keep + 1] = e end end
    pool = keep
end
print(string.format("%d recording(s)%s\n", #pool,
    OBS and "   [kit scaled to what the log says each spell healed]" or ""))

-- THE CONTROL, first row. The recorded casts through the same engine: what the
-- human actually did. Without it you cannot tell a planner's deaths from the
-- engine's -- on a held-out raid fight every strategy lost one person, and so
-- did the human's own casts, in a fight where nobody really died.
local cd, cf, cm, cn = 0, 0, 0, 0
for _, e in ipairs(pool) do
    ApplyProfile(e.profile)
    local kit = MD.RankMath:SpellKit({ live = true })
    kit = (Calibrate(kit, e.who))
    local sc = SM.ScenarioFromRecording(e.rec, kit)
    if sc then
        local r = SM:Run(sc, nil, { critMode = "ev" })
        cd = cd + (r.deaths and r.deaths.n or 0)
        cf = cf + (r.floorSeconds or 0)
        cm = cm + (r.manaSpent or 0)
        cn = cn + (e.rec.ownCasts or 0)
    end
end
print(string.format("%-26s %-46s %s", "strategy", "total over every recording", "causal?"))
print(string.format("%-26s deaths %2d  floor %6.1fs  mana %7.0f  %4d casts   %s",
    "the recorded casts", cd, cf, cm, cn, "<- the CONTROL"))
local rows = {}
for _, entry in ipairs(SP.STRATEGY_SET) do
    local d, f, m, casts = 0, 0, 0, 0
    local sees = false
    for _, e in ipairs(pool) do
        ApplyProfile(e.profile)
        local kit = MD.RankMath:SpellKit({ live = true })
        local worst
        kit, worst = Calibrate(kit, e.who)
        local sc = SM.ScenarioFromRecording(e.rec, kit)
        if sc then
            local plan = SP.MakeStrategy(entry, SP.MaxRankBinds(), kit,
                { scenario = sc, seed = e.rec.id or 1,
                  recs = allRecs, excludeID = e.rec.id, zone = e.rec.zone,
                  encounter = e.rec.encounter })
            if plan and plan.foresees then sees = true end
            local r = SP.RunPlan(sc, plan, { critMode = "ev",
                onCast = function() casts = casts + 1 end })
            local a = SP.Score(r, plan, 0)
            d, f, m = d + a[1], f + a[2], m + a[3]
        end
    end
    rows[#rows + 1] = { entry = entry, d = d, f = f, m = m, casts = casts, sees = sees }
    print(string.format("%-26s deaths %2d  floor %6.1fs  mana %7.0f  %4d casts   %s",
        entry.label, d, f, m, casts, sees and "NO - sees this fight" or "yes"))
end

table.sort(rows, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if math.abs(a.f - b.f) > 0.05 then return a.f < b.f end
    return a.m < b.m
end)
print("\nranked by the lexicographic tuple (deaths, then time in danger, then mana):")
for i, r in ipairs(rows) do
    print(string.format("  %d. %-26s %s", i, r.entry.label, r.entry.why))
end
