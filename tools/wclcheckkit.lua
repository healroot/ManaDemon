-- tools/run.sh tools/wclcheckkit.lua [recordsFile] [observedFile] [--fit]
--
-- What our model says each spell heals, against what the log says it DID.
-- The kit is built from the profile the importer inferred (stats from the
-- combatant info, talents from the tree split); the observed medians come from
-- the raw report. A row that is off by more than the crit spread is a number in
-- Data/SpellData.lua to go and fix, not noise.
--
-- v0.14.7, --fit: the other direction. Instead of trusting the profile's
-- +healing and grading the spell data, solve for the +healing that makes the
-- model reproduce the log, ONE ROW AT A TIME. Four independent families -- a
-- Rejuvenation tick, a Regrowth tick, a Lifebloom tick and its bloom -- land on
-- the same number to within a few percent on every parse in the corpus, which
-- is what says the heal values and the coefficients are right and the PROFILE
-- was wrong: the log's `spellPower` is spell damage, not +healing (see
-- SPELLPOWER_TO_HEALING in tools/wclconvert.py). Regrowth's DIRECT is the one
-- row that does not join them -- it asks for ~28% more +healing than the other
-- four on every parse that has it, i.e. the model's Regrowth direct is ~13%
-- low. That is a measurement, not yet a mechanism, so nothing was changed for
-- it; docs/SPEC-v0.14.md 4c carries it.
local here = arg[0]:match("^(.*)/[^/]+$")
-- tools/run.sh passes the checkout root as arg[1]; ours start at 2
local fit = false
local pos = {}
for i = 2, #arg do
    if arg[i] == "--fit" then fit = true else pos[#pos + 1] = arg[i] end
end
local file = pos[1] or ".logs/wcl-records.lua"
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char) do pre[k] = c.profile end
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

-- observed medians, gross, non-crit: written next to the records by the converter
local OBS = dofile(pos[2] or ".logs/wcl-observed.lua")

local ratios = {}
for key, p in pairs(pre) do
    local o = OBS[key]
    if o then
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

        -- one row's model value at a given +healing
        local function modelAt(H, row)
            _G.GetSpellBonusHealing = function() return H end
            local kit = MD.RankMath:SpellKit({ live = true }).caster
            -- v0.14.4: a heal can arrive under a different spell id from the
            -- one cast -- Lifebloom's bloom is 33778, its HoT 33763 -- and the
            -- kit is keyed by the cast. Without the alias the bloom row silently
            -- matched nothing and the bloom was never compared at all.
            local e = kit[MD.SpellData:Resolve(row.id)]
            if not e then return nil end
            if row.what == "tick" then return (e.tick or 0) * (row.stacks or 1) end
            return (e.direct or 0) + (e.bloom or 0)
        end

        print(string.format("== %s   +%d healing%s, %.1f%% crit, talents %s",
            key, healing,
            (p.spellPower or 0) > 0 and string.format(" (log spellPower %d)", p.spellPower) or "",
            crit, next(tal) and "deep resto (inferred)" or "none"))
        if not fit then
            print(string.format("   %-22s %10s %10s %8s", "", "model", "log", "ratio"))
            for _, row in ipairs(o) do
                local model = modelAt(healing, row)
                if model and model > 0 then
                    print(string.format("   %-22s %10.0f %10.0f %8.2f",
                        row.label, model, row.median, row.median / model))
                end
            end
        else
            -- the +healing each row alone asks for
            print(string.format("   %-22s %10s %10s %8s", "", "model", "log", "implies"))
            local implied = {}
            for _, row in ipairs(o) do
                local m0 = modelAt(healing, row)
                if m0 and m0 > 0 then
                    local best, bestH
                    for H = 0, 6000, 5 do
                        local m = modelAt(H, row)
                        local l = math.log(row.median / m)
                        if not best or l * l < best then best, bestH = l * l, H end
                    end
                    implied[#implied + 1] = bestH
                    print(string.format("   %-22s %10.0f %10.0f %8d",
                        row.label, m0, row.median, bestH))
                end
            end
            table.sort(implied)
            if #implied > 0 then
                local med = implied[math.ceil(#implied / 2)]
                print(string.format("   %-22s %10s %10s %8d   x%.2f of the log's spellPower",
                    "median of the rows", "", "", med,
                    (p.spellPower or 0) > 0 and med / p.spellPower or 0))
                if (p.spellPower or 0) > 0 then ratios[#ratios + 1] = med / p.spellPower end
            end
        end
        print("")
    end
end
if fit and #ratios > 0 then
    table.sort(ratios)
    print(string.format("%d parses; implied +healing / the log's spellPower: min %.2f, median %.2f, max %.2f",
        #ratios, ratios[1], ratios[math.ceil(#ratios / 2)], ratios[#ratios]))
end
