-- tools/run.sh tools/healcheck.lua [savedVariables.lua]
--
-- The client-side twin of tools/wclcheckkit.lua: what THIS character's
-- recordings say each spell healed, against what the model says it heals.
-- Where wclcheckkit grades the model against somebody else's raid with an
-- INFERRED profile, this grades it against the author's own fights with the
-- profile the client itself wrote down -- level, +healing, crit and talents,
-- all measured. It is the only fully trusted calibration the project has.
--
-- Read it by the MINIMUM of each bucket, not the median. A recorded amount is
-- gross, and a heal that lands on a full target is still gross, so the bucket
-- is one value smeared upwards by nothing at all -- unless something adds the
-- overheal back on, which is exactly the v0.14.7 bug this tool found: every
-- recording made before v0.14.7 carries heal + overheal, so its ticks run from
-- 1.0x the model (no overheal) to 2.0x (a full one), and the bottom of each
-- bucket is the only honest sample in it.
--
-- Lifebloom's tick is per-stack, so its bucket is three overlapping ones
-- (1x, 2x, 3x the base); the 1-stack cluster is printed separately.
local here = arg[0]:match("^(.*)/[^/]+$")
local file = arg[2]
if not file then
    local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end end
    file = os.getenv("MD_SAVEDVARS")
    if not file then
        for _, c in ipairs({ ".logs/ManaDemon.lua" }) do if exists(c) then file = c end end
        local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"'
            .. '/*/SavedVariables/ManaDemon.lua 2>/dev/null')
        if p then for line in p:lines() do file = file or line end; p:close() end
    end
end
if not file then print("usage: healcheck.lua <SavedVariables.lua>"); os.exit(2) end
dofile(file)
local realDB = _G.ManaDemonDB
local pre = {}
for k, c in pairs(realDB.char or {}) do pre[k] = c.profile end
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SD, K = MD.SpellData, MD.SimModel.K
local CRIT_FLAG = 100000

for key, c in pairs(realDB.char or {}) do
    -- every own heal event of every recording, by spell and kind, non-crit
    local buckets, order = {}, {}
    local oldest
    for _, rec in ipairs(c.recordings or {}) do
        local v = rec.v or 1
        if not oldest or v < oldest then oldest = v end
        for i = 1, (rec.n or 0) do
            local kind = rec.ev.kind[i]
            if kind == K.OWNHEAL or kind == K.OWNTICK then
                local raw = rec.ev.x[i] or 0
                if raw < CRIT_FLAG then
                    local what = (kind == K.OWNTICK) and "tick" or "direct"
                    local bk = raw .. "|" .. what
                    local b = buckets[bk]
                    if not b then
                        b = { id = raw, what = what, v = {} }
                        buckets[bk] = b; order[#order + 1] = bk
                    end
                    b.v[#b.v + 1] = rec.ev.amt[i] or 0
                end
            end
        end
    end
    if #order > 0 then
        local p = pre[key]
        if p then
            S.level = p.level; S.manaMax = p.manaMax; S.mana = p.manaMax
            if (p.intellect or 0) > 0 then S.stats[4] = p.intellect end
            if (p.spirit or 0) > 0 then S.stats[5] = p.spirit end
            local h, cr = p.healing or 0, p.crit or 0
            _G.GetSpellBonusHealing = function() return h end
            _G.GetSpellCritChance = function() return cr end
            local tal = p.talents or {}
            function MD:TalentRank(n) return tal[n] or 0 end
            MD.player.class = "DRUID"; MD.player.isDruid = true; MD.player.level = p.level
            function MD:InTreeForm() return (p.form == "tree") end
            SD:BuildKnown(); MD.Regen:Refresh()
        end
        local kit = MD.RankMath:SpellKit({ live = true }).caster
        table.sort(order)
        print("== " .. key .. (p and string.format("   level %d, +%d healing, %.1f%% crit",
            p.level or 0, p.healing or 0, p.crit or 0) or "   (no profile)"))
        if (oldest or 1) < 2 then
            print("   stream v" .. tostring(oldest) .. ": recorded before v0.14.7, so every amount "
                .. "below is heal + overheal.")
            print("   Read the MINIMUM column; the median and the max are the same heal with "
                .. "somebody's overheal on top.")
        end
        print(string.format("   %-26s %5s %7s %7s %7s %8s %7s",
            "spell", "n", "min", "median", "max", "model", "min/model"))
        local function line(label, v, model)
            local n = #v
            print(string.format("   %-26s %5d %7d %7d %7d %8.0f %7s", label, n, v[1],
                v[math.ceil(n / 2)], v[n], model,
                model > 0 and string.format("%.2f", v[1] / model) or "-"))
        end
        for _, bk in ipairs(order) do
            local b = buckets[bk]
            table.sort(b.v)
            local resolved = SD:Resolve(b.id)
            local sd, e = SD.spells[resolved], kit[resolved]
            local label = sd and (sd.family .. " R" .. tostring(sd.rank)) or ("spell " .. b.id)
            if resolved ~= b.id then label = label .. " bloom" end
            local model = 0
            if e then
                if b.what == "tick" then model = e.tick or 0
                elseif resolved ~= b.id then model = e.bloom or 0
                else model = e.direct or 0 end
            end
            line(label, b.v, model)
            if resolved == SD.maxRank.Lifebloom and b.what == "tick" then
                local lo, base = b.v[1], {}
                for _, x in ipairs(b.v) do if x <= lo * 1.15 then base[#base + 1] = x end end
                line("  1-stack cluster", base, model)
            end
        end
        print("")
    end
end
