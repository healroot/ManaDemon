-- Options > General: everything the slash commands can do, in titled panes.
local _, MD = ...
local UI = MD.UI

local tab = UI.CreateFrame("ManaDemonOptionsFrame_GeneralTab", MD.optionsFrame, nil, nil, true)
tab:SetAllPoints(MD.optionsFrame)
tab:Hide()

local recordCB, rebindCB, fullHpSlider, floorSlider, runsCB, nextPullCB
local lockCB, restCB, tipCB, cdCB, muteCB, drinkCB, minimapCB, spellTipCB, halfLifeSlider, confSlider, treeAuraCB, ngCB, calibCB

--------------------------------------------------------------------------------
-- OOM widget
--------------------------------------------------------------------------------
local function CreateWidgetPane()
    local pane = UI.CreateTitledPane(tab, "OOM Widget", 205, 164)
    pane:SetPoint("TOPLEFT", tab, "TOPLEFT", 5, -5)

    lockCB = UI.CreateCheckButton(pane, "Lock widget", function(checked)
        MD.db.locked = checked
        if MD.UpdateVisibility then MD:UpdateVisibility() end
    end, "Lock widget", "Uncheck to drag the OOM clock.", "It stays visible while unlocked.")
    lockCB:SetPoint("TOPLEFT", pane, 5, -27)

    restCB = UI.CreateCheckButton(pane, "Show rest time", function(checked)
        MD.db.showRest = checked
    end, "Show rest time", "Grey 'rest 2:10' next to the clock:", "time to full if you stop casting right now.")
    restCB:SetPoint("TOPLEFT", lockCB, "BOTTOMLEFT", 0, -9)

    tipCB = UI.CreateCheckButton(pane, "Tooltip on the clock", function(checked)
        MD.db.widgetTooltip = checked
        if MD.UpdateVisibility then MD:UpdateVisibility() end
    end, "Tooltip on the floating clock", "Hovering the clock shows the full mana breakdown,",
        "and left-click opens the dashboard. This needs mouse input on the",
        "widget, so it also swallows clicks in its own small rectangle.",
        "Turn it OFF if the clock sits in the middle of the screen: it then",
        "takes no mouse input at all, and stays draggable while unlocked.",
        "The minimap button and the ElvUI datatexts keep their tooltips.",
        "Same as /md tooltip.")
    tipCB:SetPoint("TOPLEFT", restCB, "BOTTOMLEFT", 0, -9)

    cdCB = UI.CreateCheckButton(pane, "Show mana cooldown", function(checked)
        MD.db.showCooldown = checked
    end, "Mana cooldown projection", "Under 90s to OOM, with Innervate (or a potion) ready and",
        "worth at least 10% of your pool, the clock shows 'inn 2:10':",
        "what it becomes if you press it now. It replaces 'rest' there.")
    cdCB:SetPoint("TOPLEFT", tipCB, "BOTTOMLEFT", 0, -9)

    local resetBtn = UI.CreateButton(pane, "Reset position", "accent-hover", { 150, 17 })
    resetBtn:SetPoint("TOPLEFT", cdCB, "BOTTOMLEFT", 0, -12)
    resetBtn:SetScript("OnClick", function()
        local d = MD.DEFAULTS.pos
        MD.db.pos = { d[1], d[2], d[3], d[4] }
        if MD.ApplyWidgetPosition then MD:ApplyWidgetPosition() end
        MD:Print("widget position reset.")
    end)
    return pane
end

--------------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------------
local function CreateAlertsPane(anchor)
    local pane = UI.CreateTitledPane(tab, "Alerts", 205, 95)
    pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    muteCB = UI.CreateCheckButton(pane, "Mute alerts", function(checked)
        MD.db.muted = checked
    end, "Mute alerts", "Silences the advisor (Innervate / potion timing),", "the rank-shift toast and the drink reminder.")
    muteCB:SetPoint("TOPLEFT", pane, 5, -27)

    drinkCB = UI.CreateCheckButton(pane, "Drink reminder", function(checked)
        MD.db.drinkReminder = checked
    end, "Drink reminder", "Out of combat, below 90% mana and not drinking: 'Drink.'")
    drinkCB:SetPoint("TOPLEFT", muteCB, "BOTTOMLEFT", 0, -9)
    return pane
end

--------------------------------------------------------------------------------
-- Model
--------------------------------------------------------------------------------
local function CreateModelPane()
    local pane = UI.CreateTitledPane(tab, "Model", 205, 245)
    pane:SetPoint("TOPLEFT", tab, "TOPLEFT", 222, -5)

    halfLifeSlider = UI.CreateSlider("Spend half-life (s)", pane, 5, 60, 160, 1, function(value)
        MD.db.halfLife = value
    end, nil, false, "Spend half-life", "How fast the spend estimator forgets old casts.",
        "Shorter reacts faster, longer is steadier. Default 15s.")
    halfLifeSlider:SetPoint("TOPLEFT", pane, 22, -45)

    -- Stored as a fraction (0.3-1.5), shown as a percentage: "print the OOM
    -- digits while the projection's error is under N% of its own value".
    confSlider = UI.CreateSlider("OOM digits below error", pane, 30, 150, 160, 5, function(value)
        MD.db.oomConfidence = value / 100
    end, nil, true, "How sure the clock must be to print digits",
        "sigma/net of the projection. Below this the clock shows 'OOM 2:00';",
        "above it, 'OOM >2:00' (no sooner than). 70% comes from one easy dungeon:",
        "the hard pull sat at 34-66%, the quiet ones at a median 73%. Retune on raid logs.")
    confSlider:SetPoint("TOPLEFT", halfLifeSlider, "BOTTOMLEFT", 0, -34)

    treeAuraCB = UI.CreateCheckButton(pane, "Count Tree of Life aura", function(checked)
        MD.db.treeAura = checked
        MD:Fire("FORM_CHANGED", MD:InTreeForm())
    end, "Tree of Life aura in heal values", "Party members under your Tree of Life aura receive",
        "25% of your Spirit as extra healing. It is not part of the", "+healing stat, so the dashboard adds it while you are in form.")
    treeAuraCB:SetPoint("TOPLEFT", pane, 5, -135)

    ngCB = UI.CreateCheckButton(pane, "Average in Nature's Grace", function(checked)
        MD.db.naturesGrace = checked
        MD:Fire("TALENTS_CHANGED")
    end, "Nature's Grace in cast times", "A spell crit takes 0.5s off your next cast, so chain-casting",
        "Healing Touch or Regrowth averages out faster than the tooltip says.",
        "Marked with a grey * in the dashboard's Cast column.")
    ngCB:SetPoint("TOPLEFT", treeAuraCB, "BOTTOMLEFT", 0, -9)

    calibCB = UI.CreateCheckButton(pane, "Calibration drift alerts", function(checked)
        MD.db.calibAlerts = checked
    end, "Calibration drift alerts", "The model checks itself against every heal you land.",
        "When a spell drifts more than 3% from it over 30+ events, one chat",
        "line per session says so. /md calibrate shows the whole table.")
    calibCB:SetPoint("TOPLEFT", ngCB, "BOTTOMLEFT", 0, -9)

    local ohBtn = UI.CreateButton(pane, "Reset overheal data", "red-hover", { 150, 17 }, false, false, nil, nil,
        "Reset overheal data", "The dashboard's 'Effective' numbers come from your own combat log,",
        "per character. Clear it after a gear jump or a change of content -",
        "otherwise it forgets on its own over about 150 healing events.")
    ohBtn:SetPoint("TOPLEFT", calibCB, "BOTTOMLEFT", 0, -12)
    ohBtn:SetScript("OnClick", function()
        if MD.Overheal then MD.Overheal:Reset() end
    end)
    return pane
end

--------------------------------------------------------------------------------
-- Misc
--------------------------------------------------------------------------------
local function CreateMiscPane(anchor)
    local pane = UI.CreateTitledPane(tab, "Misc", 205, 169)
    pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    minimapCB = UI.CreateCheckButton(pane, "Show minimap button", function(checked)
        MD.db.minimap.hide = not checked
        if MD.UpdateMinimapButton then MD:UpdateMinimapButton() end
    end)
    minimapCB:SetPoint("TOPLEFT", pane, 5, -27)

    spellTipCB = UI.CreateCheckButton(pane, "Heals on spell tooltips", function(checked)
        MD.db.spellTooltip = checked
    end, "Each tick, the HoT total, the direct range and the bloom of the",
        "exact rank under the mouse, on your bars and in the spellbook.",
        "Hold Shift over a spell for how the numbers are calculated.")
    spellTipCB:SetPoint("TOPLEFT", minimapCB, "BOTTOMLEFT", 0, -8)

    local debugBtn = UI.CreateButton(pane, "Debug Console", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Debug Console", "Live log of regen, mana ticks, casts and the clock state.", "Enable logging there; Copy exports it as text.")
    debugBtn:SetPoint("TOPLEFT", spellTipCB, "BOTTOMLEFT", 0, -12)
    debugBtn:SetScript("OnClick", function()
        if MD.ToggleDebugConsole then MD:ToggleDebugConsole() end
    end)

    local verifyBtn = UI.CreateButton(pane, "Verify spell data", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Verify spell data", "Same as /md verify: static TBC spell table vs the live client,", "plus an input snapshot. Output goes to chat and the debug log.")
    verifyBtn:SetPoint("TOPLEFT", debugBtn, "BOTTOMLEFT", 0, -5)
    verifyBtn:SetScript("OnClick", function()
        if MD.RunVerify then MD:RunVerify() end
    end)

    local regenBtn = UI.CreateButton(pane, "Regen test (30s)", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Regen test", "Stand idle at partial mana, no drink, no casting, for 30s.",
        "Compares observed mana gain with GetManaRegen and tells whether", "Dreamstate is included in the API value.")
    regenBtn:SetPoint("TOPLEFT", verifyBtn, "BOTTOMLEFT", 0, -5)
    regenBtn:SetScript("OnClick", function()
        if MD.RunRegenTest then MD:RunRegenTest(30) end
    end)

    local profileBtn = UI.CreateButton(pane, "Copy profile", "accent-hover", { 150, 17 }, false, false, nil, nil,
        "Copy profile", "Same as /md profile: every model input, cost, clock state and",
        "setting in one copyable box. Paste this into a bug report.")
    profileBtn:SetPoint("TOPLEFT", regenBtn, "BOTTOMLEFT", 0, -5)
    profileBtn:SetScript("OnClick", function()
        if MD.RunProfile then MD:RunProfile() end
    end)
    return pane
end

--------------------------------------------------------------------------------
-- Simulation (v0.7). Only the settings a player would actually reach for: the
-- gate thresholds and the search's internals stay in Core.lua's DEFAULTS with
-- their provenance comments, because a slider invites tuning and these numbers
-- are supposed to be argued with, not nudged.
--------------------------------------------------------------------------------
local function CreateSimPane(anchor)
    local pane = UI.CreateTitledPane(tab, "Fight recording", 205, 225)
    pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    recordCB = UI.CreateCheckButton(pane, "Record fights", function(checked)
        MD.db.recordFights = checked
    end, "Keep the full event stream of the last 8 interesting pulls",
        "so they can be replayed and reviewed (/md -> Review).",
        "Fight summaries keep working either way.")
    recordCB:SetPoint("TOPLEFT", pane, 5, -27)

    rebindCB = UI.CreateCheckButton(pane, "Let Coach change ranks", function(checked)
        MD.db.simAllowRebinds = checked
    end, "Off: the card suggests thresholds for the ranks you already cast.",
        "On: it may also suggest binding a different rank.",
        "Off by default - a card that silently rebinds everything is",
        "somebody else's strategy, not this fight's.")
    rebindCB:SetPoint("TOPLEFT", recordCB, "BOTTOMLEFT", 0, -8)

    -- v0.9: runs. Starting one is deliberate (/md run start, or the Review
    -- tab's button); this only says whether that is allowed at all.
    runsCB = UI.CreateCheckButton(pane, "Allow run recording", function(checked)
        MD.db.recordRuns = checked
    end, "A whole dungeon as one recording: every pull and the gaps",
        "between them (drinking, deaths, the clock).",
        "Runs are always started by hand - /md run start.")
    runsCB:SetPoint("TOPLEFT", rebindCB, "BOTTOMLEFT", 0, -8)

    nextPullCB = UI.CreateCheckButton(pane, "Replay: next pull follows", function(checked)
        MD.db.replayNextPull = checked
    end, "In a run, playing a pull to the end opens the next one.",
        "Off: it stops at each pull's end.")
    nextPullCB:SetPoint("TOPLEFT", runsCB, "BOTTOMLEFT", 0, -8)

    fullHpSlider = UI.CreateSlider("Full health is above (%)", pane, 70, 99, 160, 1, function(value)
        MD.db.simFullHp = value / 100
    end, nil, true, "A cast on a target at or above this counts as healing nobody.",
        "0.85 came from the first dungeon log, not from a rulebook.")
    fullHpSlider:SetPoint("TOPLEFT", nextPullCB, "BOTTOMLEFT", 17, -30)

    floorSlider = UI.CreateSlider("Danger below (%)", pane, 10, 60, 160, 1, function(value)
        MD.db.simFloor = value / 100
    end, nil, true, "Seconds a tracked target spends below this are what a plan",
        "is scored on first, ahead of mana.")
    floorSlider:SetPoint("TOPLEFT", fullHpSlider, "BOTTOMLEFT", 0, -32)

    return pane
end

--------------------------------------------------------------------------------
-- build + show
--------------------------------------------------------------------------------
local built = false
local function Build()
    if built then return end
    built = true
    local widgetPane = CreateWidgetPane()
    local alertsPane = CreateAlertsPane(widgetPane)
    CreateSimPane(alertsPane)
    local modelPane = CreateModelPane()
    CreateMiscPane(modelPane)
end

local function ShowTab(which)
    if which ~= "general" then
        tab:Hide()
        return
    end
    Build()
    tab:Show()
    lockCB:SetChecked(MD.db.locked)
    restCB:SetChecked(MD.db.showRest ~= false)
    tipCB:SetChecked(MD.db.widgetTooltip ~= false)
    cdCB:SetChecked(MD.db.showCooldown ~= false)
    muteCB:SetChecked(MD.db.muted)
    drinkCB:SetChecked(MD.db.drinkReminder)
    minimapCB:SetChecked(not MD.db.minimap.hide)
    spellTipCB:SetChecked(MD.db.spellTooltip ~= false)
    halfLifeSlider:SetValue(MD.db.halfLife or 15)
    confSlider:SetValue(math.floor((MD.db.oomConfidence or 0.7) * 100 + 0.5))
    treeAuraCB:SetChecked(MD.db.treeAura ~= false)
    ngCB:SetChecked(MD.db.naturesGrace ~= false)
    calibCB:SetChecked(MD.db.calibAlerts ~= false)
    recordCB:SetChecked(MD.db.recordFights ~= false)
    rebindCB:SetChecked(MD.db.simAllowRebinds == true)
    runsCB:SetChecked(MD.db.recordRuns ~= false)
    nextPullCB:SetChecked(MD.db.replayNextPull ~= false)
    fullHpSlider:SetValue(math.floor((MD.db.simFullHp or 0.85) * 100 + 0.5))
    floorSlider:SetValue(math.floor((MD.db.simFloor or 0.30) * 100 + 0.5))
end
MD:RegisterCallback("ShowOptionsTab", ShowTab)
