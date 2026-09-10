local here = arg[0]:match("^(.*)/[^/]+$")
local a0=arg[0]; arg[0]=here.."/harness.lua"
local MD=dofile(here.."/harness.lua"); arg[0]=a0
local S=_G.STUB
dofile(here.."/fakepull.lua")(MD, S)
local SM,SP=MD.SimModel,MD.SimPlanner
local K=SM.K
local kit=MD.RankMath:SpellKit({live=true})
local binds=SP.MaxRankBinds()
local base=MD.FightRecorder:Get(1)

local function micro(name, id, casts, dur)
    local rec={}
    for k,v in pairs(base) do rec[k]=v end
    rec.id=90000+math.random(1,99999)
    rec.dur=dur
    rec.ev={t={},kind={},tgt={},amt={},x={}}
    rec.n=0
    -- keep the target at 1 hp so nothing overheals: every point lands
    rec.hp={t={0},hp={},max={}}
    for _,ti in ipairs(base.tracked or {}) do
        rec.hp.hp[ti]={1}; rec.hp.max[ti]={999999}
    end
    rec.mana={t={0},v={99999},base={0},cast={0}}
    rec.initial={mana=99999, apiBase=0, apiCasting=0, form="caster",
                 known=base.initial and base.initial.known}
    rec.pool=99999
    rec.precasts={}
    for _,at in ipairs(casts) do
        rec.n=rec.n+1
        rec.ev.t[rec.n],rec.ev.kind[rec.n]=at,K.OWNCAST
        rec.ev.tgt[rec.n],rec.ev.amt[rec.n],rec.ev.x[rec.n]=1,(kit.caster[id].cost or 0),id
    end
    local sc=SM.ScenarioFromRecording(rec,kit)
    -- the target must be able to soak everything
    sc.targets[1].maxHP=999999; sc.targets[1].hp0=1
    local r=SM:Run(sc,nil,{critMode="ev"})
    local got=(r.healed or 0)+(r.overhealed or 0)
    local e=kit.caster[id]
    local one=(e.direct or 0)+(e.tick or 0)*(e.ticks or 0)+(e.bloom or 0)
    print(string.format("%-18s %d cast(s)  engine %8.0f   one cast %7.0f   ratio %.2f",
        name, #casts, got, one, one>0 and got/(one*#casts) or 0))
end
micro("Lifebloom x1", binds.Lifebloom, {1}, 25)
micro("Lifebloom x2 (5s)", binds.Lifebloom, {1,6}, 30)
micro("Lifebloom x4 rolling", binds.Lifebloom, {1,2.5,4,5.5}, 30)
micro("Rejuvenation x1", binds.Rejuvenation, {1}, 25)
micro("Regrowth x1", binds.Regrowth, {1}, 35)
