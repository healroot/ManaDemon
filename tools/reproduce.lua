-- tools/run.sh tools/reproduce.lua <records.lua> [observed.lua]
--
-- THE CONTROL FOR THE HEALTH GATE. Replays a recording's own casts through the
-- engine and asks one question: how much of the healing the log recorded does
-- the engine actually generate from the same script?
--
-- The health-curve gate says a target "was not reproduced" without saying why,
-- and a plan's deaths cannot be told from the engine's until this number is
-- known. On a Prince Malchezaar parse it came back at 44% -- with the per-tick
-- magnitudes calibrated to the log exactly -- which is how the phantom death in
-- docs/SPEC-v0.13.md §13 was tracked to HoT scheduling rather than spell data.
--
-- With an `observed.lua` (tools/wclrules.py --observed) the kit is first scaled
-- so each spell heals what the log says it healed, which removes spell values
-- from the question entirely. What is left is the engine.
local here = arg[0]:match("^(.*)/[^/]+$")
local file, obsFile = arg[2], arg[3]
if not file then print("usage: reproduce.lua <records.lua> [observed.lua]"); os.exit(2) end
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char or {}) do pre[k] = c.profile end

local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SM, SP = MD.SimModel, MD.SimPlanner
local OBS = obsFile and dofile(obsFile) or nil
local K = SM.K

local function ApplyProfile(p)
    if not p then return end
    S.level = p.level or S.level
    if (p.intellect or 0) > 0 then S.stats[4] = p.intellect end
    if (p.spirit or 0) > 0 then S.stats[5] = p.spirit end
    S.manaMax = p.manaMax or S.manaMax; S.mana = S.manaMax
    local h, c = p.healing or 0, p.crit or 0
    _G.GetSpellBonusHealing = function() return h end
    _G.GetSpellCritChance = function() return c end
    local tal = p.talents or {}
    function MD:TalentRank(n) return tal[n] or 0 end
    MD.player.class = p.class or "DRUID"
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
    MD.SpellData:BuildKnown(); MD.Regen:Refresh()
end

local function Calibrate(kit, who)
    local rows = OBS and OBS[who]
    if not rows then return kit end
    for _, form in pairs(kit) do
        if type(form) == "table" then
            for _, row in ipairs(rows) do
                -- v0.14.4: Lifebloom's bloom arrives as 33778, the kit is keyed
                -- by the HoT's 33763; without the alias the bloom was left
                -- uncalibrated while every tick around it was scaled
                local e = form[MD.SpellData:Resolve(row.id)]
                if e then
                    local m = (row.what == "tick") and (e.tick or 0) * (row.stacks or 1)
                              or ((e.direct or 0) + (e.bloom or 0))
                    if m > 0 then
                        local k = row.median / m
                        if row.what == "tick" then e.tick = (e.tick or 0) * k
                        else e.direct = (e.direct or 0) * k; e.bloom = (e.bloom or 0) * k end
                    end
                end
            end
        end
    end
    return kit
end

print(string.format("%-30s %9s %9s %7s  %s",
    "recording", "log", "engine", "share", "deaths (log -> engine)"))
for key, c in pairs(realDB.char or {}) do
    for _, rec in ipairs(c.recordings or {}) do
        ApplyProfile(pre[key])
        local kit = Calibrate(MD.RankMath:SpellKit({ live = true }), key)
        local sc = SM.ScenarioFromRecording(rec, kit)
        if sc then
            local fired = 0
            local r = SM:Run(sc, nil, { critMode = "ev",
                onCast = function() fired = fired + 1 end })
            local logOwn = 0
            for i = 1, (rec.n or 0) do
                local k2 = rec.ev.kind[i]
                if k2 == K.OWNHEAL or k2 == K.OWNTICK then logOwn = logOwn + (rec.ev.amt[i] or 0) end
            end
            local eng = (r.healed or 0) + (r.overhealed or 0)
            -- v0.14.7: a stream older than v2 wrote every own heal down as
            -- heal + overheal (the truncated multi-return in
            -- Engine/FightRecorder.lua), so its `log` column is inflated by up
            -- to 2x and the share below is not a statement about the engine.
            -- Imported Warcraft Logs recordings are written by the converter
            -- and carry v2.
            local stale = (rec.v or 1) < 2
            print(string.format("%-30s %9d %9d %6.0f%%  %d -> %d%s",
                string.sub(tostring(rec.zone), 1, 30), logOwn, eng,
                logOwn > 0 and 100 * eng / logOwn or 0,
                #(rec.deaths or {}), r.deaths and r.deaths.n or 0,
                stale and "   [v1 stream: log column is heal + overheal]" or ""))
            -- per family, which is what says WHERE the healing went missing
            local SDm = MD.SpellData
            local logFam = {}
            for i = 1, (rec.n or 0) do
                local k2 = rec.ev.kind[i]
                if k2 == K.OWNHEAL or k2 == K.OWNTICK then
                    local id = SDm:Resolve((rec.ev.x[i] or 0) % 100000)   -- crit flag off, bloom aliased
                    local sd = SDm.spells[id]
                    local fam = sd and sd.family or "?"
                    logFam[fam] = (logFam[fam] or 0) + (rec.ev.amt[i] or 0)
                end
            end
            -- tick COUNT against the log's heal-event count: it says whether
            -- the engine heals too little per tick or too seldom
            local logTicks, logDirect = 0, 0
            for i = 1, (rec.n or 0) do
                local k2 = rec.ev.kind[i]
                if k2 == K.OWNTICK then logTicks = logTicks + 1
                elseif k2 == K.OWNHEAL then logDirect = logDirect + 1 end
            end
            print(string.format("    %-24s %9d %9d %6.0f%%", "casts executed",
                rec.ownCasts or 0, fired,
                (rec.ownCasts or 0) > 0 and 100 * fired / rec.ownCasts or 0))
            print(string.format("    %-24s %9s %9s", "heal events",
                string.format("%d+%d", logTicks, logDirect),
                string.format("%d+%d", r.ticks or 0, r.blooms or 0)))
            local fams = {}
            for fam in pairs(logFam) do fams[#fams + 1] = fam end
            for fam in pairs(r.healByFamily or {}) do
                if not logFam[fam] then fams[#fams + 1] = fam end
            end
            table.sort(fams)
            for _, fam in ipairs(fams) do
                local lg = logFam[fam] or 0
                local en = (r.healByFamily[fam] or 0) + ((r.ohByFamily or {})[fam] or 0)
                print(string.format("    %-24s %9d %9d %6s", fam, lg, en,
                    lg > 0 and string.format("%.0f%%", 100 * en / lg) or "-"))
            end
        end
    end
end
