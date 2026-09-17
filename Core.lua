-- ManaDemon: mana dynamics, time-to-OOM prediction and healing rank analysis
-- for TBC healers. Core: namespace, saved variables, event/tick dispatch,
-- profile & talent scanning, debug log entry point, slash commands.
local ADDON_NAME, MD = ...
_G.ManaDemon = MD

do
    local ok, v = pcall(GetAddOnMetadata, ADDON_NAME, "Version")
    MD.version = (ok and v) or "dev"
end

local DEFAULTS = {
    pos = { "CENTER", "CENTER", 0, -140 }, -- point, relativePoint, x, y
    locked = true,
    muted = false,
    halfLife = 15,        -- seconds; half-life of the spend-rate EWMA
    drinkReminder = true,
    showRest = true,      -- "rest 2:10" segment: time to full if you stop casting
    widgetTooltip = true, -- hover tooltip on the FLOATING WIDGET only (it needs mouse input on the
                          -- frame, so off also stops it swallowing clicks). The minimap button and the
                          -- ElvUI datatexts are not gated by it and must not be: they are surfaces you
                          -- go to on purpose, and the clock is one you park somewhere and stop looking at
    spellTooltip = true,  -- v0.14.9: this rank's tick / HoT total / direct range / bloom on the game's own
                          -- spell tooltip (action bars, spellbook, chat links); Shift adds the derivation
    showCooldown = true,  -- "inn 2:10" segment: the clock if you press your mana cooldown now
    oomConfidence = 0.7,  -- print OOM digits only while sigma/net <= this; above it show the bound.
                          -- Derived from one level-61 dungeon (docs/DESIGN-v0.6.md §3b): re-derive on raid logs.
    treeAura = true,      -- count the Tree of Life aura (+25% Spirit as healing received by the party) in heal values
    naturesGrace = true,  -- average Nature's Grace into the dashboard's cast times
    effectiveMode = false, -- dashboard shows overheal-adjusted heal/HPM/HPS
    calibAlerts = true,   -- chat line when a spell drifts >3% from the model over 30+ events
    simFullHp = 0.85,     -- a target at or above this fraction of health counts as "full" for the
                          -- cast labels and the replay engine (docs/SPEC-v0.7.md §2.2)
    simFloor = 0.30,      -- below this fraction of health a tracked target is "in danger": the
                          -- seconds spent there are what a plan is scored on first. Used for
                          -- SYNTHETIC scenarios only since v0.10.3 -- a recording measures its
                          -- own line (see simDangerHits)
    simDangerHits = 1,    -- "in danger" is this many of the biggest hits the target actually took
                          -- in that fight away from death. 1 = one more hit kills. A flat 30% says
                          -- the same thing about a quest mob hitting for 7% and a boss hitting for
                          -- a third of the tank, which is why it stopped being the line
    simReaction = 0.5,    -- seconds a simulated healer takes to start casting after idling.
                          -- Only after a wait: BF-1's inter-cast gaps (p10/p25 1.50/1.52s) show
                          -- chained casts go out at the GCD with no delay at all
    simMinActivity = 0,   -- minimum fraction of the fight a plan must spend casting (0 = off;
                          -- waiting is a legitimate action for a 5-man healer)
    recordFights = true,  -- keep the full event stream of the last 8 interesting pulls so they
                          -- can be replayed (Engine/FightRecorder.lua). Summaries run regardless
    recordThreat = true,  -- record the two things a healer can see coming: aggro on each tracked
                          -- target, and a hostile cast aimed at one (docs/SPEC-v0.12.md). A few
                          -- dozen events a pull; off for anyone who does not want the bytes
    recordRuns = true,    -- allow /md run start: a whole dungeon as one recording, every pull plus
                          -- the gaps (Engine/RunRecorder.lua). Two runs kept, one pinnable
    runMaxMinutes = 90,   -- a recording run stops itself at this age (0 = no ceiling)
    runAutoStart = false, -- RESERVED (docs/SPEC-v0.9.md 1.1): start a run on entering a 5-man.
                          -- Runs are manual; the recorder already takes a reason so this is one
                          -- `if` away when the author asks for it
    -- Replay validation gates (docs/SPEC-v0.7.md §7). A recording earns the right to be
    -- coached from; each threshold's provenance is printed with its result in Engine/SimModel.lua.
    simGateManaMean = 0.02,   -- mean |delta| on the mana curve, as a fraction of the pool
    simGateManaMax = 0.05,    -- worst single mana sample
    simGateHpMean = 0.05,     -- mean |delta| on one target's health, fraction of its max
    simGateHpMax = 0.15,      -- worst single health snapshot
    simForeignShare = 0.25,   -- above this share of foreign healing, replay is fiction
    simAllowRebinds = false,  -- let the search change which RANKS you bind, not just the thresholds
    replaySpeed = 1,          -- the replay window's last playback speed (1, 2 or 4)
    replayTicks = true,       -- draw the recorder's real HP snapshots over the left bars
    replayNextPull = true,    -- inside a run, playing a pull to the end opens the next one
    replayAutoCoach = true,   -- opening a replay with no plan coaches it (v0.13.9): validate,
                              -- coach and play were three commands to answer one question
    simBigHit = 0.15,         -- a single hit worth this much of a target's max health is a "big hit"
                              -- when a preset is derived from recordings (v0.7.7)
    simUtilityPerFight = nil, -- derived: median utility mana per fight, applied as a lump in
                              -- synthetic scenarios. nil until 5 summaries exist
    healAmountGross = nil, -- latched from the combat log: does SPELL_HEAL's "amount" include the overheal?
    firstRun = true,
    minimap = { hide = false, angle = 220 },
    debug = {
        enabled = false,  -- MD:Debug() is a no-op unless this is on
        maxLines = 1000,  -- memory ring size (Debug Console "keep lines")
        categories = { regen = true, mana = true, spend = true, tto = true,
                       heal = true, cast = true, calib = true, combat = true, chat = true,
                       sim = true, other = true },
    },
    optionsPos = false,   -- v0.11.2: settings are a group of the one window, which remembers its
                          -- own position. Kept so an old database does not grow a stray key back
    char = {},
}
MD.DEFAULTS = DEFAULTS

-- What-if overrides for the rank dashboard (never saved): heal, crit (%),
-- casting / base (mp5), mana. nil = live. See UI/Dashboard.lua "Simulate".
MD.sim = {}

--------------------------------------------------------------------------------
-- Event dispatch
--------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

-- Register a handler; events unknown to this client are silently skipped.
function MD:On(event, fn)
    if not handlers[event] then
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then return end
        handlers[event] = {}
    end
    handlers[event][#handlers[event] + 1] = fn
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end)

-- Internal pub/sub (module-to-module, not Blizzard events).
local callbacks = {}
function MD:RegisterCallback(name, fn)
    callbacks[name] = callbacks[name] or {}
    callbacks[name][#callbacks[name] + 1] = fn
end
function MD:Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    for i = 1, #list do
        list[i](...)
    end
end

--------------------------------------------------------------------------------
-- Master ticker: the model is event-driven; this drives accumulation/rendering.
--------------------------------------------------------------------------------
local tickers = {}
function MD:OnTick(fn)
    tickers[#tickers + 1] = fn
end

local TICK = 0.5
C_Timer.NewTicker(TICK, function()
    for i = 1, #tickers do
        tickers[i](TICK)
    end
end)

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------
function MD:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ffManaDemon:|r " .. tostring(msg))
    MD:Debug("chat", tostring(msg))
end

-- Alert respects /md mute and pulses the widget if present.
function MD:Alert(msg)
    MD:Debug("other", "alert%s: %s", (MD.db and MD.db.muted) and " (muted)" or "", tostring(msg))
    if MD.db and MD.db.muted then return end
    MD:Print(msg)
    if MD.PulseWidget then MD:PulseWidget() end
end

-- Debug log (Cell-style): a no-op unless debug logging is enabled in the
-- settings, otherwise one timestamped line into the in-memory ring that the
-- Debug Console (UI/DebugConsole.lua) shows and copies. Categories: regen,
-- mana, spend, tto, heal, cast, calib, combat, chat, sim, other. Extra arguments go through
-- string.format; a bad format never raises.
function MD:Debug(category, fmt, ...)
    local db = MD.db and MD.db.debug
    if not (db and db.enabled) then return end
    local text
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        text = ok and s or tostring(fmt)
    else
        text = tostring(fmt)
    end
    if MD.DebugLog then MD:DebugLog(category, text) end
end

--------------------------------------------------------------------------------
-- Player profile
--------------------------------------------------------------------------------
MD.player = { class = "UNKNOWN", level = 0, isDruid = false, guid = "", charKey = "?" }

function MD:DetectProfile()
    local _, class = UnitClass("player")
    MD.player.class = class or "UNKNOWN"
    MD.player.isDruid = class == "DRUID"
    MD.player.level = UnitLevel("player") or 0
    MD.player.guid = UnitGUID("player") or ""
    MD.player.charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
    -- Druids are checked at login (caster form); cat/bear later doesn't change
    -- that mana is their healing resource.
    MD.player.usesMana = UnitPowerType("player") == 0
end

-- Buff scan by name; tolerates both the classic UnitBuff API and C_UnitAuras.
function MD:HasBuff(matchName)
    if not matchName then return false end
    if UnitBuff then
        for i = 1, 40 do
            local name = UnitBuff("player", i)
            if not name then break end
            if name == matchName then return true end
        end
    elseif C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then break end
            if aura.name == matchName then return true end
        end
    end
    return false
end

-- Tree of Life form: the shapeshift form ID when the client exposes it
-- (FrameXML TREE_FORM = 2), the form buff by name as fallback.
local TREE_OF_LIFE = GetSpellInfo(33891)
local TREE_FORM_ID = _G.TREE_FORM or 2
function MD:InTreeForm()
    if not MD.player.isDruid then return false end
    if GetShapeshiftFormID then
        local ok, id = pcall(GetShapeshiftFormID)
        if ok and id ~= nil then return id == TREE_FORM_ID end
    end
    return MD:HasBuff(TREE_OF_LIFE)
end

-- Fired (as "FORM_CHANGED", inTree) when the shapeshift form changes.
local lastTree = nil
local function CheckForm()
    if not MD.db then return end
    local inTree = MD:InTreeForm()
    if inTree ~= lastTree then
        lastTree = inTree
        MD:Debug("other", "form: %s", inTree and "Tree of Life" or "caster / other")
        MD:Fire("FORM_CHANGED", inTree)
    end
end
MD:On("UPDATE_SHAPESHIFT_FORM", CheckForm)
MD:On("UPDATE_SHAPESHIFT_FORMS", CheckForm)
MD:RegisterCallback("MD_READY", function() lastTree = MD:InTreeForm() end)

--------------------------------------------------------------------------------
-- Talents: scanned by NAME across all tabs so positional index shifts between
-- client builds can't silently return the wrong talent.
--------------------------------------------------------------------------------
MD.talents = {}

-- Talents the model reads or that the verification output should show.
MD.RELEVANT_TALENTS = {
    "Intensity", "Dreamstate", "Living Spirit", "Lunar Guidance",
    "Moonglow", "Tranquil Spirit", "Gift of Nature", "Improved Rejuvenation",
    "Empowered Rejuvenation", "Empowered Touch", "Improved Regrowth",
    "Naturalist", "Natural Perfection", "Nature's Grace", "Tree of Life",
}

function MD:ScanTalents()
    wipe(MD.talents)
    if not GetNumTalentTabs then return end
    for tab = 1, GetNumTalentTabs() do
        for i = 1, GetNumTalents(tab) do
            local name, _, _, _, rank = GetTalentInfo(tab, i)
            if name then
                MD.talents[name] = rank or 0
            end
        end
    end
    MD:Debug("other", "talents scanned: %s", MD:TalentSummary())
    MD:Fire("TALENTS_CHANGED")
end

function MD:TalentRank(name)
    return MD.talents[name] or 0
end

-- "Intensity 3, Moonglow 3, ..." for the relevant talents, or "none relevant".
function MD:TalentSummary()
    local list = {}
    for _, t in ipairs(MD.RELEVANT_TALENTS) do
        local r = MD:TalentRank(t)
        if r > 0 then list[#list + 1] = t .. " " .. r end
    end
    return #list > 0 and table.concat(list, ", ") or "none relevant"
end

--------------------------------------------------------------------------------
-- The profile snapshot (v0.9.0, docs/SPEC-v0.9.md 2.2). Everything
-- Engine/RankMath.lua's Context() reads about this character, written into the
-- SavedVariables so the offline tools can build THIS character's spell kit
-- instead of the harness's stand-in. It is a handful of numbers, rewritten at
-- login, on a talent change and on a gear change; nothing reads it in-game --
-- in the client the live API is always better.
--------------------------------------------------------------------------------
function MD:WriteProfile()
    if not MD.cdb then return end
    local function pcallv(fn, ...)
        if not fn then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end
    local talents = {}
    for _, name in ipairs(MD.RELEVANT_TALENTS) do talents[name] = MD:TalentRank(name) end
    local _, relicID = nil, nil
    if MD.SpellData and MD.SpellData.Relic then
        local _, id = MD.SpellData:Relic()
        relicID = id
    end
    MD.cdb.profile = {
        v = 1, at = time(), charKey = MD.player.charKey,
        class = MD.player.class, level = UnitLevel("player") or MD.player.level or 0,
        healing = pcallv(GetSpellBonusHealing) or 0,
        crit = pcallv(GetSpellCritChance, 4) or 0,
        spirit = UnitStat("player", 5) or 0,
        intellect = UnitStat("player", 4) or 0,
        manaMax = UnitPowerMax("player", 0) or 0,
        apiBase = MD.Regen and MD.Regen.apiBase or 0,
        apiCasting = MD.Regen and MD.Regen.apiCasting or 0,
        talents = talents,
        relic = relicID,
        form = MD:InTreeForm() and "tree" or "caster",
    }
    MD:Debug("other", "profile written: level %d, +%d healing, %.1f%% crit, %d spirit, %d int, relic %s",
        MD.cdb.profile.level, MD.cdb.profile.healing, MD.cdb.profile.crit,
        MD.cdb.profile.spirit, MD.cdb.profile.intellect, tostring(relicID))
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------
-- Fill missing keys recursively so nested defaults (debug.categories) are
-- copied, never shared with the DEFAULTS table.
local function FillDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            FillDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function InitDB()
    ManaDemonDB = ManaDemonDB or {}
    FillDefaults(ManaDemonDB, DEFAULTS)
    MD.db = ManaDemonDB
    MD.db.char[MD.player.charKey] = MD.db.char[MD.player.charKey] or {}
    MD.cdb = MD.db.char[MD.player.charKey]
end

MD:On("PLAYER_LOGIN", function()
    MD:DetectProfile()
    InitDB()
    MD:Debug("other", "=== PLAYER_LOGIN === ManaDemon v%s, %s level %d, debug categories: %s",
        MD.version, MD.player.class, MD.player.level, (function()
            local on = {}
            for k, v in pairs(MD.db.debug.categories) do if v then on[#on + 1] = k end end
            table.sort(on)
            return table.concat(on, " ")
        end)())
    MD:ScanTalents()
    MD:Fire("MD_READY")
    -- once now, and again once the client has settled: at PLAYER_LOGIN the
    -- stat APIs can still read zero.
    MD:WriteProfile()
    if C_Timer and C_Timer.After then C_Timer.After(5, function() MD:WriteProfile() end) end

    if MD.db.firstRun then
        MD.db.firstRun = false
        MD:Print("first run — the widget is unlocked for 60s so you can drag it. |cffffff00/md lock|r when done, |cffffff00/md help|r for commands.")
        if MD.ForceWidgetPreview then MD:ForceWidgetPreview(60) end
    end
end)

MD:On("CHARACTER_POINTS_CHANGED", function() MD:ScanTalents(); MD:WriteProfile() end)
MD:On("PLAYER_TALENT_UPDATE", function() MD:ScanTalents(); MD:WriteProfile() end)

-- Gear changes move both the profile and the measured mp5. The profile is
-- rewritten (it is free); the measurement is NOT invalidated -- an old
-- measurement is still a measurement -- but the author is reminded once per
-- session, out of combat, that it predates the gear they are wearing.
local gearReminded = false
MD:On("PLAYER_EQUIPMENT_CHANGED", function()
    if not MD.cdb then return end
    MD:WriteProfile()
    if gearReminded or UnitAffectingCombat("player") then return end
    local m = MD.cdb.mp5
    if not m or not m.at then return end
    gearReminded = true
    MD:Print(string.format("item mp5 was measured on %s (%d mp5); gear changed since - |cffffff00/md regentest|r " ..
        "solo to re-measure.", date("%d %b", m.at), m.mp5 or 0))
end)
MD:On("PLAYER_LEVEL_UP", function(level)
    MD.player.level = tonumber(level) or UnitLevel("player") or MD.player.level
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------
-- Shared with the About tab.
MD.COMMANDS = {
    { "/md",              "toggle the rank dashboard" },
    { "/md options",      "open the settings window" },
    { "/md lock, unlock", "lock / unlock (drag) the OOM widget" },
    { "/md reset",        "reset the widget position" },
    { "/md mute",         "toggle alert messages" },
    { "/md drink",        "toggle the drink reminder" },
    { "/md rest",         "toggle the 'rest' segment (time to full if you stop casting)" },
    { "/md tooltip",      "hover tooltip on the FLOATING clock only (off also stops it swallowing clicks)" },
    { "/md spelltip",     "heal values on the game's spell tooltips (bars, spellbook); Shift for the maths" },
    { "/md window N",     "spend estimator half-life in seconds (5-60, default 15)" },
    { "/md verify",       "check static spell data against the live client" },
    { "/md profile",      "copyable dump of every model input - use this for bug reports" },
    { "/md export",       "fights, overheal and roster as tab-separated text, for analysis" },
    { "/md calibrate",    "the model against every heal you landed: ratio per spell and event kind" },
    { "/md fsrtest",      "log mana ticks for 15s (five-second-rule anchor test)" },
    { "/md regentest [N or clear]", "idle regen check: observed mana gain vs GetManaRegen (N s, default 30; clear forgets the measurement)" },
    { "/md spamtest",     "arm, then chain-cast one spell to OOM: checks the dashboard's To OOM column" },
    { "/md simrun",       "self-tests for the simulation engine (heals, HoT refresh, GCD, 5SR)" },
    { "/md simreplay [n]", "replay recorded fight n (or the BF-1 fixture) and score it against the log" },
    { "/md coach [n]",    "search for a better plan on recorded fight n and show the card (cancel stops it)" },
    { "/md sim",          "simulation window: build a fight and find the cheapest plan that holds it" },
    { "/md replay [n] [force]", "play recorded fight n (or run:pull, or 'run N') as unit frames; force: draw the suggested column on a fight that does not replay" },
    { "/md run start / stop / status", "record a whole dungeon: every pull and the gaps between them" },
    { "/md coachrun [n]", "coach a recorded RUN: one plan and a drink policy for the whole dungeon" },
    { "/md debug",        "toggle the debug console (enable logging there, Copy to export)" },
}

local function ShowHelp()
    MD:Print("commands:")
    for _, c in ipairs(MD.COMMANDS) do
        MD:Print("  |cffffff00" .. c[1] .. "|r - " .. c[2])
    end
end

SLASH_MANADEMON1 = "/manademon"
SLASH_MANADEMON2 = "/md"
SlashCmdList.MANADEMON = function(msg)
    -- commands are matched lower-case; the RAW tail is kept because a run's
    -- name is the author's text ("/md run start Blood Furnace") and lower-casing
    -- it would hand them back a name they did not type
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    msg = raw:lower()
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    local _, rawArg = raw:match("^(%S*)%s*(.*)$")
    if cmd == "" then
        if MD.ToggleDashboard then MD:ToggleDashboard() end
    elseif cmd == "help" then
        ShowHelp()
    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        if MD.ShowOptionsFrame then MD:ShowOptionsFrame() end
    elseif cmd == "lock" then
        MD.db.locked = true
        if MD.UpdateVisibility then MD:UpdateVisibility() end
        MD:Print("widget locked.")
    elseif cmd == "unlock" then
        MD.db.locked = false
        if MD.UpdateVisibility then MD:UpdateVisibility() end
        MD:Print("widget unlocked — drag it, then /md lock.")
    elseif cmd == "reset" then
        MD.db.pos = { DEFAULTS.pos[1], DEFAULTS.pos[2], DEFAULTS.pos[3], DEFAULTS.pos[4] }
        if MD.ApplyWidgetPosition then MD:ApplyWidgetPosition() end
        MD:Print("widget position reset.")
    elseif cmd == "mute" then
        MD.db.muted = not MD.db.muted
        MD:Print("alerts " .. (MD.db.muted and "muted." or "unmuted."))
    elseif cmd == "drink" then
        MD.db.drinkReminder = not MD.db.drinkReminder
        MD:Print("drink reminder " .. (MD.db.drinkReminder and "on." or "off."))
    elseif cmd == "rest" then
        MD.db.showRest = not MD.db.showRest
        MD:Print("rest segment " .. (MD.db.showRest and "on." or "off."))
    elseif cmd == "spelltip" then
        MD.db.spellTooltip = (MD.db.spellTooltip == false)
        MD:Print(MD.db.spellTooltip
            and "spell tooltips: on - hover a heal on your bars or in the spellbook; hold Shift for the maths."
            or "spell tooltips: off.")
    elseif cmd == "tooltip" or cmd == "tip" then
        MD.db.widgetTooltip = (MD.db.widgetTooltip == false)
        if MD.UpdateVisibility then MD:UpdateVisibility() end
        MD:Print(MD.db.widgetTooltip
            and "floating clock: tooltip on - hovering shows the breakdown, left-click opens the dashboard."
            or "floating clock: tooltip off - it takes no mouse input at all now, so it neither pops a tooltip "
               .. "nor swallows clicks in its rectangle, and it is still draggable while unlocked. The minimap "
               .. "button and the ElvUI datatexts keep theirs.")
    elseif cmd == "window" then
        local n = tonumber(arg)
        if n and n >= 5 and n <= 60 then
            MD.db.halfLife = n
            MD:Print("spend half-life set to " .. n .. "s.")
        else
            MD:Print("usage: /md window N (5–60 seconds)")
        end
    elseif cmd == "verify" then
        if MD.RunVerify then MD:RunVerify() end
    elseif cmd == "profile" then
        if MD.RunProfile then MD:RunProfile() end
    elseif cmd == "export" then
        if MD.RunExport then MD:RunExport() end
    elseif cmd == "calibrate" or cmd == "calib" then
        if MD.RunCalibrate then MD:RunCalibrate() end
    elseif cmd == "fsrtest" then
        if MD.RunFSRTest then MD:RunFSRTest() end
    elseif cmd == "regentest" then
        if MD.RunRegenTest then MD:RunRegenTest(arg ~= "" and arg or nil) end
    elseif cmd == "spamtest" then
        if MD.RunSpamTest then MD:RunSpamTest() end
    elseif cmd == "simrun" then
        if MD.RunSimRun then MD:RunSimRun() end
    elseif cmd == "simreplay" then
        if MD.RunSimReplay then MD:RunSimReplay(arg) end
    elseif cmd == "coach" then
        if MD.RunCoach then MD:RunCoach(arg) end
    elseif cmd == "sim" then
        if MD.ToggleSimWindow then MD:ToggleSimWindow() end
    elseif cmd == "replay" then
        if MD.ToggleReplay then MD:ToggleReplay(arg) end
    elseif cmd == "run" then
        if MD.RunCommand then MD:RunCommand(rawArg) end
    elseif cmd == "coachrun" then
        if MD.RunCoachRun then MD:RunCoachRun(arg) end
    elseif cmd == "debug" then
        if MD.ToggleDebugConsole then MD:ToggleDebugConsole() end
    else
        ShowHelp()
    end
end
