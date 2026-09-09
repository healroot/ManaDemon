-- tools/run.sh tools/import.lua [command] [n] [options]
--
-- Real recordings, offline. Loads the game's SavedVariables file -- the only
-- file a WoW addon can write -- as this addon's own database, and runs the
-- same engine the Review tab runs, on the real fights, without the game:
--
--   list                 every recording of the character, with its validate verdict
--   runs                 every stored RUN with its stats (v0.9.2)
--   spells N             what recording N spent its mana on, by kind (v0.10.1)
--   validate N           the full gate report for recording N (1 = most recent)
--   gates --run K        every pull of run K through the gates at once, summarised
--                        by which gate failed and how often (SP.RunGates)
--   replay N             the trace: every own cast with its target and label, the
--                        mana fit, each target's lowest health
--   coach N [force]      the search and the card (force: even if the gates failed)
--   export N             the /md export text for N, written to .logs/recordings/<id>.txt
--
-- With --run K, every command above addresses the pulls of run K instead of the
-- ring of single fights: `list --run 1` lists that run's pulls, `validate 3
-- --run 1` is its third pull, and `export --run 1` writes the whole run to
-- .logs/runs/<id>.txt. The same address the game takes as "1:3".
--
-- Options: --file <path>   the SavedVariables file (default: $MD_SAVEDVARS, then
--                          .logs/ManaDemon.lua, then the author's install)
--          --char <key>    "Name-Realm" (default: the first character with recordings)
--          --run K         address the pulls of run K
--
-- The spell kit is the CHARACTER's when the file carries a profile (v0.9.0:
-- ManaDemon writes cdb.profile at login, on a talent change and on a gear
-- change) -- healing, crit, spirit, intellect, level, talents and the relic are
-- applied to the stub before the kit is built. Without one, the kit is the
-- harness's stand-in (the BF-1 build, +450 healing, 15% crit) and every run
-- says so. Costs are the recorded ones either way, so the mana side is exact.
local here = arg[0]:match("^(.*)/[^/]+$")

-- arguments
local cmd, n, opts = "list", 1, {}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--file" then opts.file = arg[i + 1]; i = i + 1
        elseif a == "--char" then opts.char = arg[i + 1]; i = i + 1
        elseif a == "--run" then opts.run = tonumber(arg[i + 1]); i = i + 1
        elseif a == "force" then opts.force = true
        elseif tonumber(a) then n = tonumber(a); opts.gotN = true
        elseif a:match("^%a+$") then cmd = a end
        i = i + 1
    end
end

-- the file
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end
local file = opts.file or os.getenv("MD_SAVEDVARS")
if not file then
    local candidates = { ".logs/ManaDemon.lua" }
    local p = io.popen('ls "/mnt/e/Blizzard/World of Warcraft/_anniversary_/WTF/Account"/*/SavedVariables/ManaDemon.lua 2>/dev/null')
    if p then for line in p:lines() do candidates[#candidates + 1] = line end; p:close() end
    for _, c in ipairs(candidates) do if exists(c) then file = c; break end end
end
if not file or not exists(file) then
    print("import: no SavedVariables file. Pass --file <path>, set MD_SAVEDVARS, or copy ManaDemon.lua to .logs/.")
    os.exit(2)
end

-- Load the database BEFORE the addon, so Core.lua initialises from it exactly
-- as the client does: settings, history, calibration, recordings.
dofile(file)
local realDB = _G.ManaDemonDB
if not realDB then print("import: " .. file .. " holds no ManaDemonDB."); os.exit(2) end

-- Loading the addon over the real database runs its PLAYER_LOGIN path, and
-- that path WRITES the profile -- with the stub's stats, over the character's
-- own. Keep what the file said and put it back afterwards: this tool reads the
-- game's database, it does not get to invent one.
local preloaded = {}
for key, c in pairs(realDB.char or {}) do preloaded[key] = { profile = c.profile, mp5 = c.mp5 } end

local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
S.Load({ "UI/Style.lua", "UI/Tooltip.lua" }, "ManaDemon", MD)   -- Tip is what the card and reports print through

-- the character: the stub's charKey is "Penek-Anniversary"; the real one is
-- whatever the game wrote
local chars = {}
for key, c in pairs(realDB.char or {}) do chars[#chars + 1] = { key = key, n = #(c.recordings or {}) } end
table.sort(chars, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
local charKey = opts.char or (chars[1] and chars[1].key)
if not charKey or not realDB.char[charKey] then
    print("import: no character with recordings in " .. file); os.exit(2)
end
MD.cdb = realDB.char[charKey]
MD.player.charKey = charKey
MD.cdb.profile = preloaded[charKey] and preloaded[charKey].profile or nil
MD.cdb.mp5 = preloaded[charKey] and preloaded[charKey].mp5 or nil

-- The character, applied to the stub (v0.9.0). Every number RankMath:Context()
-- reads comes from the client in game; here it comes from the profile the addon
-- wrote. Talents replace the harness's BF-1 build, so a spell kit built after
-- this is THIS druid's. Anything the profile does not carry keeps the stub's
-- value, and the header line says which of the two you are looking at.
local profile = MD.cdb.profile
local kitLine
if profile then
    S.level = profile.level or S.level
    S.stats[4] = profile.intellect or S.stats[4]
    S.stats[5] = profile.spirit or S.stats[5]
    S.manaMax = profile.manaMax or S.manaMax
    S.mana = S.manaMax
    local healing, crit = profile.healing or 0, profile.crit or 0
    _G.GetSpellBonusHealing = function() return healing end
    _G.GetSpellCritChance = function() return crit end
    if profile.relic then _G.GetInventoryItemID = function() return profile.relic end end
    local talents = profile.talents or {}
    function MD:TalentRank(name) return talents[name] or 0 end
    MD.player.class = profile.class or MD.player.class
    MD.player.isDruid = (profile.class == "DRUID")
    MD.player.level = S.level
    -- the form the profile was taken in, so the Tree aura and the costs agree
    if profile.form == "tree" then
        function MD:InTreeForm() return true end
    elseif profile.form then
        function MD:InTreeForm() return false end
    end
    -- v0.13: a profile lifted out of a Warcraft Logs report. The stub's
    -- IsSpellKnown answers for the AUTHOR's spellbook, so a level 70 druid's
    -- Rejuvenation R13 and Regrowth R10 fell out of the kit entirely and the
    -- engine could not price half their casts. Ranks are trainer
    -- prerequisites, so level decides the book.
    if profile.fromLog then
        local lvl = profile.level or 70
        _G.IsSpellKnown = function(id)
            local sd = MD.SpellData.spells[id]
            return sd ~= nil and (sd.level or 0) <= lvl
        end
        _G.IsPlayerSpell = _G.IsSpellKnown
        MD.SpellData:BuildKnown()
    end
    MD.Regen:Refresh()
    kitLine = string.format("kit:   the character's (profile of %s): level %d %s, +%d healing, %.1f%% crit, " ..
        "%d spirit, %d int, %s", os.date("%Y-%m-%d %H:%M", profile.at or 0), profile.level or 0,
        profile.class or "?", profile.healing or 0, profile.crit or 0, profile.spirit or 0,
        profile.intellect or 0, profile.form == "tree" and "Tree of Life form" or "caster form")
else
    kitLine = "kit:   the harness's (BF-1 build, +450 healing, 15% crit) -- this file carries no profile; " ..
        "log in with v0.9.0 or later and it will"
end

local mp5 = MD.cdb.mp5
local mp5Line
if mp5 then
    mp5Line = string.format("mp5:   %d measured by %s on %s (%d beats%s) - the model adds %.2f/s the API omits",
        mp5.mp5 or 0, mp5.source or "?", os.date("%Y-%m-%d", mp5.at or 0), mp5.ticks or 0,
        mp5.solo == false and ", IN A GROUP" or "", MD.Regen:Unreported())
else
    mp5Line = "mp5:   not measured (/md regentest solo) - recordings made before it carry energize 0"
end

local function Say(fmt, ...) print(string.format(fmt, ...)) end
local function Strip(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

Say("file:  %s", file)
Say("char:  %s   (%d recording(s), %d summarised fight(s))", charKey, #(MD.cdb.recordings or {}), #(MD.cdb.fights or {}))
Say("%s", kitLine)
Say("%s", mp5Line)
Say("")

local FR, SM, SP, RR = MD.FightRecorder, MD.SimModel, MD.SimPlanner, MD.RunRecorder

-- What "N" addresses: the ring of single fights, or -- with --run K -- the
-- pulls of run K, in the order they happened. Everything below reads `list`,
-- so a run's pull goes through exactly the same engine as a single fight.
local runs = RR and RR:List() or {}
local theRun, list, what = nil, nil, "recording"
if opts.run then
    theRun = runs[opts.run]
    if not theRun then
        Say("no run %d (%d stored). Try: runs", opts.run, #runs)
        os.exit(1)
    end
    list = theRun.pulls or {}
    what = "pull"
    Say("run:   %d. %s -- %s", opts.run, theRun.name or "?", Strip(RR:Line(theRun)))
    Say("")
else
    list = FR:List()
end

if cmd ~= "runs" and #list == 0 then
    Say(theRun and "this run kept no pulls." or "no recordings.")
    os.exit(0)
end

-- the label the game would take for this recording: "3", or "1:3" inside a run
local function Label(i)
    return opts.run and (opts.run .. ":" .. i) or tostring(i)
end

local function Verdict(rec)
    local v = SM:Validate(rec)
    if not v then return "?" end
    if v.ok then return "ok" end
    for _, g in ipairs(v.gates) do if not g.ok then return g.name .. ": " .. Strip(g.text) end end
    return "failed"
end

local function When(id)
    return id and os.date("%Y-%m-%d %H:%M", id) or "?"
end

if cmd == "list" then
    Say("%-5s %-17s %-22s %7s %5s %6s %7s %5s  %s", "#", theRun and "into the run" or "when", "zone",
        "dur", "casts", "spent", "tracked", "auras", "validate")
    for i, r in ipairs(list) do
        local when = theRun and string.format("+%d:%02d", math.floor((r.runT0 or 0) / 60), (r.runT0 or 0) % 60)
            or When(r.id)
        Say("%-5s %-17s %-22s %6.1fs %5d %6d %7d %5d  %s%s", Label(i), when, r.zone or "?", r.dur or 0,
            r.ownCasts or 0, r.spent or 0, #(r.tracked or {}), r.auraN or 0,
            r.short and "short - under the recording gate" or Verdict(r),
            r.pinned and "  [pinned]" or "")
    end

elseif cmd == "runs" then
    if #runs == 0 then
        Say("no runs stored. In game: /md run start at the instance door, /md run stop when you leave.")
        os.exit(0)
    end
    Say("%-3s %-24s %-20s %6s %6s %6s %6s %6s  %s", "#", "name", "zone", "pulls", "wall", "combat",
        "drinks", "deaths", "spent")
    for i, run in ipairs(runs) do
        local st = run.stats or {}
        Say("%-3d %-24s %-20s %6d %6s %5.0f%% %6d %6d %6d%s", i, run.name or "?", run.zone or "?",
            st.pulls or 0, RR:Clock(st.wall or 0), (st.combatPct or 0) * 100, st.drinks or 0,
            st.deaths or 0, st.spent or 0, run.pinned and "  [pinned]" or "")
    end
    Say("")
    for i, run in ipairs(runs) do
        Say("%d. %s", i, Strip(RR:Line(run)))
        local short = 0
        for _, p in ipairs(run.pulls or {}) do if p.short then short = short + 1 end end
        Say("   %d pull(s) with a stream, %d of them under the recording gate%s. " ..
            "Address them as %d:1 .. %d:%d, or: list --run %d",
            #(run.pulls or {}), short, (run.stats and (run.stats.summarised or 0) > 0)
                and string.format(", %d summarised only", run.stats.summarised) or "",
            i, i, #(run.pulls or {}), i)
    end

elseif cmd == "spells" then
    -- what a recording spent its mana on, by kind (v0.10.1)
    local rec = list[n]; if not rec then Say("no %s %s", what, Label(n)); os.exit(1) end
    local sum = MD.DruidSpells.Summarise(rec)
    Say("%s %s: %s, %.0fs, %d mana", what, Label(n), rec.zone or "?", rec.dur or 0, rec.spent or 0)
    local order = { "heal", "damage", "cc", "utility", "shift", "unknown" }
    local total = 0
    for _, k in ipairs(order) do total = total + (sum[k] and sum[k].mana or 0) end
    for _, k in ipairs(order) do
        local b = sum[k]
        if b and b.casts > 0 then
            Say("  %-9s %2d cast(s) %6d mana  %3.0f%%", k, b.casts, b.mana,
                total > 0 and b.mana / total * 100 or 0)
        end
    end
    Say("")
    local rows = {}
    for label, v in pairs(sum.byName) do rows[#rows + 1] = { label, v } end
    table.sort(rows, function(a, b) return a[2].mana > b[2].mana end)
    for _, r in ipairs(rows) do
        Say("    %-24s %-8s id %-6d x%-3d %6d mana", r[1], r[2].kind, r[2].id, r[2].casts, r[2].mana)
    end

elseif cmd == "validate" then
    local rec = list[n]; if not rec then Say("no %s %s", what, Label(n)); os.exit(1) end
    for _, line in ipairs(MD:ValidationReport(rec, Label(n))) do Say("%s", Strip(line)) end

elseif cmd == "replay" then
    local rec = list[n]; if not rec then Say("no %s %s", what, Label(n)); os.exit(1) end
    -- The reasons (v0.12.3) need a plan to reason WITH: without one there is no
    -- suggested column and no classifier labels. Offline, fall back to the
    -- default plan on the ranks this fight actually cast, and say so.
    local kitR = MD.RankMath:SpellKit()
    local planR = SP.plans[rec.id]
    if not planR then
        planR = SP.NewPlan(SP.BindsFromRecording(rec, kitR),
            { swiftmendBelow = 0.30, directBelow = 0.45, rollStacks = 0, hotBelow = 1.00,
              filler = false }, kitR)
    end
    local rp = SP.Replay(rec, { force = true, plan = planR })
    local L, TK = rp.left.trace, SM.TK
    Say("%s %s: %s, %.1fs, %d own casts, %d trace events, grid %d x %.2fs%s", what, Label(n), rec.zone or "?",
        rec.dur or 0, rec.ownCasts or 0, L.nEv, L.n, L.dt,
        rp.right and "  (+ the coached plan on the right)" or "")
    for _, line in ipairs(MD:ValidationReport(rec, Label(n))) do Say("  %s", Strip(line)) end
    Say("")
    Say("%s", SP.plans[rec.id] and "labels against the coached plan"
        or "labels against the default plan on this fight's own ranks (coach it for a better one)")
    Say("%7s  %-22s %-14s %5s  %s", "t", "cast", "target", "cost", "label")
    local ci = 0
    for i = 1, L.nEv do
        if L.ev.kind[i] == TK.CAST then
            ci = ci + 1
            local sd = MD.SpellData.spells[L.ev.a[i]]
            local name = sd and (sd.family .. " R" .. sd.rank) or ("spell " .. L.ev.a[i])
            local tgt = rec.roster[L.ev.tgt[i]] and rec.roster[L.ev.tgt[i]].name or "-"
            local rec2 = rp.casts and rp.casts[ci]
            local label = rec2 and rec2.label or ""
            Say("%7.2f  %-22s %-14s %5d  %s", L.ev.t[i], name, tgt, L.ev.b[i], label)
            -- v0.12.3: why that one was inefficient, in the recording's numbers
            local why = rec2 and SP.CastWhy(rec2, rec.names)
            if why then Say("%7s  %s", "", Strip(why)) end
        end
    end
    Say("")
    for _, ti in ipairs(rec.tracked or {}) do
        local col = L.hp[ti]
        if col then
            local lo, loK = 1, 1
            for k = 1, L.n do if col[k] < lo then lo, loK = col[k], k end end
            Say("  %-14s lowest %3d%% at %.1fs", rec.roster[ti] and rec.roster[ti].name or ("#" .. ti), lo * 100 + 0.5, (loK - 1) * L.dt)
        end
    end
    if rp.right then
        -- what the plan did, and why it did it there (v0.12.3)
        local R2 = rp.right.trace
        Say("")
        Say("%7s  %-22s %s", "t", "the plan", "why")
        for i = 1, R2.nEv do
            local kind = R2.ev.kind[i]
            local reason = R2.reasons and R2.reasons[i]
            local why = reason and SP.ReasonText(reason, rec.names)
            if kind == TK.CAST and why then
                local sd = MD.SpellData.spells[R2.ev.a[i]]
                Say("%7.2f  %-22s %s", R2.ev.t[i],
                    sd and (sd.family .. " R" .. sd.rank) or ("spell " .. R2.ev.a[i]), Strip(why))
            elseif kind == TK.WAIT and why and (R2.ev.a[i] or 0) >= 2 then
                Say("%7.2f  %-22s %s", R2.ev.t[i], string.format("wait %.0fs", R2.ev.a[i]), Strip(why))
            end
        end
        Say("")
    end

    if rp.right then
        local R = rp.right.trace
        local casts, waits = 0, 0
        for i = 1, R.nEv do
            if R.ev.kind[i] == TK.CAST then casts = casts + 1 elseif R.ev.kind[i] == TK.WAIT then waits = waits + 1 end
        end
        Say("  plan: %d casts, %d waits, spent %d vs your %d", casts, waits, rp.right.snapshot.manaSpent, rp.left.snapshot.manaSpent)
    end

elseif cmd == "coach" and theRun and not opts.gotN then
    -- the WHOLE run: one plan and one drink policy for the dungeon, the pulls
    -- chained with mana carried over and the gaps simulated (v0.9.3)
    if not MD.player.isDruid then MD.player.isDruid = true end
    local done, out = false, nil
    SP.CoachRun(theRun, {}, function(lines) out = lines; done = true end)
    local frames = 0
    while not done and frames < 200000 do S.Tick(0.016); frames = frames + 1 end
    if not done then Say("coach: the run search did not finish in %d frames", frames); os.exit(1) end
    for _, line in ipairs(out) do Say("%s", Strip(line)) end
    Say("(the search ran across %d stub frames)", frames)

elseif cmd == "coach" then
    local rec = list[n]; if not rec then Say("no %s %s", what, Label(n)); os.exit(1) end
    if not MD.player.isDruid then MD.player.isDruid = true end
    local done, out = false, nil
    local h = SP.CoachAsync(rec, { n = Label(n), force = opts.force }, function(lines) out = lines; done = true end)
    local frames = 0
    while not done and frames < 20000 do S.Tick(0.016); frames = frames + 1 end
    if not done then Say("coach: the search did not finish in %d frames", frames); os.exit(1) end
    for _, line in ipairs(out) do Say("%s", Strip(line)) end
    if h then Say("(search ran across %d stub frames)", frames) end

elseif cmd == "gates" then
    if not opts.run then
        Say("gates: needs --run K (it validates a whole run at once).")
        os.exit(2)
    end
    local run = MD.RunRecorder:Get(opts.run)
    if not run then Say("gates: no run %d.", opts.run); os.exit(2) end
    local g = SP.RunGates(run, kit)
    Say("")
    Say("%s: %d pull(s) validated, %d failed", run.name or "run", g.of or 0, g.failed or 0)
    if (g.of or 0) > 0 then
        Say("  %d%% of the run's pulls are safe to coach from",
            math.floor(100 * ((g.of - g.failed) / g.of) + 0.5))
    end
    for _, name in ipairs(g.order or {}) do
        Say("  %-20s failed on %d pull(s)", name, g.byGate[name] or 0)
    end
    if (g.failed or 0) == 0 then Say("  every gate passed on every pull") end

elseif cmd == "export" then
    -- MD:Export renders everything; this keeps the head sections (fights,
    -- overheal, roster) plus exactly one section: the whole run when a run was
    -- named without a pull, else the one recording.
    local lines = MD:Export()
    local path, want
    if theRun and not opts.gotN then
        os.execute("mkdir -p .logs/runs")
        path = string.format(".logs/runs/%s.txt", tostring(theRun.id))
        want = "run"
    else
        local rec = list[n]
        if not rec then Say("no %s %s", what, Label(n)); os.exit(1) end
        os.execute("mkdir -p .logs/recordings")
        path = string.format(".logs/recordings/%s%s.txt", tostring(rec.id),
            theRun and ("-run" .. tostring(theRun.id) .. "-pull" .. n) or "")
        want = theRun and string.format("run %s pull %d", tostring(theRun.id), n) or nil
    end

    local f = assert(io.open(path, "w"))
    local phase, kept = "head", 0
    for _, line in ipairs(lines) do
        local isRunHead = line:match("^# run %d")
        local isRecHead = line:match("^# recording %d")
        if isRunHead or isRecHead or line:match("^# calibration") then
            if want == "run" then
                -- everything from this run's header until the next run's
                if isRunHead then
                    phase = line:find(tostring(theRun.id), 1, true) and "mine" or "other"
                elseif phase ~= "mine" or line:match("^# calibration") then
                    phase = "other"
                end
            elseif want then
                phase = (isRecHead and line:find(want, 1, true)) and "mine" or "other"
            else
                -- a single fight: its own section, never a run's pull
                phase = (isRecHead == tostring(n) and not line:find(" pull ", 1, true)) and "mine" or "other"
            end
        end
        if phase ~= "other" then f:write(line, "\n"); kept = kept + 1 end
    end
    f:close()
    Say("wrote %s (%d of %d lines: the header plus %s)", path, kept, #lines,
        want == "run" and ("run " .. (theRun.name or "?")) or (what .. " " .. Label(n)))

else
    Say("unknown command %q", cmd)
    os.exit(1)
end
