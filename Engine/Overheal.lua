-- Measured overheal from the combat log, in several dimensions at once:
--   f:<family>        s:<spellID>        k:<spellID>:<kind>   (tick / direct / bloom)
--   r:<role>          c:<class>          u:<guid>             (one target)
-- UI/Summary.lua's single COMBAT_LOG handler feeds Record(); RankMath asks
-- Fraction() so the dashboard can show "effective" heal / HPM / HPS -- what a
-- spell is worth on the targets this player actually heals, not on a dummy at
-- 1 hp -- and UI/Dashboard_Waste.lua asks the *Rows() readers for the view.
--
-- Two stores. `stats` is persisted per character (MD.cdb.overheal), weighted
-- by AMOUNT and decayed per event with a HALF_EVENTS half-life so a changed
-- spec, raid slot or gear level washes out on its own. `session` is this
-- login only, undecayed, and is the only place the per-target buckets live:
-- persisting those would grow SavedVariables with every stranger healed in a
-- pug. Per-target buckets are pruned whenever the roster changes.
--
-- Wasted mana. An event with gross > 0 and effective == 0 healed nothing; its
-- share of the cast's mana is attributed by kind (see Attribute). The first
-- dungeon log put ~24% of all mana spent into targets at full health.
--
-- Known bias, surfaced in the tooltip rather than hidden: until a rank has
-- MIN_EVENTS of its own it borrows the family's fraction, which UNDERSTATES
-- the case for downranking. A family-scope fraction also scales every rank of
-- that family by the same factor, so it can never reorder them -- which is why
-- the Pareto filter and the suggested rank deliberately stay on raw values
-- (docs/DECISIONS.md v0.5 §3).
local _, MD = ...

local OH = {}
MD.Overheal = OH

local HALF_EVENTS = 150
local DECAY = 0.5 ^ (1 / HALF_EVENTS)
local MIN_EVENTS = 40

OH.stats = nil        -- persisted, decayed (bound at MD_READY)
OH.session = {}       -- this login, undecayed; the only home of u:<guid>
OH.waste = {}         -- session: key -> { events, mana }  (keys as above, plus "all")

--------------------------------------------------------------------------------
-- Which convention does this client use for SPELL_HEAL's "amount"?
--
-- Documented both ways across client versions: GROSS (the full heal, of which
-- "overhealing" was wasted) or NET (the part that landed, with "overhealing"
-- on top). A full overheal is the discriminator -- gross reports
-- amount == overheal, net reports amount == 0 -- so the first unambiguous
-- sample latches it. The first dungeon log latched GROSS on its first tick
-- (561 events amount == overheal, none amount == 0). Until latched, NET is
-- assumed, which is what the fight summary always did.
--------------------------------------------------------------------------------
local function LatchConvention(amount, overheal)
    if overheal <= 0 or MD.db == nil or MD.db.healAmountGross ~= nil then return end
    local gross
    if amount == 0 then
        gross = false
    elseif amount == overheal then
        gross = true
    else
        return -- a partial overheal says nothing
    end
    MD.db.healAmountGross = gross
    MD:Debug("heal", "combat log convention latched: SPELL_HEAL amount is %s overheal "
        .. "(sample amount %d, overheal %d)", gross and "GROSS, including" or "NET, excluding",
        amount, overheal)
end

-- Returns effective (landed) and gross (attempted) healing for one event,
-- under whichever convention is in force.
function OH:Split(amount, overheal)
    amount, overheal = amount or 0, overheal or 0
    if MD.db and MD.db.healAmountGross then
        return math.max(0, amount - overheal), amount
    end
    return amount, amount + overheal
end

--------------------------------------------------------------------------------
-- Mana attribution for a wasted event: which share of the cast's cost did
-- this one event carry?
--   single-target HoT tick   cost / ticks
--   direct heal              cost            (hybrid Regrowth: half to the
--   hybrid HoT tick          cost / 2 / 7     direct, half spread over the ticks)
--   AoE tick (Tranquility)   cost / (ticks x group size)
--   Lifebloom bloom          0               (the ticks already carry the cost)
--------------------------------------------------------------------------------
local TICKS = { Rejuvenation = 4, Regrowth = 7, Lifebloom = 7, Tranquility = 4 }

local function Attribute(spellID, spell, kind)
    if not spell then return 0 end
    local cost = MD.SpellData:GetCost(spellID) or spell.cost or 0
    local fam, ftype = spell.family, MD.SpellData.families[spell.family] and MD.SpellData.families[spell.family].type
    if kind == "bloom" then return 0 end
    if ftype == "channel" then
        local group = 1
        if MD.Targets then
            group = 0
            for _, e in pairs(MD.Targets.byGUID) do if not e.isPet then group = group + 1 end end
            group = math.max(group, 1)
        end
        return cost / ((TICKS[fam] or 4) * group)
    end
    if ftype == "hybrid" then
        if kind == "direct" then return cost / 2 end
        return cost / 2 / (TICKS[fam] or 7)
    end
    if kind == "tick" then return cost / (TICKS[fam] or 4) end
    return cost
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------
local function Bump(store, key, effective, over, decay)
    local st = store[key]
    if not st then
        st = { h = 0, o = 0, n = 0 }
        store[key] = st
    end
    if decay then
        st.h = st.h * DECAY + effective
        st.o = st.o * DECAY + over
    else
        st.h = st.h + effective
        st.o = st.o + over
    end
    st.n = math.min(st.n + 1, 100000)
end

local function BumpWaste(key, mana)
    local w = OH.waste[key]
    if not w then w = { events = 0, mana = 0 }; OH.waste[key] = w end
    w.events = w.events + 1
    w.mana = w.mana + mana
end

-- Called for every SPELL_HEAL / SPELL_PERIODIC_HEAL the player lands, in and
-- out of combat: rolling Lifebloom on a tank between pulls is exactly the sort
-- of casting whose overheal belongs in the average. Returns the mana this
-- event wasted (0 unless it healed nothing), for the fight totals.
function OH:Record(spellID, kind, amount, overheal, destGUID, destName)
    if not OH.stats or not spellID then return 0 end
    LatchConvention(amount or 0, overheal or 0)
    local effective, gross = OH:Split(amount, overheal)
    if gross <= 0 then return 0 end
    local over = gross - effective
    kind = kind or "direct"

    local s = MD.SpellData and MD.SpellData.spells[MD.SpellData:Resolve(spellID)]
    local t = MD.Targets and MD.Targets:Lookup(destGUID, destName)
    local role = t and t.role or "UNKNOWN"
    local class = t and t.class or "UNKNOWN"

    -- persisted, decayed
    Bump(OH.stats, "s:" .. spellID, effective, over, true)
    Bump(OH.stats, "k:" .. spellID .. ":" .. kind, effective, over, true)
    Bump(OH.stats, "r:" .. role, effective, over, true)
    Bump(OH.stats, "c:" .. class, effective, over, true)
    if s then Bump(OH.stats, "f:" .. s.family, effective, over, true) end

    -- this login, undecayed, plus the per-target bucket
    Bump(OH.session, "s:" .. spellID, effective, over)
    Bump(OH.session, "k:" .. spellID .. ":" .. kind, effective, over)
    Bump(OH.session, "r:" .. role, effective, over)
    Bump(OH.session, "c:" .. class, effective, over)
    if s then Bump(OH.session, "f:" .. s.family, effective, over) end
    if destGUID then
        Bump(OH.session, "u:" .. destGUID, effective, over)
        local u = OH.session["u:" .. destGUID]
        u.name = t and t.name or destName or "?"
        u.class, u.role, u.roleSource = class, role, t and t.roleSource or "unknown"
        u.owner = t and t.owner or nil
    end

    -- wasted: healed nothing at all
    local wasted = 0
    if effective <= 0 then
        wasted = Attribute(spellID, s, kind)
        BumpWaste("all", wasted)
        BumpWaste("s:" .. spellID, wasted)
        BumpWaste("k:" .. spellID .. ":" .. kind, wasted)
        BumpWaste("r:" .. role, wasted)
        BumpWaste("c:" .. class, wasted)
        if destGUID then BumpWaste("u:" .. destGUID, wasted) end
        if s then BumpWaste("f:" .. s.family, wasted) end
    end
    return wasted
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------
local function FractionIn(store, key)
    local st = store and store[key]
    if not st or st.n < MIN_EVENTS then return nil end
    local total = st.h + st.o
    if total <= 0 then return nil end
    return st.o / total, st.n
end

-- Returns fraction (0..1), sample count, scope ("rank" | "family"), or nil
-- when neither scope has enough data yet. Persisted store.
function OH:Fraction(spellID)
    local frac, n = FractionIn(OH.stats, "s:" .. spellID)
    if frac then return frac, n, "rank" end
    local s = MD.SpellData and MD.SpellData.spells[MD.SpellData:Resolve(spellID)]
    if s then
        frac, n = FractionIn(OH.stats, "f:" .. s.family)
        if frac then return frac, n, "family" end
    end
    return nil
end

-- Overheal of one EVENT KIND of a spell (tick vs bloom), for the Lifebloom
-- economics in RankMath. Falls back to the spell, then the family.
function OH:KindFraction(spellID, kind)
    local frac, n = FractionIn(OH.stats, "k:" .. spellID .. ":" .. kind)
    if frac then return frac, n, "kind" end
    return OH:Fraction(spellID)
end

-- Per-family summary for the dashboard's callout line.
function OH:FamilyFraction(family)
    return FractionIn(OH.stats, "f:" .. family)
end

-- Per-target, for the Cell brief (read-only publication) and the Waste view.
function OH:Target(guid)
    local st = OH.session["u:" .. guid]
    if not st or st.n == 0 then return nil end
    local total = st.h + st.o
    return total > 0 and st.o / total or 0, st.n, st
end

-- Rows for the Waste view. scope = "session" | "all" (persisted, decayed;
-- no per-target rows there). Each row: { label, sub, healed, overhealed,
-- events, frac, wastedMana, wastedEvents, guessed }
local function Rows(prefix, scope, labelOf)
    local store = scope == "all" and OH.stats or OH.session
    local out = {}
    if not store then return out end
    for k, st in pairs(store) do
        if k:sub(1, #prefix) == prefix then
            local total = st.h + st.o
            local w = OH.waste[k]
            local label, sub, guessed = labelOf(k, st)
            if label then
                out[#out + 1] = { key = k, label = label, sub = sub, healed = st.h, overhealed = st.o,
                    events = st.n, frac = total > 0 and st.o / total or 0,
                    wastedMana = w and w.mana or 0, wastedEvents = w and w.events or 0, guessed = guessed }
            end
        end
    end
    table.sort(out, function(a, b) return (a.healed + a.overhealed) > (b.healed + b.overhealed) end)
    return out
end

function OH:SpellRows(scope)
    return Rows("k:", scope, function(k)
        local id, kind = k:match("^k:(%d+):(%a+)$")
        id = tonumber(id)
        local s = id and MD.SpellData.spells[id]
        local name = GetSpellInfo(id) or tostring(id)
        local label = s and string.format("%s R%d", name, s.rank) or name
        return label, kind
    end)
end

function OH:RoleRows(scope)
    return Rows("r:", scope, function(k) return k:sub(3), nil, k:sub(3) == "UNKNOWN" end)
end

function OH:ClassRows(scope)
    return Rows("c:", scope, function(k) return k:sub(3) end)
end

function OH:TargetRows()
    return Rows("u:", "session", function(k, st)
        local label = st.name or "?"
        local sub = st.class == "PET" and ("pet of " .. (st.owner or "?")) or (st.class or "?")
        return label, sub, st.roleSource ~= "assigned" and st.roleSource ~= "partyassign"
    end)
end

function OH:WastedTotal()
    local w = OH.waste.all
    return w and w.mana or 0, w and w.events or 0
end

-- Casts and mana per family this session, from the spend tracker, for the
-- Waste view's Spell mode.
function OH:Reset()
    if not OH.stats then return end
    wipe(OH.stats)
    MD:Print("overheal data cleared.")
end

-- Plain lines for /md profile and the debug log (persisted store).
function OH:Summary()
    local out = {}
    if not OH.stats then return out end
    local keys = {}
    for k in pairs(OH.stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local st = OH.stats[k]
        local total = st.h + st.o
        local label = k
        local id = k:match("^s:(%d+)$") or k:match("^k:(%d+):")
        if id then
            label = (GetSpellInfo(tonumber(id)) or "?") .. " (" .. id .. ")" .. (k:match("^k:%d+:(%a+)$") and (" " .. k:match("^k:%d+:(%a+)$")) or "")
        else
            label = k
        end
        out[#out + 1] = string.format("%s: overheal %.0f%% over %d events%s",
            label, total > 0 and st.o / total * 100 or 0, st.n,
            st.n < MIN_EVENTS and string.format(" (needs %d)", MIN_EVENTS) or "")
    end
    local wm, we = OH:WastedTotal()
    if we > 0 then
        out[#out + 1] = string.format("wasted this session: %d events healed nothing, ~%.0f mana", we, wm)
    end
    return out
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
MD:RegisterCallback("MD_READY", function()
    MD.cdb.overheal = MD.cdb.overheal or {}
    OH.stats = MD.cdb.overheal
end)

-- Per-target buckets follow the group: a target who left is pruned, so the
-- table cannot grow across a night of pugs.
MD:RegisterCallback("ROSTER_CHANGED", function()
    if not MD.Targets then return end
    for k in pairs(OH.session) do
        local guid = k:match("^u:(.+)$")
        if guid and not MD.Targets.byGUID[guid] then
            OH.session[k] = nil
            OH.waste[k] = nil
        end
    end
end)
