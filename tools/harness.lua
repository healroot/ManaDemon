-- Loads the non-UI half of ManaDemon under tools/wowstub.lua and returns the
-- addon table. arg[1] is the repo root.
--
-- The file list is the .toc's order minus everything that draws. Keep it in
-- step with ManaDemon.toc when an engine file is added.
local here = arg[0]:match("^(.*)/[^/]+$")
dofile(here .. "/wowstub.lua")
local S = _G.STUB
S.root = arg[1] or "."

local MD = {}
S.Load({
    "Core.lua", "Data/SpellData.lua", "Engine/RegenModel.lua", "Engine/SpendTracker.lua",
    "Engine/Targets.lua", "Engine/Overheal.lua", "Engine/ManaCooldowns.lua", "Engine/TTO.lua",
    "Engine/RankMath.lua", "Engine/Calibration.lua", "Engine/PullBudget.lua",
    "Engine/SimModel.lua", "Engine/FightRecorder.lua", "Engine/RunRecorder.lua", "Engine/Intuition.lua", "Engine/Foresight.lua", "Engine/SimSolver.lua",
    "Engine/SimPlanner.lua", "Engine/RunTimeline.lua", "Engine/ReplayTrace.lua",
    "Data/SimFixture_BF1.lua", "Data/SimPresets.lua", "Data/AuraList.lua", "Data/Intuition_TBC.lua", "Data/DruidSpells.lua",
    -- UI/Summary.lua owns the combat-log handler and the fight lifecycle; it
    -- touches no widgets, so it loads here too.
    "UI/Summary.lua", "Verify.lua",
}, "ManaDemon", MD)

-- Everything the BF-1 druid knew: every rank at or below level 64.
local SD = MD.SpellData
for id, s in pairs(SD.spells) do
    if (s.level or 1) <= S.level then S.known[id] = true end
end
-- The client names every spell; the stub only knows the healing table, so the
-- non-healing ids the fixtures cast are named here. Without them MD:ClassifyCast
-- has nothing to fall back on and calls a Mark of the Wild "unknown", which is
-- a property of the harness rather than of the addon.
S.spellNames = setmetatable({
    [9885]  = "Mark of the Wild",
    [2782]  = "Remove Curse",
    [17116] = "Nature's Swiftness",
    [33891] = "Tree of Life",
    [26987] = "Moonfire", [25298] = "Starfire", [24977] = "Insect Swarm",
    [9853]  = "Entangling Roots", [17329] = "Nature's Grasp", [24858] = "Moonkin Form",
}, { __index = function(_, k)
    local s = SD.spells[k]
    return s and (s.family .. " r" .. tostring(s.rank)) or ("Spell" .. tostring(k))
end })

-- The log's talent build. Resto to the teeth, and NO Dreamstate -- the BF-1
-- log's regen lines carry no Dreamstate suffix, so the engine must not get it.
local TALENTS = {
    ["Gift of Nature"] = 5, ["Empowered Touch"] = 2, ["Empowered Rejuvenation"] = 5,
    ["Improved Rejuvenation"] = 3, ["Naturalist"] = 5, ["Moonglow"] = 3,
    ["Tranquil Spirit"] = 5, ["Improved Regrowth"] = 5, ["Nature's Grace"] = 1,
    ["Intensity"] = 3, ["Dreamstate"] = 0,
}
function MD:TalentRank(name) return TALENTS[name] or 0 end
MD.harnessTalents = TALENTS

S.Fire("ADDON_LOADED", "ManaDemon")
S.Fire("PLAYER_LOGIN")
S.Fire("PLAYER_ENTERING_WORLD")
return MD
