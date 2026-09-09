-- In-game verification harness (/md verify): diff the static SpellData table
-- against whatever the live client exposes, and dump the regen/healing inputs
-- so formulas can be checked by hand before any number is trusted.
-- /md fsrtest logs mana ticks for 15s to pin down the five-second-rule anchor.
-- /md regentest measures idle regen against GetManaRegen (Dreamstate check).
local _, MD = ...

function MD:RunVerify()
    local SD = MD.SpellData
    MD:Print("— verify: static data vs live client —")
    local mismatches, checkedCost, checkedCast = 0, 0, 0

    local ids = {}
    for id in pairs(SD.spells) do ids[#ids + 1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local s = SD.spells[id]
        local name, _, _, castMs = GetSpellInfo(id)
        local label = string.format("%s R%d (%d)", s.family, s.rank, id)

        if not name then
            mismatches = mismatches + 1
            MD:Print("|cffff4444MISSING|r " .. label .. " — spellID unknown to this client")
        else
            -- cast time (GetSpellInfo returns milliseconds)
            if s.cast and castMs and castMs > 0 then
                checkedCast = checkedCast + 1
                -- Compare against what the model expects, not the raw table:
                -- Naturalist and a cast-time idol are known. (The first
                -- regression log reported 13 "mismatches", all Naturalist.)
                -- The live value may sit UNDER the 1.5s GCD floor the model
                -- applies (HT R1 reads 1.0s with Naturalist 5); that is fine.
                local expect = s.cast
                if s.family == "HealingTouch" then
                    expect = expect - 0.1 * MD:TalentRank("Naturalist")
                    local relic = SD:Relic()
                    if relic and relic.castReduce and relic.family == s.family then
                        expect = expect - relic.castReduce
                    end
                end
                if math.abs(castMs / 1000 - expect) > 0.01 then
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33CAST|r %s: table %.1fs%s, live %.1fs",
                        label, s.cast, expect ~= s.cast and string.format(" (model %.1fs)", expect) or "",
                        castMs / 1000))
                end
            end
            -- mana cost: the live value is what the model uses; the static
            -- table (with talent modifiers) should agree with it.
            local live = SD:LiveCost(id)
            local static = SD:StaticCost(id)
            if live ~= nil and static ~= nil then
                checkedCost = checkedCost + 1
                if live ~= static then
                    mismatches = mismatches + 1
                    MD:Print(string.format("|cffffaa33COST|r %s: static %d (base %d), live %d (used)",
                        label, static, s.cost, live))
                end
            end
        end
    end

    if checkedCost == 0 then
        MD:Print("|cffffaa33GetSpellPowerCost unavailable|r — the static table is in use; costs must be verified " ..
            "by hand (cast each rank at full idle mana and read the drop; compare to the table).")
    end
    MD:Print(string.format("checked %d cast times, %d costs — %d mismatch(es).",
        checkedCast, checkedCost, mismatches))

    -- Spells outside the healing model, by what they were for (v0.10.1). The
    -- ones that come back "unknown" are the author's list to correct: a wrong
    -- or missing row in Data/DruidSpells.lua costs a label, never a number.
    local unknown = {}
    for id in pairs(MD.Spend.unknown) do unknown[#unknown + 1] = id end
    if #unknown > 0 then
        table.sort(unknown)
        local by = { damage = {}, cc = {}, utility = {}, shift = {}, unknown = {} }
        for _, id in ipairs(unknown) do
            local family, kind = MD:ClassifyCast(id)
            local list = by[kind] or by.unknown
            list[#list + 1] = (family or GetSpellInfo(id) or "?") .. " (" .. id .. ")"
        end
        for _, kind in ipairs({ "damage", "cc", "utility", "shift", "unknown" }) do
            if #by[kind] > 0 then
                MD:Print(string.format("%s spells outside the healing model: %s",
                    kind == "unknown" and "|cffff9966unclassified|r" or kind,
                    table.concat(by[kind], ", ")))
            end
        end
    end

    MD:Print("— input snapshot —")
    for _, line in ipairs(MD:Snapshot()) do MD:Print(line) end
    MD:Print("For the FSR anchor: stand idle at partial mana, run /md fsrtest, cast ONE " ..
        "Healing Touch, and watch which tick sizes appear when. For Dreamstate: /md regentest.")
end

--------------------------------------------------------------------------------
-- Every model input in one block. /md verify prints it, /md profile copies it,
-- and both therefore always agree. Returns an array of plain strings (no
-- colour escapes, so it survives a paste).
--------------------------------------------------------------------------------
function MD:Snapshot()
    local SD = MD.SpellData
    local RM = MD.Regen
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    if GetManaRegen then
        add("GetManaRegen: base %.2f/s, casting %.2f/s (x5 = %d / %d mp5)",
            RM.apiBase, RM.apiCasting, RM.apiBase * 5 + 0.5, RM.apiCasting * 5 + 0.5)
        if RM.unreported > 0 then
            add("model adds %.2f/s the API omits (%d mp5: Dreamstate %d, measured %d) -> base %.2f/s, casting %.2f/s",
                RM.unreported, RM.unreported * 5 + 0.5, RM.dreamstate * 5 + 0.5, RM.measured * 5 + 0.5,
                RM.base, RM.casting)
        end
        local m = MD.cdb and MD.cdb.mp5
        if m then
            add("measured mp5: %d (%.2f/s) from %s on %s, %d beat(s)%s", m.mp5 or 0, m.perSec or 0,
                m.source or "?", date("%Y-%m-%d %H:%M", m.at or 0), m.ticks or 0,
                m.hint and (" at " .. m.hint) or "")
        else
            add("measured mp5: none - run /md regentest solo to measure the beat the API omits")
        end
        local drinking = MD:HasBuff("Drink") or MD:HasBuff("Refreshment") or MD:HasBuff("Food & Drink")
        add("drink buff up: %s; observed OOC fill %.2f/s (FSR duty %d%%)",
            drinking and "yes" or "no", RM:ObservedFill(), RM:Duty() * 100)
    end

    local spirit = UnitStat("player", 5) or 0
    local intellect = UnitStat("player", 4) or 0
    local spiritPerSec, mp5Gear, inFSRFrac = RM:Components()
    add("spirit %d, int %d -> spirit share %.2f/s (%d mp5), gear/buffs ~%d mp5, in-5SR fraction %d%%",
        spirit, intellect, spiritPerSec, spiritPerSec * 5 + 0.5, mp5Gear, inFSRFrac * 100)

    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        add("+healing: " .. (ok and tostring(v) or "unavailable") ..
            (MD:InTreeForm() and string.format(" (Tree of Life form: +%d aura on party targets = 25%% of %d spirit%s)",
                0.25 * spirit, spirit, (MD.db.treeAura == false) and ", NOT counted (setting off)" or "")
             or " (not in Tree form)"))
    end
    if GetSpellCritChance then
        local ok, v = pcall(GetSpellCritChance, 4)
        add("nature crit: %s%%", ok and string.format("%.1f", v) or "unavailable")
    end
    add("talents: " .. MD:TalentSummary())

    local relic, relicID, relicName = SD:Relic()
    if relicID then
        if relic then
            local what = relic.flat and string.format("+%d %s", relic.flat, relic.family)
                or relic.perTick and string.format("+%d per %s tick", relic.perTick, relic.family)
                or relic.castReduce and string.format("-%.2fs %s cast", relic.castReduce, relic.family)
                or relic.cost and string.format("-%d mana on %s (live cost already includes it)", relic.cost, relic.family)
                or relic.aura and string.format("+%d Tree of Life aura", relic.aura) or "?"
            add("relic: %s (%d) - %s%s", relic.name, relicID, what,
                relic.verify and " [value from a database tooltip, not yet measured - calibration will say]" or " [measured]")
        else
            add("relic: %s (%d) - NOT in the relic table (tell the author what it does)", relicName or "?", relicID)
        end
    else
        add("relic: none equipped")
    end

    if MD.Overheal then
        local oh = MD.Overheal:Summary()
        if #oh > 0 then
            add("overheal (combat log, per character):")
            for _, line in ipairs(oh) do add("  " .. line) end
        else
            add("overheal: no samples yet")
        end
        add("combat log 'amount' convention: %s", MD.db.healAmountGross == nil and "not yet latched"
            or (MD.db.healAmountGross and "GROSS (includes overheal)" or "NET (excludes overheal)"))
    end

    if MD.Calibration then
        add("calibration (observed / model, non-crit events):")
        for _, line in ipairs(MD.Calibration:Report()) do add("  " .. line) end
    end

    local hist = MD.fightHistory or {}
    add("recorded fights: %d", #hist)
    for i = math.max(1, #hist - 4), #hist do
        local f = hist[i]
        add("  [%s] %s", f.zone or "?", (f.summary or "-"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    return out
end

--------------------------------------------------------------------------------
-- /md profile: every model input in one copyable block. This is the bug report
-- -- chat-spamming forty lines is not one, a Ctrl+C box is, so it goes straight
-- into the debug console's copy popup.
--------------------------------------------------------------------------------
function MD:Profile()
    local SD = MD.SpellData
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    local _, build, _, iface = GetBuildInfo()
    add("=== ManaDemon v%s profile ===", MD.version)
    add("client build %s, interface %s, ElvUI %s", tostring(build), tostring(iface),
        ElvUI and "present" or "absent")
    add("%s, %s level %d, form: %s, mana %d/%d", MD.player.charKey, MD.player.class,
        MD.player.level, MD:InTreeForm() and "Tree of Life" or "caster / other",
        UnitPower("player", 0) or 0, UnitPowerMax("player", 0) or 0)

    add("")
    add("--- inputs ---")
    for _, line in ipairs(MD:Snapshot()) do add(line) end

    add("")
    add("--- costs of known max ranks ---")
    if MD.player.isDruid then
        for _, family in ipairs(SD.familyOrder) do
            local id = SD.maxRank[family]
            if id then
                local spell = SD.spells[id]
                local live = SD:LiveCost(id)
                local static = SD:StaticCost(id)
                add("%s R%d (%d): live %s, static %s, cast %.1fs",
                    family, spell.rank, id, tostring(live), tostring(static), spell.cast or 1.5)
            end
        end
    else
        add("(druid-only)")
    end

    add("")
    add("--- clock ---")
    local st = MD:GetManaState()
    if st then
        add("mode %s, tto %s, ttf %s, rest %s, shown \"%s\"", st.mode,
            st.tto and string.format("%.0fs", st.tto) or "-",
            st.ttf and string.format("%.0fs", st.ttf) or "-",
            st.rest and string.format("%.0fs", st.rest) or "-",
            (MD:GetDisplayString():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        add("spend %.2f +- %.2f mana/s (%d casts, cv %.2f, half-life %ds), regen %.2f/s (duty %d%%)",
            st.spend, st.sigma, st.casts, st.cv, MD.db.halfLife or 15, st.regen, st.duty * 100)
        if st.cd then
            add("mana cooldown: %s worth %d mana%s", st.cd.name, st.cd.delta,
                st.cd.tto and string.format(" -> OOM %.0fs", st.cd.tto) or "")
        end
    else
        add("(no state yet)")
    end
    local unknown = {}
    for id in pairs(MD.Spend.unknown) do unknown[#unknown + 1] = id end
    if #unknown > 0 then
        table.sort(unknown)
        local names = {}
        for _, id in ipairs(unknown) do
            names[#names + 1] = (GetSpellInfo(id) or "?") .. " (" .. id .. ")"
        end
        add("unpriced spells this session: %s", table.concat(names, ", "))
    end

    add("")
    add("--- settings ---")
    local keys = {}
    for k, v in pairs(MD.db) do
        if k ~= "char" and k ~= "pos" and k ~= "optionsPos" and k ~= "debug" and type(v) ~= "table" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(MD.db[k])
    end
    add(table.concat(parts, "  "))
    local cats = {}
    for k, v in pairs(MD.db.debug.categories) do
        if v then cats[#cats + 1] = k end
    end
    table.sort(cats)
    add("debug: enabled=%s, keep %d lines, categories: %s",
        tostring(MD.db.debug.enabled), MD.db.debug.maxLines or 1000, table.concat(cats, " "))
    if MD.sim and next(MD.sim) then
        local sim = {}
        for k, v in pairs(MD.sim) do sim[#sim + 1] = k .. "=" .. tostring(v) end
        table.sort(sim)
        add("SIMULATION ACTIVE: %s", table.concat(sim, " "))
    end

    return out
end

function MD:RunProfile()
    local lines = MD:Profile()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon profile", table.concat(lines, "\n"))
        MD:Print("profile ready - Ctrl+C in the box to copy it.")
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
    MD:Debug("other", "profile dumped (%d lines)", #lines)
end

--------------------------------------------------------------------------------
-- /md export: machine-readable TSV for analysis (fights, overheal buckets,
-- roster, calibration when present). Tabs, no quoting: the first dungeon log
-- was analysed by regexing prose, which is how the analyst wants to stop.
--------------------------------------------------------------------------------
-- One recorded stream, dumped verbatim: the parallel arrays as they are, one
-- event per row. This is the raw material for offline replay, so it is not
-- summarised -- a summary of a stream is what the Review tab is for. Shared by
-- the ring of 8 and (v0.9.1) by every pull of a run, which passes `extra` to
-- say which run and which pull the stream belongs to.
local function DumpRecording(add, r, n, extra)
    add("# recording " .. n, r.id or "", r.zone or "",
        string.format("%.1f", r.dur or 0), "pool " .. (r.pool or 0),
        (r.ownCasts or 0) .. " casts", (r.spent or 0) .. " mana",
        string.format("foreign %.0f%%", (r.foreignShare or 0) * 100),
        r.truncated and "TRUNCATED" or "", r.pinned and "pinned" or "",
        (r.auraN or 0) .. " auras" .. (r.auraTruncated and " (debuffs truncated)" or ""),
        extra or "")
    add("# roster")
    add("idx", "name", "class", "role", "roleSource", "maxHP", "tracked")
    local trackedSet = {}
    for _, idx in ipairs(r.tracked or {}) do trackedSet[idx] = true end
    for i, e in ipairs(r.roster or {}) do
        add(i, e.name or "", e.class or "", e.role or "", e.roleSource or "",
            e.maxHP or -1, trackedSet[i] and "y" or "")
    end
    local init = r.initial or {}
    add("# initial", "mana " .. (init.mana or 0), "base " .. (init.apiBase or 0),
        "casting " .. (init.apiCasting or 0), init.form or "?")
    for _, a in ipairs(init.auras or {}) do
        add("aura", a.target, a.spellID, a.stacks, string.format("%.1f", a.remaining or 0))
    end
    for _, b in ipairs(init.buffs or {}) do
        add("buff", b.spellID or 0, b.name or "", string.format("%.1f", b.remaining or 0))
    end
    add("# precasts")
    add("t", "spellID", "cost", "tgt", "hpAtCast", "form")
    for _, c in ipairs(r.precasts or {}) do
        add(string.format("%.2f", c[1]), c[2], c[3], c[4],
            string.format("%.3f", c[5] or -1), c[6])
    end
    add("# ev")
    add("t", "kind", "tgt", "amt", "x")
    local ev = r.ev or {}
    for i = 1, #(ev.t or {}) do
        add(string.format("%.2f", ev.t[i]), ev.kind[i], ev.tgt[i],
            string.format("%.0f", ev.amt[i] or 0), ev.x[i])
    end
    add("# hp")
    local hp = r.hp or {}
    local head = { "t" }
    for _, idx in ipairs(r.tracked or {}) do head[#head + 1] = "hp" .. idx end
    for _, idx in ipairs(r.tracked or {}) do head[#head + 1] = "max" .. idx end
    add(unpack(head))
    for i = 1, #(hp.t or {}) do
        local row = { string.format("%.1f", hp.t[i]) }
        for _, idx in ipairs(r.tracked or {}) do row[#row + 1] = hp.hp[idx][i] or -1 end
        for _, idx in ipairs(r.tracked or {}) do row[#row + 1] = hp.max[idx][i] or -1 end
        add(unpack(row))
    end
    add("# mana")
    add("t", "v", "base", "cast")
    local mn = r.mana or {}
    for i = 1, #(mn.t or {}) do
        add(string.format("%.1f", mn.t[i]), mn.v[i],
            string.format("%.2f", mn.base[i] or 0), string.format("%.2f", mn.cast[i] or 0))
    end
end

function MD:Export()
    local out = {}
    local function add(...) out[#out + 1] = table.concat({ ... }, "\t") end
    add("# manademon " .. MD.version, MD.player.charKey, MD.player.class .. " " .. MD.player.level,
        date("%Y-%m-%d %H:%M"), MD.db.healAmountGross == nil and "amount:unknown"
            or (MD.db.healAmountGross and "amount:gross" or "amount:net"))

    add("# fights")
    add("t", "zone", "dur", "spent", "netMp5", "healed", "overhealed", "oomAt")
    for _, f in ipairs(MD.fightHistory or {}) do
        add(f.t or "", f.zone or "", string.format("%.1f", f.duration or 0),
            string.format("%.0f", (f.avgSpendRate or 0) * (f.duration or 0)),
            string.format("%.0f", f.netMp5 or 0), f.healed or "", f.overhealed or "",
            f.oomAt and string.format("%.1f", f.oomAt) or "")
    end

    if MD.Overheal and MD.Overheal.stats then
        add("# overheal")
        add("key", "n", "healed", "overhealed")
        local keys = {}
        for k in pairs(MD.Overheal.stats) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local st = MD.Overheal.stats[k]
            add(k, st.n, string.format("%.0f", st.h), string.format("%.0f", st.o))
        end
    end

    if MD.Targets then
        add("# roster")
        add("name", "class", "role", "roleSource", "kind")
        for _, row in ipairs(MD.Targets:ExportRows()) do out[#out + 1] = row end
    end

    -- Recorded streams (v0.7.2), the ring of 8.
    if MD.FightRecorder then
        for n, r in ipairs(MD.FightRecorder:List()) do DumpRecording(add, r, n) end
    end

    -- Runs (v0.9.1): the container, then every pull it kept. The run's own
    -- arrays are the GAPS -- mana across the whole run, the drinks with the mana
    -- either side of them, deaths, zone changes -- which is the half a single
    -- fight's stream cannot hold.
    if MD.RunRecorder then
        local RR = MD.RunRecorder
        for n, run in ipairs(RR:List()) do
            local st = run.stats or {}
            add("# run " .. n, run.id or "", run.name or "", run.zone or "",
                string.format("%.1f", run.dur or 0), "pool " .. (run.pool or 0),
                (st.pulls or 0) .. " pulls", (st.recorded or 0) .. " recorded",
                string.format("combat %.0f%%", (st.combatPct or 0) * 100),
                (st.drinks or 0) .. " drinks", st.drinkRate and string.format("%.1f mana/s", st.drinkRate) or "no rate",
                (st.deaths or 0) .. " deaths", (st.spent or 0) .. " mana",
                run.truncated and "TRUNCATED" or "", run.pinned and "pinned" or "",
                run.stopReason or "")
            add("# run ev")
            add("t", "kind", "name", "a", "b")
            local ev = run.ev or {}
            for i = 1, #(ev.t or {}) do
                add(string.format("%.1f", ev.t[i]), ev.kind[i],
                    RR.KIND_NAMES[ev.kind[i]] or "?", string.format("%.0f", ev.a[i] or 0),
                    string.format("%.3f", ev.b[i] or 0))
            end
            add("# run mana")
            add("t", "v")
            local mn = run.mana or {}
            for i = 1, #(mn.t or {}) do add(string.format("%.1f", mn.t[i]), mn.v[i]) end
            for k, pull in ipairs(run.pulls or {}) do
                DumpRecording(add, pull, k, string.format("run %s pull %d%s", tostring(run.id), k,
                    pull.short and " short" or ""))
            end
        end
    end

    if MD.Calibration and MD.Calibration.ExportRows then
        add("# calibration")
        add("spellID", "kind", "n", "obs", "pred")
        for _, row in ipairs(MD.Calibration:ExportRows()) do out[#out + 1] = row end
    end
    return out
end

function MD:RunCalibrate()
    if not MD.Calibration then return end
    local lines = MD.Calibration:Report()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon calibration: model vs your heals", table.concat(lines, "\n"))
        MD:Print("calibration table ready - a ratio of 1.000 means the model matched the server exactly.")
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
end

function MD:RunExport()
    local lines = MD:Export()
    if MD.ShowCopyPopup then
        MD:ShowCopyPopup("ManaDemon export (TSV)", table.concat(lines, "\n"))
        MD:Print(string.format("export ready (%d lines) - Ctrl+C in the box.", #lines))
    else
        for _, line in ipairs(lines) do MD:Print(line) end
    end
end

--------------------------------------------------------------------------------
-- FSR anchor test: log every player mana change with a timestamp for 15s.
--------------------------------------------------------------------------------
local fsrLogging = false
local fsrT0, fsrLast = 0, 0

-- Registered once; inert unless a test is running.
MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not fsrLogging or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    if cur ~= fsrLast then
        MD:Print(string.format("  t+%5.2fs  %+d  (-> %d)", GetTime() - fsrT0, cur - fsrLast, cur))
        fsrLast = cur
    end
end)

function MD:RunFSRTest()
    if fsrLogging then return end
    fsrLogging = true
    fsrT0 = GetTime()
    fsrLast = UnitPower("player", 0)
    MD:Print("fsrtest: logging mana changes for 15s — cast one spell now.")
    C_Timer.After(15, function()
        fsrLogging = false
        MD:Print("fsrtest: done.")
    end)
end

--------------------------------------------------------------------------------
-- Idle regen test (/md regentest [seconds]): does the RAW GetManaRegen()
-- include Dreamstate? Stand idle at partial mana, no drink, no casting. The
-- window starts once the five-second rule has ended (so the API side is a
-- single rate), observed mana gain is compared with the raw API base rate
-- and with the model rate (API + whatever RegenModel adds), and the raw
-- difference is matched against the talent's expected contribution
-- (4/7/10% of Intellect per 5s). Mana spent or a drink buff during the
-- window invalidates the result (reported, not hidden).
--
-- It also prints a TICK HISTOGRAM: every distinct gain size with its count and
-- median spacing. That is what identifies an energize the API is blind to --
-- the BF-1 log carried a constant 17 every 2.00s next to the spirit tick
-- (42 mp5, all 28 minutes, in and out of combat) that GetManaRegen never
-- reported. A size is what a source is; a cadence is which source it is.
-- See docs/TESTING.md 16.
--------------------------------------------------------------------------------
local DREAMSTATE_PCT = { 0.04, 0.07, 0.10 }
local regenTest = nil

local function IsDrinking()
    return MD:HasBuff("Drink") or MD:HasBuff("Refreshment") or MD:HasBuff("Food & Drink")
end

--------------------------------------------------------------------------------
-- Storing the measurement (v0.9.0, corrected in v0.9.5). What is stored is the
-- RESIDUAL: the observed regen rate minus what the client reports, minus what
-- the model already adds for Dreamstate, minus anything the histogram
-- identified as somebody else's 3s party energize.
--
--   unreported = observed - GetManaRegen - Dreamstate - party
--
-- The first version stored the SIZE OF THE TICK instead, off a cluster the
-- histogram had labelled "a 2s beat the API does not report". On a druid with
-- Dreamstate that label is wrong: Dreamstate rides inside the same server tick,
-- so the one and only tick reads ~14% above the raw API rate, gets called a
-- separate stream, and its whole size is stored. The author's character ended
-- up with 279 mp5 of "unreported" regen on top of a 244 mp5 API rate -- a 556
-- mp5 datatext for a druid regenerating 279. A term the API does not report can
-- only ever be what is LEFT OVER after everything that is reported; anything
-- else double counts by construction.
--
-- Stored only from a clean window: nothing spent, no drink, out of the
-- five-second rule throughout, enough ticks to average, and SOLO -- in a group
-- somebody's blessing lands in the same bucket. Below MP5_FLOOR the residual is
-- indistinguishable from the test's own precision, so nothing is stored and any
-- previous measurement is CLEARED: "the model already accounts for everything"
-- is a result, and leaving a stale number in place would hide it.
--------------------------------------------------------------------------------
local MP5_MIN_TICKS = 6
local MP5_FLOOR = 1.0     -- mana/s (5 mp5). The tick sizes vary by +-1 and a 30s
                          -- window holds ~15 of them, so the test itself is good
                          -- to about 0.5/s; half of that again is noise.

local function ClearMeasured(reason)
    if not (MD.cdb and MD.cdb.mp5) then return false end
    local prev = MD.cdb.mp5
    MD.cdb.mp5 = nil
    if MD.Regen then MD.Regen:Refresh() end
    MD:Print(string.format("regentest: |cffffcc00cleared|r the stored %d mp5 (measured %s) - %s.",
        prev.mp5 or 0, date("%Y-%m-%d", prev.at or 0), reason))
    return true
end

function MD:ClearMeasuredMp5()
    if not ClearMeasured("you asked") then
        MD:Print("regentest: nothing stored to clear.")
    end
end

-- t: the finished test. observed/api/ds/party are all mana per second.
local function StoreMeasuredMp5(t, elapsed, observed, api, ds, party)
    local solo = (GetNumGroupMembers and GetNumGroupMembers() or 1) <= 1
    local why = nil
    if not MD.cdb then why = "no character database yet"
    elseif t.spent > 0 then why = string.format("%d mana was spent during the window", t.spent)
    elseif t.drank then why = "a drink/food buff was up"
    elseif t.fsrTime > 0.5 then why = string.format("%.1fs of the window were inside the 5SR", t.fsrTime)
    elseif t.ticks < MP5_MIN_TICKS then why = string.format("%d regen tick(s) seen, needs %d", t.ticks, MP5_MIN_TICKS)
    elseif not solo then why = "you are in a group - somebody else's blessing would be measured in"
    end
    if why then
        MD:Print("regentest: not stored - " .. why .. ". Nothing was changed.")
        return
    end

    local unreported = observed - api - ds - party
    MD:Print(string.format("regentest: observed %.2f/s = API %.2f + Dreamstate %.2f%s + unreported %+.2f (%+d mp5)",
        observed, api, ds, party > 0 and string.format(" + party %.2f", party) or "",
        unreported, unreported * 5 + (unreported >= 0 and 0.5 or -0.5)))

    if unreported > api and api > 0 then
        MD:Print(string.format("regentest: |cffff4444not stored|r - the leftover (%d mp5) is larger than everything " ..
            "the client reports (%d mp5). That is a broken measurement, not a discovery.",
            unreported * 5 + 0.5, api * 5 + 0.5))
        return
    end
    if unreported < MP5_FLOOR then
        MD:Print(string.format("regentest: nothing to store - the model already accounts for everything the client " ..
            "regenerates (leftover %+d mp5, under the %d mp5 floor this test can resolve).",
            unreported * 5 + (unreported >= 0 and 0.5 or -0.5), MP5_FLOOR * 5))
        ClearMeasured("the leftover is now inside the noise floor")
        return
    end

    local prev = MD.cdb.mp5
    MD.cdb.mp5 = {
        perSec = unreported, mp5 = math.floor(unreported * 5 + 0.5), at = time(),
        source = "regentest", ticks = t.ticks, level = UnitLevel("player") or 0,
        hint = GetRealZoneText and GetRealZoneText() or nil,
        window = elapsed, solo = solo,
        observed = observed, api = api, dreamstate = ds, party = party,
    }
    if MD.Regen then MD.Regen:Refresh() end
    MD:Print(string.format("regentest: |cff33ff66stored %d mp5|r (%.2f/s left over after the API and Dreamstate, " ..
        "%d ticks over %.0fs) - was: %s.", MD.cdb.mp5.mp5, unreported, t.ticks, elapsed,
        prev and string.format("%d mp5 measured %s", prev.mp5 or 0, date("%Y-%m-%d", prev.at or 0)) or "none"))
end

local function FinishRegenTest(reason)
    local t = regenTest
    regenTest = nil
    if not t then return end
    if not t.t0 then
        MD:Print("regentest: stopped while waiting for the 5SR to end (" .. reason .. ") - nothing measured.")
        return
    end
    local elapsed = GetTime() - t.t0
    if elapsed < 4 then
        MD:Print(string.format("regentest: stopped after %.1fs (%s) - too short, nothing measured.", elapsed, reason))
        return
    end
    local observed = t.gained / elapsed
    local api = t.apiSum / elapsed        -- time-weighted raw GetManaRegen base
    local model = t.modelSum / elapsed    -- time-weighted RM.base (API + unreported)
    local diff = observed - api
    local intellect = UnitStat("player", 4) or 0
    local dsRank = MD:TalentRank("Dreamstate")
    local dsRate = (DREAMSTATE_PCT[dsRank] or 0) * intellect / 5

    MD:Print(string.format("regentest: %.0fs (%s), %d mana in %d ticks -> observed %.2f/s (%d mp5); " ..
        "raw API %.2f/s (%d mp5); diff %+.2f/s (%+d mp5); model %.2f/s (%d mp5), observed - model %+.2f/s",
        elapsed, reason, t.gained, t.ticks, observed, observed * 5 + 0.5, api, api * 5 + 0.5, diff, diff * 5,
        model, model * 5 + 0.5, observed - model))
    if t.spent > 0 then
        MD:Print(string.format("|cffff4444WARNING|r %d mana was spent during the test (5SR reset) - result unreliable.", t.spent))
    end
    if t.fsrTime > 0.5 then
        MD:Print(string.format("|cffff4444WARNING|r %.1fs of the window were inside the 5SR - result unreliable.", t.fsrTime))
    end
    if t.drank then
        MD:Print("|cffff4444WARNING|r a drink/food buff was up during the test - result unreliable.")
    end
    if t.ticks < 3 then
        MD:Print("|cffff4444WARNING|r fewer than 3 regen ticks observed - were you at full mana?")
    end
    -- Tick histogram. The whole point of a size/cadence table is that a
    -- periodic energize the API does not report (item mp5, Blessing of Wisdom,
    -- a party effect) shows up as its OWN constant next to the spirit tick.
    -- Sizes are clustered within +-1, because an energize proportional to
    -- somebody else's damage jitters by a point or two while a mana tick does
    -- not, and each cluster is tested for a beat the way the BF-1 log was
    -- decomposed by hand: the share of its events that have a partner exactly
    -- one period later. Interleaved phases of the same source ruin a median
    -- spacing (four overlapping 3s streams read as ~1s) but not this.
    local sizes = {}
    for size in pairs(t.sizes) do sizes[#sizes + 1] = size end
    table.sort(sizes)
    local clusters = {}
    for _, size in ipairs(sizes) do
        local b = t.sizes[size]
        local c = clusters[#clusters]
        if not (c and size - c.hi <= 1) then
            c = { lo = size, hi = size, n = 0, sum = 0, ts = {} }
            clusters[#clusters + 1] = c
        end
        c.hi, c.n, c.sum = size, c.n + b.n, c.sum + size * b.n
        for _, ts in ipairs(b.ts) do c.ts[#c.ts + 1] = ts end
    end
    table.sort(clusters, function(a, b) return a.n > b.n end)

    -- The rate one stream of ticks actually carries, without the window's edges
    -- in it. Dividing a cluster's whole mana by the whole window is biased by up
    -- to one tick -- 111 mana over 30s is 3.7/s, which is bigger than the
    -- leftover this test is trying to resolve. Between the FIRST and LAST tick
    -- of a stream there are exactly n-1 intervals, so dropping one tick's worth
    -- of mana and dividing by that span is unbiased.
    --
    -- Interleaved phases of one source (four overlapping 3s streams in the BF-1
    -- log) need p ticks dropped, not one: p is how many the cluster has more
    -- than a single phase could fit in its own span.
    local function ClusterRate(c, period)
        if c.n < 2 then return 0 end
        local span = c.ts[#c.ts] - c.ts[1]
        if span <= 0 then return 0 end
        local mean = c.sum / c.n
        local phases = 1
        if period and period > 0 then
            local perPhase = span / period + 1
            if perPhase > 0.5 then phases = math.max(1, math.floor(c.n / perPhase + 0.5)) end
        end
        return (c.sum - phases * mean) / span
    end

    -- share of events with a partner at +period (+-0.15s)
    local function beat(ts, period)
        local hits = 0
        for i = 1, #ts do
            for j = i + 1, #ts do
                local d = ts[j] - ts[i]
                if d > period + 0.15 then break end
                if d >= period - 0.15 then hits = hits + 1; break end
            end
        end
        return hits / #ts
    end

    -- Mana per second that belongs to somebody else: a cluster on a 3s beat is
    -- a party energize (the BF-1 log's second stream), and it must not end up
    -- in this character's own bucket.
    local party, ticked = 0, 0
    if #clusters > 0 then
        -- What a 2s tick of everything the model ALREADY knows about weighs.
        -- Dreamstate is not a separate stream: the server folds it into the
        -- same regen tick, so comparing against the raw API rate alone reads the
        -- one true tick as an unexplained beat -- which is the bug that stored
        -- 279 mp5 on a character regenerating 279 in total (v0.9.5).
        local expected = (t.apiSum / elapsed + dsRate) * 2
        MD:Print("regentest: tick histogram (size x count, cadence) -")
        for i = 1, math.min(#clusters, 6) do
            local c = clusters[i]
            table.sort(c.ts)
            local mean = c.sum / c.n
            local label = c.lo == c.hi and tostring(c.lo) or string.format("%d-%d", c.lo, c.hi)
            local b2, b3 = beat(c.ts, 2.0), beat(c.ts, 3.0)
            local period = (b3 >= 0.4 and b3 > b2) and 3.0 or (b2 >= 0.4 and 2.0 or nil)
            local rate = ClusterRate(c, period)
            ticked = ticked + rate
            local note
            if expected > 0 and math.abs(mean - expected) <= 0.12 * expected then
                note = dsRate > 0 and "the regen tick the model expects (spirit + gear + Dreamstate)"
                    or "the reported spirit tick"
            elseif b3 >= 0.4 and b3 > b2 then
                note = string.format("a 3s beat - a party energize, not yours (%d mp5)", rate * 5 + 0.5)
                party = party + rate
            elseif b2 >= 0.4 then
                note = string.format("a 2s beat of %d mana - a stream of its own (%d mp5)", mean + 0.5, rate * 5 + 0.5)
            elseif c.n > 2 then
                note = string.format("no clean beat (2s %d%%, 3s %d%%)", b2 * 100, b3 * 100)
            else
                note = "seen too few times to read a cadence"
            end
            MD:Print(string.format("    %7s x %-3d  %s", label, c.n, note))
        end
    end
    -- the rate the TICKS carry (edge-free), not the window's endpoints
    StoreMeasuredMp5(t, elapsed, ticked > 0 and ticked or observed, api, dsRate, party)

    if dsRank == 0 then
        MD:Print(string.format("no Dreamstate talent: diff should be ~0 (it is %+.2f/s). A large positive diff means " ..
            "GetManaRegen misses some regen source.", diff))
    elseif diff >= 0.5 * dsRate then
        MD:Print(string.format("|cffffcc00VERDICT|r raw GetManaRegen EXCLUDES Dreamstate: diff %.2f/s vs expected %.2f/s " ..
            "(Dreamstate %d = %d%% of %d int / 5s). The model adds %.2f/s for it.", diff, dsRate, dsRank,
            DREAMSTATE_PCT[dsRank] * 100, intellect, MD.Regen.unreported))
    else
        MD:Print(string.format("|cffffcc00VERDICT|r raw GetManaRegen INCLUDES Dreamstate: diff %.2f/s, it would be ~%.2f/s " ..
            "if excluded (Dreamstate %d, %d int). The model's %.2f/s Dreamstate term would then double count!",
            diff, dsRate, dsRank, intellect, MD.Regen.unreported))
    end
end

-- Registered once; inert unless a test is measuring.
MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not regenTest or not regenTest.t0 or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    local delta = cur - regenTest.last
    regenTest.last = cur
    if delta > 0 then
        regenTest.gained = regenTest.gained + delta
        regenTest.ticks = regenTest.ticks + 1
        local b = regenTest.sizes[delta]
        if not b then b = { n = 0, ts = {} }; regenTest.sizes[delta] = b end
        b.n = b.n + 1
        b.ts[#b.ts + 1] = GetTime()
        if cur >= UnitPowerMax("player", 0) then
            FinishRegenTest("mana full")
        end
    elseif delta < 0 then
        regenTest.spent = regenTest.spent + (-delta)
    end
end)

MD:OnTick(function(dt)
    if not regenTest then return end
    local RM = MD.Regen
    if UnitAffectingCombat("player") then
        FinishRegenTest("entered combat")
        return
    end
    if not regenTest.t0 then
        if RM:InFSR() then return end
        regenTest.t0 = GetTime()
        regenTest.last = UnitPower("player", 0)
        MD:Print(string.format("regentest: 5SR over, measuring for %ds now - stand still.", regenTest.duration))
        return
    end
    regenTest.apiSum = regenTest.apiSum + RM.apiBase * dt
    regenTest.modelSum = regenTest.modelSum + RM.base * dt
    if RM:InFSR() then regenTest.fsrTime = regenTest.fsrTime + dt end
    if IsDrinking() then regenTest.drank = true end
    if GetTime() - regenTest.t0 >= regenTest.duration then
        FinishRegenTest("done")
    end
end)

function MD:RunRegenTest(seconds)
    if tostring(seconds or ""):lower():match("^clear") then
        MD:ClearMeasuredMp5()
        return
    end
    if regenTest then
        MD:Print("regentest: already running.")
        return
    end
    seconds = tonumber(seconds) or 30
    if seconds < 10 then seconds = 10 end
    if UnitAffectingCombat("player") then
        MD:Print("regentest: leave combat first.")
        return
    end
    local mana, manaMax = UnitPower("player", 0), UnitPowerMax("player", 0)
    if mana >= manaMax then
        MD:Print("regentest: you are at full mana - spend some first (a few casts), then run it again.")
        return
    end
    local RM = MD.Regen
    regenTest = {
        t0 = nil, duration = seconds, last = mana,
        gained = 0, ticks = 0, spent = 0, apiSum = 0, modelSum = 0, fsrTime = 0, drank = IsDrinking(),
        sizes = {}, -- [gain] = { n, ts = {} }
    }
    MD:Print(string.format("regentest: %ds - do not cast or drink. Mana %d/%d, raw API base %.2f/s, model %.2f/s, " ..
        "Dreamstate %d, int %d, %s%s.", seconds, mana, manaMax, RM.apiBase, RM.base,
        MD:TalentRank("Dreamstate"), UnitStat("player", 4) or 0,
        MD.db.debug.enabled and "debug log on" or "debug log OFF (enable it in the Debug Console to keep the ticks)",
        RM:InFSR() and string.format("; waiting %.1fs for the 5SR to end", RM:FSRRemaining()) or ""))
end

--------------------------------------------------------------------------------
-- Spam test (/md spamtest): validates the dashboard's "To OOM" column. Arm
-- it, then chain-cast ONE spell until you are out of mana (or stop for 10s).
-- Counts the casts, the real per-cast drops and the regen that landed, and
-- compares with the prediction made from the mana you had when you armed it.
--------------------------------------------------------------------------------
local spamTest = nil

local function FinishSpamTest(reason)
    local t = spamTest
    spamTest = nil
    if not t then return end
    if t.casts == 0 then
        MD:Print("spamtest: no cast seen (" .. reason .. ").")
        return
    end
    local name = GetSpellInfo(t.spellID) or "?"
    local duration = (t.lastCastT or t.firstCastT) - t.firstCastT
    local interval = t.casts > 1 and duration / (t.casts - 1) or t.interval
    local avgDrop = t.spent / math.max(t.casts, 1)
    local mana = UnitPower("player", 0)
    MD:Print(string.format("spamtest (%s): %d casts of %s (%d) in %.1fs (%.2fs apart) - %d mana spent (%.1f per cast, live cost %d), " ..
        "%d regained; mana %d -> %d.", reason, t.casts, name, t.spellID, duration, interval, t.spent, avgDrop, t.liveCost, t.gained,
        t.armMana, mana))
    local predicted = MD.RankMath:CastsToOOM(t.liveCost, t.interval, t.armMana, t.castingRegen)
    local predictedReal = MD.RankMath:CastsToOOM(avgDrop, interval, t.armMana, t.gained / math.max(duration, 1))
    MD:Print(string.format("prediction from %d mana: %s casts (live cost %d, %.1fs interval, casting regen %.2f/s); " ..
        "with the MEASURED drop and regen it would be %s. Observed regen during the spam: %.2f/s.",
        t.armMana, predicted == math.huge and "inf" or tostring(predicted), t.liveCost, t.interval, t.castingRegen,
        predictedReal == math.huge and "inf" or tostring(predictedReal), t.gained / math.max(duration, 1)))
    if math.abs(avgDrop - t.liveCost) > 1 then
        MD:Print(string.format("|cffffaa33NOTE|r the real drop per cast (%.1f) differs from the live cost (%d) - that is the column's error source.",
            avgDrop, t.liveCost))
    end
    if t.otherCasts > 0 then
        MD:Print(string.format("|cffffaa33NOTE|r %d cast(s) of other spells were mixed in and counted in the mana spent.", t.otherCasts))
    end
end

MD:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if not spamTest or unit ~= "player" or type(spellID) ~= "number" then return end
    local now = GetTime()
    if not spamTest.spellID then
        local cost = MD.SpellData:GetCost(spellID)
        if not cost or cost <= 0 then return end -- ignore free/unknown (form shift etc.)
        spamTest.spellID = spellID
        spamTest.liveCost = cost
        local _, _, _, castMs = GetSpellInfo(spellID)
        spamTest.interval = math.max((castMs or 0) / 1000, 1.5)
        spamTest.firstCastT = now
        MD:Print(string.format("spamtest: counting %s (live cost %d, %.1fs interval) - keep casting until OOM.",
            GetSpellInfo(spellID) or "?", cost, spamTest.interval))
    end
    if spellID == spamTest.spellID then
        spamTest.casts = spamTest.casts + 1
        spamTest.lastCastT = now
    else
        spamTest.otherCasts = spamTest.otherCasts + 1
    end
end)

MD:On("UNIT_POWER_UPDATE", function(unit, powerType)
    if not spamTest or unit ~= "player" or powerType ~= "MANA" then return end
    local cur = UnitPower("player", 0)
    local delta = cur - spamTest.last
    spamTest.last = cur
    if delta < 0 then
        spamTest.spent = spamTest.spent - delta
    elseif delta > 0 then
        spamTest.gained = spamTest.gained + delta
    end
end)

MD:OnTick(function()
    if not spamTest then return end
    local now = GetTime()
    if spamTest.spellID then
        if UnitPower("player", 0) < spamTest.liveCost then
            FinishSpamTest("OOM")
        elseif now - spamTest.lastCastT > 10 then
            FinishSpamTest("stopped")
        end
    elseif now - spamTest.armT > 30 then
        FinishSpamTest("timed out waiting for the first cast")
    end
end)

function MD:RunSpamTest()
    if spamTest then
        MD:Print("spamtest: already armed.")
        return
    end
    local mana = UnitPower("player", 0)
    spamTest = {
        armT = GetTime(), armMana = mana, last = mana,
        castingRegen = MD.Regen.casting,
        casts = 0, otherCasts = 0, spent = 0, gained = 0,
    }
    MD:Print(string.format("spamtest: armed at %d mana (casting regen %.2f/s). Chain-cast ONE spell now until OOM; " ..
        "the dashboard's To OOM column for it should match.", mana, MD.Regen.casting))
end

--------------------------------------------------------------------------------
-- /md simrun -- self-tests for Engine/SimModel.lua (docs/SPEC-v0.7.md 3.8).
--
-- Nine assertions about mechanics nobody can eyeball once the engine is inside
-- a search: does a Rejuvenation heal what the dashboard says it heals, does a
-- refresh drop the ticks it should, does one Lifebloom stack bloom once, does
-- Swiftmend eat the right HoT, does a corpse stop taking heals, does the
-- five-second rule switch rates at 5.0, does the GCD hold two instants 1.5s
-- apart, and does Run allocate. Everything downstream trusts these.
--------------------------------------------------------------------------------
local function SimTargets(n, maxHP, hp0)
    local t = {}
    for i = 1, n do t[i] = { name = "T" .. i, maxHP = maxHP, hp0 = hp0, tracked = true } end
    return t
end

local function Near(a, b, tol)
    return math.abs((a or 0) - (b or 0)) <= tol
end

function MD:RunSimRun()
    local SM, RM, SD = MD.SimModel, MD.RankMath, MD.SpellData
    if not (SM and RM and SD) then MD:Print("simrun: engine not loaded.") return end

    -- The kit's caster half is built with inTree = false, so the rows it is
    -- compared against must be too -- otherwise running this in Tree form
    -- fails every heal assertion for the wrong reason.
    local kit = RM:SpellKit()
    local ctx = RM:Context({ live = true, healer = { inTree = false } })
    local out, fails = {}, 0
    local function Check(name, ok, detail)
        if not ok then fails = fails + 1 end
        out[#out + 1] = string.format("%-28s %s%s", name, ok and "ok" or "FAIL",
            detail and (" - " .. detail) or "")
    end

    local BIG = 1000000
    local rejuvID = SD.maxRank.Rejuvenation
    local regrowthID = SD.maxRank.Regrowth
    local lifebloomID = SD.maxRank.Lifebloom
    local swiftmendID = SD.maxRank.Swiftmend
    local caster = kit.caster

    -- 1. one Rejuvenation heals what the dashboard row says it heals
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local row = RM:RowFor(rejuvID, ctx)
        local sc = { dur = 30, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } }))
        Check("1 rejuv total heal", Near(r.healed, row.heal, 1),
            string.format("sim %.1f vs row %.1f", r.healed, row.heal))
        Check("1 rejuv mana", Near(r.manaSpent, e.cost, 0.01),
            string.format("spent %.0f vs cost %d", r.manaSpent, e.cost))
    else
        Check("1 rejuv", false, "Rejuvenation not known")
    end

    -- 2. chain-cast to OOM matches the dashboard's closed form
    if regrowthID and caster[regrowthID] then
        local e = caster[regrowthID]
        local mana = math.max(e.cost * 6, 8000)
        local regen = ctx.castingRegen
        local expected = RM:CastsToOOM(e.cost, e.cast, mana, regen)
        local sc = { dur = (expected + 2) * e.cast, pool = mana,
                     initial = { mana = mana, apiBase = regen, apiCasting = regen, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ChainPlan(regrowthID, 1, kit, "caster"))
        Check("2 chain casts to OOM", r.casts == expected,
            string.format("sim %d vs closed form %s", r.casts, tostring(expected)))
    else
        Check("2 chain casts to OOM", false, "Regrowth not known")
    end

    -- 3. a refresh drops the ticks that were still pending
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local expected = 2 + e.ticks
        local sc = { dur = 40, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 }, { 6.5, rejuvID, e.cost, 1 } }))
        Check("3 refresh loses ticks", r.ticks == expected,
            string.format("%d ticks, expected %d", r.ticks, expected))
    end

    -- 4. a Lifebloom stack blooms exactly once
    if lifebloomID and caster[lifebloomID] then
        local e = caster[lifebloomID]
        local sc = { dur = 25, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, lifebloomID, e.cost, 1 },
                                             { 1, lifebloomID, e.cost, 1 },
                                             { 2, lifebloomID, e.cost, 1 } }))
        Check("4 lifebloom blooms once", r.blooms == 1, string.format("%d bloom(s)", r.blooms))
    end

    -- 5. Swiftmend eats Regrowth before Rejuvenation
    if swiftmendID and caster[swiftmendID] and caster[swiftmendID].swiftmendRegrowth then
        local sm = caster[swiftmendID]
        local sc = { dur = 25, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, regrowthID, caster[regrowthID].cost, 1 },
                                             { 0.1, rejuvID, caster[rejuvID].cost, 1 },
                                             { 0.2, swiftmendID, sm.cost, 1 } }))
        local got = r.healByFamily.Swiftmend or 0
        Check("5 swiftmend eats regrowth", Near(got, sm.swiftmendRegrowth, 1),
            string.format("%.0f vs regrowth %.0f / rejuv %.0f", got,
                sm.swiftmendRegrowth or 0, sm.swiftmendRejuv or 0))
    end

    -- 6. nothing lands on a corpse
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local sc = { dur = 20, pool = 50000, initial = { mana = 50000, form = "caster" },
                     targets = { { name = "T1", maxHP = 1000, hp0 = 1000, tracked = true } },
                     kit = kit, grace = 0, floor = 0,
                     ev = { t = { 1 }, kind = { MD.SimModel.K.DMG }, tgt = { 1 }, amt = { 5000 }, x = { 0 } } }
        local r = SM:Run(sc, SM.ScriptPlan({ { 2, rejuvID, e.cost, 1 } }))
        Check("6 no heals on a corpse", (r.healByFamily.Rejuvenation or 0) == 0 and r.deaths.n == 1,
            string.format("healed %.0f, deaths %d", r.healByFamily.Rejuvenation or 0, r.deaths.n))
    end

    -- 7. the five-second rule switches rates at 5.0
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local M0, B, C = 40000, 40, 10
        local sc = { dur = 12, pool = 100000,
                     initial = { mana = M0, apiBase = B, apiCasting = C, form = "caster" },
                     targets = SimTargets(1, BIG, 1), kit = kit, sampleT = { 5, 10 } }
        local r = SM:Run(sc, SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } }))
        local want5 = M0 - e.cost + C * 5
        local want10 = want5 + B * 5
        Check("7 5SR rate switch", Near(r.manaCurve[1], want5, 0.5) and Near(r.manaCurve[2], want10, 0.5),
            string.format("%.0f/%.0f vs %.0f/%.0f", r.manaCurve[1] or -1, r.manaCurve[2] or -1, want5, want10))
    end

    -- 8. the GCD holds two instants 1.5s apart
    if rejuvID and caster[rejuvID] then
        local function ChainFor(dur)
            local sc = { dur = dur, pool = 100000, initial = { mana = 100000, form = "caster" },
                         targets = SimTargets(1, BIG, 1), kit = kit }
            return SM:Run(sc, SM.ChainPlan(rejuvID, 1, kit, "caster")).casts
        end
        local a, b = ChainFor(1.4), ChainFor(1.6)
        Check("8 gcd 1.5s", a == 1 and b == 2, string.format("1.4s -> %d, 1.6s -> %d", a, b))
    end

    -- 9. Run's cost does not grow with the timeline.
    --
    -- Measured per run over many runs, not once: a single run right after a
    -- collect reports the collector's own bookkeeping as if it were ours (4.1 KB
    -- against a true 2.1). What matters is that a 1,500-event fight costs the
    -- same as an empty one -- the loop reads the recorded arrays by index and
    -- allocates nothing. The fixed ~2 KB is Run's own local closures, built
    -- once per call.
    if rejuvID and caster[rejuvID] then
        local e = caster[rejuvID]
        local n, reps = 1500, 50
        local evT, evK, evTg, evA, evX = {}, {}, {}, {}, {}
        for i = 1, n do
            evT[i], evK[i], evTg[i], evA[i], evX[i] = i * 0.02, MD.SimModel.K.FHEAL, 1, 10, 0
        end
        local heavy = { dur = 35, pool = 100000, initial = { mana = 100000, form = "caster" },
                        targets = SimTargets(1, BIG, 1), kit = kit,
                        ev = { t = evT, kind = evK, tgt = evTg, amt = evA, x = evX } }
        local light = { dur = 35, pool = 100000, initial = { mana = 100000, form = "caster" },
                        targets = SimTargets(1, BIG, 1), kit = kit }
        local script = SM.ScriptPlan({ { 0, rejuvID, e.cost, 1 } })
        local function PerRun(sc)
            SM:Run(sc, script)
            collectgarbage("collect")
            local before = collectgarbage("count")
            for _ = 1, reps do SM:Run(sc, script) end
            return (collectgarbage("count") - before) / reps
        end
        local heavyKB, lightKB = PerRun(heavy), PerRun(light)
        Check("9 run cost is flat", heavyKB < 4 and math.abs(heavyKB - lightKB) < 0.5,
            string.format("%.2f KB/run with %d events, %.2f KB/run with none", heavyKB, n, lightKB))
    end

    MD:Print(string.format("simrun: %d test(s), %s", #out,
        fails == 0 and "all ok" or (fails .. " FAILED")))
    for _, line in ipairs(out) do
        MD:Print("  " .. line)
        MD:Debug("sim", "simrun %s", line)
    end
end

--------------------------------------------------------------------------------
-- /md simreplay fixture -- replay Data/SimFixture_BF1.lua and report how well
-- the engine reproduces the mana curve the log actually recorded.
--
-- Three numbers, because they answer three different questions:
--   spend     the recorded costs, summed by the engine. Must be exact; if it
--             is not, the script or the cost handling is broken.
--   modelled  the fit using ONLY what GetManaRegen reports. This is what the
--             addon's own regen model can predict, and on BF-1 it is short by
--             design -- the log carries ~23 mana/s of periodic energize the
--             API never mentions (see the fixture header).
--   measured  the fit with that energize included. THIS is the engine gate
--             (mean <= 2%, max <= 5% of pool): five-second-rule handling,
--             per-cast deduction, ordering and curve shape, with the rate
--             argument taken out of the question.
--------------------------------------------------------------------------------
local function ReplayFixture(fx)
    local SM, RM = MD.SimModel, MD.RankMath
    local sampleT, sampleM = {}, {}
    for i, m in ipairs(fx.mana) do sampleT[i], sampleM[i] = m[1], m[2] end

    local targets = {}
    for i, r in ipairs(fx.roster or {}) do
        targets[i] = { name = r.name, role = r.role, maxHP = 10000, hp0 = 10000, tracked = false }
    end

    local function RunWith(energize)
        local sc = {
            dur = fx.dur, pool = fx.pool,
            initial = { mana = fx.initial.mana, apiBase = fx.initial.apiBase,
                        apiCasting = fx.initial.apiCasting, energize = energize,
                        form = fx.initial.form, auras = fx.initial.auras },
            targets = targets, forms = fx.forms, sampleT = sampleT,
            kit = RM:SpellKit(),
        }
        local r = SM:Run(sc, SM.ScriptPlan(fx.casts))
        local sum, worst, worstT = 0, 0, 0
        for i = 1, #sampleT do
            local d = math.abs((r.manaCurve[i] or 0) - sampleM[i])
            sum = sum + d
            if d > worst then worst, worstT = d, sampleT[i] end
        end
        return sum / math.max(1, #sampleT) / fx.pool, worst / fx.pool, worstT, r
    end

    -- Order matters: the result belongs to the pool slot, so the run whose
    -- result is still read must be the last one.
    local mMean, mMax, mAt = RunWith(0)
    local eMean, eMax, eAt, eRes = RunWith(fx.initial.energize or 0)

    local recorded = 0
    for _, c in ipairs(fx.casts) do recorded = recorded + (c[3] or 0) end

    local lines = {
        string.format("fixture %s: %d casts, %.1fs, pool %d", fx.name or "?", #fx.casts, fx.dur, fx.pool),
        string.format("  spend    sim %.0f vs recorded %d  (%s)", eRes.manaSpent, recorded,
            math.abs(eRes.manaSpent - recorded) < 1 and "exact" or "MISMATCH"),
        string.format("  modelled mean %.1f%%  max %.1f%% at %.1fs   (GetManaRegen only)",
            mMean * 100, mMax * 100, mAt),
        string.format("  measured mean %.1f%%  max %.1f%% at %.1fs   (+ %.1f mana/s energize) -> %s",
            eMean * 100, eMax * 100, eAt, fx.initial.energize or 0,
            (eMean <= 0.02 and eMax <= 0.05) and "PASS" or "FAIL"),
    }
    return lines
end

function MD:RunSimReplay(arg)
    if not (MD.SimModel and MD.RankMath) then MD:Print("simreplay: engine not loaded.") return end
    if arg == nil or arg == "" or arg == "fixture" or arg == "bf1" then
        local fx = MD.SimFixtures and MD.SimFixtures.BF1
        if not fx then MD:Print("simreplay: no fixture loaded.") return end
        for _, line in ipairs(ReplayFixture(fx)) do
            MD:Print(line)
            MD:Debug("sim", "simreplay %s", line)
        end
        return
    end
    local rec, label = MD:GetRecording(arg)
    if not rec then
        MD:Print("simreplay: no recording " .. tostring(arg) .. " (try /md simreplay fixture).")
        return
    end
    for _, line in ipairs(MD:ValidationReport(rec, label)) do
        MD:Print(line)
        MD:Debug("sim", "simreplay %s", line)
    end
end

--------------------------------------------------------------------------------
-- The validation report for one recording: whether the engine can reproduce the
-- fight, gate by gate, with each threshold's provenance. This is what the
-- Review tab's tooltip shows and what decides whether the Coach is allowed to
-- say anything at all about this pull.
--------------------------------------------------------------------------------
function MD:ValidationReport(rec, n)
    local v = MD.SimModel:Validate(rec)
    if not v then return { "simreplay: nothing to validate." } end
    local out = {
        string.format("recording %s: %s, %.0fs, %d casts, %d mana%s", tostring(n or 1),
            rec.zone or "?", rec.dur or 0, rec.ownCasts or 0, rec.spent or 0,
            rec.truncated and " (stream truncated)" or ""),
        string.format("  verdict: %s", v.ok and "REPLAYS - safe to coach from"
            or "does NOT replay - nothing will be suggested from this fight"),
    }
    for _, g in ipairs(v.gates) do
        out[#out + 1] = string.format("  %-18s %-4s %s", g.name, g.ok and "ok" or "FAIL", g.text)
    end
    if (v.energize or 0) > 0 then
        out[#out + 1] = string.format("  energize: %.2f/s (%d mp5) the API does not report%s",
            v.energize, v.energize * 5 + 0.5,
            v.energizeAssumed and " - ASSUMED: this recording predates the measurement, so the current one was applied"
                or " - recorded with the fight")
    end
    for i, why in pairs(v.excluded) do
        local name = rec.roster[i] and rec.roster[i].name or ("target " .. i)
        out[#out + 1] = string.format("  excluded: %s - %s", name, why)
    end
    for _, g in ipairs(v.gates) do
        if not g.ok and g.why then
            out[#out + 1] = string.format("  why %s is %s: %s", g.name,
                g.limit and string.format("%.2f", g.limit) or "set where it is", g.why)
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- /md coachrun [n]: the whole run through the engine (docs/SPEC-v0.9.md 5).
-- The same search as /md coach, one plan for the dungeon, scored on time before
-- mana -- because in a five-man mana is only worth the time it saves.
--------------------------------------------------------------------------------
function MD:RunCoachRun(arg)
    if not (MD.SimPlanner and MD.RunRecorder) then MD:Print("coachrun: not loaded.") return end
    arg = tostring(arg or ""):gsub("%s+", "")
    if arg == "cancel" then
        if MD.runSearch then MD.runSearch:Cancel(); MD.runSearch = nil
        else MD:Print("coachrun: nothing running.") end
        return
    end
    -- "/md coachrun 2 force": coach every pull, the ones that do not replay
    -- included. Same escape hatch a single fight has had since v0.9.6.
    local force = arg:find("force") ~= nil
    arg = arg:gsub("force", "")
    local n = tonumber(arg) or 1
    local run = MD.RunRecorder:Get(n)
    if not run then
        MD:Print("coachrun: no run " .. n .. " (/md run status lists them).")
        return
    end
    if MD.runSearch then MD:Print("coachrun: already searching (/md coachrun cancel).") return end
    if not MD.player.isDruid then MD:Print("coachrun: coaching is Druid-only in v1.") return end
    MD:Print(string.format("coachrun: %s - %d pull(s) through the engine, this may take a moment.",
        run.name or "?", #(run.pulls or {})))
    if force then MD:Print("coachrun: FORCED - pulls that do not replay are coached too.") end
    MD.runSearch = MD.SimPlanner.CoachRun(run, { force = force }, function(lines)
        MD.runSearch = nil
        if MD.ShowCopyPopup and #lines > 6 then
            MD:ShowCopyPopup("ManaDemon coach: " .. (run.name or "run"), table.concat(lines, "\n"))
        end
        for _, line in ipairs(lines) do
            MD:Print(line)
            MD:Debug("sim", "coachrun %s", line)
        end
    end)
end

--------------------------------------------------------------------------------
-- /md coach [n] [force]
--------------------------------------------------------------------------------
function MD:RunCoach(arg)
    if not (MD.SimPlanner and MD.FightRecorder) then MD:Print("coach: not loaded.") return end
    arg = arg or ""
    if arg == "cancel" then
        if MD.coachSearch then MD.coachSearch:Cancel(); MD.coachSearch = nil
        else MD:Print("coach: nothing running.") end
        return
    end
    -- "2" is a single fight, "2:7" the seventh pull of the second run
    local n, rest = arg:match("^([%d:]*)%s*(%a*)$")   -- "3", "3 force", "3 health"
    if not n or n == "" then n = "1" end
    local rec, label = MD:GetRecording(n)
    if not rec then MD:Print("coach: no recording " .. tostring(n) .. ".") return end
    n = label

    -- /md coach 3 health: pick one of the strategies the last search on this
    -- fight produced, without searching again (v0.10.4)
    local SP = MD.SimPlanner
    for _, obj in ipairs(SP.OBJECTIVES or {}) do
        if rest == obj.key then
            local w = SP.strategies[rec.id] and SP.strategies[rec.id][obj.key]
            if not w then
                MD:Print(string.format("coach: no strategies for recording %s yet - run |cffffff00/md coach %s|r first.",
                    tostring(n), tostring(n)))
                return
            end
            SP.plans[rec.id] = w.plan
            MD:Print(string.format("coach: |cff33ff66%s|r is now the plan the replay draws for recording %s - %s.",
                obj.name, tostring(n), obj.what))
            MD:Print(string.format("  %s mana, floor %d%%, %.1fs in danger.",
                (w.result.manaSpent or 0) + SP.ManaOwed(w.result, w.plan) + 0.5,
                (w.result.lowest and w.result.lowest.hp or 1) * 100 + 0.5, w.result.floorSeconds or 0))
            return
        end
    end
    if MD.coachSearch then MD:Print("coach: already searching (/md coach cancel).") return end

    local function Show(lines)
        MD.coachSearch = nil
        if MD.ShowCopyPopup and #lines > 6 then
            MD:ShowCopyPopup("ManaDemon coach: recording " .. tostring(n), table.concat(lines, "\n"))
        end
        for _, line in ipairs(lines) do
            MD:Print(line)
            MD:Debug("sim", "coach %s", line)
        end
    end
    MD.coachSearch = MD.SimPlanner.CoachAsync(rec, { n = n, force = (rest == "force") }, Show)
end
