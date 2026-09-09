-- tools/run.sh tools/timeline.lua
--
-- The run's own clock (docs/SPEC-v0.14.md): a run is one continuous timeline,
-- not 36 separate fights. These assertions are about the MODEL -- no frames --
-- because what is true at time t has to be a pure function of the run before a
-- window can be trusted to draw it.
local here = arg[0]:match("^(.*)/[^/]+$")
local a0 = arg[0]; arg[0] = here .. "/harness.lua"
local MD = dofile(here .. "/harness.lua"); arg[0] = a0
local RT, RR = MD.RunTimeline, MD.RunRecorder

local ok, fails = 0, {}
local function check(name, cond, detail)
    if cond then ok = ok + 1 else fails[#fails + 1] = name .. (detail and (" - " .. detail) or "") end
    print(string.format("%-52s %s%s", name, cond and "ok" or "FAIL", detail and (" - " .. detail) or ""))
end

-- a hand-built run: three pulls with real gaps between them, health sampled
-- across the whole thing, a drink in the second gap
local run = {
    id = 1, name = "Test Run", zone = "Somewhere", dur = 100,
    pulls = {
        { id = 11, dur = 10, runT0 = 5,  roster = { { name = "T", class = "WARRIOR", role = "TANK" },
                                                    { name = "H", class = "DRUID", role = "HEALER" } } },
        { id = 12, dur = 12, runT0 = 30, roster = { { name = "T", class = "WARRIOR", role = "TANK" },
                                                    { name = "M", class = "MAGE", role = "DAMAGER" } } },
        { id = 13, dur = 8,  runT0 = 70, roster = { { name = "T", class = "WARRIOR", role = "TANK" } } },
    },
    mana = { t = {}, v = {} },
    hp = { t = {}, who = {}, frac = {} },
    ev = { t = { 45 }, kind = { RR.K.DRINK }, a = { 3000 }, b = { 0.4 } },
}
for i = 0, 50 do
    local t = i * 2
    run.mana.t[#run.mana.t + 1] = t
    run.mana.v[#run.mana.v + 1] = 3000 + i * 100
    run.hp.t[#run.hp.t + 1] = t
    -- the tank climbs back up through the gaps, which is the thing to watch
    run.hp.who[#run.hp.who + 1] = { "T", "H", "M" }
    run.hp.frac[#run.hp.frac + 1] = { math.min(1, 0.4 + i * 0.02), 1.0, 0.9 }
end

local tl = RT.Build(run)
check("the timeline builds", tl ~= nil)
check("it spans the whole run", math.abs(tl.dur - 100) < 0.01, tostring(tl.dur))

-- segments: gap, pull, gap, pull, gap, pull, gap
local kinds = {}
for _, s in ipairs(tl.segs) do kinds[#kinds + 1] = s.kind end
check("pulls and gaps alternate across the whole run",
    table.concat(kinds, ",") == "gap,pull,gap,pull,gap,pull,gap",
    table.concat(kinds, ","))
check("no segment overlaps the next", (function()
    for i = 2, #tl.segs do
        if tl.segs[i].from < tl.segs[i - 1].to - 0.01 then return false end
    end
    return true
end)())
check("the segments cover the run with no holes", (function()
    local at = 0
    for _, s in ipairs(tl.segs) do
        if s.from > at + 0.01 then return false end
        at = math.max(at, s.to)
    end
    return math.abs(at - tl.dur) < 0.01
end)())

-- seeking
local s, into = RT.At(tl, 8)
check("mid-pull seeks into that pull", s.kind == "pull" and s.k == 1 and math.abs(into - 3) < 0.01,
    string.format("%s %s +%.1f", s.kind, tostring(s.k), into))
s = RT.At(tl, 20)
check("between pulls is a gap", s.kind == "gap", s.kind)
s, into = RT.At(tl, 0)
check("the run can start in a gap", s.kind == "gap" and into == 0, s.kind)
s = RT.At(tl, 99)
check("the tail after the last pull is a gap", s.kind == "gap", s.kind)

-- skipping, which is what the timeline bar is for
check("skip forward lands on the next pull",
    RT.NextPull(tl, 8) and RT.NextPull(tl, 8).k == 2, tostring((RT.NextPull(tl, 8) or {}).k))
-- standing in the gap after pull 2, the previous fight IS pull 2
check("skip back from a gap lands on the fight just finished",
    RT.PrevPull(tl, 45) and RT.PrevPull(tl, 45).k == 2, tostring((RT.PrevPull(tl, 45) or {}).k))
-- and from inside pull 2 it lands on pull 1
check("skip back from inside a pull lands on the one before it",
    RT.PrevPull(tl, 35) and RT.PrevPull(tl, 35).k == 1, tostring((RT.PrevPull(tl, 35) or {}).k))
check("there is nothing before the first pull", RT.PrevPull(tl, 6) == nil)
check("there is nothing after the last pull", RT.NextPull(tl, 90) == nil)
check("a pull can be addressed by its number",
    RT.PullSeg(tl, 2) and math.abs(RT.PullSeg(tl, 2).from - 30) < 0.01)

-- THE POINT: health moves in the gaps
local hpA = RT.HpAt(tl, 16)
local hpB = RT.HpAt(tl, 28)
check("the gaps have health at all", hpA ~= nil and hpA.T ~= nil,
    hpA and tostring(hpA.T) or "none")
check("health CHANGES across a gap -- the whole reason for this version",
    hpB.T > hpA.T, string.format("%.2f at 16s -> %.2f at 28s", hpA.T, hpB.T))
check("somebody who was in no pull at all still has bars", hpA.M ~= nil, tostring(hpA and hpA.M))
check("health is a step function, not interpolated", (function()
    local a = RT.HpAt(tl, 16.0)
    local b = RT.HpAt(tl, 17.9)     -- same sample
    return a.T == b.T
end)())

local mana = RT.ManaAt(tl, 21)
check("the healer's mana is known in the gaps", mana ~= nil and mana > 3000, tostring(mana))
check("mana rises while drinking", RT.ManaAt(tl, 60) > RT.ManaAt(tl, 20),
    string.format("%s -> %s", tostring(RT.ManaAt(tl, 20)), tostring(RT.ManaAt(tl, 60))))

-- one row per person for the WHOLE run, not per pull
local roster = RT.Roster(tl)
local names = {}
for _, r in ipairs(roster) do names[#names + 1] = r.name end
table.sort(names)
check("the roster is the union of every pull's", table.concat(names, ",") == "H,M,T",
    table.concat(names, ","))
check("and it carries what it knows about them", (function()
    for _, r in ipairs(roster) do if r.name == "T" then return r.class == "WARRIOR" end end
end)())

-- the run's own events, which is all there is to show in a gap
local e = RT.EventAt(tl, 46)
check("a drink in a gap is visible", e ~= nil and e.kind == RR.K.DRINK,
    e and tostring(e.kind) or "none")
check("and it is gone once it is old", RT.EventAt(tl, 80) == nil)

-- a run from before v0.13.7 has no gap health, and must say so rather than lie
local old = { id = 2, dur = 50, pulls = { { id = 21, dur = 10, runT0 = 5, roster = {} } },
              mana = { t = { 0 }, v = { 100 } }, ev = { t = {}, kind = {}, a = {}, b = {} } }
local tlOld = RT.Build(old)
check("a run recorded before gap health says so", tlOld.hasGapHealth == false)
check("...and returns no health rather than inventing it", RT.HpAt(tlOld, 20) == nil)

print(string.format("\n%d ok, %d failed", ok, #fails))
if #fails > 0 then for _, m in ipairs(fails) do print("  FAIL " .. m) end; os.exit(1) end
