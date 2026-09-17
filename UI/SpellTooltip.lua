-- The spell tooltip hook (v0.14.9): ManaDemon's numbers for the exact rank
-- under the mouse, appended to the game's own tooltip wherever it shows a spell
-- -- action bars, the spellbook, a chat link. The lines are MD.Tip:Spell
-- (UI/Tooltip.lua); this file only decides WHEN to add them.
--
-- Rules it keeps:
--   * Druid only, and only for a spell Data/SpellData.lua has a row for.
--   * Once per tooltip. OnTooltipSetSpell can fire more than once for one
--     showing, and an action button re-sets its tooltip on a timer; the id is
--     remembered until OnTooltipCleared, which every re-set goes through.
--   * Never break the game's tooltip: the builder runs under pcall.
--   * Holding or releasing Shift re-runs the owner's OnEnter so the derivation
--     appears without moving the mouse.
local _, MD = ...

-- 2.5.x returns (name, spellID); older builds returned (name, rank[, id]).
-- The id is the one number among the returns.
local function SpellIDOf(tt)
    if not tt.GetSpell then return nil end
    local r = { pcall(tt.GetSpell, tt) }
    if not r[1] then return nil end
    local id
    for i = 2, #r do
        if type(r[i]) == "number" then id = r[i] end
    end
    return id
end

function MD:SpellTooltipAppend(tt)
    if MD.db and MD.db.spellTooltip == false then return end
    if not (MD.player and MD.player.isDruid) then return end
    local id = SpellIDOf(tt)
    if not id or not (MD.SpellData and MD.SpellData.spells[id]) then return end
    if tt.mdSpellID == id then return end
    tt.mdSpellID = id
    local shift = IsShiftKeyDown and IsShiftKeyDown() or false
    local ok, lines = pcall(MD.Tip.Spell, MD.Tip, id, shift)
    if not ok then
        MD:Debug("other", "spell tooltip for %s failed: %s", tostring(id), tostring(lines))
        return
    end
    if lines and #lines > 0 then
        tt:AddLine(" ")
        MD.Tip:Render(tt, lines)
        tt:Show()   -- resize to the new lines
    end
end

local function Hook(tt)
    if not tt or not tt.HookScript then return end
    tt:HookScript("OnTooltipSetSpell", function(self) MD:SpellTooltipAppend(self) end)
    tt:HookScript("OnTooltipCleared", function(self) self.mdSpellID = nil end)
end
Hook(GameTooltip)
Hook(_G.ItemRefTooltip)

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MODIFIER_STATE_CHANGED")
watcher:SetScript("OnEvent", function(_, _, key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    if not (GameTooltip:IsShown() and GameTooltip.mdSpellID) then return end
    local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
    local enter = owner and owner.GetScript and owner:GetScript("OnEnter")
    if enter then pcall(enter, owner) end
end)
