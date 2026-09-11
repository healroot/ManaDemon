-- Static TBC druid healing spell data. Costs are read LIVE from the client
-- (GetSpellPowerCost works on the 2.5.x anniversary client: /md verify
-- checked 44 costs on 2026-09-03) and this table is the fallback plus the
-- reference the verify harness diffs against. Heal values, cast times and
-- coefficients still come from here.
--
-- Costs corrected from /md verify output on 2026-09-03 (level 64 druid):
-- Rejuvenation R6-R12, Tranquility R1-R4, Swiftmend. Fields marked VERIFY
-- are the least certain (heal values for ranks not yet learned).
--
-- v0.14.7: the heal values were CHECKED against 17 level 70 Warcraft Logs
-- parses, and they hold. Solving each parse for the +healing that makes this
-- table reproduce what the log says each spell healed, four independent
-- families -- a Rejuvenation tick, a Regrowth tick, a Lifebloom tick and its
-- bloom -- agree on one number per parse to within a few percent
-- (tools/run.sh tools/wclcheckkit.lua --fit). The 1.6-1.8x error that was
-- blamed on this table was the IMPORTER reading the log's spellPower as
-- +healing; nothing here was wrong. Healing Touch R12/R13 stay marked: nobody
-- in the corpus casts one, so nobody has measured them.
local _, MD = ...

local SD = {}
MD.SpellData = SD

local EMPTY = {}

-- family metadata
--   type:    direct | hot | hybrid | lifebloom | channel | instant
--   tol:     castable while in Tree of Life form
--   exclude: excluded from the single-target rank dashboard (still priced for
--            the spend tracker)
SD.families = {
    HealingTouch = { type = "direct",    tol = false, label = "Healing Touch" },
    Regrowth     = { type = "hybrid",    tol = true,  label = "Regrowth" },
    Rejuvenation = { type = "hot",       tol = true,  label = "Rejuvenation" },
    Lifebloom    = { type = "lifebloom", tol = true,  label = "Lifebloom" },
    Tranquility  = { type = "channel",   tol = false, label = "Tranquility",  exclude = true },
    Swiftmend    = { type = "instant",   tol = true,  label = "Swiftmend",    exclude = true },
}

SD.familyOrder = { "HealingTouch", "Lifebloom", "Rejuvenation", "Regrowth" }

-- Lifebloom coefficients are empirical 2.4-era values. VERIFY in-game.
SD.lifebloomHotCoef = 0.5187
SD.lifebloomBloomCoef = 0.3422

-- spellID -> data
--   level: level the rank is learned (drives downrank + sub-20 penalties)
--   cost:  base mana cost before talents/forms
--   cast:  base cast time in seconds (used for both the cast column and the
--          direct coefficient; nil = instant/GCD)
--   healMin/healMax: direct heal range;  hotTotal/hotDuration: HoT portion
SD.spells = {
    -- Healing Touch (direct)
    [5185]  = { family = "HealingTouch", rank = 1,  level = 1,  cost = 25,  cast = 1.5, healMin = 37,   healMax = 51 },
    [5186]  = { family = "HealingTouch", rank = 2,  level = 8,  cost = 55,  cast = 2.0, healMin = 88,   healMax = 112 },
    [5187]  = { family = "HealingTouch", rank = 3,  level = 14, cost = 110, cast = 2.5, healMin = 195,  healMax = 243 },
    [5188]  = { family = "HealingTouch", rank = 4,  level = 20, cost = 185, cast = 3.0, healMin = 363,  healMax = 445 },
    [5189]  = { family = "HealingTouch", rank = 5,  level = 26, cost = 270, cast = 3.5, healMin = 572,  healMax = 694 },
    [6778]  = { family = "HealingTouch", rank = 6,  level = 32, cost = 335, cast = 3.5, healMin = 742,  healMax = 894 },
    [8903]  = { family = "HealingTouch", rank = 7,  level = 38, cost = 405, cast = 3.5, healMin = 936,  healMax = 1121 },
    [9758]  = { family = "HealingTouch", rank = 8,  level = 44, cost = 495, cast = 3.5, healMin = 1199, healMax = 1428 },
    [9888]  = { family = "HealingTouch", rank = 9,  level = 50, cost = 600, cast = 3.5, healMin = 1516, healMax = 1804 },
    [9889]  = { family = "HealingTouch", rank = 10, level = 56, cost = 720, cast = 3.5, healMin = 1890, healMax = 2230 },
    [25297] = { family = "HealingTouch", rank = 11, level = 60, cost = 800, cast = 3.5, healMin = 2267, healMax = 2678 },
    [26978] = { family = "HealingTouch", rank = 12, level = 62, cost = 820, cast = 3.5, healMin = 2364, healMax = 2799 }, -- VERIFY
    [26979] = { family = "HealingTouch", rank = 13, level = 69, cost = 935, cast = 3.5, healMin = 2707, healMax = 3198 }, -- VERIFY

    -- Rejuvenation (HoT, 12s, 4 ticks)
    [774]   = { family = "Rejuvenation", rank = 1,  level = 4,  cost = 25,  hotTotal = 32,   hotDuration = 12 },
    [1058]  = { family = "Rejuvenation", rank = 2,  level = 10, cost = 40,  hotTotal = 56,   hotDuration = 12 },
    [1430]  = { family = "Rejuvenation", rank = 3,  level = 16, cost = 75,  hotTotal = 116,  hotDuration = 12 },
    [2090]  = { family = "Rejuvenation", rank = 4,  level = 22, cost = 105, hotTotal = 180,  hotDuration = 12 },
    [2091]  = { family = "Rejuvenation", rank = 5,  level = 28, cost = 135, hotTotal = 244,  hotDuration = 12 },
    [3627]  = { family = "Rejuvenation", rank = 6,  level = 34, cost = 160, hotTotal = 304,  hotDuration = 12 },
    [8910]  = { family = "Rejuvenation", rank = 7,  level = 40, cost = 195, hotTotal = 388,  hotDuration = 12 },
    [9839]  = { family = "Rejuvenation", rank = 8,  level = 46, cost = 235, hotTotal = 488,  hotDuration = 12 },
    [9840]  = { family = "Rejuvenation", rank = 9,  level = 52, cost = 280, hotTotal = 608,  hotDuration = 12 },
    [9841]  = { family = "Rejuvenation", rank = 10, level = 58, cost = 335, hotTotal = 756,  hotDuration = 12 },
    [25299] = { family = "Rejuvenation", rank = 11, level = 60, cost = 360, hotTotal = 888,  hotDuration = 12 },
    [26981] = { family = "Rejuvenation", rank = 12, level = 63, cost = 370, hotTotal = 932,  hotDuration = 12 }, -- VERIFY heal
    [26982] = { family = "Rejuvenation", rank = 13, level = 69, cost = 415, hotTotal = 1060, hotDuration = 12 }, -- v0.14.7 checked

    -- Regrowth (hybrid: direct + HoT over 21s, 7 ticks)
    [8936]  = { family = "Regrowth", rank = 1,  level = 12, cost = 80,  cast = 2.0, healMin = 84,   healMax = 98,   hotTotal = 98,   hotDuration = 21 },
    [8938]  = { family = "Regrowth", rank = 2,  level = 18, cost = 135, cast = 2.0, healMin = 164,  healMax = 188,  hotTotal = 175,  hotDuration = 21 },
    [8939]  = { family = "Regrowth", rank = 3,  level = 24, cost = 185, cast = 2.0, healMin = 240,  healMax = 274,  hotTotal = 259,  hotDuration = 21 },
    [8940]  = { family = "Regrowth", rank = 4,  level = 30, cost = 230, cast = 2.0, healMin = 318,  healMax = 360,  hotTotal = 343,  hotDuration = 21 },
    [8941]  = { family = "Regrowth", rank = 5,  level = 36, cost = 275, cast = 2.0, healMin = 405,  healMax = 457,  hotTotal = 427,  hotDuration = 21 },
    [9750]  = { family = "Regrowth", rank = 6,  level = 42, cost = 335, cast = 2.0, healMin = 511,  healMax = 576,  hotTotal = 546,  hotDuration = 21 },
    [9856]  = { family = "Regrowth", rank = 7,  level = 48, cost = 405, cast = 2.0, healMin = 646,  healMax = 724,  hotTotal = 686,  hotDuration = 21 },
    [9857]  = { family = "Regrowth", rank = 8,  level = 54, cost = 485, cast = 2.0, healMin = 809,  healMax = 905,  hotTotal = 861,  hotDuration = 21 },
    [9858]  = { family = "Regrowth", rank = 9,  level = 60, cost = 575, cast = 2.0, healMin = 1003, healMax = 1119, hotTotal = 1064, hotDuration = 21 },
    -- v0.14.7 checked: the HoT lands within 5% on 17 level 70 parses; the
    -- DIRECT is the corpus's one outlier and reads ~13% low (docs/SPEC-v0.14.md 4c)
    [26980] = { family = "Regrowth", rank = 10, level = 65, cost = 675, cast = 2.0, healMin = 1215, healMax = 1356, hotTotal = 1274, hotDuration = 21 },

    -- Lifebloom (single rank in TBC; 7s HoT + bloom on expiry)
    [33763] = { family = "Lifebloom", rank = 1, level = 64, cost = 220, hotTotal = 273, hotDuration = 7, bloom = 600 },

    -- Priced for the spend tracker only (excluded from ranking).
    [740]   = { family = "Tranquility", rank = 1, level = 30, cost = 525,  cast = 8, channel = true },
    [8918]  = { family = "Tranquility", rank = 2, level = 40, cost = 705,  cast = 8, channel = true },
    [9862]  = { family = "Tranquility", rank = 3, level = 50, cost = 975,  cast = 8, channel = true },
    [9863]  = { family = "Tranquility", rank = 4, level = 60, cost = 1295,  cast = 8, channel = true },
    [26983] = { family = "Tranquility", rank = 5, level = 69, cost = 1650, cast = 8, channel = true },
    [18562] = { family = "Swiftmend",   rank = 1, level = 40, cost = 271 },

    -- Innervate costs a percentage of base mana (67 at level 64), so it has
    -- no static cost: priced live only. Listed so it is never "unknown".
    [29166] = { family = "Innervate", rank = 1, level = 40 },
}

--------------------------------------------------------------------------------
-- Relics (idols): the heal-side effect of the equipped idol, read from slot 18.
--   flat       added to the spell's BASE heal (a HoT's total over its duration)
--              before talent multipliers -- SPELLMOD_DAMAGE flat
--   perTick    added to each Lifebloom tick (no current idol does this; kept)
--   aura       added to the Tree of Life aura (healing received by party targets)
--   castReduce seconds off the cast (Idol of Health, Healing Touch)
--   cost       flat mana off the spell -- the LIVE cost already includes it, so
--              this only feeds the static fallback and the Simulate strip
--   verify     the value is from a database tooltip, not measured on this
--              client. Engine/Calibration.lua's drift alert names the equipped
--              relic and states the value the data implies, which is how these
--              get confirmed or corrected without a hand-run test.
-- Sources checked 2026-09-05 (wowhead tbc / warcraft.wiki.gg / tbc.cavernoftime):
-- two earlier entries were wrong -- Idol of Health is a cast-time relic, not
-- +100 healing, and Emerald Queen is +88 to Lifebloom's TOTAL periodic
-- healing (~12.6 a tick), not +47 a tick. IDs matter: a wrong one never
-- matches the slot and the idol silently vanishes from the model.
--------------------------------------------------------------------------------
SD.relics = {
    -- Vanilla / Anniversary greens, still worn while levelling
    [22398] = { name = "Idol of Rejuvenation",         family = "Rejuvenation", flat = 50 },              -- measured 2026-09-03
    [186054] = { name = "Communal Idol of Life",       family = "Rejuvenation", flat = 15, verify = true },  -- Anniversary green, ilvl 52; author wore it 2026-09-05
    [22399] = { name = "Idol of Health",               family = "HealingTouch", castReduce = 0.15, verify = true },
    -- Burning Crusade
    [25643] = { name = "Harold's Rejuvenating Broach", family = "Rejuvenation", flat = 87, verify = true },    -- quest; one source says 86
    [27886] = { name = "Idol of the Emerald Queen",    family = "Lifebloom",    flat = 88, verify = true },    -- Ambassador Hellmaw, Shadow Labyrinth
    [28568] = { name = "Idol of the Avian Heart",      family = "HealingTouch", flat = 136, verify = true },   -- Moroes, Karazhan
    [32387] = { name = "Idol of the Raven Goddess",    aura = 44, verify = true },                             -- Vanquish the Raven God
    [33508] = { name = "Idol of Budding Life",         family = "Rejuvenation", cost = 36, verify = true },    -- badges, G'eras
    [30051] = { name = "Idol of the Crescent Goddess", family = "Regrowth",     cost = 65, verify = true },    -- Hydross, Serpentshrine Cavern
}

-- Returns the equipped relic's entry (or nil), plus the item ID and name for
-- the verify snapshot (so unknown idols can be added).
function SD:Relic()
    if not GetInventoryItemID then return nil end
    local ok, itemID = pcall(GetInventoryItemID, "player", 18)
    if not ok or not itemID then return nil end
    local name = GetItemInfo and GetItemInfo(itemID) or nil
    return SD.relics[itemID], itemID, name
end

--------------------------------------------------------------------------------
-- Costs. SD:GetCost() is what the model and the dashboard use: the client's
-- live value when it reports one (talents, Tree of Life and whatever else the
-- client applies are then exact), else the static table with the talent
-- modifiers below. SD:StaticCost() is the table-only figure the verify
-- harness diffs against the live one.
--------------------------------------------------------------------------------
function SD:LiveCost(spellID)
    if not GetSpellPowerCost then return nil end
    local ok, costs = pcall(GetSpellPowerCost, spellID)
    if ok and type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 then return c.cost end -- 0 = mana
        end
        return 0 -- costs table without mana: free for our purposes
    end
    return nil
end

-- The client ROUNDS talent-modified costs to the nearest integer (verified
-- 2026-09-03: Swiftmend 271 x 0.8 = 216.8 -> live 217) and SUMS same-type
-- percent modifiers (Moonglow + Tree of Life = -29%, not x0.91 x0.8), which is
-- what this does. The optional ctx overrides the live talents/form so the
-- dashboard can price a rank in a form the player is not currently in:
--   ctx = { inTree = <bool>, moonglow = 0..3, tranquilSpirit = 0..5 }
-- Any nil field falls back to the live value, so SD:StaticCost(id) is
-- unchanged for every existing caller.
local MOONGLOW_FAMILIES = { HealingTouch = true, Regrowth = true, Rejuvenation = true }
local TRANQUIL_FAMILIES = { HealingTouch = true, Tranquility = true }
local TOL_FAMILIES = { Rejuvenation = true, Regrowth = true, Lifebloom = true,
                       Swiftmend = true, Tranquility = true }

function SD:StaticCost(spellID, ctx)
    local s = SD.spells[spellID]
    if not s or s.cost == nil then return nil end
    local cost = s.cost
    if MD.player.isDruid and cost > 0 then
        ctx = ctx or EMPTY
        local fam = s.family
        local moonglow = ctx.moonglow or MD:TalentRank("Moonglow")
        local tranquil = ctx.tranquilSpirit or MD:TalentRank("Tranquil Spirit")
        local inTree = ctx.inTree
        if inTree == nil then inTree = MD:InTreeForm() end

        local reduction = 0
        -- Moonglow: -3%/rank for Healing Touch, Regrowth AND Rejuvenation.
        if MOONGLOW_FAMILIES[fam] then reduction = reduction + 0.03 * moonglow end
        -- Tranquil Spirit: -2%/rank for Healing Touch and Tranquility.
        if TRANQUIL_FAMILIES[fam] then reduction = reduction + 0.02 * tranquil end
        -- Tree of Life: -20% on the form's HoTs, Swiftmend AND Tranquility
        -- (verified 2026-09-03: the client discounts Tranquility in form even
        -- though it cannot be cast there).
        if inTree and TOL_FAMILIES[fam] then reduction = reduction + 0.20 end

        cost = cost * (1 - reduction)

        -- cost-only idol on this family (Budding Life, Crescent Goddess). Flat
        -- after percent is assumed; /md verify's COST lines will say if the
        -- client does it the other way round the day one is equipped.
        local relic = SD:Relic()
        if relic and relic.cost and relic.family == fam then
            cost = math.max(0, cost - relic.cost)
        end
    end
    return math.floor(cost + 0.5)
end

-- Returns cost, "api" | "table"; nil when neither source knows the spell.
function SD:GetCost(spellID)
    local live = SD:LiveCost(spellID)
    if live ~= nil then return live, "api" end
    local static = SD:StaticCost(spellID)
    if static ~= nil then return static, "table" end
    return nil
end

--------------------------------------------------------------------------------
-- Known-rank index (built at login, rebuilt when spells change).
--------------------------------------------------------------------------------
SD.known = {}     -- family -> sorted array of known spellIDs (ascending rank)
SD.knownSet = {}  -- spellID -> true for known spells
-- v0.14.3: some heals arrive under a DIFFERENT spell id from the one that was
-- cast. Lifebloom's final heal is 33778 while the HoT that ticked is 33763, so a
-- combat log attributes the bloom to a spell this table has never heard of -- on
-- one Prince Malchezaar parse that is 44,946 healing, a fifth of all the
-- Lifebloom in the fight, credited to nothing at all.
--
-- These are aliases and NOT rows in SD.spells: a second entry with the same
-- family and rank would enter SD.all and corrupt the known-rank index, which is
-- what decides which rank the dashboard suggests.
SD.alias = {
    [33778] = 33763,    -- Lifebloom's bloom -> the Lifebloom that bloomed
    -- v0.14.7: Tranquility heals under its own id, never the one cast, so
    -- 43,104 healing on one parse landed in family "?". MEASURED by pairing
    -- caster with healer in the Warcraft Logs corpus, not looked up:
    --   26983 (R5) cast -> 44208 healed, on four parses
    --    9863 (R4) cast -> 44207 healed, on two
    -- The lower ranks are presumed to follow the same descent and are NOT
    -- listed: nobody in the corpus cast one, so nobody has seen the id.
    [44208] = 26983,
    [44207] = 9863,
}

-- The id to attribute a heal to. Always use this on an id that came out of a
-- combat log or a recording; a CAST id never needs it.
function SD:Resolve(id)
    return SD.alias[id] or id
end

SD.maxRank = {}   -- family -> highest known spellID

-- Static family -> sorted array of ALL spellIDs (built once at load; the
-- dashboard shows unlearned ranks dimmed).
SD.all = {}
for id, s in pairs(SD.spells) do
    SD.all[s.family] = SD.all[s.family] or {}
    local list = SD.all[s.family]
    list[#list + 1] = id
end
for _, list in pairs(SD.all) do
    table.sort(list, function(a, b)
        return SD.spells[a].rank < SD.spells[b].rank
    end)
end

local function IsKnown(id)
    if IsSpellKnown then return IsSpellKnown(id) end
    if IsPlayerSpell then return IsPlayerSpell(id) end
    return GetSpellInfo(GetSpellInfo(id) or "") ~= nil
end

function SD:BuildKnown()
    wipe(SD.known)
    wipe(SD.knownSet)
    wipe(SD.maxRank)
    -- Ranks are trainer prerequisites: knowing rank N implies every rank
    -- below it. The anniversary client's IsSpellKnown misses lower ranks,
    -- so find the highest detectable rank per family and backfill.
    for family, list in pairs(SD.all) do
        local top = 0
        for i = 1, #list do
            if IsKnown(list[i]) then top = i end
        end
        if top > 0 then
            SD.known[family] = {}
            for i = 1, top do
                SD.knownSet[list[i]] = true
                SD.known[family][i] = list[i]
            end
            SD.maxRank[family] = list[top]
        end
    end
    MD:Fire("SPELLS_REBUILT")
end

function SD:IsMaxKnownRank(spellID)
    local s = SD.spells[spellID]
    return s and SD.maxRank[s.family] == spellID
end

MD:RegisterCallback("MD_READY", function() SD:BuildKnown() end)
MD:On("LEARNED_SPELL_IN_TAB", function() SD:BuildKnown() end)
MD:On("SPELLS_CHANGED", function()
    if MD.db then SD:BuildKnown() end
end)
