-- The one tooltip line builder. Every hover surface in the addon (both ElvUI
-- datatexts, the minimap button, the floating widget, the dashboard's rows and
-- recap line) renders lines produced here, so they can never drift apart.
--
-- A line is a plain table:
--   { l = "left", r = "right", c = {r,g,b}, rc = {r,g,b}, wrap = bool }
-- l alone -> AddLine, l+r -> AddDoubleLine, {} -> a blank spacer. Both
-- GameTooltip and ElvUI's DT.tooltip take exactly those two calls, which is why
-- the pair is the abstraction.
--
-- ASCII only in every string here (default WoW fonts lack arrow/infinity
-- glyphs) and never a bare "|" (it opens a colour escape).
local _, MD = ...
local UI = MD.UI

local Tip = {}
MD.Tip = Tip

local WHITE  = { 1, 1, 1 }
local KEY    = { 0.78, 0.78, 0.78 }
local SUB    = { 0.63, 0.63, 0.63 }
local MUTED  = { 0.43, 0.43, 0.43 }
local WARN   = { 1, 0.67, 0.2 }
local GOLD   = { 1, 0.82, 0 }
local GOOD   = { 0.2, 1, 0.4 }
local MANA   = { 0.31, 0.66, 0.94 }

local function Accent()
    return { UI.accent[1], UI.accent[2], UI.accent[3] }
end

local function Plain(str)
    return (tostring(str):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------
-- Pushes lines into any tooltip object exposing AddLine / AddDoubleLine.
function Tip:Render(tt, lines)
    if not tt or not lines then return end
    for i = 1, #lines do
        local ln = lines[i]
        if ln.l == nil and ln.r == nil then
            tt:AddLine(" ")
        elseif ln.r ~= nil then
            local c = ln.c or WHITE
            local rc = ln.rc or ln.c or WHITE
            tt:AddDoubleLine(ln.l or "", ln.r, c[1], c[2], c[3], rc[1], rc[2], rc[3])
        else
            local c = ln.c or WHITE
            tt:AddLine(ln.l, c[1], c[2], c[3], ln.wrap)
        end
    end
end

-- Convenience for plain GameTooltip owners: Tip:Show(frame, "ANCHOR_LEFT", lines)
function Tip:Show(owner, anchor, ...)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    for i = 1, select("#", ...) do
        Tip:Render(GameTooltip, (select(i, ...)))
    end
    GameTooltip:Show()
end

-- Same, but pinned to a frame instead of following the owner: the dashboard's
-- rows are narrow and centred, so ANCHOR_RIGHT would run off the screen edge.
function Tip:ShowAt(owner, point, relFrame, relPoint, x, y, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint(point, relFrame, relPoint, x, y)
    GameTooltip:ClearLines()
    for i = 1, select("#", ...) do
        Tip:Render(GameTooltip, (select(i, ...)))
    end
    GameTooltip:Show()
end

function Tip:Hide()
    GameTooltip:Hide()
end

--------------------------------------------------------------------------------
-- Mana state: the clock, what it is made of, and why it says what it says.
--------------------------------------------------------------------------------
function Tip:Mana()
    local lines = {}
    local s = MD.GetManaState and MD:GetManaState()
    if not s then return lines end
    local RM = MD.Regen
    local spiritPerSec, mp5Gear, _, unreported = RM:Components()

    if s.tto then
        lines[#lines + 1] = { l = "Time to OOM (raw)",
            r = string.format("%ds +- %ds", s.tto, s.sigmaT or 0) }
    elseif s.ttf then
        lines[#lines + 1] = { l = "Time to full (raw)", r = string.format("%ds", s.ttf) }
    elseif s.mode == "hold" then
        lines[#lines + 1] = { l = "Net rate within noise",
            r = s.bound and string.format("OOM no sooner than %ds", s.bound) or "sustainable" }
    end
    if s.inCombat and s.rest then
        lines[#lines + 1] = { l = "Full if you stop casting", r = string.format("%ds", s.rest) }
    end
    lines[#lines + 1] = { l = "Net rate (pessimistic)", r = string.format("%+d mana/s", -s.net) }
    lines[#lines + 1] = { l = "Spending",
        r = string.format("%d +- %d mana/s (%d casts, CV %.2f)", s.spend, s.sigma, s.casts, s.cv) }
    lines[#lines + 1] = { l = "Regen now / projected",
        r = string.format("%d / %d mana/s  (5SR %d%% of time)", s.regenNow, s.regen, s.duty * 100) }
    lines[#lines + 1] = { l = "Regen out of 5SR / casting",
        r = string.format("%d / %d mana/s", RM.base, RM.casting) }
    lines[#lines + 1] = { l = "Spirit / gear mp5",
        r = string.format("~%d / ~%d", spiritPerSec * 5, mp5Gear) }
    if unreported > 0 then
        lines[#lines + 1] = { l = "mp5 added, not in the API",
            r = string.format("%d  (Dreamstate %d, measured %d)", unreported * 5 + 0.5,
                RM.dreamstate * 5 + 0.5, RM.measured * 5 + 0.5) }
    end
    if RM:InFSR() then
        lines[#lines + 1] = { l = "Spirit regen resumes",
            r = string.format("%.1fs", RM:FSRRemaining()), c = WARN, rc = WHITE }
    end

    -- Between pulls: how many more this pool affords (Engine/PullBudget.lua).
    if MD.PullBudget then
        for _, ln in ipairs(MD.PullBudget:Lines()) do lines[#lines + 1] = ln end
    end

    -- What each mana source is worth right now, and what it buys on the clock.
    if MD.ManaCooldowns then
        local sources = MD.ManaCooldowns:All()
        if #sources > 0 then
            lines[#lines + 1] = {}
            for _, src in ipairs(sources) do
                local right
                if not src.ready then
                    right = string.format("%d mana, ready in %ds", src.delta, src.cdRemaining)
                elseif s.cd and s.cd.key == src.key and s.cd.tto then
                    right = string.format("%d mana -> OOM %ds", src.delta, s.cd.tto)
                else
                    right = string.format("%d mana, ready", src.delta)
                end
                lines[#lines + 1] = { l = src.name, r = right, c = KEY,
                    rc = src.ready and MANA or MUTED }
            end
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- Recent fights.
--------------------------------------------------------------------------------
function Tip:Fights(n)
    local lines = {}
    local hist = MD.fightHistory
    if not hist or #hist == 0 then return lines end
    n = math.min(n or 1, #hist)
    lines[#lines + 1] = {}
    if n == 1 then
        lines[#lines + 1] = { l = "Last fight: " .. Plain(hist[#hist].summary or "-"), c = SUB, wrap = true }
    else
        lines[#lines + 1] = { l = string.format("Last %d fights", n), c = Accent() }
        for i = #hist - n + 1, #hist do
            lines[#lines + 1] = { l = Plain(hist[i].summary or "-"), c = SUB, wrap = true }
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- Dashboard row: every term behind the numbers in the table, from row.calc
-- (RankMath:Explain). Nothing is modelled here that the row did not already
-- compute -- this is a view of RankMath, not a second opinion.
--------------------------------------------------------------------------------
local function Num(v, dec)
    return string.format(dec and ("%." .. dec .. "f") or "%d", v)
end

function Tip:Row(row)
    local lines = {}
    if not row then return lines end
    local c = row.calc
    if not c then return lines end

    local rankText = row.rankLabel and (c.label .. " (rolling " .. row.rankLabel .. ")")
        or string.format("%s (Rank %d)", c.label, row.rank)
    local note = row.suggested and "efficient rank" or row.isMax and "max rank"
        or row.dominated and "dominated" or (not row.known) and "not learned" or nil
    lines[#lines + 1] = { l = rankText, r = note,
        rc = row.suggested and GOLD or MUTED }
    lines[#lines + 1] = {}

    -- heal breakdown
    local healSuffix = ""
    if c.duration then
        healSuffix = string.format("  over %ds", c.duration)
        if c.ticks then healSuffix = healSuffix .. string.format(" (%d ticks)", c.ticks) end
    end
    lines[#lines + 1] = { l = "Heal", r = Num(row.heal) .. healSuffix, c = KEY }

    if c.kind == "lifebloom" then
        lines[#lines + 1] = { l = "  tick", r = Num(c.tick) .. " x7", c = SUB, rc = SUB }
        if not c.stacks then
            lines[#lines + 1] = { l = "  bloom", r = Num(c.bloom), c = SUB, rc = SUB }
        end
        lines[#lines + 1] = { l = string.format("  +healing  %d x %.4f hot / %.4f bloom coef x %.2f pen x %.2f %s",
            c.bonus, c.hotCoef, c.bloomCoef, c.penalty, c.bonusMult, c.bonusMultName), c = SUB }
        if c.relicTick and c.relicTick > 0 then
            lines[#lines + 1] = { l = "  relic", r = string.format("+%d per tick", c.relicTick), c = SUB, rc = SUB }
        end
    else
        lines[#lines + 1] = { l = "  base", r = Num(c.base), c = SUB, rc = SUB }
        if c.relicFlat and c.relicFlat > 0 then
            local relic = MD.RankMath.info and MD.RankMath.info.relic
            lines[#lines + 1] = { l = "  relic  " .. (relic and relic.name or "idol"),
                r = "+" .. Num(c.relicFlat), c = SUB, rc = SUB }
        end
        if c.kind == "hybrid" then
            lines[#lines + 1] = { l = string.format("  +healing direct  %d x %.2f coef x %.2f downrank",
                c.bonus, c.directCoef, c.penalty), r = "+" .. Num(c.directBonus), c = SUB, rc = SUB }
            lines[#lines + 1] = { l = string.format("  +healing hot  %d x %.2f coef x %.2f downrank x %.2f %s",
                c.bonus, c.hotCoef, c.penalty, c.bonusMult, c.bonusMultName),
                r = "+" .. Num(c.hotBonus), c = SUB, rc = SUB }
            lines[#lines + 1] = { l = string.format("  direct %d + hot %d", c.direct, c.hot), c = SUB }
        else
            lines[#lines + 1] = { l = string.format("  +healing  %d x %.2f coef x %.2f downrank x %.2f %s",
                c.bonus, c.coef, c.penalty, c.bonusMult, c.bonusMultName),
                r = "+" .. Num(c.bonusOut), c = SUB, rc = SUB }
        end
    end
    lines[#lines + 1] = { l = string.format("  talents  x%.2f", c.talentMult), c = SUB }
    if c.critMult then
        lines[#lines + 1] = { l = string.format("  crit  %.1f%% x1.5", c.crit * 100),
            r = string.format("x%.3f", c.critMult), c = SUB, rc = SUB }
    end

    lines[#lines + 1] = {}
    lines[#lines + 1] = { l = "Mana", r = Num(c.cost) .. "  " .. (c.costSource or "?"), c = KEY }
    lines[#lines + 1] = { l = "Cast", r = Num(row.cast, 1) .. "s" .. (row.ng and "*" or "") ..
        (row.cast <= 1.5 and "  GCD" or ""), c = KEY }
    if row.ng then
        lines[#lines + 1] = { l = string.format("  %.1fs base, %.1fs after a crit, %.1f%% crit -> %.2fs average",
            c.castBase, math.max(c.castBase - c.naturesGrace, 1.5), (c.ngCrit or 0) * 100, c.castNG), c = SUB }
        lines[#lines + 1] = { l = "  * Nature's Grace, chain-casting this one spell; an instant cast " ..
            "in between eats the buff for nothing.", c = MUTED, wrap = true }
    end

    lines[#lines + 1] = {}
    lines[#lines + 1] = { l = "HPM   heal per mana", r = Num(row.hpm, 2), c = KEY }
    lines[#lines + 1] = { l = "HPS   heal per second of cast", r = Num(row.hps), c = KEY }
    if row.casts == math.huge then
        lines[#lines + 1] = { l = "To OOM", r = "never: regen covers the cost", c = KEY, rc = GOOD }
    else
        lines[#lines + 1] = { l = "To OOM",
            r = string.format("%d casts from %d mana (net %d each)", row.casts, c.mana, c.netPerCast), c = KEY }
    end

    if row.overheal then
        local oh = row.overheal
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Overheal",
            r = string.format("%d%%  (%s, %d events)", oh.frac * 100,
                oh.scope == "rank" and "measured on this rank" or "family average", oh.n), c = KEY }
        lines[#lines + 1] = { l = "Effective",
            r = string.format("%d heal, %.2f HPM, %d HPS", row.effHeal, row.effHpm, row.effHps), c = KEY }
        if oh.tick then
            lines[#lines + 1] = { l = "  ticks / bloom overheal",
                r = string.format("%d%% / %s", oh.tick * 100 + 0.5, oh.bloom and string.format("%d%%", oh.bloom * 100 + 0.5) or "no bloom"),
                c = SUB, rc = SUB }
        end
        if oh.scope == "family" then
            lines[#lines + 1] = { l = "  A family average is the same factor on every rank, so it " ..
                "cannot say whether downranking overheals less. That needs samples on this rank.",
                c = MUTED, wrap = true }
        end
    end

    if row.virtual then
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Rolling stack: refreshed before it expires, so each cast is paid " ..
            "for with 6 ticks at the stack multiplier and never a bloom.", c = MUTED, wrap = true }
    end
    return lines
end

--------------------------------------------------------------------------------
-- Spell tooltip (v0.14.9): what ONE rank heals, appended to the game's own
-- tooltip on the action bar, the spellbook and a chat link (the hook lives in
-- UI/SpellTooltip.lua). The dashboard row tooltip above answers "why is this
-- rank better than that one"; this answers "what does this button do", so it
-- is the parts of a cast a healer reads -- each tick, the HoT total, the direct
-- range, the bloom, the whole -- and nothing about chain-casting to OOM.
-- Same RankMath row, same numbers, a different cut of them. Shift adds the
-- derivation.
--
-- Always the LIVE context: the dashboard's Simulate strip is a what-if for the
-- dashboard, and a button on your bar must never show a hypothetical heal.
--------------------------------------------------------------------------------
local function R(v) return math.floor((v or 0) + 0.5) end

local function Range(lo, hi)
    lo, hi = R(lo), R(hi)
    if lo == hi then return tostring(lo) end
    return lo .. " - " .. hi
end

local function Pct(p) return string.format("%d%%", (p or 0) * 100 + 0.5) end

function Tip:Spell(spellID, detail)
    local lines = {}
    local SD, RM = MD.SpellData, MD.RankMath
    local s = SD and SD.spells[spellID]
    if not s or not RM then return lines end
    local ctx = RM:Context({ live = true })
    local head = { l = "ManaDemon", c = Accent(),
                   r = string.format("+%d healing", R(ctx.bonus)), rc = MUTED }

    -- Swiftmend has no heal of its own: it is worth the HoT it eats, which is
    -- your highest rank of each, at your stats.
    if s.family == "Swiftmend" then
        local out = {}
        local function eat(family, seconds, label)
            local id = SD.maxRank[family]
            local row = id and RM:RowFor(id, ctx, nil, true)
            local c = row and row.calc
            if not c then return end
            local hot = (c.kind == "hybrid") and c.hot or row.heal
            local ticks = (c.kind == "hybrid") and (c.duration / 3) or c.ticks
            local n = math.min(ticks, seconds / 3)
            out[#out + 1] = { l = "Eats " .. label,
                r = string.format("%d  (%ds of its ticks)", R(hot / ticks * n), seconds), c = KEY }
        end
        eat("Rejuvenation", 12, "Rejuvenation")
        eat("Regrowth", 18, "Regrowth")
        if #out == 0 then return lines end
        lines[1] = head
        for _, ln in ipairs(out) do lines[#lines + 1] = ln end
        return lines
    end

    local row = RM:RowFor(spellID, ctx, nil, true)
    local c = row and row.calc
    if not c then return lines end
    lines[1] = head

    if c.kind == "direct" then
        lines[#lines + 1] = { l = "Heal", r = Range(c.min, c.max), c = KEY }
        lines[#lines + 1] = { l = "  crit " .. Pct(c.crit), r = Range(c.min * 1.5, c.max * 1.5), c = SUB, rc = SUB }
        lines[#lines + 1] = { l = "Average", r = string.format("%d  (%d with crits)",
            R(row.heal / c.critMult), R(row.heal)), c = KEY }

    elseif c.kind == "hot" then
        lines[#lines + 1] = { l = "Tick", r = string.format("%d  x%d, every 3s", R(row.heal / c.ticks), c.ticks), c = KEY }
        lines[#lines + 1] = { l = "Total", r = string.format("%d  over %ds", R(row.heal), c.duration), c = KEY }

    elseif c.kind == "hybrid" then
        local ticks = c.duration / 3
        local direct = c.direct / c.critMult
        lines[#lines + 1] = { l = "Direct", r = Range(c.min, c.max), c = KEY }
        lines[#lines + 1] = { l = "  crit " .. Pct(c.crit), r = Range(c.min * 1.5, c.max * 1.5), c = SUB, rc = SUB }
        lines[#lines + 1] = { l = "Tick", r = string.format("%d  x%d, every 3s", R(c.hot / ticks), ticks), c = KEY }
        lines[#lines + 1] = { l = "HoT total", r = string.format("%d  over %ds", R(c.hot), c.duration), c = KEY }
        lines[#lines + 1] = { l = "Total", r = string.format("%d  (%d with crits)",
            R(direct + c.hot), R(row.heal)), c = KEY }

    elseif c.kind == "lifebloom" then
        lines[#lines + 1] = { l = "Tick", r = string.format("%d  x7, every 1s", R(c.tick)), c = KEY }
        lines[#lines + 1] = { l = "  at 2 / 3 stacks", r = string.format("%d / %d", R(c.tick * 2), R(c.tick * 3)),
            c = SUB, rc = SUB }
        lines[#lines + 1] = { l = "HoT total", r = string.format("%d  over %ds", R(c.hot), c.duration), c = KEY }
        lines[#lines + 1] = { l = "Bloom", r = string.format("%d  (crit %d)", R(c.bloom), R(c.bloom * 1.5)), c = KEY }
        lines[#lines + 1] = { l = "Total", r = string.format("%d  (7 ticks + bloom)", R(c.hot + c.bloom)), c = KEY }
        -- rolling: refreshed every 6s, so 6 ticks a cast at the stack and never a bloom
        lines[#lines + 1] = { l = "Rolled at 3 stacks", r = string.format("%d a refresh, no bloom",
            R(c.tick * 3 * 6)), c = KEY }
    end

    lines[#lines + 1] = { l = "HPM / HPS", r = string.format("%.2f  /  %d", row.hpm, R(row.hps)), c = KEY }

    if row.overheal then
        lines[#lines + 1] = { l = "After your overheal", r = string.format("%d  (%s wasted, %s)",
            R(row.effHeal), Pct(row.overheal.frac),
            row.overheal.scope == "family" and "family average" or "measured"), c = KEY, rc = SUB }
    end
    if c.penalty < 0.999 then
        lines[#lines + 1] = { l = "Downranked", r = string.format("+healing x%.2f", c.penalty), c = WARN, rc = WARN }
    end

    if detail then
        lines[#lines + 1] = {}
        local SHORT = { ["Empowered Rejuvenation"] = "Emp. Rejuvenation", ["Empowered Touch"] = "Emp. Touch" }
        local function term(label, base, bonus, amount, coef, mult, multName)
            local t = string.format("%d healing x %.3f coef", R(bonus), coef)
            if c.penalty < 0.999 then t = t .. string.format(" x %.2f downrank", c.penalty) end
            if mult and mult > 1.0001 then
                t = t .. string.format(" x %.2f %s", mult, SHORT[multName] or multName)
            end
            lines[#lines + 1] = { l = "  " .. label, r = string.format("%d base + %d", R(base), R(amount)),
                c = SUB, rc = SUB }
            lines[#lines + 1] = { l = "    " .. t, c = MUTED }
        end
        if c.kind == "direct" then
            term("direct", c.base + (c.relicFlat or 0), c.bonus, c.bonusOut, c.coef, c.bonusMult, c.bonusMultName)
        elseif c.kind == "hot" then
            term("HoT", c.base + (c.relicFlat or 0), c.bonus, c.bonusOut, c.coef, c.bonusMult, c.bonusMultName)
        elseif c.kind == "hybrid" then
            term("direct", c.base + (c.relicFlat or 0), c.bonus, c.directBonus, c.directCoef)
            term("HoT", c.hotBase, c.bonus, c.hotBonus, c.hotCoef, c.bonusMult, c.bonusMultName)
        elseif c.kind == "lifebloom" then
            term("HoT", c.base + (c.relicFlat or 0), c.bonus, c.hotBonus, c.hotCoef, c.bonusMult, c.bonusMultName)
            term("bloom", c.bloomBase, c.bonus, c.bloomBonus, c.bloomCoef, c.bonusMult, c.bonusMultName)
        end
        local talentName = (c.kind == "hot") and "Gift of Nature, Improved Rejuvenation" or "Gift of Nature"
        if c.talentMult > 1.0001 then
            lines[#lines + 1] = { l = string.format("  then x %.2f  %s", c.talentMult, talentName), c = SUB }
        end
        if ctx.treeAura > 0 then
            lines[#lines + 1] = { l = string.format("  +healing includes %d Tree of Life aura", R(ctx.treeAura)), c = SUB }
        end
    else
        lines[#lines + 1] = { l = "Shift: how it is calculated", c = MUTED }
    end
    return lines
end

--------------------------------------------------------------------------------
-- Column glossary, shown on the dashboard's header row. This used to be a
-- paragraph under the table; at 760px it wrapped onto the rows below it.
--------------------------------------------------------------------------------
function Tip:Columns()
    local info = MD.RankMath and MD.RankMath.info
    local lines = { { l = "What the columns mean", c = Accent() }, {} }

    lines[#lines + 1] = { l = "Heal/cast", r = "one cast, all ticks, at your stats", c = KEY, rc = SUB }
    lines[#lines + 1] = { l = "HPM", r = "heal per mana", c = KEY, rc = SUB }
    lines[#lines + 1] = { l = "HPS", r = "heal per second of cast time (1.5s GCD for instants)", c = KEY, rc = SUB }
    lines[#lines + 1] = { l = "To OOM", r = "chain-casts from your current mana", c = KEY, rc = SUB }

    if info then
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Regen used", r = string.format("%d mp5 casting, %d mp5 resting",
            info.castingRegen * 5 + 0.5, info.baseRegen * 5 + 0.5), c = KEY }
        lines[#lines + 1] = { l = "Mana used", r = string.format("%d", info.mana), c = KEY }
        if info.naturesGrace > 0 then
            lines[#lines + 1] = { l = "Cast *", r = "Nature's Grace averaged in", c = KEY, rc = SUB }
        end
    end
    if MD.db and MD.db.effectiveMode then
        lines[#lines + 1] = {}
        lines[#lines + 1] = { l = "Effective mode is on: the accent-coloured columns are " ..
            "multiplied by (1 - your measured overheal).", c = MUTED, wrap = true }
    end
    lines[#lines + 1] = {}
    lines[#lines + 1] = { l = "Hover any row for the full derivation of its numbers.", c = MUTED }
    return lines
end

--------------------------------------------------------------------------------
-- The widget / minimap composite: clock, state, last fight, click hints.
--------------------------------------------------------------------------------
function Tip:Clock(hints)
    local lines = { { l = "ManaDemon", c = Accent() } }
    local str = MD.GetDisplayString and MD:GetDisplayString() or ""
    if str ~= "" then
        lines[#lines + 1] = { l = Plain(str) }
    end
    lines[#lines + 1] = {}
    for _, ln in ipairs(Tip:Mana()) do lines[#lines + 1] = ln end
    for _, ln in ipairs(Tip:Fights(1)) do lines[#lines + 1] = ln end
    if hints then
        lines[#lines + 1] = {}
        for _, h in ipairs(hints) do
            lines[#lines + 1] = { l = h, c = MUTED }
        end
    end
    return lines
end
