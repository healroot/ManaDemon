-- The scripted pull shared by tools/reccheck.lua and tools/replaycheck.lua:
-- a party of five, damage on the tank and the mage, the player's own casts
-- (one refresh with ticks pending, one on a full-health target), a foreign
-- heal, a death, and 6s of pre-pull Lifebloom. It runs through the REAL
-- combat-log handler in UI/Summary.lua and Engine/FightRecorder.lua.
--
-- Returns the spell ids it used, so a harness can assert against them.
return function(MD, S)
local SD = MD.SpellData
S.AddUnit("party1", { guid = "Tank-1",  name = "Destroyka", class = "WARRIOR", role = "TANK",   hp = 8000, hpMax = 8000 })
S.AddUnit("party2", { guid = "Mage-1",  name = "Alkandari", class = "MAGE",    role = "DAMAGER", hp = 4000, hpMax = 4000 })
S.AddUnit("party3", { guid = "Lock-1",  name = "Abufaisall",class = "WARLOCK", role = "DAMAGER", hp = 4200, hpMax = 4200 })
S.AddUnit("party4", { guid = "Pala-1",  name = "Trecoda",   class = "PALADIN", role = "DAMAGER", hp = 5200, hpMax = 5200 })
S.Fire("GROUP_ROSTER_UPDATE")

MD.db.debug.enabled = true
function MD:DebugLog(cat, text) if cat == "sim" or cat == "combat" then print("[" .. cat .. "] " .. text) end end

local PLAYER = "Player-1"
MD.db.healAmountGross = true
local rejuv, regrowth, lifebloom = SD.maxRank.Rejuvenation, SD.maxRank.Regrowth, SD.maxRank.Lifebloom
local MOTW = 9885

-- One combat-log event. The prefix must be spliced into the SAME call as the
-- payload: a function call in a non-final argument position is truncated to one
-- value, which is exactly the Lua trap CLAUDE.md names -- and it silently ate
-- every event the first time this file was written.
local function ev(sub, src, dst, dstName, ...)
    S.Combat(0, sub, false, src, "src", 0, 0, dst, dstName, 0, 0, ...)
end
local function castStart(spellID, dst, dstName)
    ev("SPELL_CAST_START", PLAYER, dst, dstName, spellID, "S", 8)
end
local function cast(spellID, dst, dstName)
    ev("SPELL_CAST_SUCCESS", PLAYER, dst, dstName, spellID, "S", 8)
    -- the client fires both; Engine/SpendTracker.lua listens to this one
    S.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, spellID)
end
-- This client reports heal `amount` GROSS (overheal included), so a full
-- overheal is amount == overheal.
local function ownTick(spellID, dst, dstName, gross, over)
    ev("SPELL_PERIODIC_HEAL", PLAYER, dst, dstName, spellID, "S", 8, gross, over, 0, false)
end
local function swing(dst, dstName, amount)
    ev("SWING_DAMAGE", "Mob-1", dst, dstName, amount, 0, 1, 0, 0, 0, false)
end
local function foreignHeal(dst, dstName, amount)
    ev("SPELL_HEAL", "Pala-1", dst, dstName, 635, "Holy Light", 2, amount, 0, 0, false)
end
-- auras: spellId, spellName, school, auraType[, amount]
local function aura(sub, src, dst, dstName, spellID, name, kind, amount)
    ev(sub, src, dst, dstName, spellID, name, 1, kind, amount)
end

-- 6s of pre-pull: a Lifebloom on a full-health tank whose ticks all overheal
S.Tick(0.5)
cast(lifebloom, "Tank-1", "Destroyka")
for _ = 1, 4 do S.Tick(1.0); ownTick(lifebloom, "Tank-1", "Destroyka", 99, 99) end

S.Fire("PLAYER_REGEN_DISABLED")
local FR = MD.FightRecorder
assert(FR.active, "recorder did not start")

local function advance(sec) for _ = 1, math.floor(sec / 0.5 + 0.5) do S.Tick(0.5) end end

S.units.party1.hp = 3000
swing("Tank-1", "Destroyka", 5000)
-- v0.8.3 auras: Shield Wall on the tank (whitelisted, kept), a Fortitude buff
-- (not whitelisted, dropped), a debuff on the mage that stacks to 2, and a
-- debuff on a mob (untracked, dropped)
advance(1.0); aura("SPELL_AURA_APPLIED", "Tank-1", "Tank-1", "Destroyka", 871, "Shield Wall", "BUFF")
aura("SPELL_AURA_APPLIED", "Priest-9", "Tank-1", "Destroyka", 10938, "Power Word: Fortitude", "BUFF")
aura("SPELL_AURA_APPLIED", "Mob-1", "Mob-2", "Some Mob", 44444, "Sunder", "DEBUFF")
advance(0.5); castStart(regrowth, "Tank-1", "Destroyka")
advance(2.0); cast(regrowth, "Tank-1", "Destroyka"); S.mana = S.mana - (SD:GetCost(regrowth) or 0)
advance(1.5); cast(rejuv, "Tank-1", "Destroyka");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
advance(1.5); cast(MOTW, PLAYER, "Penek");           S.mana = S.mana - 445
-- 400 gross of which 150 was wasted: on this client `amount` ALREADY
-- includes the overheal, so the recorder must write down 400. Every own
-- tick in this fixture used to be a clean one, which is how v0.14.7's bug
-- (a truncated multi-return that always added the overheal back on) lived
-- through every suite.
advance(3.0); ownTick(rejuv, "Tank-1", "Destroyka", 400, 150)
S.units.party2.hp = 1000
swing("Mage-1", "Alkandari", 3000)
aura("SPELL_AURA_APPLIED", "Mob-1", "Mage-1", "Alkandari", 55555, "Curse of Weakness", "DEBUFF")
foreignHeal("Mage-1", "Alkandari", 900)
advance(2.0); cast(rejuv, "Mage-1", "Alkandari");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
-- refresh a Rejuvenation with three ticks still pending: this must label "early".
-- v0.12.0 rides along inside this same 3s so the fixture's clock does not move:
-- a hostile cast on the tank that lands, and one on the mage that never does.
-- This is what Cell's "Targeted Spells" shows, and the only foresight the plan
-- is given.
ev("SPELL_CAST_START", "Mob-1", "Tank-1", "Destroyka", 12471, "Shadow Bolt", 32)
ev("SPELL_CAST_START", "Mob-1", "Mage-1", "Alkandari", 12472, "Shadow Bolt", 32)
advance(3.0)
ev("SPELL_DAMAGE", "Mob-1", "Tank-1", "Destroyka", 12471, "Shadow Bolt", 32, 900, 0, 32, false)
cast(rejuv, "Mage-1", "Alkandari");    S.mana = S.mana - (SD:GetCost(rejuv) or 0)
aura("SPELL_AURA_APPLIED_DOSE", "Mob-1", "Mage-1", "Alkandari", 55555, "Curse of Weakness", "DEBUFF", 2)
aura("SPELL_AURA_REMOVED", "Tank-1", "Tank-1", "Destroyka", 871, "Shield Wall", "BUFF")
-- and one cast on a target at full health: this must label "overheal"
advance(2.0); cast(lifebloom, "Pala-1", "Trecoda");  S.mana = S.mana - (SD:GetCost(lifebloom) or 0)
ev("UNIT_DIED", "Mob-1", "Lock-1", "Abufaisall")
advance(10)
S.Fire("PLAYER_REGEN_ENABLED")

return { rejuv = rejuv, regrowth = regrowth, lifebloom = lifebloom, MOTW = MOTW, PLAYER = PLAYER }
end
