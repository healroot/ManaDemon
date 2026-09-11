-- Fight recorder (docs/SPEC-v0.7.md 4): the full stream of one pull, kept so a
-- fight can be replayed through Engine/SimModel.lua afterwards and asked what
-- a different plan would have done. Everything the engine needs and nothing it
-- does not -- damage on tracked targets, foreign heals, own casts and heals,
-- form changes, mana samples, HP snapshots, deaths -- as parallel arrays of
-- numbers, because a table per event is what makes a SavedVariables file
-- unopenable.
--
-- Nothing here parses the combat log. UI/Summary.lua's single handler already
-- unpacks each event once and forwards the raw payload slots; this file decides
-- what is worth keeping.
local _, MD = ...

local FR = {}
MD.FightRecorder = FR

local K = nil            -- MD.SimModel.K, bound lazily (load order)
local MAX_EV = 4000      -- events per stream; the fight keeps its summary either way
local AURA_EVENTS = {
    SPELL_AURA_APPLIED = "apply", SPELL_AURA_REFRESH = "apply",
    SPELL_AURA_APPLIED_DOSE = "dose", SPELL_AURA_REMOVED_DOSE = "dose",
    SPELL_AURA_REMOVED = "remove",
}
local MAX_STREAMS = 8
local MAX_PINNED = 2
local RECENT_PROTECTED = 3
local HP_SNAPSHOT_EVERY = 5   -- seconds
local MANA_SAMPLE_TICKS = 4   -- MD:OnTick is 0.5s, so every 2s
local CRIT_FLAG = 100000      -- own-heal events carry crit as spellID + this

FR.active = nil

local DAMAGE_EVENTS = {
    SWING_DAMAGE = "swing", SPELL_DAMAGE = "spell", SPELL_PERIODIC_DAMAGE = "spell",
    RANGE_DAMAGE = "spell", SPELL_BUILDING_DAMAGE = "spell", DAMAGE_SHIELD = "spell",
    DAMAGE_SPLIT = "spell", ENVIRONMENTAL_DAMAGE = "env",
}

MD:RegisterCallback("MD_READY", function()
    MD.cdb.recordings = MD.cdb.recordings or {}
    if #MD.cdb.recordings > 0 then
        MD:Debug("sim", "loaded %d recorded fight stream(s)", #MD.cdb.recordings)
    end
end)

--------------------------------------------------------------------------------
-- Who is worth recording. Solo or in a party: everyone. In a raid: the player's
-- own subgroup plus anyone flagged main tank -- a raid's other twenty-odd
-- health bars are not this healer's problem and recording them would bury the
-- ones that are.
--------------------------------------------------------------------------------
local function SubgroupOf(name)
    if not (GetRaidRosterInfo and GetNumGroupMembers) then return nil end
    for i = 1, GetNumGroupMembers() do
        local ok, rname, _, subgroup = pcall(GetRaidRosterInfo, i)
        if ok and rname == name then return subgroup end
    end
    return nil
end

local function BuildTracked()
    local T = MD.Targets
    if not T then return {} end
    local tracked = {}
    local inRaid = IsInRaid and IsInRaid()
    local mySubgroup = inRaid and SubgroupOf(UnitName("player")) or nil

    for _, e in pairs(T.byGUID) do
        if not e.isPet then
            local keep
            if not inRaid then
                keep = true
            else
                local sub = SubgroupOf(e.name)
                keep = (sub ~= nil and sub == mySubgroup)
                if not keep and e.unit and GetPartyAssignment then
                    local ok, mt = pcall(GetPartyAssignment, "MAINTANK", e.unit)
                    keep = ok and mt and true or false
                end
            end
            if keep then
                local idx = MD.Recorder and MD.Recorder:Index(e.guid, e.name) or -1
                if idx > 0 then tracked[idx] = true end
            end
        end
    end
    return tracked
end

-- The roster the stream is indexed by IS the session roster the v0.7.0 cast
-- records already use, so a precast's `tgt` and a damage event's `tgt` mean the
-- same person without any translation.
local function BuildRoster()
    local out = {}
    local rec = MD.Recorder
    if not rec then return out end
    for i, r in ipairs(rec.roster) do
        local e = MD.Targets and MD.Targets.byGUID[r.guid]
        local maxHP = -1
        if e and e.unit and UnitGUID(e.unit) == r.guid then
            maxHP = UnitHealthMax(e.unit) or -1
        end
        out[i] = { name = r.name, guid = r.guid, class = r.class, role = r.role,
                   roleSource = e and e.roleSource or "unknown", maxHP = maxHP }
    end
    return out
end

--------------------------------------------------------------------------------
-- Initial state: what was already ticking when the pull started. The BF-1 log
-- proved this matters -- HoTs had been rolling on the tank for 19s before the
-- first damage event, and a replay that starts from nothing is replaying a
-- different fight.
--------------------------------------------------------------------------------
local DRINK_BUFFS = { ["Drink"] = true, ["Refreshment"] = true, ["Food & Drink"] = true }

local function ScanAuras(stream)
    local SD = MD.SpellData
    local auras, buffs = {}, {}
    local now = GetTime()

    for idx in pairs(stream.trackedSet) do
        local r = MD.Recorder.roster[idx]
        local e = r and MD.Targets and MD.Targets.byGUID[r.guid]
        local unit = e and e.unit
        if unit and UnitGUID(unit) == r.guid then
            for i = 1, 40 do
                local ok, name, _, count, _, duration, expires, source, _, _, spellID =
                    pcall(UnitAura, unit, i, "HELPFUL|PLAYER")
                if not ok or not name then break end
                if spellID and SD.spells[spellID] then
                    auras[#auras + 1] = {
                        target = idx, spellID = spellID,
                        stacks = (count and count > 0) and count or 1,
                        remaining = expires and expires > 0 and (expires - now) or (duration or 0),
                    }
                end
            end
        end
    end

    for i = 1, 40 do
        local ok, name, _, _, _, duration, expires, _, _, _, spellID =
            pcall(UnitAura, "player", i, "HELPFUL")
        if not ok or not name then break end
        if DRINK_BUFFS[name] or spellID == 29166 or (name and name:find("Mana")) then
            buffs[#buffs + 1] = { spellID = spellID or 0, name = name,
                remaining = expires and expires > 0 and (expires - now) or (duration or 0) }
        end
    end
    return auras, buffs
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
function FR:Start(t0)
    FR.active = nil
    if not MD.Recorder then return end
    -- v0.9.1: a run is the container for its own pulls, so it overrides
    -- db.recordFights -- turning single-fight recording off is a statement about
    -- the ring of 8, not about a dungeon the author explicitly started
    -- recording. Once the run's budget is spent, pulls are summarised only.
    local RR = MD.RunRecorder
    local inRun = RR and RR.active ~= nil
    if not (MD.db and MD.db.recordFights ~= false) and not inRun then return end
    if inRun then
        RR:PullStarted()
        if RR:FullUp() then
            RR.active.truncated = true
            MD:Debug("sim", "run full (%d events): this pull is summarised, not recorded", RR.MAX_RUN_EV)
            return
        end
    end
    K = K or (MD.SimModel and MD.SimModel.K)
    if not K then return end

    -- tracked FIRST: it is what assigns roster indices to group members who
    -- have not been healed yet, and BuildRoster snapshots that list.
    local trackedSet = BuildTracked()
    local stream = {
        -- v: the stream's own schema. 2 (v0.14.7) is the first version whose
        -- own-heal amounts are gross ONCE; every v1 stream on disk carries
        -- heal + overheal and cannot be un-mixed, because the overheal was
        -- never written down separately. Read by tools/healcheck.lua and
        -- tools/reproduce.lua, which say so rather than quoting a magnitude.
        v = 2, id = time(), zone = GetRealZoneText and GetRealZoneText() or nil,
        t0 = t0, dur = 0, pool = UnitPowerMax("player", 0) or 0,
        roster = BuildRoster(), trackedSet = trackedSet,
        ev = { t = {}, kind = {}, tgt = {}, amt = {}, x = {} },
        hp = { t = {}, hp = {}, max = {} },
        mana = { t = {}, v = {}, base = {}, cast = {} },
        precasts = {}, deaths = {}, n = 0, truncated = false,
        auraOn = {}, auraN = 0, auraTruncated = false,   -- v0.8.3, per-target aura bookkeeping
        threatOn = {},    -- v0.12.0: [roster index] = last recorded threat status
        names = {},       -- v0.10.1: [spellID] = "Moonfire r11". A recording is read offline,
                          -- where no client can name an id; a few dozen bytes buys that
        pinned = false,
    }
    stream.tracked = {}
    for idx in pairs(stream.trackedSet) do stream.tracked[#stream.tracked + 1] = idx end
    table.sort(stream.tracked)
    for _, idx in ipairs(stream.tracked) do
        stream.hp.hp[idx] = {}
        stream.hp.max[idx] = {}
    end

    local RM = MD.Regen
    stream.initial = {
        mana = UnitPower("player", 0) or 0,
        apiBase = RM and RM.apiBase or 0,
        apiCasting = RM and RM.apiCasting or 0,
        form = MD:InTreeForm() and "tree" or "caster",
        -- v0.9.0: every mana/s this character gains that GetManaRegen does not
        -- report -- Dreamstate (a talent, computed) plus the measured item-mp5
        -- beat (/md regentest, stored in cdb.mp5). apiBase/apiCasting above are
        -- the RAW client numbers, so the engine's `energize` term is the only
        -- place this is counted. It rides with the recording rather than being
        -- looked up at replay time, so a fight recorded before a re-measurement
        -- still replays against what was true then.
        energize = RM and RM:Unreported() or 0,
        energizeParts = RM and { dreamstate = RM:Dreamstate(), measured = RM:MeasuredMp5() } or nil,
        -- v0.9.7: which healing spells the player actually HAD at this pull, as
        -- family -> highest known rank id. A recording is replayed and coached
        -- long after it happened, sometimes on a different talent build and
        -- always offline against a harness that pretends every spell is known.
        -- Without this the replay drew a Swiftmend indicator for a druid who has
        -- never trained Swiftmend, and the offline coach bound it. Six numbers.
        known = (function()
            local k = {}
            for family, id in pairs(MD.SpellData.maxRank or {}) do k[family] = id end
            return k
        end)(),
    }
    stream.initial.auras, stream.initial.buffs = ScanAuras(stream)

    -- the 20s ring, flattened
    for _, c in ipairs(MD.Recorder.ring) do
        stream.precasts[#stream.precasts + 1] = {
            c.t - t0, c.spellID, c.cost, c.tgt, c.hpAtCast, c.form,
        }
    end

    FR.active = stream
    FR.tickCount = 0
    FR.nextHpAt = 0
    FR.pending = nil
    FR:Snapshot(0)
    MD:Debug("sim", "recording started: %d tracked, %d initial aura(s), %d precast(s)",
        #stream.tracked, #stream.initial.auras, #stream.precasts)
end

local function Push(s, t, kind, tgt, amt, x)
    if s.n >= MAX_EV then
        if not s.truncated then
            s.truncated = true
            MD:Debug("sim", "recording truncated at %d events", MAX_EV)
        end
        return
    end
    local n = s.n + 1
    s.n = n
    s.ev.t[n], s.ev.kind[n], s.ev.tgt[n], s.ev.amt[n], s.ev.x[n] = t, kind, tgt, amt, x
end

function FR:Snapshot(t)
    local s = FR.active
    if not s then return end
    local hp = s.hp
    local n = #hp.t + 1
    hp.t[n] = t
    for _, idx in ipairs(s.tracked) do
        local r = MD.Recorder.roster[idx]
        local e = r and MD.Targets and MD.Targets.byGUID[r.guid]
        local unit = e and e.unit
        local cur, max = -1, -1
        if unit and UnitGUID(unit) == r.guid then
            cur, max = UnitHealth(unit) or -1, UnitHealthMax(unit) or -1
        end
        hp.hp[idx][n], hp.max[idx][n] = cur, max
    end
end

-- Called from the master ticker while a fight is being recorded.
function FR:Tick()
    local s = FR.active
    if not s then return end
    local t = GetTime() - s.t0
    FR.tickCount = (FR.tickCount or 0) + 1
    if FR.tickCount % MANA_SAMPLE_TICKS == 0 then
        local m, RM = s.mana, MD.Regen
        local n = #m.t + 1
        m.t[n], m.v[n] = t, UnitPower("player", 0) or 0
        m.base[n], m.cast[n] = RM and RM.apiBase or 0, RM and RM.apiCasting or 0
    end
    if FR.tickCount % MANA_SAMPLE_TICKS == 0 then FR:SampleThreat(t) end
    if t >= FR.nextHpAt then
        FR.nextHpAt = t + HP_SNAPSHOT_EVERY
        FR:Snapshot(t)
    end
end

MD:RegisterCallback("FORM_CHANGED", function(inTree)
    local s = FR.active
    if not s then return end
    Push(s, GetTime() - s.t0, K.FORM, -1, inTree and 1 or 0, 0)
end)

--------------------------------------------------------------------------------
-- One combat-log event, already unpacked by UI/Summary.lua. p1..p10 are the
-- payload slots after the 11-field prefix; what they mean depends on the
-- subevent (docs/SPEC-v0.7.md 1).
--------------------------------------------------------------------------------
function FR:Event(subevent, sourceGUID, destGUID, destName, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10)
    local s = FR.active
    if not s then return end
    local t = GetTime() - s.t0
    local isOwn = (sourceGUID == MD.player.guid)
    local idx = destGUID and MD.Recorder:Index(destGUID, destName) or -1
    local tracked = idx > 0 and s.trackedSet[idx] or false

    -- A cast start with no matching success by the next own event was cancelled
    -- or interrupted; the time is still gone, so it is recorded as such.
    if isOwn and FR.pending then
        local pendingSpell, pendingT = FR.pending[1], FR.pending[2]
        local matched = (subevent == "SPELL_CAST_SUCCESS" and p1 == pendingSpell)
        if not matched and subevent ~= "SPELL_CAST_START" then
            Push(s, t, K.CANCEL, -1, t - pendingT, pendingSpell)
            FR.pending = nil
        elseif matched then
            FR.pending = nil
        end
    end

    local dmg = DAMAGE_EVENTS[subevent]
    if dmg then
        if not tracked then return end
        local amount, overkill, spellID
        if dmg == "swing" then
            amount, overkill, spellID = p1, p2, 0
        elseif dmg == "env" then
            amount, overkill, spellID = p2, p3, 0
        else
            amount, overkill, spellID = p4, p5, p1
        end
        amount = amount or 0
        -- a killing blow's amount includes the overkill; only the HP that
        -- actually existed was lost
        if overkill and overkill > 0 then amount = amount - overkill end
        if amount > 0 then Push(s, t, K.DMG, idx, amount, spellID or 0) end
        return
    end

    if subevent == "SWING_MISSED" or subevent == "SPELL_MISSED" or subevent == "RANGE_MISSED" then
        if not tracked then return end
        local missType, missed
        if subevent == "SWING_MISSED" then missType, missed = p1, p3 else missType, missed = p4, p6 end
        -- A full absorb never touched health. It is recorded because it says
        -- damage was aimed here, and subtracted from nothing.
        if missType == "ABSORB" and (missed or 0) > 0 then
            Push(s, t, K.ABSORB, idx, missed, (subevent == "SWING_MISSED") and 0 or (p1 or 0))
        end
        return
    end

    if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
        local spellID, amount, overheal, critical = p1, p4 or 0, p5 or 0, p7
        local periodic = (subevent == "SPELL_PERIODIC_HEAL")
        if isOwn then
            -- THE MULTI-RETURN TRAP, third time (CLAUDE.md names the two in
            -- UI/Summary.lua). `MD.Overheal and MD.Overheal:Split(a, o)` is an
            -- `and` expression, so it truncates to ONE value: `gross` was always
            -- nil and the fallback always ran. On this client `amount` already
            -- includes the overheal, so every own heal in every recording was
            -- written down as heal + overheal -- up to 2x the truth. Write the
            -- `if` out.
            local gross
            if MD.Overheal then
                local _
                _, gross = MD.Overheal:Split(amount, overheal)
            end
            if not gross then gross = amount + overheal end
            Push(s, t, periodic and K.OWNTICK or K.OWNHEAL, idx, gross,
                (spellID or 0) + (critical and CRIT_FLAG or 0))
        elseif tracked then
            local eff = amount
            if MD.Overheal then eff = MD.Overheal:Split(amount, overheal) end
            if eff > 0 then Push(s, t, K.FHEAL, idx, eff, spellID or 0) end
        end
        return
    end

    -- Auras on tracked targets (docs/SPEC-v0.8.md 5.1): a whitelisted
    -- defensive buff, or any debuff up to a cap. Payload after the prefix:
    -- spellId, spellName, school, auraType[, amount]; the _DOSE events carry
    -- the new stack count in `amount` (recorded as 1 when it is absent -- the
    -- shape is VERIFY against Details! on this client).
    local aura = AURA_EVENTS[subevent]
    if aura then
        if not tracked then return end
        local spellID, auraType = p1 or 0, p4
        local isBuff = (auraType == "BUFF")
        local list = MD.AuraList
        if isBuff and not (list and list.Defensive(spellID)) then return end
        if not isBuff and auraType ~= "DEBUFF" then return end
        local on = s.auraOn[idx]
        if not on then on = { n = 0 }; s.auraOn[idx] = on end
        local x = spellID + (isBuff and MD.SimModel.AURA_BUFF_FLAG or 0)
        if aura == "remove" then
            if on[x] then
                on[x] = nil
                if not isBuff then on.n = on.n - 1 end
                Push(s, t, K.AURA, idx, -1, x)
            end
            return
        end
        local stacks = (aura == "dose") and (p5 or 1) or 1
        if aura == "dose" and not on[x] then aura = "apply" end
        if not on[x] then
            if not isBuff then
                local cap = (list and list.MAX_DEBUFFS_PER_TARGET) or 4
                local budget = math.floor(MAX_EV * ((list and list.DEBUFF_BUDGET) or 0.10))
                if on.n >= cap then return end
                if (s.auraN or 0) >= budget then
                    if not s.auraTruncated then
                        s.auraTruncated = true
                        MD:Debug("sim", "recording: debuff budget (%d) spent, defensives only from here", budget)
                    end
                    return
                end
                on.n = on.n + 1
                s.auraN = (s.auraN or 0) + 1
            end
            on[x] = true
        end
        Push(s, t, K.AURA, idx, stacks, x)
        return
    end

    if not isOwn then return end

    if subevent == "SPELL_CAST_SUCCESS" then
        local cost = MD.SpellData:GetCost(p1)
        Push(s, t, K.OWNCAST, idx, cost or -1, p1 or 0)
        if p1 and not s.names[p1] then
            -- p2 is the combat log's own spell name; GetSpellInfo adds the rank
            local sd = MD.SpellData.spells[p1]
            s.names[p1] = sd and (sd.family .. " r" .. sd.rank)
                or (type(p2) == "string" and p2) or (GetSpellInfo and GetSpellInfo(p1)) or nil
            if MD.ClassifyCast then MD:ClassifyCast(p1) end
        end
        -- the two cooldowns worth replaying; potions arrive as a mana jump the
        -- sample stream already shows
        if p1 == 17116 or p1 == 29166 then Push(s, t, K.CD, -1, 0, p1) end
        s.ownCasts = (s.ownCasts or 0) + 1
        if cost and cost > 0 then s.spent = (s.spent or 0) + cost end
    elseif subevent == "SPELL_CAST_START" then
        Push(s, t, K.CASTSTART, idx, 0, p1 or 0)
        FR.pending = FR.pending or {}
        FR.pending[1], FR.pending[2] = p1, t
    end
end

--------------------------------------------------------------------------------
-- v0.12.0: the two things the author's frames show them coming.
--
-- A hostile cast aimed at somebody they are healing is Cell's "Targeted Spells"
-- indicator, and aggro is its "Aggro (bar)" and "Aggro (border)". Neither is
-- foresight: the cast bar is on screen and the aggro is on the frame. What the
-- plan may do with them is docs/SPEC-v0.12.md §2; what the recorder does is
-- write them down.
--
-- The combat log's SPELL_CAST_START often carries no destination -- the target
-- is not committed until the cast lands -- so the target and the landing time
-- are PAIRED with the damage the cast did, in ScenarioFromRecording. When
-- nothing lands (interrupted, missed, the mob died) the cast stays in the
-- record with no target, exactly as the author saw a bar that came to nothing.
--------------------------------------------------------------------------------
function FR:EnemyCast(subevent, sourceGUID, destGUID, destName, spellID)
    local s = FR.active
    if not s or not spellID then return end
    if not (MD.db and MD.db.recordThreat ~= false) then return end
    if subevent ~= "SPELL_CAST_START" and subevent ~= "SPELL_CHANNEL_START" then return end
    -- a group member's cast is not an enemy cast; Index returns -1 for anybody
    -- who is not in the roster, which is exactly "a mob"
    if MD.Recorder:Index(sourceGUID) > 0 then return end
    local idx = destGUID and MD.Recorder:Index(destGUID, destName) or -1
    if idx > 0 and not s.trackedSet[idx] then return end
    Push(s, GetTime() - s.t0, K.ECAST, idx, 0, spellID)
    if not s.names[spellID] and GetSpellInfo then s.names[spellID] = GetSpellInfo(spellID) end
end

-- Sampled, not evented: the client has no "threat changed" for a party member.
function FR:SampleThreat(t)
    local s = FR.active
    if not s then return end
    if not (MD.db and MD.db.recordThreat ~= false) then return end
    if not UnitThreatSituation then return end
    s.threatOn = s.threatOn or {}
    for _, idx in ipairs(s.tracked) do
        local e = s.roster[idx]
        local entry = e and e.guid and MD.Targets and MD.Targets:Lookup(e.guid, e.name)
        local unit = entry and entry.unit
        if unit then
            local ok, status = pcall(UnitThreatSituation, unit)
            status = (ok and status) or 0
            if s.threatOn[idx] ~= status then
                s.threatOn[idx] = status
                Push(s, t, K.THREAT, idx, status, 0)
            end
        end
    end
end

-- UNIT_DIED has no source; it is dispatched here from the same handler.
function FR:Died(destGUID, destName)
    local s = FR.active
    if not s then return end
    local idx = destGUID and MD.Recorder:Index(destGUID, destName) or -1
    if idx > 0 and s.trackedSet[idx] then
        local t = GetTime() - s.t0
        Push(s, t, K.DIED, idx, 0, 0)
        s.deaths[#s.deaths + 1] = { idx, t }
    end
end

--------------------------------------------------------------------------------
-- Retention: eight streams, and the one that goes is the cheapest fight that is
-- neither pinned nor recent. Cost is the proxy for "was this pull interesting":
-- a 6k-mana pull has something to teach, a 900-mana one does not.
--------------------------------------------------------------------------------
local function Store(stream)
    MD.cdb.recordings = MD.cdb.recordings or {}
    local list = MD.cdb.recordings
    if #list < MAX_STREAMS then
        list[#list + 1] = stream
        return #list, nil
    end

    local protected = {}
    local pinnedCount = 0
    for i, r in ipairs(list) do
        if r.pinned and pinnedCount < MAX_PINNED then
            protected[i] = true
            pinnedCount = pinnedCount + 1
        end
    end
    local order = {}
    for i = 1, #list do order[i] = i end
    table.sort(order, function(a, b) return (list[a].id or 0) > (list[b].id or 0) end)
    for i = 1, math.min(RECENT_PROTECTED, #order) do protected[order[i]] = true end

    local victim, worst = nil, nil
    for i, r in ipairs(list) do
        if not protected[i] then
            local spent = r.spent or 0
            if not worst or spent < worst then victim, worst = i, spent end
        end
    end
    if not victim then victim = order[#order] end
    local dropped = list[victim]
    list[victim] = stream
    return victim, dropped
end

function FR:Finish(duration, labels)
    local s = FR.active
    FR.active = nil
    if not s then
        -- the pull was not recorded (fight recording off, or the run's budget
        -- spent); a run still wants to know one happened and how long it was
        if MD.RunRecorder and MD.RunRecorder.active then MD.RunRecorder:PullSkipped(duration) end
        return nil
    end
    s.dur = duration
    s.ownCasts = s.ownCasts or 0
    s.spent = s.spent or 0
    s.labels = labels
    FR:Snapshot(duration)

    -- foreign share: how much of the healing on tracked targets was not this
    -- player's. Below ~10% the fight is the healer's own; above it, a plan that
    -- assumes otherwise is fiction.
    local own, foreign = 0, 0
    for i = 1, s.n do
        local k = s.ev.kind[i]
        if k == K.OWNHEAL or k == K.OWNTICK then own = own + (s.ev.amt[i] or 0)
        elseif k == K.FHEAL then foreign = foreign + (s.ev.amt[i] or 0) end
    end
    s.foreignShare = (own + foreign) > 0 and (foreign / (own + foreign)) or 0
    s.trackedSet = nil  -- a set of indices does not serialise usefully

    local short = duration < 20 or s.ownCasts < 5

    -- v0.9.1: while a run is recording it takes every pull, the short ones
    -- included -- a dungeon is mostly short pulls, and the gate is about what
    -- may be COACHED from, not about what happened. The ring of 8 is left
    -- alone: a run is pinned, replaced and reviewed as one thing.
    local RR = MD.RunRecorder
    if RR and RR.active then
        local k = RR:AddPull(s, short)
        MD:Debug("sim", "stream %d -> run pull %d: %.0fs, %d events, %d casts, %d mana%s",
            s.id, k or 0, duration, s.n, s.ownCasts, s.spent, short and " (under the gate)" or "")
        return s
    end

    if short then
        MD:Debug("sim", "stream discarded: %.0fs, %d own cast(s) (needs 20s / 5)",
            duration, s.ownCasts)
        return nil
    end

    local slot, dropped = Store(s)
    MD:Debug("sim", "stream %d recorded: %.0fs, %d events%s, %d casts, %d mana, foreign %d%%%s",
        s.id, duration, s.n, s.truncated and " (truncated)" or "", s.ownCasts, s.spent,
        s.foreignShare * 100 + 0.5,
        dropped and string.format(" - replaced slot %d (%d mana)", slot, dropped.spent or 0) or "")
    return s
end

-- Newest first, for the Review tab and /md export.
function FR:List()
    local list = {}
    for _, r in ipairs(MD.cdb and MD.cdb.recordings or {}) do list[#list + 1] = r end
    table.sort(list, function(a, b) return (a.id or 0) > (b.id or 0) end)
    return list
end

function FR:Get(n)
    local list = FR:List()
    return list[n or 1]
end

-- One address for both kinds of recording (v0.9.2). "3" is the third single
-- fight; "2:7" is the seventh pull of the second run. Everything that takes a
-- recording by number -- /md coach, /md simreplay, /md replay, the Review tab's
-- buttons -- goes through this, so a pull inside a run is reachable everywhere a
-- fight is, under a label the author can retype.
-- Returns: recording, label, run, pullIndex.
function MD:GetRecording(spec)
    spec = tostring(spec or 1)
    local a, b = spec:match("^(%d+):(%d+)$")
    if a then
        if not MD.RunRecorder then return nil, spec end
        local rec, run = MD.RunRecorder:GetPull(tonumber(a), tonumber(b))
        return rec, spec, run, tonumber(b)
    end
    local n = tonumber(spec) or 1
    return FR:Get(n), tostring(n)
end
