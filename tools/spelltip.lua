-- tools/run.sh tools/spelltip.lua
--
-- The spell tooltip (v0.14.9) under the stub: a fake GameTooltip that records
-- what was added to it, driven the way the client drives the real one -- set a
-- spell, fire OnTooltipSetSpell (twice, as the client can), clear, re-set.
-- It holds two things: the plumbing (druid only, once per showing, off means
-- off, never a bare pipe) and the arithmetic (every number on the tooltip is
-- the model's own -- the same RankMath row the dashboard shows and the same
-- SpellKit value the simulator heals with).
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SD, RM = MD.SpellData, MD.RankMath

-- a GameTooltip that remembers: hooks run in order, lines are stored
local tt = _G.GameTooltip
tt.hooks, tt.lines, tt.spell = {}, {}, nil
function tt:HookScript(k, fn) self.hooks[k] = self.hooks[k] or {}; table.insert(self.hooks[k], fn) end
function tt:AddLine(l) self.lines[#self.lines + 1] = { l = l } end
function tt:AddDoubleLine(l, r) self.lines[#self.lines + 1] = { l = l, r = r } end
function tt:GetSpell() if self.spell then return "Spell", self.spell end end
local function fire(k) for _, fn in ipairs(tt.hooks[k] or {}) do fn(tt) end end
local function SetSpell(id)
    tt.lines = {}; fire("OnTooltipCleared")
    tt.spell = id; fire("OnTooltipSetSpell")
    return tt.lines
end

S.Load({ "UI/Style.lua", "UI/Tooltip.lua", "UI/SpellTooltip.lua" }, "ManaDemon", MD)

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-52s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end
local function find(lines, label)
    for _, ln in ipairs(lines) do
        if ln.l and ln.l:gsub("^%s+", "") == label then return ln end
    end
end
local function nums(str)
    local out = {}
    for n in tostring(str or ""):gmatch("%d+%.?%d*") do out[#out + 1] = tonumber(n) end
    return out
end
local function near(a, b, tol) return a and b and math.abs(a - b) <= (tol or 1) end
local function show(lines)
    for _, ln in ipairs(lines) do print("    | " .. tostring(ln.l) .. (ln.r and ("   " .. ln.r) or "")) end
end

MD.player.isDruid = true
local ctx = RM:Context({ live = true })
local kit = RM:SpellKit({ live = true }).caster

-- Rejuvenation -----------------------------------------------------------------
local rejuv = SD.maxRank.Rejuvenation
local L = SetSpell(rejuv); show(L)
local row = RM:RowFor(rejuv, ctx, nil, true)
local tick, total = find(L, "Tick"), find(L, "Total")
check("Rejuvenation: a tick line and a total", tick ~= nil and total ~= nil)
check("  the tick is the simulator's tick", tick and near(nums(tick.r)[1], kit[rejuv].tick),
    tick and string.format("%s vs %.1f", tick.r, kit[rejuv].tick))
check("  ticks x count = total", tick and total and near(nums(tick.r)[1] * nums(tick.r)[2], nums(total.r)[1], 4))
check("  the total is the dashboard's heal", total and near(nums(total.r)[1], row.heal))

-- the plumbing, on the same spell ------------------------------------------------
local before = #tt.lines
fire("OnTooltipSetSpell")
check("a second OnTooltipSetSpell adds nothing", #tt.lines == before, before .. " -> " .. #tt.lines)
check("re-setting after a clear adds it again", #SetSpell(rejuv) == before)
local bare = false
for _, ln in ipairs(L) do
    for _, str in ipairs({ ln.l or "", ln.r or "" }) do
        if str:gsub("||", ""):find("|", 1, true) then bare = true end
        if str:find("[\128-\255]") then bare = true end
    end
end
check("ASCII only, no bare pipe", not bare)
check("a hint for the derivation, not the derivation", find(L, "Shift: how it is calculated") ~= nil)
S.shift = true
local LS = SetSpell(rejuv)
S.shift = false
check("Shift adds the derivation", #LS > #L and find(LS, "HoT") ~= nil, #L .. " -> " .. #LS)
MD.db.spellTooltip = false
check("off means nothing is added", #SetSpell(rejuv) == 0)
MD.db.spellTooltip = true
check("a spell the model does not know adds nothing", #SetSpell(635) == 0)
MD.player.isDruid = false
check("a non-druid gets nothing", #SetSpell(rejuv) == 0)
MD.player.isDruid = true
MD.sim = { heal = 5000 }
local simmed = find(SetSpell(rejuv), "Total")
MD.sim = nil
check("the dashboard's Simulate strip never reaches a tooltip", simmed and near(nums(simmed.r)[1], row.heal))

-- Regrowth ---------------------------------------------------------------------
local rg = SD.maxRank.Regrowth
L = SetSpell(rg); show(L)
row = RM:RowFor(rg, ctx, nil, true)
local d, t, hot, tot = find(L, "Direct"), find(L, "Tick"), find(L, "HoT total"), find(L, "Total")
check("Regrowth: direct, tick, HoT total, total", d and t and hot and tot and true)
local lo, hi = d and nums(d.r)[1], d and nums(d.r)[2]
check("  the direct range brackets the simulator's direct", lo and hi and lo < kit[rg].direct and kit[rg].direct < hi,
    string.format("%s vs %.0f", d and d.r or "?", kit[rg].direct))
check("  the tick is the simulator's tick", t and near(nums(t.r)[1], kit[rg].tick))
check("  7 ticks over 21s", t and nums(t.r)[2] == 7 and hot and nums(hot.r)[2] == 21)
check("  total = average direct + HoT total", tot and near(nums(tot.r)[1], kit[rg].direct + row.calc.hot, 1))
check("  and with crits it is the dashboard's heal", tot and near(nums(tot.r)[2], row.heal))
local crit = find(L, "crit " .. string.format("%d%%", row.calc.crit * 100 + 0.5))
check("  the crit line uses Regrowth's own crit chance", crit ~= nil and near(nums(crit.r)[1], lo * 1.5, 1),
    crit and crit.r or "missing")

-- Lifebloom --------------------------------------------------------------------
local lb = SD.maxRank.Lifebloom
L = SetSpell(lb); show(L)
t, hot = find(L, "Tick"), find(L, "HoT total")
local bloom, stacks = find(L, "Bloom"), find(L, "at 2 / 3 stacks")
tot = find(L, "Total")
check("Lifebloom: tick, stacks, HoT total, bloom, total", t and stacks and hot and bloom and tot and true)
check("  the tick is the simulator's per-stack tick", t and near(nums(t.r)[1], kit[lb].tick))
check("  the bloom is the simulator's bloom (flat, v0.14.4)", bloom and near(nums(bloom.r)[1], kit[lb].bloom))
check("  stacked ticks are 2x and 3x", stacks and near(nums(stacks.r)[1], 2 * kit[lb].tick, 1)
    and near(nums(stacks.r)[2], 3 * kit[lb].tick, 1))
check("  total = 7 ticks + one bloom", tot and near(nums(tot.r)[1], 7 * kit[lb].tick + kit[lb].bloom, 2))
local rolled = find(L, "Rolled at 3 stacks")
check("  rolled at 3 is the dashboard's x3 row", rolled and near(nums(rolled.r)[2] or nums(rolled.r)[1],
    RM:RowFor(lb, ctx, 3).heal, 2), rolled and rolled.r)

-- Healing Touch, and a downranked one ---------------------------------------------
local ht = SD.maxRank.HealingTouch
L = SetSpell(ht); show(L)
row = RM:RowFor(ht, ctx, nil, true)
local heal = find(L, "Heal")
check("Healing Touch: a range around the average", heal and nums(heal.r)[1] < row.heal / row.calc.critMult
    and row.heal / row.calc.critMult < nums(heal.r)[2])
check("  max rank is not marked downranked", find(L, "Downranked") == nil)
local low = SD.all.HealingTouch[7]   -- rank 7, level 38, on a level 64 druid
L = SetSpell(low)
local dr = find(L, "Downranked")
check("a rank far below the player says it is downranked", dr ~= nil and dr.r:find(
    string.format("%.2f", RM:RowFor(low, ctx, nil, true).calc.penalty), 1, true) ~= nil, dr and dr.r)

-- Swiftmend ------------------------------------------------------------------
L = SetSpell(SD.maxRank.Swiftmend); show(L)
local eatsR, eatsG = find(L, "Eats Rejuvenation"), find(L, "Eats Regrowth")
local smKit = kit[SD.maxRank.Swiftmend]
check("Swiftmend: what it eats, the simulator's numbers", eatsR and eatsG
    and near(nums(eatsR.r)[1], smKit.swiftmendRejuv, 1) and near(nums(eatsG.r)[1], smKit.swiftmendRegrowth, 1),
    eatsR and eatsG and (eatsR.r .. " / " .. eatsG.r))

-- a builder that throws must not break the game's tooltip
local real = MD.Tip.Spell
MD.Tip.Spell = function() error("boom") end
local okCall = pcall(SetSpell, rejuv)
MD.Tip.Spell = real
check("a failing builder never breaks the game's tooltip", okCall)

print(string.format("\n%d ok, %d failed", ok, #fails))
for _, f in ipairs(fails) do print("  FAIL " .. f) end
if #fails > 0 then os.exit(1) end
