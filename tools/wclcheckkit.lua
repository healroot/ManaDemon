-- tools/run.sh tools/wclcheckkit.lua [recordsFile]
--
-- What our model says each spell heals, against what the log says it DID.
-- The kit is built from the profile the importer inferred (stats from the
-- combatant info, talents from the tree split); the observed medians come from
-- the raw report. A row that is off by more than the crit spread is a number in
-- Data/SpellData.lua to go and fix, not noise.
local here = arg[0]:match("^(.*)/[^/]+$")
-- tools/run.sh passes the checkout root as arg[1]; ours start at 2
local file = arg[2] or ".logs/wcl-records.lua"
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char) do pre[k] = c.profile end
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

-- observed medians, gross, non-crit: written next to the records by the converter
local OBS = dofile(arg[3] or ".logs/wcl-observed.lua")

for key, p in pairs(pre) do
    S.level = p.level; S.manaMax = p.manaMax; S.mana = p.manaMax
    if (p.intellect or 0) > 0 then S.stats[4] = p.intellect end
    if (p.spirit or 0) > 0 then S.stats[5] = p.spirit end
    local healing, crit = p.healing, p.crit
    _G.GetSpellBonusHealing = function() return healing end
    _G.GetSpellCritChance = function() return crit end
    local tal = p.talents or {}
    function MD:TalentRank(n) return tal[n] or 0 end
    MD.player.class = "DRUID"; MD.player.isDruid = true; MD.player.level = p.level
    function MD:InTreeForm() return false end
    _G.IsSpellKnown = function(id)
        local sd = MD.SpellData.spells[id]
        return sd ~= nil and (sd.level or 0) <= p.level
    end
    _G.IsPlayerSpell = _G.IsSpellKnown
    MD.SpellData:BuildKnown(); MD.Regen:Refresh()
    local kit = MD.RankMath:SpellKit({ live = true }).caster
    local o = OBS[key]
    if o then
        print(string.format("== %s   +%d healing, %.1f%% crit, talents %s",
            key, healing, crit, next(tal) and "deep resto (inferred)" or "none"))
        print(string.format("   %-22s %10s %10s %8s", "", "model", "log", "ratio"))
        for _, row in ipairs(o) do
            local e = kit[row.id]
            if e then
                local model
                if row.what == "tick" then
                    model = (e.tick or 0) * (row.stacks or 1)
                elseif row.what == "direct" then
                    model = (e.direct or 0) + (e.bloom or 0)
                end
                if model and model > 0 then
                    print(string.format("   %-22s %10.0f %10.0f %8.2f",
                        row.label, model, row.median, row.median / model))
                end
            end
        end
        print("")
    end
end
