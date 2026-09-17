-- Rank math: per-rank effective heal / HPM / HPS with TBC downranking rules.
-- Formulas (per the design debate, confidence noted in docs/DECISIONS.md):
--   direct coefficient  = clamp(baseCast, 1.5, 3.5) / 3.5
--   HoT coefficient     = duration / 15
--   hybrid (Regrowth)   = portions weighted by c/(c+h), h/(c+h)
--   sub-level-20 malus  = 1 - (20 - spellLevel) * 0.0375
--   downrank penalty    = min(1, (spellLevel + 11) / casterLevel)
--   healing crits are 1.5x, HoTs never crit.
-- Penalties apply to the BONUS-healing contribution, not the base heal.
--
-- Structure (docs/DESIGN-v0.5.md §1.3): Context() resolves every input once
-- (simulation overrides are applied THERE and nowhere else), RowFor() turns one
-- spell into one row, Compute() runs every family plus the Pareto/suggestion
-- pass, and Explain() rebuilds a single row with its intermediate terms for the
-- dashboard tooltip. RowFor only allocates row.calc when asked, because the
-- dashboard re-renders every 2s and those tables would be pure garbage.
local _, MD = ...

local RankMath = {}
MD.RankMath = RankMath

local EMPTY = {}

local function BonusHealing()
    if GetSpellBonusHealing then
        local ok, v = pcall(GetSpellBonusHealing)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

local function NatureCrit()
    if GetSpellCritChance then
        local ok, v = pcall(GetSpellCritChance, 4) -- 4 = nature school
        if ok and type(v) == "number" then return v / 100 end
    end
    return 0
end

local function Penalty(spellLevel, playerLevel)
    local downrank = math.min(1, (spellLevel + 11) / math.max(playerLevel, 1))
    local sub20 = spellLevel < 20 and (1 - (20 - spellLevel) * 0.0375) or 1
    return downrank * sub20
end

-- Chain-casts until the next cast is unaffordable: each cast nets
-- (cost - regen * interval) mana, so floor((mana - cost) / net) + 1 casts.
-- math.huge when regen covers the cost, 0 when mana < cost.
function RankMath:CastsToOOM(cost, interval, mana, regen)
    if cost <= 0 then return math.huge end
    local net = cost - regen * interval
    if net <= 0 then return math.huge end
    if mana < cost then return 0 end
    return math.floor((mana - cost) / net) + 1
end

--------------------------------------------------------------------------------
-- Context: every input the rank math reads, resolved once.
--
-- Tree of Life aura: party members (the tree included) receive extra healing
-- equal to 25% of the druid's Spirit. It is a "healing received" aura on the
-- targets, so GetSpellBonusHealing() never shows it, but it goes through the
-- same coefficient/penalty path as +healing (MaNGOS-era SpellHealingBonus:
-- taken advertised benefit * coeff). Counted while in form unless the setting
-- is off; only true for targets in your party.
--
-- Simulation overrides (MD.sim, session-only, set from the dashboard's
-- "Simulate" strip): nil = live value. Only the rank math reads them; the
-- clock, widget and advisor always use real inputs.
--------------------------------------------------------------------------------
-- opts.live: ignore the Simulate strip. Calibration compares REAL heals with
-- the model and must never see a what-if input (the first regression log had
-- it predicting Regrowth at 1488 against a real 1282 -- a simulated +healing
-- was still in the strip).
function RankMath:Context(opts)
    local SD = MD.SpellData
    -- opts.healer (v0.7.1): the simulator's own stat overrides, applied exactly
    -- where the Simulate strip's are and nowhere else, so a simulated healer
    -- and a simulated dashboard row go down one code path. `inTree` is the
    -- strip's `tree` under the name the scenario uses.
    local sim
    if opts and opts.healer then
        local h = opts.healer
        sim = { heal = h.heal, crit = h.crit, casting = h.casting, base = h.base,
                mana = h.mana, tree = h.inTree, moonglow = h.moonglow }
        if next(sim) == nil then sim = EMPTY end
    elseif opts and opts.live then
        sim = EMPTY
    else
        sim = MD.sim or EMPTY
    end

    local liveBonus = BonusHealing()
    local statBonus = sim.heal or liveBonus
    local relic = SD:Relic()

    -- A simulated form changes the aura AND the costs; keep the two in step.
    local inTree
    if sim.tree ~= nil then inTree = sim.tree else inTree = MD:InTreeForm() end

    local treeAura = 0
    if inTree and not (MD.db and MD.db.treeAura == false) then
        treeAura = 0.25 * (UnitStat("player", 5) or 0) + (relic and relic.aura or 0)
    end

    local liveCrit = NatureCrit()
    local crit = sim.crit and (sim.crit / 100) or liveCrit

    -- Chain-cast budget: every cast nets (cost - castingRegen * interval);
    -- from the current mana that allows floor((mana - cost) / net) + 1 casts
    -- (interval = cast time, or the 1.5s GCD for instants). Casting regen is
    -- the in-5SR rate (Intensity, gear mp5, Dreamstate) since spamming keeps
    -- you inside the five-second rule the whole time.
    local liveMana = UnitPower("player", 0) or 0
    local liveCasting = MD.Regen and MD.Regen.casting or 0
    local liveBase = MD.Regen and MD.Regen.base or 0

    local ctx = {
        bonus = statBonus + treeAura,
        statBonus = statBonus,
        treeAura = treeAura,
        inTree = inTree,
        relic = relic,
        crit = crit,
        playerLevel = MD.player.level,
        mana = sim.mana or liveMana,
        castingRegen = sim.casting and (sim.casting / 5) or liveCasting,
        baseRegen = sim.base and (sim.base / 5) or liveBase,

        goN = 1 + 0.02 * MD:TalentRank("Gift of Nature"),
        empTouch = 1 + 0.10 * MD:TalentRank("Empowered Touch"),
        empRejuv = 1 + 0.04 * MD:TalentRank("Empowered Rejuvenation"),
        impRejuv = 1 + 0.05 * MD:TalentRank("Improved Rejuvenation"),
        naturalist = 0.1 * MD:TalentRank("Naturalist"), -- -0.1s HT cast per rank

        simulated = next(sim) ~= nil,
        live = { heal = liveBonus, crit = liveCrit * 100, casting = liveCasting * 5,
                 base = liveBase * 5, mana = liveMana },
    }
    ctx.regrowthCrit = math.min(1, crit + 0.10 * MD:TalentRank("Improved Regrowth"))

    -- Nature's Grace: a spell critical takes 0.5s off the NEXT cast, never
    -- below the 1.5s GCD. Chain-casting one spell, the fraction of casts that
    -- follow a crit is the crit chance, so the throughput-correct cast time is
    -- the MIXTURE -- not (cast - 0.5 * crit) floored, which clips the wrong
    -- branch when cast - 0.5 lands on the GCD. Throughput over a chain is
    -- heal / E[T] exactly, so averaging the cast time is right for a sustained
    -- column. HoTs never crit and sit at the GCD anyway, so it is a no-op for
    -- them twice over. Assumed 0.5s until the "cast" debug category confirms
    -- it on this client (docs/DESIGN-v0.5.md F1).
    ctx.naturesGrace = (MD:TalentRank("Nature's Grace") > 0
        and not (MD.db and MD.db.naturesGrace == false)) and 0.5 or 0
    ctx.ExpectedCast = function(T0, p)
        if ctx.naturesGrace <= 0 or p <= 0 then return T0 end
        return (1 - p) * T0 + p * math.max(T0 - ctx.naturesGrace, 1.5)
    end

    -- Cost source. The live client value is exact (it applies talents and form
    -- itself), so it stays the default. It is wrong the moment the dashboard
    -- simulates a form or a talent rank the player does not actually have, and
    -- only then does the static table (with those overrides) take over.
    local costOverride = (sim.tree ~= nil) or (sim.moonglow ~= nil)
    ctx.costCtx = costOverride and { inTree = inTree, moonglow = sim.moonglow } or nil
    ctx.CostFor = function(id)
        if ctx.costCtx then
            return SD:StaticCost(id, ctx.costCtx), "table (simulated)"
        end
        return SD:GetCost(id)
    end

    ctx.CastsToOOM = function(cost, interval)
        return RankMath:CastsToOOM(cost, interval, ctx.mana, ctx.castingRegen)
    end

    return ctx
end

--------------------------------------------------------------------------------
-- One row from one spell.
--   variant  nil for the real rank; 2 or 3 for the rolling Lifebloom stacks
--   explain  fills row.calc with every intermediate term (tooltip only)
-- Row: { id, rank, level, cost, cast, heal, hpm, hps, casts (chain-casts to
-- OOM from current mana, math.huge when regen covers the cost), known, isMax;
-- overheal + effHeal/effHpm/effHps when the combat log has enough samples;
-- dominated/suggested are set by Compute() }
-- HP5 ("sustained healing per 5s") was removed in v0.6.0: chain-casting inside
-- the 5SR it reduces to 5 x castingRegen x HPM, so it ordered every rank
-- exactly like HPM and carried no information of its own.
--------------------------------------------------------------------------------
function RankMath:RowFor(spellID, ctx, variant, explain)
    local SD = MD.SpellData
    local s = SD.spells[spellID]
    if not s then return nil end
    local info = SD.families[s.family]
    if not info then return nil end

    local pen = Penalty(s.level, ctx.playerLevel)
    local relic = ctx.relic
    -- relic bonus for this family: flat goes on the BASE heal, perTick on
    -- each Lifebloom tick
    local relicFlat = (relic and relic.family == s.family and relic.flat) or 0
    local relicTick = (relic and relic.family == s.family and relic.perTick) or 0
    local relicCast = (relic and relic.family == s.family and relic.castReduce) or 0
    local bonus = ctx.bonus

    local heal, castTime, calc

    local castBase, ngCrit
    -- Lifebloom's two halves, kept for the overheal weighting below. These
    -- were GLOBALS until v0.7.1 -- harmless by luck (only the lifebloom branch
    -- reads them, and it always writes them first) but a _G write on a path
    -- the dashboard runs every 2s.
    local lbHot, lbBloom

    if info.type == "direct" then
        castBase = math.max(s.cast - ctx.naturalist - relicCast, 1.5)
        ngCrit = ctx.crit
        castTime = ctx.ExpectedCast(castBase, ngCrit)
        -- the coefficient uses the spell's BASE cast time, not the modified one
        local coef = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
        local base = (s.healMin + s.healMax) / 2 + relicFlat
        local bonusOut = bonus * coef * pen * ctx.empTouch
        local critMult = 1 + 0.5 * ctx.crit
        heal = (base + bonusOut) * ctx.goN * critMult
        if explain then
            calc = { kind = "direct", base = (s.healMin + s.healMax) / 2, relicFlat = relicFlat,
                     bonus = bonus, coef = coef, penalty = pen, bonusMult = ctx.empTouch,
                     bonusMultName = "Empowered Touch", bonusOut = bonusOut,
                     talentMult = ctx.goN, critMult = critMult, crit = ctx.crit,
                     -- v0.14.9: the non-crit roll range, for the spell tooltip
                     min = (s.healMin + relicFlat + bonusOut) * ctx.goN,
                     max = (s.healMax + relicFlat + bonusOut) * ctx.goN }
        end

    elseif info.type == "hot" then
        castTime = 1.5 -- GCD
        local coef = s.hotDuration / 15
        local bonusOut = bonus * coef * pen * ctx.empRejuv
        heal = (s.hotTotal + relicFlat + bonusOut) * ctx.goN * ctx.impRejuv
        if explain then
            calc = { kind = "hot", base = s.hotTotal, relicFlat = relicFlat,
                     bonus = bonus, coef = coef, penalty = pen, bonusMult = ctx.empRejuv,
                     bonusMultName = "Empowered Rejuvenation", bonusOut = bonusOut,
                     talentMult = ctx.goN * ctx.impRejuv,
                     duration = s.hotDuration, ticks = s.hotDuration / 3 }
        end

    elseif info.type == "hybrid" then
        castBase = math.max(s.cast, 1.5)
        ngCrit = ctx.regrowthCrit
        castTime = ctx.ExpectedCast(castBase, ngCrit)
        local c = math.min(math.max(s.cast, 1.5), 3.5) / 3.5
        local h = s.hotDuration / 15
        -- The hybrid's +healing is split between the direct hit and the HoT in
        -- proportion to their BASE AMOUNTS, each portion then taking its own
        -- coefficient: direct gets c x avg/(avg+hot), the HoT h x hot/(avg+hot).
        -- For Regrowth that is 0.286 / 0.70 -- the widely quoted numbers. The
        -- earlier coefficient-weighted split (c^2/(c+h), h^2/(c+h) = 0.166 /
        -- 0.994) predicted a 232 tick where the first regression log showed
        -- 209; the amount-weighted split predicts 209.3 (docs/DECISIONS.md
        -- v0.6 §15). Calibration confirms or refutes it with the next run.
        local avgBase = (s.healMin + s.healMax) / 2
        local share = avgBase / (avgBase + s.hotTotal)
        local dCoef = c * share
        local hCoef = h * (1 - share)
        local base = avgBase + relicFlat
        local dBonus = bonus * dCoef * pen
        local hBonus = bonus * hCoef * pen * ctx.empRejuv
        local critMult = 1 + 0.5 * ctx.regrowthCrit
        local direct = (base + dBonus) * ctx.goN * critMult
        local hot = (s.hotTotal + hBonus) * ctx.goN
        heal = direct + hot
        if explain then
            calc = { kind = "hybrid", base = (s.healMin + s.healMax) / 2, relicFlat = relicFlat,
                     bonus = bonus, penalty = pen, talentMult = ctx.goN,
                     directCoef = dCoef, directBonus = dBonus, direct = direct,
                     hotCoef = hCoef, hotBonus = hBonus, hot = hot, hotBase = s.hotTotal,
                     bonusMult = ctx.empRejuv, bonusMultName = "Empowered Rejuvenation",
                     critMult = critMult, crit = ctx.regrowthCrit,
                     duration = s.hotDuration,
                     -- v0.14.9: the direct hit's non-crit roll range
                     min = (s.healMin + relicFlat + dBonus) * ctx.goN,
                     max = (s.healMax + relicFlat + dBonus) * ctx.goN }
        end

    elseif info.type == "lifebloom" then
        castTime = 1.5 -- GCD
        -- One application ticking to completion plus its bloom.
        -- Verified 2026-09-03 (heal log): tick 87 = (273 + 450*0.5187*1.2)*1.1/7,
        -- bloom 864 = (600 + 450*0.3422*1.2)*1.1 -> Empowered Rejuvenation
        -- applies to the bloom too.
        local hotBonus = bonus * SD.lifebloomHotCoef * pen * ctx.empRejuv
        local bloomBonus = bonus * SD.lifebloomBloomCoef * pen * ctx.empRejuv
        -- Emerald Queen is "+88 to the periodic healing": on the HoT TOTAL,
        -- like any flat, not on the bloom
        local hot = (s.hotTotal + relicFlat + 7 * relicTick + hotBonus) * ctx.goN
        local bloom = (s.bloom + bloomBonus) * ctx.goN
        lbHot, lbBloom = hot, bloom
        if variant then
            -- Rolling stacks: each refresh cast is paid for with 6 ticks at the
            -- stack's multiplier (one tick is lost to the refresh) and never a
            -- bloom (the stack is renewed before it expires).
            heal = (hot / 7) * 6 * variant
        else
            heal = hot + bloom
        end
        if explain then
            calc = { kind = "lifebloom", base = s.hotTotal, relicTick = relicTick, relicFlat = relicFlat,
                     bonus = bonus, penalty = pen, bonusMult = ctx.empRejuv,
                     bonusMultName = "Empowered Rejuvenation", talentMult = ctx.goN,
                     hotCoef = SD.lifebloomHotCoef, hotBonus = hotBonus, hot = hot,
                     bloomCoef = SD.lifebloomBloomCoef, bloomBonus = bloomBonus,
                     bloomBase = s.bloom, bloom = bloom,
                     tick = hot / 7, stacks = variant, duration = s.hotDuration,
                     -- the bloom is a direct heal and can crit (a recorded bloom
                     -- crit is exactly 1.5x); the ticks cannot. Not `crit`:
                     -- Calibration reads that as the whole spell's chance.
                     bloomCrit = ctx.crit }
        end
    end

    if not heal then return nil end

    local cost, costSource = ctx.CostFor(spellID)
    cost = cost or 0

    local row = {
        id = spellID, rank = s.rank, level = s.level,
        cost = cost, cast = castTime, heal = heal,
        hpm = cost > 0 and heal / cost or 0,
        hps = heal / castTime,
        casts = ctx.CastsToOOM(cost, castTime),
        known = SD.knownSet[spellID] or false,
        isMax = (not variant) and SD.maxRank[s.family] == spellID or false,
        ng = castBase ~= nil and castTime < castBase - 0.001 or false,
    }
    if variant then
        row.variant = variant
        row.rankLabel = "x" .. variant
        row.virtual = true
    end

    -- Overheal calibration: what the spell is worth on the targets this player
    -- actually heals. Carried alongside the raw numbers, never instead of them
    -- -- the Pareto filter and the suggested rank stay on raw values so a noisy
    -- measurement can never fire a "rebind?" toast (docs/DESIGN-v0.5.md F3).
    if MD.Overheal then
        local done = false
        -- Lifebloom: ticks and the bloom overheal very differently (38% vs 50%
        -- in the first dungeon log), and a rolling stack has no bloom at all.
        -- So the single cast is weighted portion by portion and the rolling
        -- rows by the tick fraction only -- which is what finally makes the
        -- "roll it or let it bloom" question answerable for THIS player.
        if info.type == "lifebloom" and lbHot then
            local tf, tn, tscope = MD.Overheal:KindFraction(spellID, "tick")
            local bf, bn, bscope = MD.Overheal:KindFraction(spellID, "bloom")
            if tf and tscope == "kind" and (variant or (bf and bscope == "kind")) then
                local eff
                if variant then
                    eff = row.heal * (1 - tf)
                else
                    eff = lbHot * (1 - tf) + lbBloom * (1 - bf)
                end
                row.overheal = { frac = 1 - eff / row.heal, n = math.min(tn, bn or tn), scope = "kind",
                                 tick = tf, bloom = (not variant) and bf or nil }
                row.effHeal = eff
                row.effHpm = row.cost > 0 and eff / row.cost or 0
                row.effHps = eff / castTime
                done = true
            end
        end
        if not done then
            local frac, n, scope = MD.Overheal:Fraction(spellID)
            if frac then
                local k = 1 - frac
                row.overheal = { frac = frac, n = n, scope = scope }
                row.effHeal = row.heal * k
                row.effHpm = row.hpm * k
                row.effHps = row.hps * k
            end
        end
    end

    if calc then
        calc.family = s.family
        calc.label = info.label
        calc.type = info.type
        calc.cost = cost
        calc.costSource = costSource
        calc.castBase = castBase or castTime
        calc.castNG = castTime
        calc.ngCrit = ngCrit
        calc.naturesGrace = ctx.naturesGrace
        calc.mana = ctx.mana
        calc.castingRegen = ctx.castingRegen
        calc.baseRegen = ctx.baseRegen
        calc.netPerCast = cost - ctx.castingRegen * castTime
        calc.overheal = row.overheal
        row.calc = calc
    end
    return row
end

--------------------------------------------------------------------------------
-- SpellKit (v0.7.1): every known rank of every family, priced and valued once
-- per form, in the flat shape the simulator's inner loop reads. The engine must
-- never call RowFor -- it allocates, reads the live client and would be run
-- thousands of times inside a search -- so this is the single boundary between
-- the rank math and the simulation (docs/SPEC-v0.7.md 3.1).
--
--   kit.caster[spellID] / kit.tree[spellID] = {
--     family, rank, type, cost, cast, gcd,
--     direct, directCrit,                  -- direct / hybrid; NEVER crit-loaded
--     tick, ticks, tickPeriod, duration,   -- hot / hybrid / lifebloom
--     bloom,                               -- lifebloom
--     swiftmendRejuv, swiftmendRegrowth,   -- instant
--     channelTick, channelTicks, dataMissing }
--
-- Crit is stripped from `direct` on purpose: RowFor bakes E[crit] in for a
-- throughput column, but the engine decides per cast whether to use the
-- expectation or a seeded roll, and it cannot un-bake a multiplier it did not
-- apply.
--------------------------------------------------------------------------------
local KIT_FORMS = { "caster", "tree" }

-- TBC Swiftmend: consumes Regrowth for 18s of its ticks, else Rejuvenation for
-- 12s (Rejuvenation's whole duration). Valued off the highest known rank of
-- each, which is what a healer would actually have out.
local SWIFTMEND_REJUV_SECONDS, SWIFTMEND_REGROWTH_SECONDS = 12, 18

function RankMath:SpellKit(opts)
    local SD = MD.SpellData
    local kit = { caster = {}, tree = {} }

    for _, form in ipairs(KIT_FORMS) do
        local healer = { inTree = (form == "tree") }
        if opts and opts.healer then
            for k, v in pairs(opts.healer) do healer[k] = v end
            healer.inTree = (form == "tree")
        end
        local ctx = RankMath:Context({ live = true, healer = healer })
        local out = kit[form]

        for family, list in pairs(SD.known) do
            local info = SD.families[family]
            for _, id in ipairs(list) do
                local s = SD.spells[id]
                local e = { family = family, rank = s.rank, type = info and info.type or "direct",
                            gcd = 1.5 }
                local row = RankMath:RowFor(id, ctx, nil, true)
                local c = row and row.calc
                if c then
                    e.cost, e.cast = row.cost, row.cast
                    if c.kind == "direct" then
                        e.direct = row.heal / (c.critMult or 1)
                        e.directCrit = c.crit or 0
                    elseif c.kind == "hot" then
                        e.ticks = c.ticks
                        e.tickPeriod, e.duration = 3, c.duration
                        e.tick = row.heal / c.ticks
                    elseif c.kind == "hybrid" then
                        e.direct = c.direct / (c.critMult or 1)
                        e.directCrit = c.crit or 0
                        e.ticks = c.duration / 3
                        e.tickPeriod, e.duration = 3, c.duration
                        e.tick = c.hot / e.ticks
                    elseif c.kind == "lifebloom" then
                        e.tick = c.tick                 -- per stack, at x1
                        e.ticks, e.tickPeriod, e.duration = 7, 1, 7
                        e.bloom = c.bloom
                    end
                else
                    -- Swiftmend and Tranquility have no heal values in
                    -- Data/SpellData.lua, so RowFor returns nothing for them.
                    -- Swiftmend is derived below; Tranquility is carried with
                    -- dataMissing so a planner can see it exists and refuse to
                    -- use a number nobody has measured.
                    e.cost = ctx.CostFor(id) or s.cost or 0
                    e.cast = s.cast or 1.5
                    if family == "Tranquility" then
                        e.channelTicks, e.dataMissing = 4, true
                    end
                end
                out[id] = e
            end
        end

        -- Swiftmend's value is the HoT it eats, so it is priced after the rest.
        local rejuvID, regrowthID = SD.maxRank.Rejuvenation, SD.maxRank.Regrowth
        local rejuv, regrowth = rejuvID and out[rejuvID], regrowthID and out[regrowthID]
        local smID = SD.maxRank.Swiftmend
        local sm = smID and out[smID]
        if sm then
            if rejuv and rejuv.tick then
                sm.swiftmendRejuv = rejuv.tick * math.min(rejuv.ticks,
                    SWIFTMEND_REJUV_SECONDS / rejuv.tickPeriod)
            end
            if regrowth and regrowth.tick then
                sm.swiftmendRegrowth = regrowth.tick * math.min(regrowth.ticks,
                    SWIFTMEND_REGROWTH_SECONDS / regrowth.tickPeriod)
            end
            sm.cast = 1.5
        end
    end

    kit.crit = RankMath:Context({ live = true, healer = opts and opts.healer }).crit
    return kit
end

-- One row plus its full breakdown, for the dashboard tooltip. Rebuilt from a
-- fresh context so it always matches what the table is showing.
function RankMath:Explain(spellID, variant, opts)
    return RankMath:RowFor(spellID, RankMath:Context(opts), variant, true)
end

-- What ONE combat-log event should read, for Engine/Calibration.lua:
--   { direct = <non-crit direct heal>, tick = <per tick at x1>, bloom = <bloom>,
--     ticks = <n>, crit = <crit chance the row assumed>, stacked = <Lifebloom> }
-- Crit is stripped here because a single event either crit or did not; the
-- row's (1 + 0.5 x crit) is an expectation and cannot be compared to one hit.
function RankMath:EventPrediction(spellID)
    local row = RankMath:Explain(spellID, nil, { live = true })
    local c = row and row.calc
    if not c then return nil end
    local out = { crit = c.crit or 0, family = c.family, talentMult = c.talentMult }
    if c.kind == "direct" then
        out.direct = (c.base + (c.relicFlat or 0) + c.bonusOut) * c.talentMult
    elseif c.kind == "hot" then
        out.ticks = c.ticks
        out.tick = row.heal / c.ticks
    elseif c.kind == "hybrid" then
        out.direct = c.direct / c.critMult
        out.ticks = c.duration / 3
        out.tick = c.hot / out.ticks
    elseif c.kind == "lifebloom" then
        out.tick, out.bloom, out.ticks, out.stacked = c.tick, c.bloom, 7, true
    end
    return out
end

--------------------------------------------------------------------------------
-- Returns family -> { label, tol, rows = {...}, suggestedID, callout }; the
-- inputs used are left in RankMath.info (the context).
--------------------------------------------------------------------------------
function RankMath:Compute()
    local SD = MD.SpellData
    local results = {}
    if not MD.player.isDruid then return results end

    local ctx = RankMath:Context()
    RankMath.info = ctx

    for _, family in ipairs(SD.familyOrder) do
        local info = SD.families[family]
        local allIDs = SD.all[family]
        if info and not info.exclude and allIDs and #allIDs > 0 then
            local rows = {}
            for _, id in ipairs(allIDs) do
                local row = RankMath:RowFor(id, ctx)
                if row then
                    rows[#rows + 1] = row
                    -- Informational rolling-stack rows: excluded from Pareto /
                    -- suggestion because they are a different activity from a
                    -- single application.
                    if info.type == "lifebloom" then
                        for stacks = 2, 3 do
                            rows[#rows + 1] = RankMath:RowFor(id, ctx, stacks)
                        end
                    end
                end
            end

            -- Pareto dominance on (HPM, HPS) — among KNOWN, real ranks only.
            for i = 1, #rows do
                if rows[i].known and not rows[i].virtual then
                    for j = 1, #rows do
                        if i ~= j and rows[j].known and not rows[j].virtual
                            and rows[j].hpm >= rows[i].hpm and rows[j].hps >= rows[i].hps
                            and (rows[j].hpm > rows[i].hpm or rows[j].hps > rows[i].hps) then
                            rows[i].dominated = true
                            break
                        end
                    end
                end
            end

            -- Suggested rank: highest-HPM known non-dominated rank that still
            -- heals >= 40% of the max known rank (assumption: below that,
            -- cast-count pressure outweighs efficiency).
            local maxRow
            for i = 1, #rows do
                if rows[i].isMax then maxRow = rows[i] end
            end
            local suggested
            for i = 1, #rows do
                local r = rows[i]
                if r.known and not r.virtual and not r.dominated and maxRow and r.heal >= 0.4 * maxRow.heal then
                    if not suggested or r.hpm > suggested.hpm then
                        suggested = r
                    end
                end
            end
            suggested = suggested or maxRow
            if suggested then suggested.suggested = true end

            local callout
            -- Lifebloom: with tick and bloom overheal measured separately, say
            -- which way of using the max rank is worth more on THIS player's
            -- targets. Kept out of the Pareto filter (a different activity).
            local lbNote
            if info.type == "lifebloom" and maxRow and maxRow.overheal and maxRow.overheal.scope == "kind" then
                local roll
                for i = 1, #rows do
                    if rows[i].id == maxRow.id and rows[i].variant == 3 then roll = rows[i] end
                end
                if roll and roll.effHpm and maxRow.effHpm then
                    local better = roll.effHpm > maxRow.effHpm
                    lbNote = string.format(" Measured overheal (ticks %d%%, bloom %d%%): %s - rolling x3 %.2f vs single cast %.2f effective HPM.",
                        maxRow.overheal.tick * 100 + 0.5, (maxRow.overheal.bloom or 0) * 100 + 0.5,
                        better and "keep the stack rolling" or "let it bloom",
                        roll.effHpm, maxRow.effHpm)
                end
            end
            if suggested and maxRow and suggested ~= maxRow then
                callout = string.format(
                    "R%d: %d heal for %d mana (%.2f HPM). R%d costs %.1fx the mana for %.1fx the heal.",
                    suggested.rank, suggested.heal, suggested.cost, suggested.hpm,
                    maxRow.rank, maxRow.cost / suggested.cost, maxRow.heal / suggested.heal)
            elseif suggested then
                callout = string.format("Max rank (R%d) is also your most efficient usable rank.", suggested.rank)
            end

            results[family] = {
                label = info.label,
                tol = info.tol,
                rows = rows,
                suggestedID = suggested and suggested.id or nil,
                callout = (callout or "") .. (lbNote or ""),
            }
        end
    end

    return results
end

-- Map of family -> suggested rank number, for the gear-change toast diff.
function RankMath:SuggestedRanks()
    local out = {}
    for family, res in pairs(RankMath:Compute()) do
        if res.suggestedID then
            out[family] = MD.SpellData.spells[res.suggestedID].rank
        end
    end
    return out
end
