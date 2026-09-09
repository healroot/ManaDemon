-- tools/run.sh tools/reviewui.lua
--
-- The Review TAB under the stub (docs/SPEC-v0.9.md 4): loads the UI kit and
-- UI/Dashboard_Review.lua on top of the engine harness, records a scripted run,
-- and drives the pane the way a mouse would -- click the run's button, click a
-- row, read back what was painted and which buttons the pane turned off.
--
-- It exists for the same reason tools/replayui.lua does: a UI file's bugs are
-- nil indexes, argument orders and bare pipes, and none of those show up in a
-- syntax check. The v0.9.2 addition it guards is the "run:pull" address -- the
-- tab, the slash commands and the replay window all take it, so one of them
-- getting it wrong has to fail here.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB

S.Load({ "UI/Style.lua", "UI/Tooltip.lua", "UI/Dashboard_Review.lua", "UI/ReplayWindow.lua" },
    "ManaDemon", MD)

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-46s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local chat = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }

--------------------------------------------------------------------------------
-- one single fight (the shared scripted pull), then a run of two
--------------------------------------------------------------------------------
local ids = dofile(here .. "/fakepull.lua")(MD, S)
check("a single fight was recorded", #(MD.cdb.recordings or {}) == 1,
    tostring(#(MD.cdb.recordings or {})))

local parent = CreateFrame("Frame")
parent:SetSize(760, 420)
local api = MD.DashboardParts.CreateReview(parent, 760)
api.frame:SetSize(760, 420)
api.frame:Show()
api:Render()

-- the rows the pane painted, newest first, as the author sees them
local function Rows()
    local out = {}
    for _, f in ipairs(S.allFrames) do
        if f.cells and f.shown and f.cells.n then out[#out + 1] = f end
    end
    return out
end
local function CellText(row, key)
    local t = row.cells[key] and row.cells[key]:GetText() or ""
    return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function ButtonNamed(text)
    for _, f in ipairs(S.allFrames) do
        if f.kind == "Button" and f.text == text and f.shown ~= false then return f end
    end
    return nil
end
local function Click(btn) local fn = btn and btn:GetScript("OnClick"); if fn then fn(btn) end end

local rows = Rows()
check("the fights list paints a header and a row", #rows >= 2, tostring(#rows))
check("the fight's zone is in the row", (function()
    for _, r in ipairs(rows) do if CellText(r, "zone") == "Blood Furnace" then return true end end
    return false
end)())
check("no run button before a run exists", ButtonNamed("Blood Furnace test") == nil)

--------------------------------------------------------------------------------
-- a run: two pulls, one of them under the recording gate
--------------------------------------------------------------------------------
local SD = MD.SpellData
local PLAYER = "Player-1"
local function ev(sub, src, dst, dstName, ...)
    S.Combat(0, sub, false, src, "src", 0, 0, dst, dstName, 0, 0, ...)
end
local function cast(spellID)
    ev("SPELL_CAST_SUCCESS", PLAYER, "Tank-1", "Destroyka", spellID, "S", 8)
    S.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, spellID)
    S.mana = S.mana - (SD:GetCost(spellID) or 0)
    S.Fire("UNIT_POWER_UPDATE", "player", "MANA")
end
local function advance(sec) for _ = 1, math.floor(sec / 0.5 + 0.5) do S.Tick(0.5) end end
local function pull(dur, casts)
    S.units.party1.hp = 3000
    S.Fire("PLAYER_REGEN_DISABLED")
    ev("SWING_DAMAGE", "Mob-1", "Tank-1", "Destroyka", 5000, 0, 1, 0, 0, 0, false)
    local gap = dur / (casts + 1)
    for i = 1, casts do
        advance(gap)
        cast(i % 2 == 0 and SD.maxRank.Regrowth or SD.maxRank.Rejuvenation)
    end
    advance(gap)
    S.Fire("PLAYER_REGEN_ENABLED")
end

S.mana = 5000
local run = MD.RunRecorder:Start("manual", "Ramparts test")
pull(40, 8)
advance(6)
pull(8, 2)          -- under the gate
advance(2)
MD.RunRecorder:Stop("manual")
check("the run kept both pulls", #run.pulls == 2, tostring(#run.pulls))

api:Render()
local runBtn = ButtonNamed("Ramparts test")
check("a button appears for the run", runBtn ~= nil)
Click(runBtn)

rows = Rows()
local pullRows = {}
for _, r in ipairs(rows) do
    local n = CellText(r, "n")
    if n == "1" or n == "2" then pullRows[tonumber(n)] = r end
end
check("the run's pulls are listed", pullRows[1] ~= nil and pullRows[2] ~= nil)
check("a pull's time is its offset into the run", CellText(pullRows[2], "when"):match("^%+%d+:%d%d$") ~= nil,
    pullRows[2] and CellText(pullRows[2], "when"))
check("the short pull says why it is greyed",
    CellText(pullRows[2], "valid"):find("short") ~= nil, CellText(pullRows[2], "valid"))
check("the long pull is not called short",
    CellText(pullRows[1], "valid"):find("short") == nil, CellText(pullRows[1], "valid"))
check("the run line is painted above the list", (function()
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find("run Ramparts test") then return true end
    end
    return false
end)())

-- while a run is shown, Coach coaches the RUN and a second button coaches the
-- selected pull; that one is off for a pull under the gate
check("Coach becomes Coach run", ButtonNamed("Coach run") ~= nil)
Click(pullRows[2]); api:Render()
local coachPull = ButtonNamed("Coach pull") or ButtonNamed("Coach pull*")
check("Coach pull is disabled on the short pull", coachPull and coachPull.enabled == false,
    tostring(coachPull and coachPull.enabled))
Click(pullRows[1]); api:Render()
coachPull = ButtonNamed("Coach pull") or ButtonNamed("Coach pull*")
check("Coach pull is enabled on the real pull", coachPull and coachPull.enabled ~= false,
    tostring(coachPull and coachPull.enabled))
check("Coach run is enabled while the run has pulls", (function()
    local b = ButtonNamed("Coach run"); return b and b.enabled ~= false
end)())

-- Pin, while a run is shown, pins the RUN
local pin = ButtonNamed("Pin run")
check("the pin button offers the run", pin ~= nil)
Click(pin); api:Render()
check("pinning a run pins the run, not the pull", run.pinned == true and not run.pulls[1].pinned)
check("the button now offers to unpin", ButtonNamed("Unpin run") ~= nil)
Click(ButtonNamed("Unpin run")); api:Render()
check("unpinning works", run.pinned == false)

--------------------------------------------------------------------------------
-- the run:pull address, end to end: the tab's Play button opens the replay
-- window on a pull inside a run
--------------------------------------------------------------------------------
local realValidate = MD.SimModel.Validate
function MD.SimModel:Validate(...) local v = realValidate(self, ...); v.ok = true; return v end
Click(pullRows[1]); api:Render()
Click(ButtonNamed("Play"))
local W = MD.Replay._state()
check("Play opened the replay window", W.frame ~= nil and W.frame:IsShown())
local head = W.frame and MD.Replay._state() and nil
local headText = (function()
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find("Ramparts test pull 1") then return t end
    end
    return nil
end)()
check("the replay header names the run and the pull", headText ~= nil, headText or "not painted")
MD.SimModel.Validate = realValidate

-- the run strip: the pulls of the run on one line, click to play one
local W2 = MD.Replay._state()
check("the run strip is drawn for a pull inside a run", (function()
    local st = MD.Replay._runStrip and MD.Replay._runStrip()
    return st ~= nil and st.shown == true and #st.pulls == 2
end)(), (function()
    local st = MD.Replay._runStrip and MD.Replay._runStrip()
    return st and tostring(st.shown) .. ", " .. #st.pulls or "no strip"
end)())
check("the strip's blocks are as wide as the pulls were long", (function()
    local st = MD.Replay._runStrip()
    local a, b = st.pulls[1], st.pulls[2]
    if not (a and b) then return false end
    -- pull 1 is 40s, pull 2 is 9s: the first block must be much the wider
    return a:GetWidth() > b:GetWidth() * 2
end)())
check("clicking a block opens that pull", (function()
    local st = MD.Replay._runStrip()
    local fn = st.pulls[2]:GetScript("OnClick")
    if not fn then return false end
    fn(st.pulls[2])
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find("Ramparts test pull 2") then return true end
    end
    return false
end)())

-- the same address from the command line
MD:OpenReplay("1:2")
MD:OpenReplay("run 1")
check("/md replay run 1 opens the run's first pull", (function()
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find("Ramparts test pull 1") then return true end
    end
    return false
end)())
MD:OpenReplay("1:2")
check("/md replay 1:2 opens the second pull", (function()
    for _, f in ipairs(S.allFrames) do
        local t = f.GetText and f:GetText() or ""
        if type(t) == "string" and t:find("Ramparts test pull 2") then return true end
    end
    return false
end)())
local before = #chat
MD:OpenReplay("1:9")
check("a pull that does not exist says so, and does not error",
    (chat[#chat] or ""):find("no recording 1:9") ~= nil, chat[#chat])

--------------------------------------------------------------------------------
-- back to the fights list, and no bare pipes anywhere
--------------------------------------------------------------------------------
Click(ButtonNamed("Fights"))
api:Render()
check("back on the fights list the run button is gone", ButtonNamed("Coach run") == nil
    and (ButtonNamed("Coach") ~= nil or ButtonNamed("Coach*") ~= nil))
rows = Rows()
check("switching back shows the single fights", (function()
    for _, r in ipairs(rows) do if CellText(r, "zone") == "Blood Furnace" then return true end end
    return false
end)())

--------------------------------------------------------------------------------
-- shift-clicking Coach forces it on a fight the gates reject (v0.9.8). The
-- button stays clickable for that case on purpose: a disabled button cannot be
-- shift-clicked, and a plain click still refuses.
--------------------------------------------------------------------------------
Click(ButtonNamed("Fights"))
api:Render()
do
    local rec1 = MD.FightRecorder:Get(1)
    MD.SimPlanner.plans[rec1.id] = nil
    MD.SimPlanner.forced[rec1.id] = nil
    MD.player.isDruid = true
    api:Render()
    local star = ButtonNamed("Coach*")
    check("a rejected fight keeps a clickable Coach, marked", star ~= nil and star.enabled ~= false,
        star and tostring(star.enabled) or "no starred button")

    out = {}
    chat = {}
    S.shift = false
    Click(star)
    for _ = 1, 200 do S.Tick(0.016) end
    check("a plain click refuses and names a gate", MD.SimPlanner.plans[rec1.id] == nil
        and (function()
            for _, m in ipairs(chat) do if m:find("does not replay") then return true end end
            return false
        end)(), chat[1] or "no chat")

    S.shift = true
    Click(ButtonNamed("Coach*"))
    local frames = 0
    while MD.coachSearch and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
    S.shift = false
    check("shift-click coaches it anyway", MD.SimPlanner.plans[rec1.id] ~= nil,
        string.format("%d frames", frames))
    check("and the forced coach is remembered for Play", MD.SimPlanner.forced[rec1.id] == true)
    MD:OpenReplay(1)
    check("so Play alone now shows both columns", MD.Replay._state().right.state ~= nil)
    MD.SimPlanner.forced[rec1.id] = nil
end

--------------------------------------------------------------------------------
-- forcing the suggested column onto a fight the gates reject (v0.9.6)
--------------------------------------------------------------------------------
Click(ButtonNamed("Fights"))
api:Render()
local single = MD.FightRecorder:Get(1)
MD.SimPlanner.plans[single.id] = MD.SimPlanner.NewPlan(MD.SimPlanner.MaxRankBinds(),
    { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 3, hotBelow = 0.80, filler = false },
    MD.RankMath:SpellKit())
MD.SimPlanner.forced[single.id] = nil
check("the scripted fight really does fail its gates", (function()
    local v = MD.SimModel:Validate(single)
    return v and not v.ok
end)())
MD:OpenReplay(1)
check("no suggested column on a fight that does not replay", MD.Replay._state().right.state == nil)
MD:OpenReplay("1 force")
check("force draws it", MD.Replay._state().right.state ~= nil)
check("and the column says it was forced", (function()
    local t = MD.Replay._state().right.title:GetText() or ""
    return t:find("FORCED") ~= nil
end)(), MD.Replay._state().right.title:GetText())

-- a forced coach is remembered, so Play alone shows it afterwards
MD:OpenReplay(1)
check("without force it is hidden again", MD.Replay._state().right.state == nil)
MD.SimPlanner.forced[single.id] = true
MD:OpenReplay(1)
check("a fight coached with force stays forced", MD.Replay._state().right.state ~= nil)
MD.SimPlanner.forced[single.id] = nil

-- shift-clicking Play is the same thing from the tab
MD:OpenReplay(1)
S.shift = true
Click(ButtonNamed("Play"))
S.shift = false
check("shift-click Play forces from the tab", MD.Replay._state().right.state ~= nil)

-- a single fight has no run strip at all
MD:OpenReplay(1)
check("no run strip for a single fight", (function()
    local st = MD.Replay._runStrip()
    return st and st.shown == false and st.run == nil
end)(), (function()
    local st = MD.Replay._runStrip()
    return st and (tostring(st.shown) .. ", run " .. tostring(st.run)) or "no strip"
end)())

local bad = {}
for _, f in ipairs(S.allFrames) do
    local t = f.GetText and f:GetText() or ""
    if type(t) == "string" then
        local stripped = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if stripped:find("|", 1, true) then bad[#bad + 1] = t end
    end
end
check("no bare pipe in any painted string", #bad == 0, bad[1])

--------------------------------------------------------------------------------
-- v0.13.9: opening a replay coaches in the background. That must not get in the
-- way of the author pressing Coach -- theirs wins and cancels ours.
--------------------------------------------------------------------------------
do
    MD.coachSearch = { Cancel = function() end }
    MD.replayCoaching = 12345
    MD:RunCoach("1 force")
    check("an explicit coach cancels the automatic one",
        MD.replayCoaching == nil, tostring(MD.replayCoaching))
    if MD.coachSearch and MD.coachSearch.Cancel then MD.coachSearch:Cancel() end
    MD.coachSearch = nil
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
