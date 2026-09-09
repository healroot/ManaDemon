-- The replay window (docs/SPEC-v0.8.md 3): a recorded fight played back as two
-- columns of unit frames on one clock -- ACTUAL on the left (the recorded
-- casts through the engine), SUGGESTED on the right (the plan Coach found) --
-- with the recorder's real HP snapshots drawn as ticks on the left bars, so the
-- reconstruction's error is visible at every moment. Both columns are engine
-- output: the damage is identical by construction and every visible difference
-- is a healer decision.
--
-- This file only PAINTS. Everything it knows about a moment comes from
-- Engine/ReplayTrace.lua (`Seek`, `Advance`, `Hp`, `Hot`, `Casting`, ...); the
-- two states advance the same dt from the same OnUpdate, there is no per-column
-- clock. Nothing is interpolated: a heal is a jump and between grid points the
-- bar holds. The window never opens in combat, never runs the search (Play
-- shows what Coach found), and never touches the recorder.
local _, MD = ...
local UI = MD.UI

local COL_W = 460              -- the healer strip's width; a column is at least this wide
local GUTTER = 16
local HEADER_H, STRIP_H, SCRUB_H = 26, 96, 96
local RUNSTRIP_H = 26          -- the run strip, drawn only when the pull belongs to a run
local DT_STEP_MAX = 0.25       -- never advance more than this per frame at 1x (a hitch is not a skip)
local FLASH_CAST, FLASH_TEXT, FLASH_FOREIGN, PULSE_DMG = 0.8, 0.8, 0.4, 0.4
local GCD = 1.5                -- an instant still locks the healer for this long
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
local TICK_FADE = 5            -- the recorder's snapshot cadence

-- The author's Cell layout ("default"), copied from their SavedVariables on
-- 2026-09-06 -- NOT read from Cell at runtime, by their request. The frames
-- here are shaped to it so a replay reads like the raid frames the healer
-- actually plays on: same button, same icon slots, same colours. When the
-- Cell layout changes, change this table.
local CELL = {
    size = { 66, 46 }, spacingX = 3, spacingY = 3, unitsPerColumn = 5, powerSize = 2,
    lossFactor = 0.2,                                   -- lossColor = class_color_dark (class * 0.2)
    lossFlash = { 0.667, 0, 0 },                        -- the custom loss red, used for the damage pulse
    nameWidth = 0.75,                                   -- nameText textWidth 75% of the bar
    roleIcon = { "TOPLEFT", 0, 0, 11 },
    hots = { "TOPRIGHT", 0, 3, 13, -1 },                -- indicator1 "Healers": 13px, right-to-left
    defensives = { "LEFT", -2, 5, 12, 20, 1, 2 },       -- 12x20, left-to-right, 2
    debuffs = { "BOTTOMLEFT", 1, 4, 13, 1, 3 },         -- 13px, left-to-right, 3
    healthText = { "BOTTOMRIGHT", 0, 0 },               -- deficit_short
    swiftmend = { 9, -1, -(13 + 5) },                   -- ours: 9px at the right edge, under the HoT row
    targetedSpells = { "TOPLEFT", -4, 4, 20 },          -- 20px, one icon, border 2, TOPLEFT -4,4
    aggroBar = { 20, 4 },                               -- 20x4 above the button's top-left
    statusText = { "BOTTOM", 0, 0 },                    -- 11px with background: cast name, label, dead
    fonts = { name = 13, health = 12, status = 11, count = 11 },
    textScaleMax = 2,                                   -- status / deficit / counts stop growing here; the name does not
}
-- Frames scale with the head-count (author, 2026-09-06): a raid at Cell's own
-- size, a party stretched across the column, a solo fight big enough to read.
--   n = 1      : x3.5 both ways
--   n <= 5     : x1.6 tall, as wide as the column
--   n <= 10    : x1.25, two columns
--   otherwise  : x1, five per column
local function ScaleFor(n)
    if n <= 1 then return 3.5, 1, false end
    if n <= 5 then return 1.6, 1, true end
    if n <= 10 then return 1.25, 2, true end
    return 1, math.ceil(n / CELL.unitsPerColumn), false
end
-- Blizzard's role atlas, the coordinates Cell's roleIcon uses
local ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_COORD = {
    TANK = { 0, 19 / 64, 22 / 64, 41 / 64 }, HEALER = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
    DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}

-- Family colours, one table (spec 3.2). Utility and shifts are grey.
local FAMILY_COLOR = {
    Rejuvenation = { 0.72, 0.45, 0.95 }, Regrowth = { 0.35, 0.85, 0.35 }, Lifebloom = { 0.75, 0.90, 0.25 },
    HealingTouch = { 0.35, 0.60, 1.00 }, Swiftmend = { 1.00, 0.60, 0.20 }, Tranquility = { 0.30, 0.85, 0.85 },
    other = { 0.6, 0.6, 0.6 },
}
-- Label colours (spec 4.2): what the classifier said about each recorded cast,
-- shown in the status slot as the cast lands and on the scrubber's cast ticks.
local LABEL_COLOR = {
    late = { 1, 0.3, 0.3 }, overheal = { 1, 0.6, 0.2 }, early = { 1, 0.9, 0.3 }, stack = { 1, 0.9, 0.3 },
    spell = { 0.8, 0.8, 0.8 }, rank = { 0.8, 0.8, 0.8 }, fine = { 0.5, 0.5, 0.5 },
    unclassified = { 0.5, 0.5, 0.5 },
}
local LABEL_FLASH = 1.5
local SWIFTMEND = 18562

local frame, scrubber, playBtn, timeFS, headerFS, speedHighlight, speedButtons
local runStrip                  -- the run's pulls and drinks on one timeline (v0.9.4)
local stratDrop                                -- the strategy chooser (v0.11.11)
local openSpec, openForce                      -- what the window was opened with, for a rebuild
local runIdx, pullIdx, curRun   -- which pull of which run is open, if any
local topH = HEADER_H           -- header, plus the run strip when there is one
local left, right          -- the two columns: { state, frames = {}, strip = {}, title }
local rp                   -- the SP.Replay result being shown

-- Does the healer of the recording being played have Swiftmend at all?
local function HasSwiftmend()
    local known = rp and rp.rec and rp.rec.initial and rp.rec.initial.known
    if known then return known.Swiftmend ~= nil end
    return (MD.SpellData.maxRank or {}).Swiftmend ~= nil
end
local rows = {}            -- roster indices in display order
local playing, speed = false, 1
local classColorCache = {}

-- Show/Hide rather than SetShown: the older pair exists on every client this
-- addon targets, and a font string has no SetShown on some of them.
local function Shown(obj, on) if on then obj:Show() else obj:Hide() end end

local function ClassColor(class)
    local c = classColorCache[class]
    if c then return c end
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    c = cc and { cc.r, cc.g, cc.b } or { 0.6, 0.6, 0.6 }
    classColorCache[class] = c
    return c
end

local rankCount = nil
local function SpellLabel(spellID)
    local SD = MD.SpellData
    local sd = SD.spells[spellID]
    if sd then
        if not rankCount then
            rankCount = {}
            for _, s in pairs(SD.spells) do rankCount[s.family] = (rankCount[s.family] or 0) + 1 end
        end
        local fam = SD.families[sd.family]
        local name = fam and fam.label or sd.family
        if (rankCount[sd.family] or 1) > 1 then name = string.format("%s R%d", name, sd.rank) end
        return name, sd.family
    end
    local ok, name = pcall(GetSpellInfo, spellID)
    return (ok and name) or ("spell " .. tostring(spellID)), "other"
end

local function Clock(sec)
    if sec < 0 then sec = 0 end
    return string.format("%d:%04.1f", math.floor(sec / 60), sec % 60)
end

local function K(n)
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return string.format("%d", n + 0.5)
end

--------------------------------------------------------------------------------
-- Building one column
--------------------------------------------------------------------------------
local function CreateBar(parent, width, height)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width, height)
    bar:SetStatusBarTexture(UI.whiteTexture)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.06, 0.06, 1)
    bar.bg = bg
    return bar
end

-- The base font the kit uses, for scaled copies
local FONT_PATH, FONT_FLAGS
do
    local fo = _G[UI.FONT]
    local ok, path, _, flags = pcall(function() return fo:GetFont() end)
    FONT_PATH = (ok and path) or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    FONT_FLAGS = (ok and flags) or ""
end
local function Font(fs, size)
    pcall(fs.SetFont, fs, FONT_PATH, size, "OUTLINE")
end

local function CreateUnitFrame(parent, x, y)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UI.StylizeFrame(f, { 0, 0, 0, 1 }, { 0, 0, 0, 1 })

    -- Frame levels, as Cell lays them: the bars lowest, indicators above them,
    -- text on top. Two children of one button share a level by default and
    -- the later-drawn bar covered the icons' textures (the first in-game look:
    -- a bare stack count over solid class colour).
    local base = f:GetFrameLevel()
    f.top = CreateFrame("Frame", nil, f)
    f.top:SetAllPoints(f)
    f.top:SetFrameLevel(base + 20)

    -- the health bar fills the button inside its 1px border, above the power strip
    f.bar = CreateBar(f, 10, 10)
    f.bar:SetFrameLevel(base + 1)
    f.power = CreateBar(f, 10, 2)
    f.power:SetFrameLevel(base + 1)
    f.power:SetStatusBarColor(0, 0.5, 1)
    f.power.bg:SetColorTexture(0.15, 0.15, 0.15, 1)

    -- the damage pulse: the loss red washed over the bar, fading
    f.pulse = f.bar:CreateTexture(nil, "ARTWORK", nil, 1)
    f.pulse:SetAllPoints(f.bar)
    f.pulse:SetColorTexture(CELL.lossFlash[1], CELL.lossFlash[2], CELL.lossFlash[3], 0)

    -- the snapshot tick (left column only): the truth over the reconstruction,
    -- with a hover frame wide enough to hit that says what it is
    f.tick = f.bar:CreateTexture(nil, "OVERLAY")
    f.tick:SetColorTexture(1, 1, 1, 0)
    f.tickHit = CreateFrame("Frame", nil, f)
    f.tickHit:SetFrameLevel(base + 21)
    f.tickHit:EnableMouse(true)
    f.tickHit:Hide()
    f.tickHit:SetScript("OnEnter", function(self)
        if not (MD.Tip and f.tickInfo) then return end
        local ti = f.tickInfo
        MD.Tip:Show(self, "ANCHOR_RIGHT", {
            { l = "Recorded health", r = string.format("%d%% at %s", ti.rec * 100 + 0.5, Clock(ti.at)) },
            { l = "Engine's reconstruction now", r = string.format("%d%%", ti.sim * 100 + 0.5) },
            { l = string.format("|cff888888%s|r", math.abs(ti.rec - ti.sim) <= 0.05
                and "within the health gate's 5%" or "outside the health gate's 5% -- this is the replay's error"), r = "" },
            { l = "|cff888888The recorder reads real HP every 5s; the bar is the engine's|r", r = "" },
            { l = "|cff888888account of the same fight. The tick is the truth mark.|r", r = "" },
        })
    end)
    f.tickHit:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)

    -- nameText: centred on the bar, class colour, 75% of the bar's width
    f.name = f.bar:CreateFontString(nil, "OVERLAY", UI.FONT)
    f.name:SetPoint("CENTER", f.bar, "CENTER", 0, 0)
    f.name:SetJustifyH("CENTER")
    f.name:SetWordWrap(false)

    -- healthText: deficit_short, bottom-right of the bar
    f.pct = f.bar:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.pct:SetJustifyH("RIGHT")

    -- roleIcon, top-left
    f.role = f.top:CreateTexture(nil, "OVERLAY")
    pcall(f.role.SetTexture, f.role, ROLE_TEX)

    -- statusText: the bottom strip -- the cast in flight to this unit or the
    -- one that just landed, then the classifier's label, or DEAD. Cell has no
    -- slot for a cast target; this is the one addition. The background is
    -- drawn only while there is text.
    f.statusBG = f.top:CreateTexture(nil, "ARTWORK")
    f.statusBG:SetColorTexture(0, 0, 0, 0.6)
    f.statusBG:Hide()
    f.cast = f.top:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.cast:SetJustifyH("CENTER")
    f.cast:SetWordWrap(false)
    f.cast:SetText("")
    f.label = f.top:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    f.label:SetJustifyH("CENTER")
    f.label:SetWordWrap(false)
    f.label:SetText("")
    -- what the two strings hold, kept here: GetText() on an empty font string
    -- is nil on this client, and "nil ~= ''" drew the strip's background over
    -- every button that had nothing to say (the brown band of the first look)
    f.castText, f.labelText = "", ""
    function f.SetCast(text) f.castText = text or ""; f.cast:SetText(f.castText) end
    function f.SetLabel(text) f.labelText = text or ""; f.label:SetText(f.labelText) end

    -- One icon builder for HoTs, defensives and debuffs: the spell's texture,
    -- a Cell-style VERTICAL sweep (the elapsed share of the icon dimmed from
    -- the top down, a 1px spark at the edge -- Cell/Indicators/Base.lua's
    -- VerticalCooldown, done with an overlay rather than a mask because the
    -- window paints every frame anyway), a stack count bottom-right, and a
    -- lettered fallback when no texture resolves.
    local function Icon(level)
        local ic = CreateFrame("Frame", nil, f, "BackdropTemplate")
        ic:SetFrameLevel(base + (level or 5))
        UI.StylizeFrame(ic, { 0.15, 0.15, 0.15, 1 }, { 0, 0, 0, 1 })
        ic.tex = ic:CreateTexture(nil, "ARTWORK")
        ic.tex:SetPoint("TOPLEFT", ic, "TOPLEFT", 1, -1)
        ic.tex:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", -1, 1)
        ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.dim = ic:CreateTexture(nil, "OVERLAY", nil, 1)
        ic.dim:SetPoint("TOPLEFT", ic, "TOPLEFT", 1, -1)
        ic.dim:SetPoint("TOPRIGHT", ic, "TOPRIGHT", -1, -1)
        ic.dim:SetHeight(1)
        ic.dim:SetColorTexture(0, 0, 0, 0.65)
        ic.dim:Hide()
        ic.spark = ic:CreateTexture(nil, "OVERLAY", nil, 2)
        ic.spark:SetPoint("TOPLEFT", ic.dim, "BOTTOMLEFT", 0, 0)
        ic.spark:SetPoint("TOPRIGHT", ic.dim, "BOTTOMRIGHT", 0, 0)
        ic.spark:SetHeight(1)
        ic.spark:SetColorTexture(0.8, 0.8, 0.8, 0.9)
        ic.spark:Hide()
        ic.letter = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.letter:SetPoint("CENTER")
        ic.count = ic:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
        ic.count:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, -1)
        ic.text = ic.count   -- older name, kept for the harness
        ic:EnableMouse(true)
        ic:SetScript("OnEnter", function(self)
            if MD.Tip and self.tip then MD.Tip:Show(self, "ANCHOR_RIGHT", self.tip) end
        end)
        ic:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)
        ic:Hide()
        return ic
    end

    f.hots = {}
    for fi = 1, 3 do f.hots[fi] = Icon(5) end
    -- Swiftmend: an icon under the HoT row -- full while it is ready and has
    -- something to eat, sweeping its cooldown otherwise (the author asked for
    -- the icon in place of the 5px dot)
    f.dot = Icon(5)
    f.defIcon = Icon(10)
    f.defIcon:SetBackdropBorderColor(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    f.debuffs = {}
    for i = 1, CELL.debuffs[6] do f.debuffs[i] = Icon(5) end
    -- v0.12.2: the two indicators the author has that show what is COMING --
    -- Cell's "Targeted Spells" (a hostile cast aimed here) and its "Aggro (bar)"
    -- -- in their own positions. Drawn on both columns: both are watching the
    -- same fight, and the suggested column is answering the same cast bar.
    f.incoming = Icon(12)
    f.aggro = f:CreateTexture(nil, "OVERLAY")
    f.aggro:Hide()
    f.auraBuf = {}

    -- Size and place everything for a button of W x H pixels at scale s: the
    -- slots keep their Cell positions, the offsets and icons grow with s, the
    -- bar and the name stretch with the width.
    function f.Resize(W, H, sc)
        f.scale, f.width = sc, W
        f:SetSize(W, H)
        local pw = math.max(1, CELL.powerSize * sc)
        f.bar:ClearAllPoints()
        f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        f.bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1 + pw)
        f.power:ClearAllPoints()
        f.power:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        f.power:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        f.power:SetHeight(pw)
        f.tick:SetSize(math.max(2, 2 * sc), H - 2 - pw)
        f.name:SetWidth((W - 2) * CELL.nameWidth)
        local ts = CELL.targetedSpells
        f.incoming:SetSize(ts[4] * sc, ts[4] * sc)
        f.incoming.size = ts[4] * sc      -- Sweep reads it to size the dim overlay
        f.incoming:ClearAllPoints()
        f.incoming:SetPoint("TOPLEFT", f, "TOPLEFT", ts[2] * sc, ts[3] * sc)
        f.aggro:SetSize(CELL.aggroBar[1] * sc, math.max(1, CELL.aggroBar[2] * sc))
        f.aggro:ClearAllPoints()
        f.aggro:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 1)
        Font(f.name, CELL.fonts.name * sc)
        local ht = CELL.healthText
        f.pct:ClearAllPoints()
        f.pct:SetPoint(ht[1], f.bar, ht[1], ht[2] * sc, ht[3] * sc)
        local ts = math.min(sc, CELL.textScaleMax)
        Font(f.pct, CELL.fonts.health * ts)
        local ri = CELL.roleIcon
        f.role:SetSize(ri[4] * sc, ri[4] * sc)
        f.role:ClearAllPoints()
        f.role:SetPoint(ri[1], f, ri[1], ri[2] * sc, ri[3] * sc)
        local stt = CELL.statusText
        local sh = 12 * ts
        f.statusBG:ClearAllPoints()
        f.statusBG:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1 + pw)
        f.statusBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1 + pw)
        f.statusBG:SetHeight(sh)
        for _, fs in ipairs({ f.cast, f.label }) do
            fs:ClearAllPoints()
            fs:SetPoint(stt[1], f, stt[1], stt[2] * sc, stt[3] + pw + 1)
            fs:SetWidth(W - 4)
            Font(fs, CELL.fonts.status * ts)
        end
        -- the HoT icons are sized here and PLACED in PaintFrame: like Cell's
        -- icon indicators they pack from the anchor, so a lone Lifebloom sits
        -- in the first slot rather than floating in the third
        local ho = CELL.hots
        for fi = 1, 3 do
            local ic = f.hots[fi]
            ic:SetSize(ho[4] * sc, ho[4] * sc); ic.size = ho[4] * sc
            ic.slot = nil
            Font(ic.count, CELL.fonts.count * ts); Font(ic.letter, CELL.fonts.count * ts)
        end
        -- Swiftmend: smaller than a HoT icon, at the right edge under the row
        local sm = CELL.swiftmend
        f.dot:SetSize(sm[1] * sc, sm[1] * sc); f.dot.size = sm[1] * sc
        f.dot:ClearAllPoints()
        f.dot:SetPoint("TOPRIGHT", f, "TOPRIGHT", sm[2] * sc, sm[3] * sc)
        Font(f.dot.count, CELL.fonts.count * ts); Font(f.dot.letter, CELL.fonts.count * ts)
        f.pctRaised = nil
        local de = CELL.defensives
        f.defIcon:SetSize(de[4] * sc, de[5] * sc); f.defIcon.size = de[5] * sc
        f.defIcon:ClearAllPoints()
        f.defIcon:SetPoint(de[1], f, de[1], de[2] * sc, de[3] * sc)
        Font(f.defIcon.count, CELL.fonts.count * ts); Font(f.defIcon.letter, CELL.fonts.count * ts)
        local db = CELL.debuffs
        for i, ic in ipairs(f.debuffs) do
            ic:SetSize(db[4] * sc, db[4] * sc); ic.size = db[4] * sc
            ic:ClearAllPoints()
            ic:SetPoint(db[1], f, db[1], (db[2] + db[5] * (i - 1) * db[4]) * sc, db[3] * sc)
            Font(ic.count, CELL.fonts.count * ts); Font(ic.letter, CELL.fonts.count * ts)
        end
    end
    f.Resize(CELL.size[1], CELL.size[2], 1)

    f.flashUntil, f.textUntil, f.labelFrom, f.labelUntil, f.pulseUntil = 0, 0, 0, 0, 0
    return f
end

local function CreateStrip(parent, x, y)
    local s = {}
    s.mana = CreateBar(parent, COL_W - 70, 18)
    s.mana:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    s.mana:SetStatusBarColor(0.25, 0.45, 0.95)
    s.manaFS = s.mana:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.manaFS:SetPoint("CENTER")
    s.form = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.form:SetPoint("LEFT", s.mana, "RIGHT", 8, 0)
    s.form:SetTextColor(0.7, 0.7, 0.7)

    -- the cast bar: a real cast fills over its cast time in the family colour;
    -- an instant sweeps the GCD in grey (the healer is locked either way).
    -- The name STAYS until the next cast, dimmed once the bar is done -- the
    -- question the strip answers is "what was I doing", not "is a bar moving".
    s.cast = CreateBar(parent, COL_W - 70, 18)
    s.cast:SetPoint("TOPLEFT", s.mana, "BOTTOMLEFT", 0, -6)
    s.cast:SetStatusBarColor(0.8, 0.8, 0.8)
    s.castFS = s.cast:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.castFS:SetPoint("LEFT", s.cast, "LEFT", 5, 0)
    s.castFS:SetJustifyH("LEFT")
    s.castFS:SetWordWrap(false)
    s.wait = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.wait:SetPoint("LEFT", s.cast, "RIGHT", 8, 0)
    s.wait:SetTextColor(0.6, 0.6, 0.6)
    -- the wait band: a grey wash over the cast bar while the plan holds
    s.band = s.cast:CreateTexture(nil, "ARTWORK")
    s.band:SetAllPoints(s.cast)
    s.band:SetColorTexture(0.5, 0.5, 0.5, 0)
    -- hovering the cast bar names the rule behind the current cast or wait
    s.cast:EnableMouse(true)
    s.cast:SetScript("OnEnter", function(self)
        if not (MD.Tip and s.why) then return end
        MD.Tip:Show(self, "ANCHOR_TOP", s.why)
    end)
    s.cast:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)

    s.score = parent:CreateFontString(nil, "OVERLAY", UI.FONT)
    s.score:SetPoint("TOPLEFT", s.cast, "BOTTOMLEFT", 0, -8)
    s.score:SetJustifyH("LEFT")
    s.score:SetWidth(COL_W)
    s.gcdUntil, s.gcdStart = 0, 0
    return s
end

local function CreateColumn(x, titleText)
    local col = { frames = {}, x = x }
    col.title = frame:CreateFontString(nil, "OVERLAY", UI.FONT_TITLE)
    col.title:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(HEADER_H + 6))
    col.title:SetText(titleText)
    col.strip = CreateStrip(frame, x, -(HEADER_H + 30))
    return col
end

--------------------------------------------------------------------------------
-- Visual events: what onEvent does with a crossed event. State is read from
-- the machine every frame; these only start the short-lived effects.
--------------------------------------------------------------------------------
local function MakeOnEvent(col)
    local RT, TK = MD.ReplayTrace, MD.SimModel.TK
    return function(kind, tgt, a, b, t)
        local now = GetTime()
        local f = tgt and col.frames[tgt]
        if kind == TK.CAST then
            local label, family = SpellLabel(a)
            if f then
                local c = FAMILY_COLOR[family] or FAMILY_COLOR.other
                f:SetBackdropBorderColor(c[1], c[2], c[3], 1)
                f.flashUntil = now + FLASH_CAST
                f.SetCast(label)
                f.cast:SetTextColor(c[1], c[2], c[3])
                f.textUntil = now + FLASH_TEXT
                -- the classifier's word for this cast (left column, plan present),
                -- in the same slot once the name has had its moment
                local lc = col.state and col.state.lastCast
                local cl = col.isLeft and rp.casts and lc and rp.casts[lc.n]
                if cl and cl.label and cl.label ~= "utility" and cl.label ~= "shift" then
                    local lcol = LABEL_COLOR[cl.label] or LABEL_COLOR.unclassified
                    f.SetLabel(cl.label)
                    f.label:SetTextColor(lcol[1], lcol[2], lcol[3])
                    f.labelFrom, f.labelUntil = now + FLASH_TEXT, now + FLASH_TEXT + LABEL_FLASH
                end
            end
            local tgtName = rp.rec.roster[tgt] and rp.rec.roster[tgt].name
            col.strip.lastCast = label .. (tgtName and (" -> " .. tgtName) or "")
            col.strip.lastFamily = family
            -- an instant: sweep the GCD from this moment (replay clock, not wall clock)
            local c = col.state and col.state:Casting()
            col.strip.gcdStart, col.strip.gcdUntil = t, t + GCD
        elseif kind == RT.EV_DMG then
            if f then
                local maxHP = rp.scenario.targets[tgt] and rp.scenario.targets[tgt].maxHP or 1
                local frac = (a or 0) / maxHP
                if frac > 1 then frac = 1 end
                f.pulseAlpha = 0.25 + 0.6 * frac
                f.pulseUntil = now + PULSE_DMG
            end
        elseif kind == RT.EV_FHEAL then
            if f then
                f:SetBackdropBorderColor(1, 1, 1, 0.8)
                f.flashUntil = now + FLASH_FOREIGN
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Painting a moment
--------------------------------------------------------------------------------
local function AuraName(spellID)
    local d = MD.AuraList and MD.AuraList.Defensive(spellID)
    if d then return d[1] end
    local ok, name = pcall(GetSpellInfo, spellID)
    return (ok and name) or ("spell " .. tostring(spellID))
end

local textureCache = {}
local function SpellTexture(spellID)
    local tex = textureCache[spellID]
    if tex ~= nil then return tex or nil end
    local ok, t = pcall(GetSpellTexture, spellID)
    if not (ok and t) then
        -- this client may not have GetSpellTexture; GetSpellInfo's third
        -- return is the icon on the 2.5.x client
        local ok2, _, _, icon = pcall(GetSpellInfo, spellID)
        if ok2 and icon then ok, t = true, icon end
    end
    if not (ok and t) then MD:Debug("sim", "replay: no texture for spell %d", spellID); t = false end
    textureCache[spellID] = t
    return t or nil
end

-- Set the icon's texture (or its lettered fallback) once per spell, then the
-- sweep: the elapsed share of (since .. until) dimmed from the top down.
local function SetIcon(ic, spellID, fallbackName)
    if ic.spellID ~= spellID then
        ic.spellID = spellID
        local tex = SpellTexture(spellID)
        if tex then
            ic.tex:SetTexture(tex)
            ic.letter:SetText("")
        else
            ic.tex:SetTexture(nil)
            ic.letter:SetText((fallbackName or "?"):sub(1, 1))
        end
    end
end

local function Sweep(ic, since, until_, t)
    local dur = (until_ or 0) - (since or 0)
    if dur <= 0 then ic.dim:Hide(); ic.spark:Hide(); return end
    local frac = (t - since) / dur
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    local h = (ic.size - 2) * frac
    if h < 0.5 then
        ic.dim:Hide(); ic.spark:Hide()
    else
        ic.dim:SetHeight(h)
        ic.dim:Show()
        Shown(ic.spark, frac < 1)
    end
end

local function PaintIcon(ic, a, t, isDef)
    SetIcon(ic, a.spellID, AuraName(a.spellID))
    Sweep(ic, a.since, a.until_, t)
    ic.count:SetText((a.stacks or 1) > 1 and tostring(a.stacks) or "")
    ic.tip = ic.tip or {}
    ic.tip[1] = { l = AuraName(a.spellID), r = isDef and "|cff888888defensive|r" or "|cff888888debuff|r" }
    ic.tip[2] = { l = string.format("applied at %s", Clock(a.since)), r = string.format("up %.0fs", t - a.since) }
    ic.tip[3] = (a.stacks or 1) > 1 and { l = string.format("%d stacks", a.stacks), r = "" } or nil
    ic:Show()
end

local function Deficit(hp, maxHP)
    local d = (1 - (hp or 0)) * (maxHP or 0)
    if d < 1 then return "" end
    if d >= 1000 then return string.format("-%.1fk", d / 1000) end
    return string.format("-%d", d + 0.5)
end

local function PaintFrame(f, st, ti, isLeft, now)
    local hp = st:Hp(ti)
    local dead = st:Dead(ti)
    local c = f.classColor
    local sc = f.scale or 1
    local maxHP = rp.scenario.targets[ti] and rp.scenario.targets[ti].maxHP or 0
    if dead then
        f.bar:SetValue(0)
        f.pct:SetText("dead")
        f.pct:SetTextColor(1, 0.19, 0.19)
        f.name:SetTextColor(0.5, 0.5, 0.5)
    else
        f.bar:SetValue(hp or 0)
        f.pct:SetText(Deficit(hp, maxHP))
        f.pct:SetTextColor(1, 1, 1)
        f.name:SetTextColor(c[1], c[2], c[3])
    end
    if f.isHealer then f.power:SetValue((st:Mana() or 0) / (rp.scenario.pool or 1)) end

    -- the cast in flight to this unit: the button's border in the family
    -- colour and the spell's name in the status strip for as long as it casts
    local casting = st:Casting()
    local inFlight = casting and casting.target == ti and casting.castTime and casting.castTime > 0
    if inFlight then
        local label, family = SpellLabel(casting.spellID)
        local fc = FAMILY_COLOR[family] or FAMILY_COLOR.other
        f:SetBackdropBorderColor(fc[1], fc[2], fc[3], 1)
        f.SetCast(label .. " ...")
        f.cast:SetTextColor(fc[1], fc[2], fc[3])
        f.textUntil = now + 0.1   -- refreshed every frame while in flight
    elseif f.flashUntil <= now then
        f:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- the status slot: the landed cast's name, then its label; DEAD wins.
    -- Nothing is drawn -- no background either -- when there is nothing to say.
    if f.textUntil <= now and f.castText ~= "" then f.SetCast("") end
    local showLabel = f.labelFrom <= now and now < f.labelUntil and f.labelText ~= ""
    if f.labelUntil <= now and f.labelText ~= "" then f.SetLabel("") end
    Shown(f.label, showLabel and not dead)
    Shown(f.cast, f.castText ~= "" and not showLabel and not dead)
    local stripShown = (not dead) and (showLabel or f.castText ~= "")
    Shown(f.statusBG, stripShown)
    -- the deficit steps up above the strip while the strip has text
    if f.pctRaised ~= stripShown then
        f.pctRaised = stripShown
        local ht = CELL.healthText
        f.pct:ClearAllPoints()
        f.pct:SetPoint(ht[1], f.bar, ht[1], ht[2] * sc, ht[3] * sc + (stripShown and (12 * math.min(sc, CELL.textScaleMax) + 1) or 0))
    end

    -- HoT icons with the vertical sweep of their remaining time; Lifebloom
    -- shows its stacks and its border turns white in the last second (the
    -- bloom is coming). The dot: Swiftmend has something to eat and is ready.
    local SM = MD.SimModel
    local HOT_INDEX = SM.HOT_INDEX
    local eatable = false
    local slot, ho = 0, CELL.hots
    for fi = 1, 3 do
        local ic = f.hots[fi]
        local h = (not dead) and st:Hot(ti, fi) or nil
        if h then
            slot = slot + 1
            if ic.slot ~= slot then
                ic.slot = slot
                ic:ClearAllPoints()
                ic:SetPoint(ho[1], f, ho[1], (ho[2] + ho[5] * (slot - 1) * ho[4]) * sc, ho[3] * sc)
            end
            local fam = SM.HOT_NAME[fi]
            SetIcon(ic, MD.SpellData.maxRank[fam] or 0, fam)
            Sweep(ic, h.since, h.since + (h.duration or 0), st.t)
            if fi == HOT_INDEX.Lifebloom then
                ic.count:SetText(tostring(h.stacks or 1))
                if h.remaining <= 1 then ic:SetBackdropBorderColor(1, 1, 1, 1)
                else ic:SetBackdropBorderColor(0, 0, 0, 1) end
            else
                ic.count:SetText("")
                eatable = true
            end
            ic:Show()
        else
            ic.slot = nil
            ic:Hide()
        end
    end
    -- ...but only for a healer who HAS Swiftmend. The recording says which
    -- spells existed at that pull (v0.9.7); older recordings fall back to what
    -- the player knows now. Drawing a "Swiftmend is ready" indicator for a druid
    -- who never trained it is an instruction to press a key they do not have.
    if eatable and not dead and HasSwiftmend() then
        SetIcon(f.dot, SWIFTMEND, "Swiftmend")
        local cdUntil = st:CooldownUntil(SWIFTMEND)
        if cdUntil then
            local cd = MD.SimModel.SPELL_CD[SWIFTMEND] or 15
            Sweep(f.dot, cdUntil - cd, cdUntil, st.t)
            f.dot.tip = f.dot.tip or {}
            f.dot.tip[1] = { l = "Swiftmend", r = string.format("|cffff9966%.1fs|r", cdUntil - st.t) }
            f.dot.tip[2] = { l = "|cff888888a HoT to eat, the cooldown running|r", r = "" }
        else
            f.dot.dim:Hide(); f.dot.spark:Hide()
            f.dot.tip = f.dot.tip or {}
            f.dot.tip[1] = { l = "Swiftmend", r = "|cff99dd99ready|r" }
            f.dot.tip[2] = { l = "|cff888888a Rejuvenation or Regrowth to eat, and it is off cooldown|r", r = "" }
        end
        f.dot:Show()
    else
        f.dot:Hide()
    end

    -- auras: the defensive on the left edge, the debuffs bottom-left
    local auras = st:Auras(ti, f.auraBuf)
    local defShown, nDeb = false, 0
    for _, a in ipairs(auras) do
        if a.buff and not defShown then
            PaintIcon(f.defIcon, a, st.t, true)
            defShown = true
        elseif not a.buff and nDeb < #f.debuffs then
            nDeb = nDeb + 1
            PaintIcon(f.debuffs[nDeb], a, st.t, false)
        end
    end
    if not defShown then f.defIcon:Hide() end
    for i = nDeb + 1, #f.debuffs do f.debuffs[i]:Hide() end

    -- v0.12.2: what is coming, from the recording rather than from the trace --
    -- both columns are watching the same fight and answering the same cast bar.
    do
        local inbound = rp and rp.IncomingAt and rp.IncomingAt(ti, st.t)
        if inbound and not dead then
            SetIcon(f.incoming, inbound.spellID, rp.rec.names and rp.rec.names[inbound.spellID])
            f.incoming:SetBackdropBorderColor(1, 0.2, 0.2, 1)
            if inbound.at then Sweep(f.incoming, inbound.t, inbound.at, st.t) end
            f.incoming.tip = f.incoming.tip or {}
            f.incoming.tip[1] = { l = (rp.rec.names and rp.rec.names[inbound.spellID])
                or ("spell " .. inbound.spellID), r = inbound.at
                and string.format("|cffff9966lands in %.1fs|r", inbound.at - st.t) or "|cff888888no landing|r" }
            f.incoming.tip[2] = { l = "|cff888888cast at this target - Cell's Targeted Spells|r",
                r = inbound.amount and string.format("hit for %d", inbound.amount) or "" }
            f.incoming:Show()
        else
            f.incoming:Hide()
        end
        local threat = rp and rp.ThreatAt and rp.ThreatAt(ti, st.t) or 0
        if threat > 0 and not dead then
            -- Cell's aggro bar: yellow while somebody else holds it, red on you
            if threat >= 2 then f.aggro:SetColorTexture(1, 0.1, 0.1, 1)
            else f.aggro:SetColorTexture(1, 0.8, 0.2, 1) end
            f.aggro:Show()
        else
            f.aggro:Hide()
        end
    end

    if f.pulseUntil > now then
        local left = (f.pulseUntil - now) / PULSE_DMG
        f.pulse:SetColorTexture(CELL.lossFlash[1], CELL.lossFlash[2], CELL.lossFlash[3], (f.pulseAlpha or 0.4) * left)
    else
        f.pulse:SetColorTexture(CELL.lossFlash[1], CELL.lossFlash[2], CELL.lossFlash[3], 0)
    end

    -- the snapshot tick: the latest recorded HP at or before t, fading until
    -- the next one is due
    if isLeft and MD.db.replayTicks and rp.ticks and rp.ticks.hp[ti] then
        local ts, col = rp.ticks.t, rp.ticks.hp[ti]
        local t = st.t
        local j = f.tickIdx or 1
        if j > 1 and ts[j - 1] and ts[j - 1] > t then j = 1 end       -- seeked backwards
        while ts[j + 1] and ts[j + 1] <= t do j = j + 1 end
        f.tickIdx = j
        local v = (ts[j] and ts[j] <= t) and col[j] or nil
        if v and v >= 0 and not dead then
            local age = t - ts[j]
            local alpha = 0.9 - 0.6 * (age / TICK_FADE)
            if alpha < 0.3 then alpha = 0.3 end
            f.tick:SetColorTexture(1, 1, 1, alpha)
            f.tick:ClearAllPoints()
            local x = v * f.bar:GetWidth()
            f.tick:SetPoint("LEFT", f.bar, "LEFT", x, 0)
            f.tickInfo = f.tickInfo or {}
            f.tickInfo.rec, f.tickInfo.at, f.tickInfo.sim = v, ts[j], hp or 0
            f.tickHit:SetSize(8, f.bar:GetHeight())
            f.tickHit:ClearAllPoints()
            f.tickHit:SetPoint("CENTER", f.tick, "CENTER", 0, 0)
            f.tickHit:Show()
        else
            f.tick:SetColorTexture(1, 1, 1, 0)
            f.tickHit:Hide()
        end
    else
        f.tick:SetColorTexture(1, 1, 1, 0)
        f.tickHit:Hide()
    end
end

local function PaintStrip(s, st, pool, now, col)
    local mana = st:Mana() or 0
    s.mana:SetValue(pool > 0 and mana / pool or 0)
    s.manaFS:SetText(string.format("%d", mana + 0.5))
    s.form:SetText(st:Form() == "tree" and "[tree]" or "[caster]")

    local c = st:Casting()
    if c and c.castTime > 0 then
        -- a real cast, filling over its recorded (left) or modelled (right) time
        local label, family = SpellLabel(c.spellID)
        local frac = (st.t - c.startedAt) / c.castTime
        if frac > 1 then frac = 1 end
        if frac < 0 then frac = 0 end
        local fc = FAMILY_COLOR[family] or FAMILY_COLOR.other
        s.cast:SetStatusBarColor(fc[1], fc[2], fc[3])
        s.cast:SetValue(frac)
        local tgt = rp.rec.roster[c.target]
        s.castFS:SetText(label .. (tgt and (" -> " .. tgt.name) or "") .. string.format("  %.1fs", c.castTime))
        s.castFS:SetTextColor(1, 1, 1)
    elseif s.lastCast and st.t < s.gcdUntil and st.t >= s.gcdStart then
        -- just after an instant: the GCD sweeping, in grey
        s.cast:SetStatusBarColor(0.3, 0.3, 0.3)
        s.cast:SetValue((st.t - s.gcdStart) / GCD)
        s.castFS:SetText(s.lastCast .. "  instant")
        s.castFS:SetTextColor(1, 1, 1)
    else
        -- idle: the last cast's name stays, dimmed, so "what was I doing" has an answer
        s.cast:SetValue(0)
        s.castFS:SetText(s.lastCast or "")
        s.castFS:SetTextColor(0.55, 0.55, 0.55)
    end
    local w = st:Waiting()
    s.wait:SetText(w and string.format("waiting %.1fs", w) or "")
    s.band:SetColorTexture(0.5, 0.5, 0.5, w and 0.35 or 0)

    -- the rule behind what the bar shows, for the hover (right column: the
    -- plan's reasons; left: none are on record)
    -- v0.12.3: the rule, and the numbers that made it fire. A rule name says
    -- what kind of decision it was; the sentence says why THIS one, here, now.
    local SP2 = MD.SimPlanner
    local reason = st.LastReason and st:LastReason() or nil
    local why = (c and c.why) or (st.lastCast and st.lastCast.why) or 0
    local sentence = reason and SP2.ReasonText(reason, rp and rp.rec and rp.rec.names) or nil
    if why and why > 0 and SP2.RULE_NAMES[why] then
        s.why = { { l = string.format("rule %d: %s", why, SP2.RULE_NAMES[why]), r = "" } }
        if sentence then s.why[#s.why + 1] = { l = "|cff888888" .. sentence .. "|r", r = "" } end
    elseif w then
        s.why = { { l = "waiting", r = "" },
                  { l = "|cff888888" .. (sentence or "nobody under a threshold, or nothing affordable")
                        .. "|r", r = "" } }
    else
        s.why = nil
    end
    -- the left column's label is the classifier's; its sentence is the same idea
    -- from the other side -- why THAT cast, in the recording's numbers
    if col and col.isLeft and rp and rp.casts and st.lastCast and st.lastCast.n then
        local rec2 = rp.casts[st.lastCast.n]
        local text = rec2 and MD.SimPlanner.CastWhy(rec2, rp.rec and rp.rec.names)
        if text then
            s.why = s.why or {}
            s.why[1] = { l = string.format("%s: %s", rec2.label, text), r = "" }
            for i = 2, #s.why do s.why[i] = nil end
        end
    end
    s.reasonText = sentence

    -- spent, floor, deaths -- and (v0.11.14) how much of the healing landed and
    -- how much mana came back, which is what comparing two strategies needs:
    -- cheap is only cheap if it was not thrown away.
    local spent, lowest, deaths = st:Score()
    local oh = st:Overheal()
    s.score:SetText(string.format("spent %s   regen %s   overheal %s   lowest %d%%   %s",
        K(spent), K(st:Regen()),
        oh and string.format("%d%%", oh * 100 + 0.5) or "-",
        lowest * 100 + 0.5,
        deaths > 0 and string.format("|cffff5555%d dead|r", deaths) or "0 dead"))
end

local function Paint()
    if not rp then return end
    local now = GetTime()
    local pool = rp.scenario.pool or 1
    for _, ti in ipairs(rows) do
        PaintFrame(left.frames[ti], left.state, ti, true, now)
        if right and right.state then PaintFrame(right.frames[ti], right.state, ti, false, now) end
    end
    PaintStrip(left.strip, left.state, pool, now, left)
    if right and right.state then PaintStrip(right.strip, right.state, pool, now, right) end
    timeFS:SetText(Clock(left.state.t) .. " / " .. Clock(left.state.dur))
    if not scrubber.dragging then
        scrubber.settingValue = true
        scrubber:SetValue(left.state.t)
        scrubber.settingValue = false
    end
end

--------------------------------------------------------------------------------
-- Time control
--------------------------------------------------------------------------------
local function SeekTo(t)
    left.state:Seek(t)
    if right and right.state then right.state:Seek(t) end
    -- a seek clears every short-lived effect: they belong to the crossed events
    for _, ti in ipairs(rows) do
        for _, col in ipairs({ left, right }) do
            local f = col and col.frames[ti]
            if f then
                f.flashUntil, f.textUntil, f.labelFrom, f.labelUntil, f.pulseUntil, f.tickIdx = 0, 0, 0, 0, 0, nil
                f.SetCast(""); f.SetLabel("")
            end
        end
    end
    for _, col in ipairs({ left, right }) do
        if col then col.strip.lastCast, col.strip.gcdStart, col.strip.gcdUntil = nil, 0, 0 end
    end
    Paint()
end

local function SetPlaying(on)
    playing = on
    playBtn:SetText(on and "II" or ">")
    if on and left.state:AtEnd() then SeekTo(0) end
end

local function OnUpdate(_, elapsed)
    if not rp or not playing then return end
    local dt = elapsed * speed
    local cap = DT_STEP_MAX * speed
    if dt > cap then dt = cap end
    left.state:Advance(dt)
    if right and right.state then right.state:Advance(dt) end
    Paint()
    if left.state:AtEnd() then
        -- inside a run, the next pull follows on its own: pull by pull IS the
        -- way a dungeon is reviewed, and stopping at every boundary to click
        -- makes it a chore. db.replayNextPull turns it off.
        local nextK = pullIdx and (pullIdx + 1)
        if curRun and runIdx and nextK and curRun.pulls[nextK]
           and MD.db.replayNextPull ~= false then
            SetPlaying(false)
            MD:OpenReplay(runIdx .. ":" .. nextK)
            SetPlaying(true)
            return
        end
        SetPlaying(false)
    end
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------
local function Build()
    if frame then return end
    frame = UI.CreateMovableFrame("ManaDemon: Replay", "ManaDemonReplayWindow", 2 * COL_W + 3 * GUTTER, 300)
    frame:SetFrameStrata("HIGH")
    tinsert(UISpecialFrames, "ManaDemonReplayWindow")
    frame:SetScript("OnUpdate", OnUpdate)
    frame:SetScript("OnHide", function() playing = false end)
    function frame:OnMoved()
        local point, _, relPoint, x, y = self:GetPoint()
        MD.db.replayPos = { point, relPoint, x, y }
    end
    if MD.db.replayPos then
        local p = MD.db.replayPos
        frame:ClearAllPoints()
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    end

    headerFS = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    headerFS:SetPoint("TOPLEFT", frame, "TOPLEFT", GUTTER, -6)
    headerFS:SetJustifyH("LEFT")
    headerFS:SetWidth(2 * COL_W + GUTTER)

    -- The strategies the last search produced for this recording. One dropdown
    -- rather than four buttons: the names are long and ran off the window
    -- (v0.11.11). Switching does NOT search again -- the plans are in hand and
    -- this redraws the suggested column from the chosen one.
    stratDrop = UI.CreateDropdown(frame, 180, 16, function(id)
        local SP = MD.SimPlanner
        if not (rp and rp.rec) then return end
        -- v0.13.7: two kinds of entry share this list. A search objective picks
        -- one of the plans the search already found; a STRATEGY_SET entry is a
        -- whole planner (the rules, or the solver in one of its configurations)
        -- and is built here on demand -- it needs no search at all, which is why
        -- the chooser now has something to offer before Coach has ever run.
        local entry = SP.Strategy and SP.Strategy(id)
        if entry then
            local kit = MD.RankMath:SpellKit({ live = true })
            local sc = MD.SimModel.ScenarioFromRecording(rp.rec, kit)
            local plan = SP.MakeStrategy(entry, SP.BindsFromRecording and
                SP.BindsFromRecording(rp.rec) or SP.MaxRankBinds(), kit,
                { scenario = sc, seed = rp.rec.id or 1,
                  encounter = rp.rec.encounter, zone = rp.rec.zone,
                  recs = MD.cdb and MD.cdb.recordings, excludeID = rp.rec.id })
            if not plan then return end
            SP.plans[rp.rec.id] = plan
        else
            local w = SP.strategies[rp.rec.id]
            w = w and w[id]
            if not w then return end
            SP.plans[rp.rec.id] = w.plan
        end
        SP.strategyPick[rp.rec.id] = id
        MD:RebuildSuggested()
    end)
    stratDrop:Hide()

    runStrip = CreateFrame("Frame", nil, frame)
    runStrip:SetPoint("TOPLEFT", frame, "TOPLEFT", GUTTER, -(HEADER_H - 2))
    runStrip:SetSize(2 * COL_W + GUTTER, 18)
    runStrip.pulls, runStrip.drinks, runStrip.marks = {}, {}, {}
    runStrip.label = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    runStrip.label:SetPoint("TOPLEFT", runStrip, "BOTTOMLEFT", 0, -1)
    runStrip.label:SetJustifyH("LEFT")
    runStrip:Hide()

    left = CreateColumn(GUTTER, "ACTUAL")
    right = CreateColumn(2 * GUTTER + COL_W, "SUGGESTED")
    left.isLeft = true

    -- scrubber row, anchored to the bottom
    playBtn = UI.CreateButton(frame, ">", "accent-hover", { 24, 18 }, false, false, nil, nil,
        "Play / pause", "Space also toggles while the window has focus.")
    playBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 30)
    playBtn:SetSize(34, 22)
    playBtn:SetScript("OnClick", function() SetPlaying(not playing) end)

    local speeds, prev = {}, playBtn
    for _, sp in ipairs(SPEEDS) do
        local text = sp >= 1 and (sp .. "x") or ("1/" .. math.floor(1 / sp + 0.5) .. "x")
        local b = UI.CreateButton(frame, text, "accent-hover", { 40, 22 }, false, false, UI.FONT_SMALL)
        b.id = sp
        b:SetPoint("LEFT", prev, "RIGHT", 3, 0)
        speeds[#speeds + 1] = b
        prev = b
    end
    speedButtons = speeds
    speedHighlight = UI.CreateButtonGroup(speeds, function(id)
        speed = id
        MD.db.replaySpeed = id
    end)

    timeFS = frame:CreateFontString(nil, "OVERLAY", UI.FONT)
    timeFS:SetPoint("LEFT", prev, "RIGHT", 12, 0)
    timeFS:SetWidth(130)
    timeFS:SetJustifyH("LEFT")

    -- the scrubber on its own row above the buttons, full width
    scrubber = CreateFrame("Slider", nil, frame, "BackdropTemplate")
    scrubber:SetOrientation("HORIZONTAL")
    scrubber:SetSize(2 * COL_W + GUTTER, 14)
    scrubber:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 62)
    UI.StylizeFrame(scrubber, { 0.115, 0.115, 0.115, 1 })
    local thumb = scrubber:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(UI.accent[1], UI.accent[2], UI.accent[3], 1)
    thumb:SetSize(6, 18)
    scrubber:SetThumbTexture(thumb)
    scrubber:SetMinMaxValues(0, 1)
    scrubber:SetValueStep(0.05)
    scrubber:SetObeyStepOnDrag(true)
    scrubber:SetScript("OnValueChanged", function(self, v, user)
        if self.settingValue or not rp then return end
        SeekTo(v)
    end)
    scrubber:SetScript("OnMouseDown", function(self) self.dragging = true end)
    scrubber:SetScript("OnMouseUp", function(self) self.dragging = false end)
    scrubber.markers = {}

    local ticksCB = UI.CreateCheckButton(frame, "ticks", function(checked)
        MD.db.replayTicks = checked
        Paint()
    end, "Snapshot ticks", "The recorder's real HP every 5s, drawn over the",
        "engine's reconstruction on the left bars.")
    -- anchored from the right edge, label included, so it cannot fall off a
    -- one-column window (it did, twice)
    local labelW = (ticksCB.label and ticksCB.label.GetStringWidth and ticksCB.label:GetStringWidth()) or 32
    ticksCB:SetPoint("RIGHT", frame, "RIGHT", -(GUTTER + labelW + 6), 0)
    ticksCB:SetPoint("BOTTOM", playBtn, "BOTTOM", 0, 4)
    ticksCB:SetChecked(MD.db.replayTicks ~= false)
    frame.ticksCB = ticksCB

    -- the hint on its own line at the very bottom, never under a control
    frame.hint = frame:CreateFontString(nil, "OVERLAY", UI.FONT_SMALL)
    frame.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", GUTTER, 9)
    frame.hint:SetTextColor(0.5, 0.5, 0.5)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(false)
end

-- Markers along the scrubber: deaths red, big hits orange, the left column's
-- casts as faint grey ticks.
local function PlaceMarkers()
    for _, m in ipairs(scrubber.markers) do m:Hide() end
    local n = 0
    local function Mark(t, r, g, b, a, h)
        n = n + 1
        local m = scrubber.markers[n]
        if not m then
            m = scrubber:CreateTexture(nil, "OVERLAY")
            scrubber.markers[n] = m
        end
        m:SetSize(1, h or 10)
        m:SetColorTexture(r, g, b, a)
        m:ClearAllPoints()
        local dur = left.state.dur
        m:SetPoint("LEFT", scrubber, "LEFT", dur > 0 and (t / dur) * scrubber:GetWidth() or 0, 0)
        m:Show()
    end
    local TK, K = MD.SimModel.TK, MD.SimModel.K
    local L = rp.left.trace
    local n = 0
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.CAST then
            n = n + 1
            local cl = rp.casts and rp.casts[n]
            local lc = cl and LABEL_COLOR[cl.label]
            if lc and cl.label ~= "fine" and cl.label ~= "unclassified" then
                Mark(L.ev.t[i], lc[1], lc[2], lc[3], 0.9, 8)
            else
                Mark(L.ev.t[i], 1, 1, 1, 0.25, 6)
            end
        end
    end
    local big = (MD.db.simBigHit or 0.15)
    local sev = rp.scenario.ev
    if sev then
        for i = 1, #sev.t do
            if sev.kind[i] == K.DMG then
                local tg = rp.scenario.targets[sev.tgt[i]]
                if tg and tg.maxHP > 0 and (sev.amt[i] or 0) / tg.maxHP >= big then
                    Mark(sev.t[i], 1, 0.6, 0.2, 0.9, 10)
                end
            end
        end
    end
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.DEATH then Mark(L.ev.t[i], 1, 0.2, 0.2, 1, 14) end
    end
end

--------------------------------------------------------------------------------
-- The run strip (docs/SPEC-v0.9.md 6): the whole dungeon on one line -- each
-- pull a block as wide as it was long, the drinks between them in blue, deaths
-- as red marks, and the gaps left as gaps. The pull being played is bright.
--
-- It is the map a run needs and a scrubber cannot be: half an hour at 1x is not
-- review, so there is no "play the run through". Click a block and the window
-- re-opens on that pull, keeping the same clock controls.
--------------------------------------------------------------------------------
local function RunBlock(kind, i)
    local pool = runStrip[kind]
    local b = pool[i]
    if not b then
        b = CreateFrame("Button", nil, runStrip)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        pool[i] = b
    end
    b:Show()
    return b
end

local function PaintRunStrip(width)
    if not runStrip then return end
    for _, kind in ipairs({ "pulls", "drinks", "marks" }) do
        for _, b in ipairs(runStrip[kind]) do b:Hide() end
    end
    if not curRun then runStrip:Hide(); return end
    runStrip:Show()
    runStrip:SetWidth(width)

    local wall = (curRun.stats and curRun.stats.wall) or 0
    if wall <= 0 then runStrip:Hide(); return end
    local W = width
    local function X(t) return math.max(0, math.min(W, (t / wall) * W)) end

    local ar, ag, ab = UI.GetAccentColorRGB()
    for k, rec in ipairs(curRun.pulls or {}) do
        local x0, x1 = X(rec.runT0 or 0), X((rec.runT0 or 0) + (rec.dur or 0))
        local b = RunBlock("pulls", k)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", runStrip, "TOPLEFT", x0, -2)
        b:SetSize(math.max(2, x1 - x0), 14)
        local on = (k == pullIdx)
        if rec.short then
            b.tex:SetColorTexture(0.45, 0.45, 0.45, on and 1 or 0.55)
        else
            b.tex:SetColorTexture(ar, ag, ab, on and 1 or 0.5)
        end
        b.pull = k
        b:SetScript("OnClick", function(self)
            if runIdx then MD:OpenReplay(runIdx .. ":" .. self.pull) end
        end)
        b:SetScript("OnEnter", function(self)
            if not MD.Tip then return end
            MD.Tip:Show(self, "ANCHOR_BOTTOM", {
                { l = string.format("pull %d%s", self.pull, rec.short and " (short)" or ""),
                  r = Clock(rec.dur or 0) },
                { l = "into the run", r = Clock(rec.runT0 or 0) },
                { l = rec.zone or "", r = string.format("%d casts, %s mana", rec.ownCasts or 0, K(rec.spent or 0)) },
                { l = "|cff888888click to play this pull|r", r = "" },
            })
        end)
        b:SetScript("OnLeave", function() if MD.Tip then MD.Tip:Hide() end end)
    end

    -- drinks and deaths from the run's own timeline
    local RR = MD.RunRecorder
    local ev = curRun.ev or {}
    local nD, nM, openDrink = 0, 0, nil
    for i = 1, #(ev.t or {}) do
        local k = ev.kind[i]
        if k == RR.K.DRINK then
            openDrink = ev.t[i]
        elseif k == RR.K.DRINK_END and openDrink then
            nD = nD + 1
            local b = RunBlock("drinks", nD)
            local x0, x1 = X(openDrink), X(ev.t[i])
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", runStrip, "TOPLEFT", x0, -2)
            b:SetSize(math.max(2, x1 - x0), 14)
            b.tex:SetColorTexture(0.35, 0.6, 1, 0.8)
            b:EnableMouse(false)
            openDrink = nil
        elseif k == RR.K.DEAD then
            nM = nM + 1
            local b = RunBlock("marks", nM)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", runStrip, "TOPLEFT", X(ev.t[i]) - 1, 0)
            b:SetSize(2, 18)
            b.tex:SetColorTexture(1, 0.2, 0.2, 1)
            b:EnableMouse(false)
        end
    end

    local st = curRun.stats or {}
    runStrip.label:SetText(string.format("|cffffcc00%s|r  %s, %d pull(s)%s%s", curRun.name or "run",
        Clock(st.wall or 0), st.pulls or 0,
        (st.drinks or 0) > 0 and string.format(", %d drink(s)", st.drinks) or "",
        (st.deaths or 0) > 0 and string.format(", %d death(s)", st.deaths) or ""))
end

--------------------------------------------------------------------------------
-- Opening a fight
--------------------------------------------------------------------------------
local function Layout()
    -- roster order, as the author's layout has sortByRole off; columns of
    -- unitsPerColumn, a raid's subgroup and main tanks filling the next ones
    rows = {}
    for _, ti in ipairs(rp.rec.tracked or {}) do rows[#rows + 1] = ti end
    table.sort(rows)
    local roster = rp.rec.roster
    local healerIdx = nil
    local myName = UnitName and UnitName("player") or nil
    for i, r in ipairs(roster) do
        if (r.guid and r.guid == MD.player.guid) or (not r.guid and myName and r.name == myName) then healerIdx = i end
    end

    local n = #rows
    local sc, nCols, stretch = ScaleFor(n)
    local perCol = (sc == 1) and CELL.unitsPerColumn or math.max(1, math.ceil(n / nCols))
    local spX, spY = CELL.spacingX * sc, CELL.spacingY * sc
    local H = CELL.size[2] * sc
    local W = CELL.size[1] * sc
    local pitch = COL_W
    if stretch then
        W = (pitch - (nCols - 1) * spX) / nCols     -- as wide as the column allows
    else
        pitch = math.max(COL_W, nCols * W + (nCols - 1) * spX)
    end
    local gridH = math.min(n, perCol) * H + (math.min(n, perCol) - 1) * spY
    local overhang = CELL.hots[3] * sc + 4        -- the HoT slot sits above the button's top edge
    local hasRight = rp.right ~= nil
    local width = hasRight and (2 * pitch + 3 * GUTTER) or (pitch + 2 * GUTTER)
    -- the run strip pushes everything below it down, and only exists when this
    -- pull belongs to a run
    topH = HEADER_H + (curRun and RUNSTRIP_H or 0)
    local height = topH + STRIP_H + overhang + gridH + SCRUB_H + 12
    frame:SetSize(width, height)
    frame.hint:SetWidth(width - 2 * GUTTER)
    left.title:ClearAllPoints()
    left.title:SetPoint("TOPLEFT", frame, "TOPLEFT", left.x, -(topH + 6))
    left.strip.mana:ClearAllPoints()
    left.strip.mana:SetPoint("TOPLEFT", frame, "TOPLEFT", left.x, -(topH + 30))
    right.x = 2 * GUTTER + pitch
    right.title:ClearAllPoints()
    right.title:SetPoint("TOPLEFT", frame, "TOPLEFT", right.x, -(topH + 6))
    right.strip.mana:ClearAllPoints()
    right.strip.mana:SetPoint("TOPLEFT", frame, "TOPLEFT", right.x, -(topH + 30))
    PaintRunStrip(width - 2 * GUTTER)
    Shown(right.title, hasRight)
    for _, k in ipairs({ "mana", "cast", "form", "wait", "score" }) do Shown(right.strip[k], hasRight) end
    scrubber:SetWidth(width - 2 * GUTTER)

    for _, col in ipairs({ left, right }) do
        for _, f in pairs(col.frames) do f:Hide() end
    end
    local y0 = -(topH + STRIP_H + overhang)
    for k, ti in ipairs(rows) do
        local cI, rI = math.floor((k - 1) / perCol), (k - 1) % perCol
        local dx, y = cI * (W + spX), y0 - rI * (H + spY)
        for ci, col in ipairs({ left, right }) do
            if ci == 1 or hasRight then
                local f = col.frames[ti]
                if not f then
                    f = CreateUnitFrame(frame, col.x + dx, y)
                    col.frames[ti] = f
                else
                    f:ClearAllPoints()
                    f:SetPoint("TOPLEFT", frame, "TOPLEFT", col.x + dx, y)
                end
                f.Resize(W, H, sc)
                local r = roster[ti] or {}
                f.classColor = ClassColor(r.class)
                f.isHealer = (ti == healerIdx)
                local rc = ROLE_COORD[r.role]
                if rc then f.role:SetTexCoord(rc[1], rc[2], rc[3], rc[4]); f.role:Show() else f.role:Hide() end
                f.name:SetText(r.name or ("#" .. ti))
                local c = f.classColor
                f.bar:SetStatusBarColor(c[1], c[2], c[3])
                f.bar.bg:SetColorTexture(c[1] * CELL.lossFactor, c[2] * CELL.lossFactor, c[3] * CELL.lossFactor, 1)
                f.power:SetValue(f.isHealer and 1 or 0)
                f.flashUntil, f.textUntil, f.labelFrom, f.labelUntil, f.pulseUntil, f.tickIdx = 0, 0, 0, 0, 0, nil
                f.SetCast(""); f.SetLabel("")
                f:SetBackdropBorderColor(0, 0, 0, 1)
                f.defIcon.spellID, f.dot.spellID = nil, nil
                for _, ic in ipairs(f.debuffs) do ic.spellID = nil end
                for _, ic in ipairs(f.hots) do ic.spellID = nil end
                f:Show()
            end
        end
    end
end

-- Redraw the suggested column from whatever plan is now cached for this
-- recording, keeping the clock where it is. Switching strategy is a redraw, not
-- a search: the window never searches (SPEC-v0.8 2.5).
function MD:RebuildSuggested()
    if not (rp and openSpec) then return end
    local at = left.state and left.state.t or 0
    local wasPlaying = playing
    MD:OpenReplay(openSpec .. (openForce and " force" or ""))
    if left.state and at > 0 then SeekTo(at) end
    if wasPlaying then SetPlaying(true) end
end

function MD:OpenReplay(n)
    local FR, SP = MD.FightRecorder, MD.SimPlanner
    if not (FR and SP and MD.ReplayTrace) then MD:Print("replay: not loaded.") return end
    if (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player") then
        MD:Print("replay: not in combat - it is a review tool.")
        return
    end
    -- "3" is a single fight, "2:7" the seventh pull of run 2 (v0.9.2); "run 2"
    -- opens the first pull of run 2 with its strip (v0.9.4); a trailing "force"
    -- draws the suggested column on a fight the gates rejected (v0.9.6)
    local spec = tostring(n or 1)
    local force = false
    if spec:find("force") then
        force = true
        spec = spec:gsub("force", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if spec == "" then spec = "1" end
    end
    local r = spec:match("^run%s*(%d+)$")
    if r then spec = r .. ":1" end
    local rec, label, run, pullK = MD:GetRecording(spec)
    if not rec then MD:Print("replay: no recording " .. tostring(n) .. ".") return end
    n = label
    curRun, runIdx, pullIdx = run, run and tonumber(label:match("^(%d+):")) or nil, pullK

    Build()
    playing = false
    local t0 = debugprofilestop and debugprofilestop() or 0
    openSpec, openForce = n, force
    rp = SP.Replay(rec, { dt = 0.25, force = force })
    if not rp then MD:Print("replay: could not build the fight.") return end
    if force and not rp.right then
        MD:Print(string.format("replay: nothing to force - no plan has been coached for this fight. " ..
            "|cffffff00/md coach %s force|r first.", tostring(n)))
    end
    local RT = MD.ReplayTrace
    left.state = RT.New(rp.left.trace, rp.scenario, { onEvent = MakeOnEvent(left) })
    right.state = rp.right and RT.New(rp.right.trace, rp.scenario, { onEvent = MakeOnEvent(right) }) or nil
    MD:Debug("sim", "replay %s opened: %d rows, %d/%d trace events, dt %.2f, %.0f ms", tostring(n), #(rec.tracked or {}),
        rp.left.trace.nEv, rp.right and rp.right.trace.nEv or 0, rp.left.trace.dt,
        (debugprofilestop and debugprofilestop() or 0) - t0)

    Layout()
    speed = MD.db.replaySpeed or 1
    speedHighlight(speed)

    local v = rp.validation
    local fit = ""
    if v and v.gates then
        for _, g in ipairs(v.gates) do
            if g.name == "mana" then fit = g.text; break end
        end
    end
    local when = rec.id and date and date("%H:%M", rec.id) or ""
    headerFS:SetText(string.format("|cffffcc00#%s|r  %s%s  %s  %s   %s%s", tostring(n),
        run and (run.name .. " pull " .. tostring(pullK) .. " - ") or "", rec.zone or "?", when,
        Clock(rec.dur or 0), v and (v.ok and "|cff99dd99replays|r" or "|cffff9966does not replay|r") or "",
        fit ~= "" and ("  |cff888888" .. fit .. "|r") or ""))
    -- the strategy chooser, when a search has produced strategies for this fight
    do
        local SP = MD.SimPlanner
        local winners = rp.rec and SP.strategies[rp.rec.id]
        local items, current = {}, nil
        if rp.right and rp.rec then
            local pick = SP.strategyPick[rp.rec.id]
            -- the planners first: they are available whether or not a search has
            -- run, and they are what the author is actually choosing between
            for _, e in ipairs(SP.STRATEGY_SET or {}) do
                items[#items + 1] = { id = e.key, text = e.label, tooltip = e.why }
                if pick == e.key then current = e.key end
            end
            -- then the four readings of the last search, when there was one
            if winners then
                for _, obj in ipairs(SP.OBJECTIVES) do
                    local w = winners[obj.key]
                    if w then
                        items[#items + 1] = { id = obj.key, text = "Search: " .. obj.name,
                                              tooltip = obj.what }
                        -- what the author CHOSE, not the first objective that
                        -- happens to share the winning plan
                        if pick == obj.key then current = obj.key end
                        if not current and SP.plans[rp.rec.id] == w.plan then current = obj.key end
                    end
                end
            end
        end
        if #items > 0 then
            stratDrop:SetItems(items)
            if current then stratDrop:SetValue(current) end
            stratDrop:ClearAllPoints()
            -- Anchored to the window's RIGHT edge on the header line, so it
            -- cannot run off the way four buttons growing rightward from the
            -- column title did. The header text is left-anchored and short; a
            -- one-column window has no suggested column and so no chooser.
            stratDrop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -GUTTER, -6)
            stratDrop:Show()
        else
            stratDrop:Close()
            stratDrop:Hide()
        end
    end

    if rp.right then
        local p = rp.right.plan
        right.title:SetText(string.format("SUGGESTED  |cff888888(%s, %d binds)|r%s", p.name or "plan", p:BindCount(),
            rp.forced and "  |cffff9966FORCED - this fight does not replay|r" or ""))
        frame.hint:SetText("")
    else
        frame.hint:SetText(v and not v.ok and "no plan: this fight does not replay"
            or "no plan: press Coach first")
    end

    scrubber.settingValue = true
    scrubber:SetMinMaxValues(0, left.state.dur)
    scrubber:SetValue(0)
    scrubber.settingValue = false
    PlaceMarkers()
    SeekTo(0)
    frame:Show()
end

function MD:ToggleReplay(arg)
    if frame and frame:IsShown() and (arg == nil or arg == "") then
        frame:Hide()
        return
    end
    MD:OpenReplay(arg)
end

MD.Replay = {
    Open = function(_, n) MD:OpenReplay(n) end,
    -- for tools/replayui.lua: what the window is showing, read-only
    _state = function() return { frame = frame, left = left, right = right, rows = rows, rp = rp,
                                 scrubber = scrubber, timeFS = timeFS, playing = playing, speeds = speedButtons } end,
    _runStrip = function()
        if not runStrip then return nil end
        return { shown = runStrip:IsShown(), pulls = runStrip.pulls, drinks = runStrip.drinks,
                 marks = runStrip.marks, label = runStrip.label:GetText(), run = curRun,
                 pull = pullIdx, runIdx = runIdx }
    end,
    _strategy = function() return stratDrop end,
    _setPlaying = function(on) SetPlaying(on) end,
    _seek = function(t) SeekTo(t) end,
}
