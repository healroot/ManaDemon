-- tools/run.sh tools/reccheck.lua
--
-- Drives a whole fake pull through the real UI/Summary.lua handler and
-- Engine/FightRecorder.lua: a party of five, damage on the tank, the player's
-- own casts and heals, a foreign heal, a death, form changes. Then checks the
-- recorded stream and the plan-free labels against what was scripted.
--
-- This is the only way to exercise the recorder without a dungeon.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local S = _G.STUB
local SD = MD.SpellData

local ids = dofile(here .. "/fakepull.lua")(MD, S)
local rejuv, regrowth, lifebloom = ids.rejuv, ids.regrowth, ids.lifebloom
local FR = MD.FightRecorder

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-34s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

local rec = FR:Get(1)
check("stream recorded", rec ~= nil)
if rec then
    local n = { }
    for i = 1, rec.n do n[rec.ev.kind[i]] = (n[rec.ev.kind[i]] or 0) + 1 end
    local K = MD.SimModel.K
    check("own casts recorded", (n[K.OWNCAST] or 0) == 6, tostring(n[K.OWNCAST]))
    -- two swings, plus the Shadow Bolt that v0.12.0's scripted hostile cast lands
    check("damage recorded", (n[K.DMG] or 0) == 3, tostring(n[K.DMG]))
    check("foreign heal recorded", (n[K.FHEAL] or 0) == 1, tostring(n[K.FHEAL]))
    check("own tick recorded", (n[K.OWNTICK] or 0) == 1, tostring(n[K.OWNTICK]))
    -- v0.14.7: and recorded GROSS, not gross + overheal again. The fixture's
    -- tick is 400 of which 150 was wasted, under the convention this client
    -- actually uses (db.healAmountGross), so 550 means the overheal was counted
    -- twice -- which is what every real recording on disk carries.
    local tickAmt
    for i = 1, rec.n do if rec.ev.kind[i] == K.OWNTICK then tickAmt = rec.ev.amt[i] end end
    check("own tick recorded gross, once", tickAmt == 400,
        string.format("%s, expected the log's 400 (550 = the overheal added back on)",
            tostring(tickAmt)))
    check("death recorded", #rec.deaths == 1, tostring(#rec.deaths))
    -- v0.8.3: Shield Wall apply + remove, the mage's debuff apply + dose; the
    -- Fortitude buff (not whitelisted) and the mob's debuff (untracked) dropped
    check("auras recorded", (n[K.AURA] or 0) == 4, tostring(n[K.AURA]))
    local FLAG = MD.SimModel.AURA_BUFF_FLAG
    local sw, curse, fort = 0, 0, 0
    for i = 1, rec.n do
        if rec.ev.kind[i] == K.AURA then
            if rec.ev.x[i] == 871 + FLAG then sw = sw + 1 end
            if rec.ev.x[i] == 55555 then curse = curse + 1 end
            if rec.ev.x[i] == 10938 + FLAG then fort = fort + 1 end
        end
    end
    check("defensive kept, plain buff dropped", sw == 2 and fort == 0, string.format("sw %d fort %d", sw, fort))
    check("debuff stacks recorded", curse == 2, tostring(curse))
    check("aura count exported", (rec.auraN or 0) == 1, tostring(rec.auraN))
    check("precasts carried", #rec.precasts == 1, tostring(#rec.precasts))
    check("mana samples", #rec.mana.t > 5, tostring(#rec.mana.t))
    check("hp snapshots", #rec.hp.t > 3, tostring(#rec.hp.t))
    check("roster indexed", #rec.roster == 5, tostring(#rec.roster))
    check("foreign share sane", rec.foreignShare > 0 and rec.foreignShare < 1,
        string.format("%.2f", rec.foreignShare))
    local L = rec.labels
    check("labels attached", L ~= nil)
    if L then
        -- costs come from the live/static maths, so the expectations do too
        local cRejuv, cLB = SD:GetCost(rejuv), SD:GetCost(lifebloom)
        check("utility labelled", (L.utility or 0) == 445, tostring(L.utility))
        check("early labelled", (L.early or 0) == cRejuv,
            string.format("%s, expected one Rejuvenation (%s)", tostring(L.early), tostring(cRejuv)))
        check("overheal labelled", (L.overheal or 0) == cLB,
            string.format("%s, expected one Lifebloom (%s)", tostring(L.overheal), tostring(cLB)))
        local sum = 0
        for _, k in ipairs({ "utility", "shift", "early", "overheal", "ok" }) do sum = sum + (L[k] or 0) end
        check("label identity holds", sum == (rec.spent or 0),
            string.format("%d labelled vs %d spent", sum, rec.spent or 0))
    end
end

local f = MD.fightHistory[#MD.fightHistory]
check("summary row written", f ~= nil and f.streamID == (rec and rec.id))
if f then
    check("row has hp buckets", f.hpBuckets ~= nil and (f.hpBuckets[3] or 0) >= 1,
        f.hpBuckets and table.concat(f.hpBuckets, "/") or "nil")
    check("row prehot > 0", (f.prehot or 0) > 0, tostring(f.prehot))
end

-- /md export must render the stream without blowing up on a nil array
local exported = MD:Export()
local sections = 0
for _, line in ipairs(exported) do if line:match("^# ") then sections = sections + 1 end end
check("export renders the stream", #exported > 60 and sections >= 8,
    string.format("%d lines, %d sections", #exported, sections))

-- Replay the recording we just made, through the real gates.
if rec then
    print("\n-- /md simreplay 1 --")
    local report = MD:ValidationReport(rec, 1)
    for _, line in ipairs(report) do print(line) end
    local v = MD.SimModel:Validate(rec)
    check("validate returns gates", v and #v.gates >= 6, v and tostring(#v.gates) or "nil")
    -- this scripted pull HAS a death and heavy foreign healing, so it must be
    -- rejected: a replay that passed here would mean the gates do nothing
    check("scripted pull is rejected", v and v.ok == false)
    local byName = {}
    for _, g in ipairs(v.gates) do byName[g.name] = g end
    check("death gate fired", byName["no tracked death"] and not byName["no tracked death"].ok)
    check("foreign gate fired", byName["foreign healing"] and not byName["foreign healing"].ok)
    check("coverage gate present", byName["spend coverage"] ~= nil,
        byName["spend coverage"] and byName["spend coverage"].text or "missing")
end

-- The coach must refuse a fight that does not replay, and produce a card when
-- forced. Both paths are exercised: silence is the more important one.
if rec then
    print("\n-- /md coach 1 --")
    local refused = MD.SimPlanner.Coach(rec, { n = 1 })
    for _, l in ipairs(refused) do print(l) end
    check("coach refuses a failed replay", refused[1]:find("does not replay") ~= nil)

    print("\n-- /md coach 1 force --")
    local card = MD.SimPlanner.Coach(rec, { n = 1, force = true })
    for _, l in ipairs(card) do print(l) end
    check("card produced", #card > 8, tostring(#card))
    check("card names the binds", table.concat(card, "\n"):find("Bind:") ~= nil)
    check("card carries caveats", table.concat(card, "\n"):find("caveat:") ~= nil)
    check("coach mark written", MD.cdb.coachMarks and MD.cdb.coachMarks["Blood Furnace"] ~= nil)
end

-- The search: drive it across frames the way the client would.
if rec then
    print("\n-- search --")
    local done, bestPlan, bestRes, evalCount = false, nil, nil, 0
    local sc = MD.SimModel.ScenarioFromRecording(rec, MD.RankMath:SpellKit())
    local t0 = os.clock()
    MD.SimPlanner.Search(sc, { rec = rec, maxEvals = 300 }, nil,
        function(b, r, evals) done, bestPlan, bestRes, evalCount = true, b, r, evals end)
    local frames = 0
    while not done and frames < 5000 do S.Tick(0.016); frames = frames + 1 end
    check("search finished", done, string.format("%d frames, %d evals, %.0f ms",
        frames, evalCount, (os.clock() - t0) * 1000))
    check("search stayed in budget", evalCount <= 300, tostring(evalCount))
    check("search found a plan", bestPlan ~= nil)
    if bestPlan then
        print(string.format("  best: swiftmend<%.0f%% direct<%.0f%% roll x%d hot<%.0f%% filler=%s -> %.0f mana, lowest %.0f%%",
            bestPlan.swiftmendBelow * 100, bestPlan.directBelow * 100, bestPlan.rollStacks,
            bestPlan.hotBelow * 100, tostring(bestPlan.filler), bestRes.manaSpent,
            (bestRes.lowest.hp or 0) * 100))
        -- the search must not lose to a baseline it was seeded with
        local base = MD.SimPlanner.RunPlan(sc, MD.SimPlanner.Baselines(rec, MD.RankMath:SpellKit())[1].plan,
            { critMode = "ev" })
        local baseSnap = { manaSpent = base.manaSpent, healed = base.healed, overhealed = base.overhealed,
                           floorSeconds = base.floorSeconds, deaths = { n = base.deaths.n },
                           lowest = { hp = base.lowest.hp } }
        local bs = MD.SimPlanner.Score(baseSnap, bestPlan, 0)
        local ws = MD.SimPlanner.Score(bestRes, bestPlan, 0)
        check("search beats or ties max rank", not MD.SimPlanner.Better(bs, ws),
            string.format("best %.0f vs max-rank %.0f mana", bestRes.manaSpent, base.manaSpent))
    end
end

-- v0.9.7: the stream says which healing spells the player had at the pull
do
    local k = rec.initial and rec.initial.known
    check("the recording carries the spells the healer had",
        k ~= nil and k.Rejuvenation == MD.SpellData.maxRank.Rejuvenation
        and k.Lifebloom == MD.SpellData.maxRank.Lifebloom,
        k and ("Rejuvenation " .. tostring(k.Rejuvenation)) or "no known table")
end

-- v0.10.1: the stream names every spell it recorded, and the classifier knows
-- what kind of cast each one was
do
    local names = rec.names or {}
    check("the recording names its casts", names[ids.rejuv] ~= nil and names[ids.MOTW] ~= nil,
        tostring(names[ids.rejuv]) .. " / " .. tostring(names[ids.MOTW]))
    local _, k1 = MD:ClassifyCast(ids.rejuv)
    check("a heal is classified as a heal", k1 == "heal", tostring(k1))
    local _, k2 = MD:ClassifyCast(9853)          -- Entangling Roots, from the seed table
    check("a root is crowd control", k2 == "cc", tostring(k2))
    local _, k3 = MD:ClassifyCast(26987)         -- Moonfire r11
    check("a Moonfire is damage", k3 == "damage", tostring(k3))
    check("what it learns is written down", MD.cdb.spellbook and MD.cdb.spellbook[26987]
        and MD.cdb.spellbook[26987].kind == "damage")

    local sum = MD.DruidSpells.Summarise(rec)
    check("the summary splits the fight's mana by kind",
        sum.heal.mana > 0 and sum.heal.casts >= 4, string.format("%d heal casts, %d mana",
            sum.heal.casts, sum.heal.mana))
    check("Mark of the Wild is utility, not a hole",
        (sum.utility.casts or 0) >= 1 and sum.unknown.casts == 0,
        string.format("utility %d, unknown %d", sum.utility.casts, sum.unknown.casts))
end

-- v0.12.0: the two things a healer can see coming
do
    local K2 = MD.SimModel.K
    local casts, threats = 0, 0
    for i = 1, (rec.n or 0) do
        if rec.ev.kind[i] == K2.ECAST then casts = casts + 1 end
        if rec.ev.kind[i] == K2.THREAT then threats = threats + 1 end
    end
    check("a hostile cast on a tracked target is recorded", casts == 2, tostring(casts))
    check("and its spell is named for the offline tools", rec.names[12471] ~= nil,
        tostring(rec.names[12471]))

    local sc = MD.SimModel.ScenarioFromRecording(rec, MD.RankMath:SpellKit())
    check("the scenario carries the incoming casts", #sc.incoming == 2, tostring(#sc.incoming))
    local landed, unlanded
    for _, c in ipairs(sc.incoming) do
        if c.at then landed = c else unlanded = c end
    end
    check("a cast that landed is paired with its damage",
        landed ~= nil and landed.at > landed.t and landed.amount == 900,
        landed and string.format("cast %.1fs, landed %.1fs for %d", landed.t, landed.at or -1,
            landed.amount or -1) or "none")
    check("and with the target it actually hit", landed and landed.target ~= nil)
    check("a cast that never landed has no landing time", unlanded ~= nil and unlanded.at == nil,
        unlanded and tostring(unlanded.at) or "every cast landed")

    -- the setting turns the pair off
    MD.db.recordThreat = false
    local before = rec.n
    MD.FightRecorder.active = rec
    MD.FightRecorder:EnemyCast("SPELL_CAST_START", "Mob-9", "Tank-1", "Destroyka", 999)
    MD.FightRecorder:SampleThreat(1)
    MD.FightRecorder.active = nil
    check("db.recordThreat off records neither", rec.n == before, tostring(rec.n - before))
    MD.db.recordThreat = true
end

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
