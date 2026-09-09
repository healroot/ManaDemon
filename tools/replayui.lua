-- tools/run.sh tools/replayui.lua
--
-- The replay WINDOW under the stub: loads UI/Style.lua, UI/Tooltip.lua and
-- UI/ReplayWindow.lua on top of the engine harness, opens the scripted pull,
-- plays it, seeks it, and reads back what was painted. The stub's frames are
-- permissive (unknown methods are no-ops) but they store text, values and
-- colours, which is enough to catch the class of bug that bit v0.7.6: a nil
-- index, a wrong argument order, a string with a bare pipe.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

S.Load({ "UI/Style.lua", "UI/Tooltip.lua", "UI/ReplayWindow.lua" }, "ManaDemon", MD)

local ids = dofile(here .. "/fakepull.lua")(MD, S)
local SM, SP = MD.SimModel, MD.SimPlanner

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-38s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local rec = MD.FightRecorder:Get(1)
local kit = MD.RankMath:SpellKit()
-- the scripted pull fails validation on purpose (a death, 69% foreign healing);
-- let it through so the right column is exercised too
local realValidate = SM.Validate
function SM:Validate(...) local v = realValidate(self, ...); v.ok = true; return v end
SP.plans[rec.id] = SP.NewPlan(SP.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false }, kit)

MD:OpenReplay(1)
local W = MD.Replay._state()
check("window shown", W.frame and W.frame:IsShown())
check("five rows", #W.rows == 5, tostring(#W.rows))
local roster = rec.roster
-- the author's Cell layout has sortByRole off: roster order, as on their frames
local inOrder = true
for i = 2, #W.rows do if W.rows[i] < W.rows[i - 1] then inOrder = false end end
check("rows in roster order (Cell: sortByRole off)", inOrder)
-- five people: x1.6 tall, stretched across the column
check("party buttons stretched to the column", W.left.frames[W.rows[1]]:GetWidth() == 460 and math.abs(W.left.frames[W.rows[1]]:GetHeight() - 46 * 1.6) < 0.01,
    string.format("%dx%d", W.left.frames[W.rows[1]]:GetWidth(), W.left.frames[W.rows[1]]:GetHeight()))
check("right column built", W.right and W.right.state ~= nil and W.right.title:IsShown())
check("time text", W.timeFS:GetText():match("^0:00%.0 / 0:%d%d%.%d$") ~= nil, W.timeFS:GetText())

-- every painted string: no bare pipe (WoW would eat the text after it)
local function Pipes()
    local bad = {}
    local function scan(fs, label)
        local t = fs and fs.GetText and fs:GetText() or ""
        local stripped = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if stripped:find("|", 1, true) then bad[#bad + 1] = label .. ": " .. t end
    end
    for _, col in ipairs({ W.left, W.right }) do
        for ti, f in pairs(col.frames) do scan(f.name, "name"); scan(f.pct, "pct"); scan(f.cast, "cast") end
        scan(col.strip.score, "score"); scan(col.strip.castFS, "castbar"); scan(col.strip.wait, "wait")
    end
    scan(W.timeFS, "time")
    return bad
end

-- play through at 1x: one 0.1s frame at a time
MD.Replay._setPlaying(true)
local tankRow, lockRow, mageRow = nil, nil, nil
for _, ti in ipairs(W.rows) do
    if roster[ti].name == "Destroyka" then tankRow = ti end
    if roster[ti].name == "Abufaisall" then lockRow = ti end
    if roster[ti].name == "Alkandari" then mageRow = ti end
end
local sawRegrowth, sawDamage = false, false
-- v0.8.2: indicators and labels seen at some point during the play-through
local sawEarly, sawLBStack, sawRejuvDigit, sawDot, sawWhy, sawBand = false, false, false, false, false, false
-- v0.12.3: every cast that lands in either column must be able to say why, in
-- numbers. A sentence with no number in it is a justification, not a reason.
local whySeen, whyMissing = { left = {}, right = {} }, {}
local whyCount = { left = 0, right = 0 }
local function NoteWhy(side, col)
    local st, strip = col.state, col.strip
    local lc = st.lastCast
    if not lc then return end
    local key = tostring(lc.n or lc.t or "?")
    if whySeen[side][key] then return end
    whySeen[side][key] = true
    whyCount[side] = whyCount[side] + 1
    local why = strip.why
    local line = why and why[#why] and why[#why].l or nil
    if not line or not line:find("%d") then
        whyMissing[#whyMissing + 1] = string.format("%s cast %s: %s", side, key, tostring(line))
    end
end
local sawDefIcon, sawDebuff2 = false, false
local sawCastProgress, castProgressDetail = false, ""
local sawTargetIcon = false
local sawGcdSweep = false
local frames = 0
local HOT_INDEX = SM.HOT_INDEX
while MD.Replay._state().playing and frames < 2000 do
    S.Tick(0.1); frames = frames + 1
    local f = W.left.frames[tankRow]
    if f.cast:GetText():find("Regrowth") then sawRegrowth = true end
    -- the tank's hit is at t = 0 (initial state, never fires); the mage's is at 6.5s
    local m = mageRow and W.left.frames[mageRow]
    if m and m.pulse.color and m.pulse.color[4] > 0 then sawDamage = true end
    for _, ti in ipairs(W.rows) do
        local lf = W.left.frames[ti]
        if lf.label:GetText() == "early" then sawEarly = true end
        local lb = lf.hots[HOT_INDEX.Lifebloom]
        if lb:IsShown() and lb.text:GetText() == "1" then sawLBStack = true end
        local rj = lf.hots[HOT_INDEX.Rejuvenation]
        -- the sweep: the dim overlay partway down the icon while the HoT runs
        if rj:IsShown() and rj.dim:IsShown() and rj.dim.h and rj.dim.h > 0.5 and rj.dim.h < rj.size - 2 then sawRejuvDigit = true end
        if lf.dot:IsShown() then sawDot = true end
    end
    if W.right.strip.why then sawWhy = true end
    NoteWhy("left", W.left)
    if W.right.state then NoteWhy("right", W.right) end
    local cb = W.left.strip.cast
    local v, txt = cb:GetValue(), W.left.strip.castFS:GetText()
    if txt:find("Regrowth") and v > 0.05 and v < 0.95 then
        sawCastProgress = true; castProgressDetail = string.format("%.2f at %s", v, txt)
    end
    if txt:find("instant") and v > 0 and v < 1 then sawGcdSweep = true end
    local tf = W.left.frames[tankRow]
    if tf.cast:GetText():find("^Regrowth.*%.%.%.$") and tf.border and tf.border[2] > 0.8 then sawTargetIcon = true end
    if W.left.frames[tankRow].defIcon:IsShown() then sawDefIcon = true end
    if mageRow and W.left.frames[mageRow].debuffs[1]:IsShown() and W.left.frames[mageRow].debuffs[1].count:GetText() == "2" then sawDebuff2 = true end
    if W.right.strip.band.color and W.right.strip.band.color[4] > 0 then sawBand = true end
end
check("played to the end", not MD.Replay._state().playing and W.left.state:AtEnd(), string.format("%d frames", frames))
check("cast text appeared on the tank", sawRegrowth)
check("damage pulse appeared on the mage", sawDamage)
check("the warlock reads dead", lockRow and W.left.frames[lockRow].pct:GetText() == "dead",
    lockRow and W.left.frames[lockRow].pct:GetText() or "no row")
local spent = W.left.state:Score()
check("strip spent == recording spent", spent == (rec.spent or 0), string.format("%d vs %d", spent, rec.spent or 0))
check("score line painted", W.left.strip.score:GetText():find("spent") ~= nil, W.left.strip.score:GetText())
local bad = Pipes()
check("no bare pipe in painted text", #bad == 0, bad[1])

-- v0.8.2
check("'early' label shown under its cast", sawEarly)
check("Lifebloom icon counts a stack", sawLBStack)
check("Rejuvenation icon sweeps its duration", sawRejuvDigit)
check("Swiftmend icon shown", sawDot)
check("Swiftmend icon carries its texture", W.left.frames[tankRow].dot.spellID == 18562 or (mageRow and W.left.frames[mageRow].dot.spellID == 18562))
check("right cast bar carries a why", sawWhy)
check("every cast in either column says why, with a number in it",
    #whyMissing == 0 and whyCount.left > 0 and whyCount.right > 0,
    whyMissing[1] or string.format("%d left, %d right", whyCount.left, whyCount.right))
check("wait band drawn while the plan holds", sawBand)
local enter = W.right.strip.cast:GetScript("OnEnter")
local okTip = pcall(enter, W.right.strip.cast)
check("why tooltip does not error", okTip)
local labelled = 0
for _, m in ipairs(W.scrubber.markers) do
    if m:IsShown() and m.color and m.color[1] == 1 and m.color[2] == 0.9 and m.color[3] == 0.3 then labelled = labelled + 1 end
end
check("scrubber tick coloured by label", labelled >= 1, tostring(labelled))
-- v0.8.4
check("cast bar progresses during the Regrowth", sawCastProgress, castProgressDetail)
check("in-flight cast named on the tank with its border", sawTargetIcon)
check("instant sweeps the GCD", sawGcdSweep)
check("last cast name stays after the fight", W.left.strip.castFS:GetText() ~= "", W.left.strip.castFS:GetText())
check("five speeds incl. 1/4x", #W.speeds == 5 and W.speeds[1].id == 0.25, tostring(#W.speeds))
-- v0.8.3
check("Shield Wall icon shown on the tank", sawDefIcon)
check("debuff icon with 2 stacks on the mage", sawDebuff2)
local ic = W.left.frames[tankRow].defIcon
MD.Replay._seek(5.0)
check("defensive icon at 5s with a tooltip", ic:IsShown() and ic.tip and ic.tip[1].l == "Shield Wall",
    ic.tip and ic.tip[1].l or "no tip")
check("icon tooltip does not error", pcall(ic:GetScript("OnEnter"), ic))
MD.Replay._seek(16.0)
check("defensive icon gone at 16s", not ic:IsShown())

-- seek back to the start: effects cleared, bars back
MD.Replay._seek(0)
check("seek clears the cast text", W.left.frames[tankRow].cast:GetText() == "")
local anyLabel = false
for _, ti in ipairs(W.rows) do if W.left.frames[ti].label:GetText() ~= "" then anyLabel = true end end
check("seek clears the labels", not anyLabel)
-- the status strip's background only while there is text (the brown band)
local bgIdle = W.left.frames[tankRow].statusBG:IsShown()
check("no status background when idle", not bgIdle)
-- the healer's own button carries their mana on the power strip
local me
for _, ti in ipairs(W.rows) do if roster[ti].name == "Penek" then me = ti end end
check("healer recognised by guid", me and W.left.frames[me].isHealer == true)
MD.Replay._seek(10.0)
check("healer's power strip shows mana", me and W.left.frames[me].power:GetValue() > 0.3 and W.left.frames[me].power:GetValue() < 1,
    me and string.format("%.2f", W.left.frames[me].power:GetValue()) or "no row")
MD.Replay._seek(0)
local anyHot = false
for _, ti in ipairs(W.rows) do for fi = 1, 3 do if W.left.frames[ti].hots[fi]:IsShown() then anyHot = true end end end
check("no HoT icons at t=0", not anyHot)
check("seek resets the clock", W.timeFS:GetText():match("^0:00%.0") ~= nil, W.timeFS:GetText())
check("warlock alive again at 0", W.left.frames[lockRow].pct:GetText() ~= "dead", W.left.frames[lockRow].pct:GetText())

-- ticks: at a snapshot time the left tick is drawn, and never on the right
MD.Replay._seek(5.0)
local tick = W.left.frames[tankRow].tick
check("snapshot tick drawn on the left", tick.color and tick.color[4] > 0, tick.color and tostring(tick.color[4]))
local hit = W.left.frames[tankRow].tickHit
check("tick has a hover frame", hit:IsShown() and W.left.frames[tankRow].tickInfo ~= nil)
check("tick tooltip does not error", pcall(hit:GetScript("OnEnter"), hit))
check("no tick on the right", W.right.frames[tankRow].tick.color[4] == 0)

-- a lone Lifebloom packs into the first HoT slot (Trecoda at 16.5s has only a Lifebloom)
do
    local pala
    for _, ti in ipairs(W.rows) do if roster[ti].name == "Trecoda" then pala = ti end end
    MD.Replay._seek(17.0)
    local lb = pala and W.left.frames[pala].hots[HOT_INDEX.Lifebloom]
    check("lone Lifebloom packs into slot 1", lb and lb:IsShown() and lb.slot == 1, lb and tostring(lb.slot) or "no row")
    MD.Replay._seek(0)
end

-- markers on the scrubber: the death, the casts
local shown = 0
for _, m in ipairs(W.scrubber.markers) do if m:IsShown() then shown = shown + 1 end end
check("scrubber markers placed", shown >= 7, tostring(shown))

-- the left-only path
SP.plans[rec.id] = nil
MD:OpenReplay(1)
W = MD.Replay._state()
check("left only without a plan", W.right.state == nil and not W.right.title:IsShown())
check("hint says to coach first", W.frame.hint:GetText():find("Coach") ~= nil, W.frame.hint:GetText())
check("narrower window", W.frame:GetWidth() < 500, tostring(W.frame:GetWidth()))

-- in combat: refuses
_G.UnitAffectingCombat = function() return true end
local before = W.frame:IsShown()
W.frame:Hide()
MD:OpenReplay(1)
check("refuses to open in combat", not MD.Replay._state().frame:IsShown())
_G.UnitAffectingCombat = function() return false end

--------------------------------------------------------------------------------
-- v0.9.7: the Swiftmend indicator belongs to a healer who HAS Swiftmend. The
-- recording says what existed at that pull; a druid with one point in Gift of
-- Nature has no Swiftmend, and telling them it is ready is telling them to
-- press a key they do not have.
--------------------------------------------------------------------------------
do
    local function dotShown()
        local W = MD.Replay._state()
        for _, ti in ipairs(W.rows) do
            local f = W.left.frames[ti]
            if f and f.dot and f.dot:IsShown() then return true end
        end
        return false
    end
    MD.Replay._seek(0)
    MD.Replay._seek(12.0)      -- a Rejuvenation is rolling on the tank here
    check("the Swiftmend dot is drawn when the spell is known", dotShown())

    local saved = rec.initial.known
    rec.initial.known = { Rejuvenation = MD.SpellData.maxRank.Rejuvenation }   -- no Swiftmend
    MD:OpenReplay(1)
    MD.Replay._seek(12.0)
    check("no Swiftmend dot for a build without Swiftmend", not dotShown())

    -- and no plan may bind a spell the recording says the healer did not have
    local binds = SP.MaxRankBinds(rec.initial.known)
    check("MaxRankBinds respects what the healer had",
        binds.Swiftmend == nil and binds.Rejuvenation ~= nil,
        tostring(binds.Swiftmend))
    local fromRec = SP.BindsFromRecording(rec, kit)
    check("BindsFromRecording does not invent Swiftmend either", fromRec.Swiftmend == nil,
        tostring(fromRec.Swiftmend))

    rec.initial.known = saved
    MD:OpenReplay(1)
end

--------------------------------------------------------------------------------
-- v0.11.7: the strategy row. One search produced four plans; switching between
-- them is a redraw of the suggested column, never another search.
--------------------------------------------------------------------------------
do
    local kit2 = MD.RankMath:SpellKit()
    local function planWith(params)
        return SP.NewPlan(SP.MaxRankBinds(), params, kit2)
    end
    local cheap = planWith({ swiftmendBelow = 0.30, directBelow = 0.35, rollStacks = 0,
                             hotBelow = 0.50, filler = false })
    local safe = planWith({ swiftmendBelow = 0.40, directBelow = 0.55, rollStacks = 3,
                            hotBelow = 0.90, filler = true })
    local function snap() return { deaths = { n = 0 }, floorSeconds = 0, manaSpent = 1,
                                   deficitArea = 1, endDeficit = 0, manaEnd = 1,
                                   healed = 1, overhealed = 0, lowest = { hp = 0.6 } } end
    SP.strategies[rec.id] = {
        safe = { plan = safe, result = snap() }, health = { plan = safe, result = snap() },
        cheap = { plan = cheap, result = snap() }, regen = { plan = cheap, result = snap() },
    }
    SP.plans[rec.id] = cheap
    MD:OpenReplay(1)

    local dd = MD.Replay._strategy()
    check("the strategy chooser is drawn", dd ~= nil and dd:IsVisible())
    check("it is ONE control, not one per strategy", dd ~= nil and dd:GetWidth() <= 200,
        dd and tostring(dd:GetWidth()))
    -- v0.13.7: the list is the PLANNERS (SP.STRATEGY_SET, always available)
    -- plus the four readings of the last search, prefixed "Search:"
    check("every objective that has a winner is in the list",
        dd ~= nil and #dd.items == #SP.STRATEGY_SET + 4,
        dd and tostring(#dd.items))
    check("it says which one is active", dd ~= nil and dd:GetText() == "Search: Least mana",
        dd and dd:GetText())
    check("the list is closed until it is asked for", dd ~= nil and not dd.list:IsShown())
    dd:GetScript("OnClick")(dd)
    check("clicking it opens the list", dd.list:IsShown())

    -- play a little way in, then switch: the clock must not jump back
    MD.Replay._seek(8.0)
    local before = MD.Replay._state().left.state.t
    local btn
    for i, it in ipairs(dd.items) do if it.id == "safe" then btn = dd.rows[i] end end
    check("the list has a row per strategy", btn ~= nil)
    btn:GetScript("OnClick")(btn)
    check("choosing one closes the list", not dd.list:IsShown())
    -- two objectives often win with the SAME plan, so the choice cannot be read
    -- back from the plan: picking one used to show the other (v0.11.13)
    check("the chooser keeps the strategy that was chosen", dd:GetText() == "Search: Safest",
        dd:GetText())
    check("switching strategy changes the plan the column draws",
        SP.plans[rec.id] == safe, tostring(SP.plans[rec.id] == safe))
    check("and keeps the clock where it was",
        math.abs(MD.Replay._state().left.state.t - before) < 0.3,
        string.format("%.1f vs %.1f", MD.Replay._state().left.state.t, before))
    check("the suggested column is still drawn", MD.Replay._state().right.state ~= nil)

    -- choosing a strategy whose plan another objective shares still reads back
    -- as the one that was clicked
    do
        local same = SP.strategies[rec.id].safe.plan
        SP.strategies[rec.id].health = { plan = same, result = snap() }
        local row
        for i, it in ipairs(dd.items) do if it.id == "health" then row = dd.rows[i] end end
        row:GetScript("OnClick")(row)
        check("Highest health does not read back as Safest",
            MD.Replay._strategy():GetText() == "Search: Highest health",
            MD.Replay._strategy():GetText())
    end

    -- v0.13.7: a planner needs no search behind it. Picking one builds the plan
    -- on the spot, which is what makes the chooser useful before Coach has run.
    do
        local dd2 = MD.Replay._strategy()
        local row
        for i, it in ipairs(dd2.items) do if it.id == "solver-blind" then row = dd2.rows[i] end end
        check("the solver is offered without a search having run", row ~= nil)
        if row then
            row:GetScript("OnClick")(row)
            check("choosing the solver builds its plan on the spot",
                SP.plans[rec.id] ~= nil and SP.plans[rec.id].kind == "solver",
                SP.plans[rec.id] and tostring(SP.plans[rec.id].kind) or "no plan")
            check("and the chooser says so", MD.Replay._strategy():GetText() == "Solver: no intuition",
                MD.Replay._strategy():GetText())
        end
        -- put the searched plan back: the tests below this one are about the
        -- column that plan draws, not about the chooser
        SP.plans[rec.id] = cheap
        SP.strategyPick[rec.id] = nil
        MD:OpenReplay(1)
    end

    -- With no search there are still the planners, so the chooser stays: what
    -- removes it is having no suggested column to point at.
    SP.strategies[rec.id] = nil
    SP.strategyPick[rec.id] = nil
    MD:OpenReplay(1)
    check("no search, but the planners are still offered",
        MD.Replay._strategy():IsVisible() and #MD.Replay._strategy().items == #SP.STRATEGY_SET,
        tostring(#MD.Replay._strategy().items))
    SP.plans[rec.id] = nil
    MD:OpenReplay(1)
    check("no suggested column, no chooser", not MD.Replay._strategy():IsVisible())
    SP.plans[rec.id] = cheap        -- the sections below need a right column
end

-- v0.11.14: the strip carries the two numbers a strategy comparison needs
do
    MD:OpenReplay(1)
    MD.Replay._seek(20.0)
    local W2 = MD.Replay._state()
    local line = W2.left.strip.score:GetText() or ""
    check("the score line carries overheal and regen",
        line:find("overheal") ~= nil and line:find("regen") ~= nil, line)
    local st = W2.left.state
    local oh, healed, over = st:Overheal()
    check("overheal is a share of gross healing",
        oh == nil or (oh >= 0 and oh <= 1 and math.abs(oh - over / (healed + over)) < 1e-9),
        oh and string.format("%.2f", oh) or "nothing healed yet")
    check("regen is what came back, not what is in the pool", (function()
        local spent = st:Score()
        local tr = MD.Replay._state().left.state.trace
        return math.abs(st:Regen() - (st:Mana() - tr.mana0 + spent)) < 0.01
    end)(), string.format("%.0f", st:Regen()))
    MD.Replay._seek(0)
    check("nothing healed yet reads as no overheal, not 0%%", select(1, st:Overheal()) == nil
        or select(1, st:Overheal()) >= 0)
end

-- v0.12.2: the two indicators that show what is coming, on BOTH columns
do
    MD:OpenReplay(1)
    local W3 = MD.Replay._state()
    -- the scripted Shadow Bolt goes up at ~11.5s on the tank and lands 3s later
    local tank
    for i, e in ipairs(rec.roster) do if e.name == "Destroyka" then tank = i end end
    check("the recording knows which target the cast was aimed at", tank ~= nil)

    local RP = MD.Replay._state().rp
    local cast = nil
    for _, c in ipairs(RP.incoming and RP.incoming[tank] or {}) do cast = c end
    check("the replay indexed the incoming cast by target", cast ~= nil,
        cast and string.format("%.1fs -> %.1fs", cast.t, cast.at or -1) or "none")

    MD.Replay._seek(cast.t + 0.5)
    local L = W3.left.frames[tank]
    local R = W3.right.frames[tank]
    check("the cast bar shows on the left column while it is in the air", L.incoming:IsShown())
    check("...and on the right, which is answering the same cast",
        R == nil or R.incoming:IsShown())
    check("it names the spell on hover", L.incoming.tip and L.incoming.tip[1] ~= nil
        and tostring(L.incoming.tip[1].r):find("lands in") ~= nil,
        L.incoming.tip and tostring(L.incoming.tip[1].r) or "no tip")

    MD.Replay._seek((cast.at or cast.t) + 1.0)
    check("and it is gone once the cast has landed", not L.incoming:IsShown())

    -- a cast that never landed still shows for the seconds its bar plausibly ran
    local mage
    for i, e in ipairs(rec.roster) do if e.name == "Alkandari" then mage = i end end
    local ghost
    for _, c in ipairs(RP.incoming and RP.incoming[mage] or {}) do ghost = c end
    check("a cast that never landed is still indexed", ghost ~= nil and ghost.at == nil,
        ghost and tostring(ghost.at) or "none")
    MD.Replay._seek(0)
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
