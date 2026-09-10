-- Self-calibration: the model against every heal the player actually lands.
--
-- The combat log reports the amount the server computed; RankMath predicts it.
-- This compares them per EVENT -- tick, direct, bloom -- and accumulates the
-- ratio observed / predicted per spell and kind. Drift is a REPORT TO A HUMAN
-- (a chat line, /md calibrate, /md profile): it is never fed back into the
-- model. Doing that would make the dashboard agree with reality while
-- Data/SpellData.lua stayed wrong, and silently absorb every real finding --
-- a missing relic, a wrong coefficient, an unmodelled talent. The Idol of
-- Rejuvenation was found by hand exactly this way ("Rejuv runs 3% high");
-- this automates the noticing, not the fixing.
--
-- Why per event and with crits separated: RankMath's direct heal carries an
-- expected (1 + 0.5 x crit) factor, which cannot be compared to one event.
-- Non-crit events go against the non-crit prediction; the crit RATE is an
-- independent second check against the crit chance the model used.
--
-- No decay: the statistic is a ratio, so it is gear-invariant -- when +healing
-- rises, observed and predicted rise together, and anything that accumulates
-- is a model error. Reset only when the talent build changes (the model
-- itself changed) or by hand.
local _, MD = ...

local CAL = {}
MD.Calibration = CAL

-- Alert when |ratio - 1| exceeds this with at least MIN_N events. The Idol of
-- Rejuvenation case was 3.2%; a 5% line would have missed the one real
-- finding this project has made, so 3%.
local ALERT_REL = 0.03
local MIN_N = 30
-- A tick landing within this many seconds of a form change is skipped: the
-- prediction is made at event time, and the Tree aura is dynamic.
local FORM_GRACE = 2
-- Lifebloom ticks scale with stack count, which the combat log does not carry.
-- The stack is inferred from which of x1/x2/x3 the tick is closest to; if the
-- best fit is still off by more than this, the tick is skipped as ambiguous.
local STACK_FIT = 0.15

CAL.data = nil          -- bound to MD.cdb.calibration at MD_READY
local alerted = {}      -- key -> true, once per session
local lastFormChange = -math.huge
local predCache = {}    -- spellID -> { t, pred }

local KIND_LABEL = { direct = "direct", tick = "tick", bloom = "bloom" }

--------------------------------------------------------------------------------
-- Prediction per event, from RankMath (cached for a second: 2000 events per
-- half hour is nothing, but Explain() builds a fresh context each call).
--------------------------------------------------------------------------------
local function Prediction(spellID)
    local now = GetTime()
    local c = predCache[spellID]
    if c and now - c.t < 1 then return c.pred end
    local pred = MD.RankMath and MD.RankMath:EventPrediction(spellID)
    predCache[spellID] = { t = now, pred = pred }
    return pred
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------
local function Bucket(key)
    local st = CAL.data.stats[key]
    if not st then
        st = { n = 0, obs = 0, pred = 0, obsSq = 0 }
        CAL.data.stats[key] = st
    end
    return st
end

-- amount is the GROSS heal (Overheal:Split decides the convention); crit is the
-- combat log's critical flag; kind is "tick" | "direct" | "bloom".
function CAL:Observe(spellID, kind, amount, crit, destGUID)
    if not CAL.data or not spellID or not amount or amount <= 0 then return end
    local s = MD.SpellData and MD.SpellData.spells[MD.SpellData:Resolve(spellID)]
    if not s then return end
    if GetTime() - lastFormChange < FORM_GRACE then
        CAL.data.skippedForm = (CAL.data.skippedForm or 0) + 1
        return
    end
    local p = Prediction(spellID)
    if not p then return end

    -- crit rate, counted on direct and bloom events (HoT ticks never crit)
    if kind ~= "tick" then
        local cr = CAL.data.crit[tostring(spellID)]
        if not cr then cr = { events = 0, crits = 0 }; CAL.data.crit[tostring(spellID)] = cr end
        cr.events = cr.events + 1
        if crit then cr.crits = cr.crits + 1 end
        if crit then return end -- amounts: non-crit only
    end

    local predicted = p[kind]
    if not predicted or predicted <= 0 then return end

    if kind == "tick" and p.stacked then
        -- Lifebloom: fit the stack count, skip if nothing fits
        local best, bestErr = nil, math.huge
        for stacks = 1, 3 do
            local err = math.abs(amount / (predicted * stacks) - 1)
            if err < bestErr then best, bestErr = stacks, err end
        end
        if bestErr > STACK_FIT then
            CAL.data.skippedStack = (CAL.data.skippedStack or 0) + 1
            return
        end
        predicted = predicted * best
    end

    local st = Bucket(spellID .. ":" .. kind)
    st.n = st.n + 1
    st.obs = st.obs + amount
    st.pred = st.pred + predicted
    st.obsSq = st.obsSq + amount * amount
    if st.n == MIN_N or (st.n > MIN_N and st.n % 50 == 0) then
        CAL:CheckDrift(spellID, kind, st)
    end
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------
function CAL:Ratio(spellID, kind)
    local st = CAL.data and CAL.data.stats[spellID .. ":" .. kind]
    if not st or st.n == 0 or st.pred <= 0 then return nil end
    return st.obs / st.pred, st.n
end

function CAL:CheckDrift(spellID, kind, st)
    local ratio = st.obs / st.pred
    local key = spellID .. ":" .. kind
    MD:Debug("calib", "%s %s: ratio %.3f over %d events (obs mean %.1f, model %.1f)",
        GetSpellInfo(spellID) or spellID, kind, ratio, st.n, st.obs / st.n, st.pred / st.n)
    if math.abs(ratio - 1) > ALERT_REL and not alerted[key]
        and not (MD.db and MD.db.calibAlerts == false) then
        alerted[key] = true
        local s = MD.SpellData.spells[MD.SpellData:Resolve(spellID)]
        local msg = string.format("|cffffcc00calibration:|r %s R%d %s is healing %.1f%% %s the model over %d events.",
            GetSpellInfo(spellID) or "?", s and s.rank or 0, kind, math.abs(ratio - 1) * 100,
            ratio > 1 and "above" or "below", st.n)
        msg = msg .. CAL:RelicHint(spellID, kind, st)
        MD:Print(msg .. " /md calibrate for the table.")
    end
end

-- The equipped idol, solved for. The slot check applies whatever value the
-- table holds; if that value came from a database tooltip rather than a
-- measurement (relic.verify), a drift on that idol's family is most likely the
-- idol, and the drift IS the correction: for a flat bonus,
--   implied = table value + (observed - predicted) x ticks / talentMult
-- because the flat sits under the talent multipliers and is spread over the
-- ticks. This turns "Rejuvenation is 3.2% high" into "the idol is worth +50,
-- the table says +87" -- the exact edit to Data/SpellData.lua.
function CAL:RelicHint(spellID, kind, st)
    local SD = MD.SpellData
    local relic, itemID, itemName = SD:Relic()
    local s = SD.spells[SD:Resolve(spellID)]
    if not s then return "" end
    if not relic then
        if itemID then
            return string.format(" You are wearing %s, which is not in the relic table - tell the author what it does.",
                itemName or ("item " .. itemID))
        end
        return " Check SpellData or an unmodelled buff."
    end
    if relic.family ~= s.family then
        return string.format(" Your idol (%s) does not affect %s, so this is the spell data or a buff.",
            relic.name, s.family)
    end
    local p = Prediction(spellID)
    if relic.flat and p and p.talentMult and p.talentMult > 0 and kind ~= "bloom" then
        local ticks = (kind == "tick") and (p.ticks or 1) or 1
        local delta = (st.obs - st.pred) / st.n * ticks / p.talentMult
        -- (per application; on stacked Lifebloom ticks the flat is carried
        -- once per stack, so this overstates a little there -- "about")
        return string.format(" You are wearing %s (table: +%d%s); the data says about +%d.",
            relic.name, relic.flat, relic.verify and ", unverified" or "", relic.flat + delta + 0.5)
    end
    return string.format(" You are wearing %s%s.", relic.name, relic.verify and " (value unverified)" or "")
end

-- Worst drift on one spell, for the replay gates (docs/SPEC-v0.7.md 7).
-- Returns |ratio - 1| over every event kind with enough samples, or nil when
-- the spell has not been calibrated -- which is "unknown", not "fine", and the
-- caller must say so rather than pass the gate silently.
function CAL:Drift(spellID)
    if not (CAL.data and CAL.data.stats) then return nil end
    local worst, kindOut = nil, nil
    for k, st in pairs(CAL.data.stats) do
        local id, kind = k:match("^(%d+):(%a+)$")
        if tonumber(id) == spellID and st.n >= MIN_N and st.pred > 0 then
            local d = math.abs(st.obs / st.pred - 1)
            if not worst or d > worst then worst, kindOut = d, kind end
        end
    end
    return worst, kindOut
end

-- Lines for /md calibrate and /md profile.
function CAL:Report()
    local out = {}
    if not CAL.data then return out end
    local keys = {}
    for k in pairs(CAL.data.stats) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ia, ka = a:match("^(%d+):(%a+)$"); local ib, kb = b:match("^(%d+):(%a+)$")
        local sa, sb = MD.SpellData.spells[tonumber(ia)], MD.SpellData.spells[tonumber(ib)]
        local fa, fb = sa and sa.family or a, sb and sb.family or b
        if fa ~= fb then return fa < fb end
        if ia ~= ib then return (sa and sa.rank or 0) < (sb and sb.rank or 0) end
        return ka < kb
    end)
    out[#out + 1] = string.format("%-22s %-7s %5s %9s %9s %6s  %s", "spell", "kind", "n", "observed", "model", "ratio", "verdict")
    for _, k in ipairs(keys) do
        local id, kind = k:match("^(%d+):(%a+)$")
        local st = CAL.data.stats[k]
        local s = MD.SpellData.spells[tonumber(id)]
        local label = string.format("%s R%d", GetSpellInfo(tonumber(id)) or id, s and s.rank or 0)
        if st.n < 5 then
            out[#out + 1] = string.format("%-22s %-7s %5d %9s %9s %6s  too few", label, kind, st.n, "-", "-", "-")
        else
            local ratio = st.obs / st.pred
            local verdict = "ok"
            if st.n < MIN_N then verdict = "early"
            elseif ratio - 1 > ALERT_REL then verdict = "HIGH  <- check relic / data"
            elseif 1 - ratio > ALERT_REL then verdict = "LOW   <- check data" end
            out[#out + 1] = string.format("%-22s %-7s %5d %9.1f %9.1f %6.3f  %s",
                label, kind, st.n, st.obs / st.n, st.pred / st.n, ratio, verdict)
        end
    end
    -- crit rates against what the model assumed
    local ids = {}
    for id in pairs(CAL.data.crit) do ids[#ids + 1] = tonumber(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local cr = CAL.data.crit[tostring(id)]
        if cr.events >= 10 then
            local p = Prediction(id)
            out[#out + 1] = string.format("%-22s crit    %5d  %5.1f%% observed vs %.1f%% assumed",
                GetSpellInfo(id) or id, cr.events, 100 * cr.crits / cr.events, 100 * (p and p.crit or 0))
        end
    end
    if (CAL.data.skippedStack or 0) + (CAL.data.skippedForm or 0) > 0 then
        out[#out + 1] = string.format("skipped: %d Lifebloom ticks with no clean stack fit, %d events within %ds of a form change",
            CAL.data.skippedStack or 0, CAL.data.skippedForm or 0, FORM_GRACE)
    end
    if #out == 1 then out[#out + 1] = "(no heals observed yet)" end
    return out
end

function CAL:ExportRows()
    local out = {}
    if not CAL.data then return out end
    for k, st in pairs(CAL.data.stats) do
        local id, kind = k:match("^(%d+):(%a+)$")
        out[#out + 1] = table.concat({ id, kind, st.n, string.format("%.0f", st.obs), string.format("%.0f", st.pred) }, "\t")
    end
    table.sort(out)
    return out
end

function CAL:Reset(reason)
    if not CAL.data then return end
    wipe(CAL.data.stats)
    wipe(CAL.data.crit)
    CAL.data.skippedStack, CAL.data.skippedForm = 0, 0
    CAL.data.talents = MD:TalentSummary()
    wipe(alerted)
    MD:Debug("calib", "reset: %s", reason or "by hand")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------
MD:RegisterCallback("MD_READY", function()
    MD.cdb.calibration = MD.cdb.calibration or { stats = {}, crit = {} }
    CAL.data = MD.cdb.calibration
    CAL.data.stats = CAL.data.stats or {}
    CAL.data.crit = CAL.data.crit or {}
    CAL.data.talents = CAL.data.talents or MD:TalentSummary()
end)

-- TALENTS_CHANGED also fires at every login (the scan), so only a CHANGED
-- build resets; a plain login keeps the accumulated data.
MD:RegisterCallback("TALENTS_CHANGED", function()
    if not CAL.data then return end
    local now = MD:TalentSummary()
    if CAL.data.talents ~= now then
        CAL:Reset("talent build changed: " .. now)
    end
    wipe(predCache)
end)

MD:RegisterCallback("FORM_CHANGED", function()
    lastFormChange = GetTime()
    wipe(predCache)
end)
MD:On("PLAYER_EQUIPMENT_CHANGED", function() wipe(predCache) end)
