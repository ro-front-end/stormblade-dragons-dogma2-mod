local PB = {}
-- Pactblade - custom vocation for Dragon's Dogma 2 (REFramework script). TEST BUILD.
-- Needs _DragonCore 1.2.0+ (by Bloodragon).
--   * While Pactblade is active and a sword is in hand, Fighter's shield actions are off. Defend's button
--     (JobSpecialAction) fires Eldritch Blast instead: tap = Eldritch Blast, hold and release = Charged Eldritch
--     Blast. The blast leaves the left palm (Mystic Spearhand's bolt animations, Magike Sperepelote's projectile).
--   * Blast damage = the hit's magick base x Magick Bolt's attack multiplier x the passive's magick bonus x 5 / 10.
--   * Passive on all your other hits: magick part x1.5 (physical part unchanged).
-- Nothing is written into the save; Reset scripts or removing the file undoes everything.
PB.NAME, PB.VERSION = "Pactblade", "1.1"
PB.DATA = "Pactblade.json"
-- (1.0) RELEASE (json.RELEASE): the short menu, and of the data files only the ones Pactblade needs are written.
-- A test build: RELEASE = false below (the full test menu + the debug dumps). (No extra main-chunk locals: 200 max.)
local json = json
do
    local RELEASE = true
    if RELEASE then
        local KEEP = { [PB.DATA] = true, ["Pactblade_guise_items.json"] = true, ["Pactblade_vsb_pick.json"] = true,
                       ["Pactblade_guise_sounds.json"] = true, ["Pactblade_trace.json"] = true,
                       ["Pactblade_slots.json"] = true }
        local real = json
        json = setmetatable({ RELEASE = true,
            dump_file = function(name, ...) if KEEP[name] then return real.dump_file(name, ...) end return true end },
            { __index = real })
    end
end

do   -- (1.0: in a block - the main chunk is at its 200 locals)
local okDC, dcv = pcall(require, "DragonCore.version")
if not okDC or (tonumber(dcv.number) or 0) < 10200 then
    re.on_draw_ui(function()
        if imgui.tree_node(PB.NAME .. " (NOT LOADED)") then
            imgui.text_colored("Pactblade needs _DragonCore 1.2.0 or newer.", 0xFF5050FF)
            imgui.tree_pop()
        end
    end)
    return
end
end
local runtime = require("DragonCore.game.runtime")
local frame = require("DragonCore.game.frame")
frame.start()

------------------------------------------------------------------------
-- tuned values (from the in-game tests)
------------------------------------------------------------------------
PB.JOB07_SHELLS = "AppSystem/Shell/UserData/HumanShellParamData_Job07.user"
PB.SKELETON_SHELLS = "AppSystem/ch/ch226/userdata/ch226003_shellparamdata.user"   -- the Skeleton Lord's waves (0)
local BLAST = {
    -- Eldritch Slash's wave (Magike Cut's shell 6): coloured like the blasts; keeps its own damage (no factor) and its
    -- full-size hit effects (noScale)
    slash = { shell = 6, noScale = true, name = "Eldritch Slash", dmgMul = 3, stagger = 5 },   -- (1.0.2 user: x3 - the earlier x9 was set while the wave multiplier never applied)   -- stagger: 2.0 -> 10 (user)
    tap = { action = "Job07_MagicBindImcomplete", layer = 1, delay = 0.46, shell = 13, scale = 1.0, speed = 0.4,
            fallback = "Job07_MagicBindImcompleteFullBody", fallbackLayer = 0,   -- when the upper-body one won't start
            fx = 1.0, flash = "own", mult = 5, factor = 0.2127, name = "Eldritch Blast", stagger = 0.25 },
    charged = { action = "Job07_MagicBindComplete", layer = 0, delay = 0.30, shell = 12, scale = 1.0, speed = 2.0,
                fx = 0.5, flash = "tap", mult = 10, factor = 0.4255, name = "Eldritch Bolt", stagger = 0.5 },   -- (user: the charged blast is called Eldritch Bolt)
    -- Eldritch Burst: pressed during / right after Onslaught or Empale. The charged animation; the hit area is a
    -- Speregonne projectile (shell 13, used for nothing else) with its effects shrunk to nothing and no launch flash
    burst = { action = "Job07_MagicBindComplete", layer = 0, delay = 0.30, shell = 12, scale = 1.0, speed = 0.3,
              fx = 0.5, flash = "tap", mult = 5, factor = 0.4255, name = "Eldritch Burst", lifetime = 0.25, hidden = "launch only",
              cast = { mode = "joint", joint = "L_Hand_Palm", face = "owner" },
              range = 2.5, arc = 150, stagger = 1.0, flinchOnly = true,
              armor = 1.5,        -- seconds of hyper armour from the start
              cancelAfter = 0.1 },  -- after the burst has fired, an attack press ends the animation's long recovery
}
PB.DODGE = "Job04_Dodge"   -- Thief's Swift Step: the vocation button's tap (user)
PB.DODGE_LOCK = 0.45       -- a new dodge only after the current one has run this long (it was spammable)
-- the direction the stick points, camera-relative, nil without stick input. Worked out from the stick and the camera
-- (the game's own move direction is not updated during a dodge, so chained dodges kept the old one); which way is
-- "right" is checked against the game's move direction while walking normally
local stickSide = 1
local function stick_candidates(a)
    local ax = a.input:call("get_AxisL")
    local cam = sdk.get_primary_camera():get_GameObject():get_Transform():get_Position()
    local me = a.character:get_GameObject():get_Transform():get_Position()
    local fx, fz = me.x - cam.x, me.z - cam.z
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 0.01 then return nil end
    fx, fz = fx / len, fz / len
    local function yaw_for(side)
        local rx, rz = fz * side, -fx * side
        local dx, dz = fx * ax.y + rx * ax.x, fz * ax.y + rz * ax.x
        return math.deg(math.atan(dx, dz))
    end
    return yaw_for(1), yaw_for(-1)
end
local function angle_gap(a1, a2) return math.abs(((a1 - a2) + 180) % 360 - 180) end
local function stick_yaw(a)
    local deg
    pcall(function()
        if not a.input:call("isLeverInputL") then return end
        local y1, y2 = stick_candidates(a)
        if y1 then deg = stickSide == 1 and y1 or y2 end
    end)
    return deg
end
local function face_yaw(a, deg)   -- (name kept: sets the MOVE direction only, the character doesn't turn)
    pcall(function()
        local tac = a.character["<TargetAngleCtrl>k__BackingField"]
        tac.Move["<AngleDeg>k__BackingField"] = deg
        pcall(function() tac:call("setMoveAngleDeg(System.Single)", deg) end)
    end)
end
PB.HOLD_SEC = 0.5          -- held longer than this = charged (user: 0.5 s, the first value again)
PB.COMBO_WINDOW = 0.3      -- a press in the first 0.3 s of an Onslaught / Empale swing = Eldritch Burst (user)
PB.PALM = "L_Hand_Palm"
PB.LOCK_RANGE = 30         -- the blast turns to the nearest enemy within this many metres
PB.MB_RATE = 1.0           -- Magick Bolt's attack multiplier (still to be measured)
PB.PHYS_BONUS, PB.MAG_BONUS = 1.0, 1.5   -- user: no physical bonus, magick +50%
-- Mystic Spearhand's hand effect (Forbeding / Redouted Bolt), kept on the left arm while Pactblade is active
local GLOW = { file = "vfx/effects/character/ch07/ns/13_ch07_ns_025_00.efx", id = 25, element = 0,
               every = 2.0 }   -- renewed this often (the old one finishes a moment later)
PB.GLOW_FF = 0.15          -- seconds to fast-forward to the freeze moment
PB.GLOW_LOOP = { 2.65, 3.00 }  -- while the blast button is held: this part of the effect loops (no vibrating air)
PB.GLOW_LOOP_SPEED = 0.5       -- ... at half speed (user)
PB.GLOW_JOINTS = { "L_Arm_Lower", "L_Hand_Palm", "L_Arm_Upper", "root" }

-- the player's choices (reframework/data/Pactblade.json)
-- defaults = the look the user settled on (2026-10-21)
local cfg = { active = true, beam = false, glow = true, nox = true, glowSpeed = 0.5, freeze = true, freezeAt = 2.59, boom = 0.31,
             armTint = true, armR = 255, armG = 3, armB = 30, armBright = 5.2, blastTint = true, bind = true, warpFx = "wisps",
             noTint = { ["13/23/0"] = true, ["13/23/1"] = true, ["13/23/2"] = true,   -- see-through layers that
                      },                                                            -- cover the screen tinted (user)
             comboNoDust = true, burstWindow = 0.8, burstWindowEmpale = PB.COMBO_WINDOW, burstWindowEmpaleAir = 0.8,   -- air Empale: as before 1.41 (user)
             burstFromEmpale = 0.5, empaleFrom = 56.6, empaleTo = 110.5,
             tuskFrom = 50, tuskTo = 91, slashFrame = 64, slashR = 255, slashG = 60, slashB = 170, slashBright = 6.0,
             slashFastFrom = 97, slashRange = 8, slashWave = "magike", slashHitRange = 28,
             slashTurn = true, slashTurnRange = 10, slashTurnCone = 70, slashTurnSpeed = 360, glowVariant = "h285g2", glowLvCharge = 4,
             chargeFull = true, chargeSpeed = 0.35, chargeEnd = 5.0,
             glowSheathed = false, armLight = false, lightLm = 800, lightRadius = 4,
             afterimage = true, afterimageSecs = 0.3,
             comboTurn = true, comboTurnSpeed = 360, comboTurnRange = 12, comboTurnCone = 70, comboDynamic = true,
             finisherHeight = -0.3, smiteSkill = "Job01_BlinkStrike",   -- (Burst Strike, user's bind)
             mistySkill = "Job01_RisingLunge",    -- (3.19: Cloudfall Strike - usable in the air; was Shield Drum)
             comboSkill = "Job01_BravesRaid",     -- (3.19: the Archfey Combo on Riotous Fury; was Cloudfall Strike)
             beamSkill = "Job01_CymbalAttack",    -- (3.21: the Eldritch Blast beam on Shield Drum; rebindable)
             blinkSkill = "Job01_CymbalAttack",   -- (3.87: Blink Strike on Shield Drum - the user's beam is on Shield Summons; rebindable)
             noxBladeR = 91, noxBladeG = 26, noxBladeB = 142, noxBladeBright = 1.0,   -- Nox look (user's sliders)
             noxMistR = 126, noxMistG = 0, noxMistB = 54, noxMistBright = 1.3, smite = {}, noxSmite = nil }   -- (user: the air finisher was too high at head + 0.4 m)
do
    local saved = json.load_file(PB.DATA) or {}
    if type(saved.active) == "boolean" then cfg.active = saved.active end
    if type(saved.glow) == "boolean" then cfg.glow = saved.glow end
    if type(saved.nox) == "boolean" then cfg.nox = saved.nox end
    if type(saved.glowSpeed) == "number" then cfg.glowSpeed = saved.glowSpeed end
    if type(saved.freeze) == "boolean" then cfg.freeze = saved.freeze end
    if type(saved.freezeAt) == "number" then cfg.freezeAt = saved.freezeAt end
    if type(saved.boom) == "number" then cfg.boom = saved.boom end
    for _, k in ipairs({ "armR", "armG", "armB", "armBright" }) do
        if type(saved[k]) == "number" then cfg[k] = saved[k] end
    end
    if type(saved.armTint) == "boolean" then cfg.armTint = saved.armTint end
    if type(saved.blastTint) == "boolean" then cfg.blastTint = saved.blastTint end
    if type(saved.bind) == "boolean" then cfg.bind = saved.bind end
    if type(saved.comboNoDust) == "boolean" then cfg.comboNoDust = saved.comboNoDust end
    if type(saved.slashTurn) == "boolean" then cfg.slashTurn = saved.slashTurn end   -- (was not read back before 1.71)
    if type(saved.keepDay) == "boolean" then cfg.keepDay = saved.keepDay end
    if type(saved.glowVariant) == "string" then cfg.glowVariant = saved.glowVariant end
    if type(saved.smiteSkill) == "string" then cfg.smiteSkill = saved.smiteSkill end
    if type(saved.mistySkill) == "string" then cfg.mistySkill = saved.mistySkill end
    if type(saved.comboSkill) == "string" then cfg.comboSkill = saved.comboSkill end
    if type(saved.beamSkill) == "string" then cfg.beamSkill = saved.beamSkill end
    if type(saved.blinkSkill) == "string" then cfg.blinkSkill = saved.blinkSkill end
    for _, other in ipairs({ cfg.beamSkill, cfg.smiteSkill, cfg.mistySkill, cfg.comboSkill }) do   -- (3.87: no double use)
        if cfg.blinkSkill == other then
            for _, free in ipairs({ "Job01_CymbalAttack", "Job01_ShieldSummons", "Job01_Springboard", "Job01_DivineDefense" }) do
                local used = false
                for _, o2 in ipairs({ cfg.beamSkill, cfg.smiteSkill, cfg.mistySkill, cfg.comboSkill }) do if o2 == free then used = true end end
                if not used then cfg.blinkSkill = free; break end
            end
        end
    end
    if not saved.slots319 then cfg.mistySkill, cfg.comboSkill = "Job01_RisingLunge", "Job01_BravesRaid" end   -- (the swap, once)
    cfg.slots319 = true
    if type(saved.smite) == "table" then cfg.smite = saved.smite end
    if type(saved.noxSmite) == "table" then cfg.noxSmite = saved.noxSmite end
    for _, k in ipairs({ "brewLand", "brewPour" }) do   -- Caustic Brew's picked sounds
        if type(saved[k]) == "table" and type(saved[k].id) == "number" then cfg[k] = saved[k] end
    end
    if type(saved.chargeFull) == "boolean" then cfg.chargeFull = saved.chargeFull end
    if type(saved.chargeSpeed) == "number" then cfg.chargeSpeed = saved.chargeSpeed end
    if type(saved.chargeEnd) == "number" then cfg.chargeEnd = saved.chargeEnd end
    if type(saved.glowSheathed) == "boolean" then cfg.glowSheathed = saved.glowSheathed end
    if type(saved.glowLvCharge) == "number" then cfg.glowLvCharge = saved.glowLvCharge end
    if type(saved.armLight) == "boolean" then cfg.armLight = saved.armLight end
    if type(saved.lightLm) == "number" then cfg.lightLm = saved.lightLm end
    if type(saved.lightRadius) == "number" then cfg.lightRadius = saved.lightRadius end
    if type(saved.afterimage) == "boolean" then cfg.afterimage = saved.afterimage end
    if type(saved.afterimageSecs) == "number" then cfg.afterimageSecs = saved.afterimageSecs end
    if type(saved.comboTurn) == "boolean" then cfg.comboTurn = saved.comboTurn end
    if type(saved.comboDynamic) == "boolean" then cfg.comboDynamic = saved.comboDynamic end
    if type(saved.finisherHeight) == "number" then cfg.finisherHeight = saved.finisherHeight end
    for _, k in ipairs({ "comboTurnSpeed", "comboTurnRange", "comboTurnCone" }) do
        if type(saved[k]) == "number" then cfg[k] = saved[k] end
    end
    for _, k in ipairs({ "burstWindow", "burstWindowEmpale", "burstWindowEmpaleAir", "burstFromEmpale", "empaleFrom", "empaleTo", "tuskFrom", "tuskTo", "slashFrame", "slashR", "slashG", "slashB", "slashBright", "slashFastFrom", "slashRange", "slashWave", "slashTurnRange", "slashTurnCone", "slashTurnSpeed", "slashHitRange",
                         "noxBladeR", "noxBladeG", "noxBladeB", "noxBladeBright", "noxMistR", "noxMistG", "noxMistB", "noxMistBright" }) do
        if type(saved[k]) == "number" then cfg[k] = saved[k] end
    end
    if type(saved.noTint) == "table" then for k, v in pairs(saved.noTint) do if v == true then cfg.noTint[k] = true end end end
    if saved.warpFx == "quikfot" or saved.warpFx == "blink" or saved.warpFx == "wisps" then cfg.warpFx = saved.warpFx end
end
local glowCol
local function save_cfg()
    json.dump_file(PB.DATA, { armRoutes = glowCol and glowCol.routes, active = cfg.active, beam = cfg.beam, glow = cfg.glow, nox = cfg.nox, glowSpeed = cfg.glowSpeed,
                           freeze = cfg.freeze, freezeAt = cfg.freezeAt, boom = cfg.boom, armTint = cfg.armTint,
                           armR = cfg.armR, armG = cfg.armG, armB = cfg.armB, armBright = cfg.armBright,
                           blastTint = cfg.blastTint, bind = cfg.bind, warpFx = cfg.warpFx,
                           noTint = cfg.noTint, comboNoDust = cfg.comboNoDust, parts = cfg.parts,
                           burstWindow = cfg.burstWindow, burstWindowEmpale = cfg.burstWindowEmpale,
                           burstWindowEmpaleAir = cfg.burstWindowEmpaleAir, burstFromEmpale = cfg.burstFromEmpale,
                           empaleFrom = cfg.empaleFrom, empaleTo = cfg.empaleTo, tuskFrom = cfg.tuskFrom, tuskTo = cfg.tuskTo,
                           slashFrame = cfg.slashFrame, slashR = cfg.slashR, slashG = cfg.slashG, slashB = cfg.slashB,
                           slashBright = cfg.slashBright, slashFastFrom = cfg.slashFastFrom,
                           slashRange = cfg.slashRange, slashWave = cfg.slashWave, slashTurn = cfg.slashTurn, slashHitRange = cfg.slashHitRange,
                           slashTurnRange = cfg.slashTurnRange, slashTurnCone = cfg.slashTurnCone, slashTurnSpeed = cfg.slashTurnSpeed,
                           keepDay = cfg.keepDay, glowVariant = cfg.glowVariant,
                           chargeFull = cfg.chargeFull, chargeSpeed = cfg.chargeSpeed, chargeEnd = cfg.chargeEnd,
                           glowSheathed = cfg.glowSheathed, glowLvCharge = cfg.glowLvCharge, armLight = cfg.armLight, lightLm = cfg.lightLm,
                           lightRadius = cfg.lightRadius, afterimage = cfg.afterimage, afterimageSecs = cfg.afterimageSecs,
                           comboTurn = cfg.comboTurn, comboTurnSpeed = cfg.comboTurnSpeed, comboTurnRange = cfg.comboTurnRange,
                           comboTurnCone = cfg.comboTurnCone, comboDynamic = cfg.comboDynamic,
                           finisherHeight = cfg.finisherHeight, brewLand = cfg.brewLand, brewPour = cfg.brewPour,
                           smiteSkill = cfg.smiteSkill, mistySkill = cfg.mistySkill, comboSkill = cfg.comboSkill, beamSkill = cfg.beamSkill, blinkSkill = cfg.blinkSkill, slots319 = true, noxBladeR = cfg.noxBladeR, noxBladeG = cfg.noxBladeG,
                           noxBladeB = cfg.noxBladeB, noxBladeBright = cfg.noxBladeBright, noxMistR = cfg.noxMistR,
                           noxMistG = cfg.noxMistG, noxMistB = cfg.noxMistB, noxMistBright = cfg.noxMistBright, smite = cfg.smite,
                           noxSmite = cfg.noxSmite })
end
-- ground Empale after its Burst window (frame > cfg.empaleTo) is only its long way back to idle: dodging is fine there
local function tusk_recovering(a)   -- Tusk Toss after its Burst window (frame > cfg.tuskTo): dodging is fine
    local fr = 0
    pcall(function() fr = a.character.FullBodyLayer:call("get_Frame") end)
    return fr > cfg.tuskTo
end
local function empale_recovering(a, curA)
    if curA:find("Air") then return false end
    local fr = 0
    pcall(function() fr = a.character.FullBodyLayer:call("get_Frame") end)
    return fr > cfg.empaleTo
end

-- debug info (shown in the menu's Debug section only)
local dbg = { log = {}, hits = {}, blocked = 0, suppressed = 0, glowMethod = "A", glowJoint = "L_Arm_Lower",
              glow = "-" }
local trace = {}
-- debug files: written at most every 2 s (each write is disk I/O on the game thread - a stutter per hit / warp)
dbg.files, dbg.filesAt = {}, 0
function dbg.save(name, data) dbg.files[name] = data end
local AIR_NO = { "rope", "rappel", "climb", "hang", "ladder", "cling", "grab", "catch", "dmg", "damage", "down", "blown", "die", "dead", "swim", "carry" }
function dbg.air_ok(a)   -- (3.65) in the air from a real jump / fall / air attack - not on a rope, climbing, hurt
    local cur = tostring(a:current_action(0) or ""):lower()
    for _, w in ipairs(AIR_NO) do if cur:find(w, 1, true) then return false, cur end end
    return cur:find("jump", 1, true) ~= nil or cur:find("fall", 1, true) ~= nil or cur:find("air", 1, true) ~= nil, cur
end
function dbg.busy_action(a)   -- (3.70) on a rope, climbing, hanging, grabbed, hurt, down...: the vocation button is off
    local cur = tostring(a:current_action(0) or ""):lower()
    for _, w in ipairs(AIR_NO) do if cur:find(w, 1, true) then return true, cur end end
    return false, cur
end
function dbg.can_dodge(a)   -- (3.65) the game's own track: may I dodge / cancel right now?
    local ok, why = true, "?"
    pcall(function()
        local t = a.character:get_Human().Track
        ok = t.All or t.Evasion or t.Cancel or t.SpecialCancel
        why = ("All %s, Evasion %s, Cancel %s"):format(tostring(t.All), tostring(t.Evasion), tostring(t.Cancel))
    end)
    local cur = tostring(a:current_action(0) or ""):lower()
    for _, w in ipairs(AIR_NO) do if cur:find(w, 1, true) then return false, cur end end
    return ok, why
end
re.on_frame(function()
    if os.clock() - dbg.filesAt < 2 or next(dbg.files) == nil then return end
    dbg.filesAt = os.clock()
    for name, data in pairs(dbg.files) do pcall(json.dump_file, name, data) end
    dbg.files = {}
end)
local function note(s)
    table.insert(dbg.log, os.date("%H:%M:%S") .. "  " .. s)
    while #dbg.log > 8 do table.remove(dbg.log, 1) end
    table.insert(trace, ("%s %.2f  %s"):format(os.date("%H:%M:%S"), os.clock(), s))
    while #trace > 120 do table.remove(trace, 1) end
    dbg.save("Pactblade_trace.json", trace)
end
dbg.stamWatch = {}   -- (3.98) { what, at, before }: stamina before / after a skill, noted
dbg.stamCosts = {}   -- (4.00) { what, cost, before, at }: the rest of a skill's cost, after what the game already took
pcall(function()   -- (4.04) a skill's own big drain swapped for our cost (dbg.stamSwap = { cost, untilT })
    sdk.hook(sdk.find_type_definition("app.StaminaManager"):get_method("add(System.Single, System.Boolean)"), function(args)
        local w = dbg.stamSwap
        if not w or os.clock() > w.untilT then return end
        pcall(function()
            local v = sdk.to_float(args[3])
            if v > -300 then return end
            local me = runtime.player().character:get_StaminaManager()
            if sdk.to_managed_object(args[2]):get_address() ~= me:get_address() then return end
            local cost = w.mul and (-v * w.mul) or w.cost   -- (1.1: w.mul = a share of the game's own drain)
            args[3] = sdk.float_to_ptr(-cost)
            dbg.stamSwap = nil
            note(("stamina: the game's %.0f swapped for %.0f (%s)"):format(-v, cost, w.what))
        end)
    end, function(r) return r end)
end)
function dbg.stam_cost(a, what, cost)
    pcall(function() dbg.stamCosts[#dbg.stamCosts + 1] = { what = what, cost = cost, before = a:stamina(), at = os.clock() + 0.6 } end)
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if #dbg.stamCosts == 0 then return end
    local c = dbg.stamCosts[1]
    if os.clock() < c.at then return end
    table.remove(dbg.stamCosts, 1)
    pcall(function()
        local a = runtime.player()
        local spent = math.max(0, (c.before or 0) - (a:stamina() or 0))
        local rest = c.cost - spent
        if rest > 0 then a:consume_stamina(rest)
        elseif rest < 0 then pcall(function() a.character:get_StaminaManager():add(-rest, true) end) end   -- (4.03: the game took more: back)
        note(("stamina: %s costs %.0f - the game took %.0f, we %s %.0f"):format(c.what, c.cost, spent, rest >= 0 and "took" or "gave back", math.abs(rest)))
    end)
end)
re.on_pre_application_entry("LateUpdateBehavior", function()   -- (3.99) any sudden stamina drop, with the action
    if not (dbg.live and dbg.live.on) then dbg.stamPrev = nil; return end   -- (live is defined further down)
    pcall(function()
        local a = runtime.player()
        if not a then return end
        local st = a:stamina()
        if type(st) ~= "number" then return end
        local prev = dbg.stamPrev
        dbg.stamPrev = st
        if prev and prev - st >= 20 then note(("stamina: -%.0f at once (%.0f -> %.0f) during %s"):format(prev - st, prev, st, tostring(a:current_action(0)))) end
        if prev and st - prev >= 20 and os.clock() < (dbg.stamTraceUntil or 0) then   -- (4.02: rises too, while watched)
            note(("stamina: +%.0f at once (%.0f -> %.0f) during %s"):format(st - prev, prev, st, tostring(a:current_action(0))))
        end
    end)
end)
function dbg.stam_mark(a, what)
    pcall(function() dbg.stamWatch[#dbg.stamWatch + 1] = { what = what, at = os.clock() + 1.5, before = a:stamina() } end)
end
re.on_frame(function()
    if #dbg.stamWatch == 0 then return end
    local w = dbg.stamWatch[1]
    if os.clock() < w.at then return end
    table.remove(dbg.stamWatch, 1)
    pcall(function()
        local now = runtime.player():stamina()
        note(("stamina: %s took %.0f (%.0f -> %.0f)"):format(w.what, (w.before or 0) - (now or 0), w.before or -1, now or -1))
    end)
end)

------------------------------------------------------------------------
-- state shared with the hooks (updated every frame)
------------------------------------------------------------------------
local live = { on = false, go = nil, am = nil, ctx = nil, avail = nil, shieldWorn = false, sc = nil }
dbg.live = live   -- (1.0) for callbacks defined above this line
-- (i-0.7) Dimension Door (from the user's standalone mod 0.8.5): reframework/autorun/Pactblade/DimensionDoor.lua
do
    local okDD, DD = pcall(require, "Pactblade.DimensionDoor")
    if okDD and type(DD) == "table" then DD.pactblade = function() return live.on end; DD.release = json.RELEASE == true; dbg.dd = DD
    else dbg.ddErr = tostring(DD) end
end
function dbg.dd_block() local ok, b = pcall(function() return dbg.dd and dbg.dd.block() end); return ok and b end

------------------------------------------------------------------------
-- (i-0.1) PactBladeVSBIntegrated: the VSB skills -> the skill code's Fighter ids (an adapter on the press)
------------------------------------------------------------------------
dbg.INTEGRATED = true
dbg.pbDepth = 0
function dbg.press_ok() return not dbg.INTEGRATED or (dbg.pbDepth or 0) > 0 end
;(function()
    local UUIDS = {   -- reframework/data/VSB/packs/pactblade/skills/*.json
        ["4a1d3cc4-c412-5340-a92b-02709ca4fd7e"] = "smite", ["9a6da1ea-e428-5ab0-9354-04724e332b8b"] = "slash",
        ["f6da6f77-72f1-5706-a42d-c00588d2655e"] = "blast", ["530e3195-dac5-5ab0-bcad-c2b78f7dad76"] = "brew",
        ["ffe5c0b8-18fb-5c62-af83-bb18642ee21e"] = "guise", ["5d203b5c-0187-578c-bbfe-2ee3dc4e2d97"] = "combo",
        ["7ad9aec8-a3c5-5c3e-a951-05fdea168a69"] = "dive", ["94db826d-21fc-53d1-805a-29bb376004c3"] = "strike",
        -- Stormblade custom skills (4 Clean Skills: Arc Slash, Tempest Flurry, Levin Storm, Nova Eléctrica)
        ["7a31b412-4019-4b21-99ee-b01149e1a002"] = "slash", -- Arc Slash (sb_slash.json)
        -- ["7a31b412-4019-4b21-99ee-b01149e1a005"] = "combo", -- Tempest Flurry (Decoupled for native VSB Wild Furie timeline)
        -- ["7a31b412-4019-4b21-99ee-b01149e1a007"] = "nova",  -- Nova Eléctrica (Decoupled for native VSB timeline)
    }
    local A = { map = {}, found = 0, lastRead = -100, info = "VSB skill ids not read yet", presses = 0 }
    dbg.adapter = A
    local idTd = sdk.find_type_definition("app.HumanCustomSkillID")
    local function fighter_id(name)
        local ok, v = pcall(function() return idTd:get_field(name):get_data(nil) & 0xFFFFFFFF end)
        return ok and v or nil
    end
    local function binding(kind)
        if kind == "smite" then return cfg.smiteSkill or "Job01_BlinkStrike" end
        if kind == "slash" then return "Job01_HindsightSlash" end
        if kind == "blast" then return cfg.beamSkill or "Job01_ShieldSummons" end
        if kind == "brew" then return "Job01_FullMoonSlash" end
        if kind == "guise" then return "Job01_DivineDefense" end
        if kind == "combo" then return cfg.comboSkill or "Job01_BravesRaid" end
        if kind == "dive" then return cfg.mistySkill or "Job01_RisingLunge" end
        if kind == "strike" then return cfg.blinkSkill or "Job01_CymbalAttack" end
        if kind == "nova" then return "Job01_FullMoonSlash" end
    end
    function dbg.ensure_drawn(a)
        if not a or not a:valid() then return false end
        if a:weapon_drawn() then return true end
        pcall(function()
            local ok = a:draw_weapon()
            if not ok then a:request_action("DrawWeapon", 0) end
        end)
        return false
    end
    function A.refresh()   -- VSB's ids of our skills (its id table), every 5 s until all are there
        if os.clock() - A.lastRead < 5 and A.found >= 8 then return end
        A.lastRead = os.clock()
        local t = json.load_file("VSB/state/idtable.json")
        local ids = t and t.ids and t.ids.custom
        if type(ids) ~= "table" then A.info = "VSB id table not found"; return end
        local m, n = {}, 0
        for u, kind in pairs(UUIDS) do
            local vid = ids[u]
            local fid = fighter_id(binding(kind))
            if vid and fid then m[math.tointeger(vid) or vid] = { kind = kind, fid = fid }; n = n + 1 end
        end
        A.map, A.found = m, n
        A.info = ("%d / 8 Pactblade skills known to VSB"):format(n)
    end
    local function translate(args, idx)
        local id0 = sdk.to_int64(args[idx]) & 0xFFFFFFFF
        if id0 >= 100 or (A.logAll and live.on) then   -- (i-0.2) every press of a VSB-range id noted
            note(("adapter: press id %d (path %s, Pactblade %s, known %s)"):format(id0, idx == 3 and "main" or "action", tostring(live.on), tostring(A.map[id0] ~= nil)))
        end
        if not live.on then return end
        pcall(A.refresh)
        local id = id0
        local e = A.map[id]
        if not e then return end
        note(("adapter: %s (VSB %d) -> Fighter id %d"):format(e.kind, id, e.fid))
        args[idx] = sdk.to_ptr(e.fid)
        dbg.pbDepth = (dbg.pbDepth or 0) + 1
        thread.get_hook_storage().pbT = true
        A.presses = A.presses + 1
        A.last, A.lastFid = e.kind, e.fid
        if PB.activeVocation == "stormblade" then
                        if e.kind == "nova" then PB.novaWant = os.clock() end
        end
    end
    local function done(r)
        if thread.get_hook_storage().pbT then
            thread.get_hook_storage().pbT = nil
            dbg.pbDepth = math.max(0, (dbg.pbDepth or 1) - 1)
        end
        return r
    end
    -- (i-0.3) during a translated press the game may use that Fighter skill (it asks for the translated id)
    for _, mname in ipairs({ "isCustomSkillAvailable(app.HumanCustomSkillID)", "isCustomSkillAvailableWithoutItemCondition(app.HumanCustomSkillID)" }) do
        pcall(function()
            sdk.hook(sdk.find_type_definition("app.HumanSkillAvailability"):get_method(mname), function(args)
                local st = thread.get_hook_storage()
                st.pbYes = nil
                if (dbg.pbDepth or 0) == 0 or not live.on then return end
                local sid = sdk.to_int64(args[3]) & 0xFFFFFFFF
                if sid ~= A.lastFid then return end
                pcall(function()
                    local ch = sdk.to_managed_object(args[2]).Chara
                    if ch and ch:get_GameObject():get_address() == live.go then st.pbYes = true end
                end)
            end, function(r)
                local st = thread.get_hook_storage()
                if st.pbYes then st.pbYes = nil; return sdk.to_ptr(1) end
                return r
            end)
        end)
    end
    local PID = sdk.find_type_definition("app.PlayerInputProcessorDetail")
    pcall(sdk.hook, PID:get_method("processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"),
        function(args) pcall(translate, args, 3) end, done)
    pcall(sdk.hook, PID:get_method("processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean)"),
        function(args) pcall(translate, args, 4) end, done)
end)()
-- while walking normally: which side matches the game's own move direction
re.on_frame(function()
    if not live.on then return end
    local a = runtime.player()
    if not a or not a:valid() then return end
    pcall(function()
        if a:current_action(0) ~= "NormalLocomotion" or not a.input:call("isLeverInputL") then return end
        local ax = a.input:call("get_AxisL")
        if math.abs(ax.x) < 0.5 then return end   -- only a clearly sideways stick tells the sides apart
        local game = a.character["<TargetAngleCtrl>k__BackingField"]:call("get_MoveAngleDeg")
        local y1, y2 = stick_candidates(a)
        if not y1 then return end
        local want = angle_gap(y1, game) <= angle_gap(y2, game) and 1 or -1
        if want ~= stickSide then stickSide = want; note("dodge: stick sides set to " .. want) end
    end)
end)
local PACK_ID = "pactblade"          -- the VSB vocation pack (reframework/data/VSB/packs/pactblade)
local forceActive = false            -- Debug: test without VSB's pick (never saved)
local ignorePick = false             -- Debug: stay off even when Pactblade is picked (crash hunting)
PB.activeVocation = nil
local function vsb_state()
    local api = rawget(_G, "VSB_API")
    local app = api and api.app
    if not app or not app.picks then return "missing" end
    local pick = app.picks.Job01
    if pick == PACK_ID or pick == "stormblade" then
        PB.activeVocation = pick
        return "picked"
    end
    PB.activeVocation = nil
    return "not picked"
end

;(function()   -- the VSB pick kept over a script reset
    local FILE = "Pactblade_vsb_pick.json"
    re.on_script_reset(function()
        pcall(json.dump_file, FILE, { picked = vsb_state() == "picked", at = os.time() })
    end)
    local saved = json.load_file(FILE)
    pcall(json.dump_file, FILE, {})   -- used once
    if type(saved) ~= "table" or not saved.picked or type(saved.at) ~= "number" or os.time() - saved.at > 60 then return end
    local tries = 0
    local function again()
        if tries < 0 then return end
        tries = tries + 1
        local api = rawget(_G, "VSB_API")
        local app = api and api.app
        if app and app.picks and app.set_vocation_pick then
            tries = -1
            if app.picks.Job01 == nil then
                local ok, e = pcall(app.set_vocation_pick, app, "Job01", PACK_ID)
                note(ok and "script reset: Pactblade picked in VSB again" or ("script reset: re-pick failed: " .. tostring(e)))
            end
        elseif tries > 1200 then tries = -1; note("script reset: VSB not found - Pactblade not re-picked") end
    end
    re.on_frame(function() pcall(again) end)
end)()

-- Fighter's shield actions (Defend and the rest) are refused while Pactblade is active
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method(
        "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"), function(args)
        if not live.on or not live.am or sdk.to_int64(args[2]) ~= live.am then return end
        local name = nil
        pcall(function()
            local obj = sdk.to_managed_object(args[4])
            if obj then name = tostring(obj:ToString()) end
        end)
        -- Only block Fighter shield actions; leave normal heavy attack and downed finisher 100% vanilla!
        if name and name:find("^Job01_") and (name:find("Guard") or name:find("Shield")) then
            dbg.blocked = dbg.blocked + 1
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(r) return r end)
end)

------------------------------------------------------------------------
-- Fighter kit changes while Pactblade is active
------------------------------------------------------------------------
-- core skills: Tusk Toss (charged attack) + Thief's Controlled Fall + Footpad on; Fighter's shield core skills off (player only)
local GRANT = { [6] = true, [17] = true, [18] = true, [27] = true }          -- Job01_TuskToss (Charged Slash), Job04_BreakFall, Job04_KickWall, Job07 Quik Fot
local DENY = { [4] = true, [5] = true, [7] = true, [8] = true }  -- Deflect, True Deflect, Steeled Foundation, Enchanted Counter
for _, spec in ipairs({ { "app.HumanSkillContext", "isNormalSkillEnable(app.HumanNormalSkillID)", "ctx" },
                        { "app.PlayerInputProcessorDetail", "isNormalSkillEnable(app.HumanNormalSkillID)", nil },
                        { "app.HumanSkillAvailability", "isNormalSkillAvailable(app.HumanNormalSkillID)", "avail" } }) do
    pcall(function()
        local stack = {}
        sdk.hook(sdk.find_type_definition(spec[1]):get_method(spec[2]), function(args)
            local v = false
            if live.on and (not spec[3] or sdk.to_int64(args[2]) == live[spec[3]]) then
                local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
                if GRANT[id] then v = 1 elseif DENY[id] then v = 0 end
            end
            stack[#stack + 1] = v
        end, function(r)
            local v = table.remove(stack)
            if v then return sdk.to_ptr(v) end
            return r
        end)
    end)
end

-- Footpad and Controlled Fall: only the current vocation's input handler runs, so Thief's is called every frame
-- (Lenient Stagger and Exhaustion's method; if that mod already does Controlled Fall, it is left to it)
local function lse_fall()
    local f = package.loaded["_NickCore/Functions"]
    return f and f.on_frame and f.on_frame["LSE - Controlled fall"] ~= nil
end
local fall = { state = nil }
local QUIK_FOT = "Job07_MagicBindJustLeap"
local leap = { untilT = 0 }
local function unbind(target, mb)
    local ok, err = pcall(function()
        if not target then error("no bound enemy recorded") end
        local bc = target:get_field("<BindCtrl>k__BackingField")
        if not bc then bc = target:call("get_BindCtrl") end
        local mod = bc:call("get_MagicBind")
        mod:call("stop(System.Boolean)", false)
        pcall(mod.call, mod, "deleteBindEffect")
    end)
    if mb then pcall(mb.call, mb, "resetHitMagicBindInfo") end
    note(ok and "Quik Fot over: bind taken off the enemy" or ("unbind failed: " .. tostring(err)))
end
pcall(function()
    sdk.hook(sdk.find_type_definition("app.Job04BreakFall"):get_method("setMotion(System.Single)"), function(args)
        if not live.on or lse_fall() then return end
        pcall(function()
            local ch = sdk.to_managed_object(args[2])["<Character>k__BackingField"]
            if ch and ch:get_GameObject():get_address() == live.go then fall.state = "start" end
        end)
    end, function(r) return r end)
end)
re.on_frame(function()
    if not live.on then return end
    local a = runtime.player()
    if not a or not a:valid() then return end
    local d
    pcall(function() d = a.character["<InputProcessor>k__BackingField"].DetailInstances[3] end)
    if not d then dbg.thief = "Thief's input handler not found"; return end
    pcall(d.call, d, "processKickWall")
    if cfg.bind then
        local d6
        pcall(function() d6 = a.character["<InputProcessor>k__BackingField"].DetailInstances[6] end)
        if d6 then
            local ok, v = pcall(d6.call, d6, "processJustMagicBind")
            if ok and v == true then note("Quik Fot started") end
            if not ok then dbg.leap = "Quik Fot handler error: " .. tostring(v) end
        else dbg.leap = "Mystic Spearhand's input handler not found" end
        pcall(function()
            local h = a.character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("app.Human"))
            local mb = h:get_field("<Job07ActionCtrl>k__BackingField"):get_field("<MagicBindCtrl>k__BackingField")
            local open = mb:call("get_IsJustMagicBindEnable")
            if open and not dbg.leapOpen then note("Quik Fot window open (press Jump)") end
            dbg.leapOpen = open
            dbg.leap = "Quik Fot window: " .. (open and "OPEN" or "closed")
            local now = os.clock()
            if open and dbg.hex_put and (a:button_pressed("Interact") or a:button_pressed("GimmickAction")) then
                local ok, e = pcall(dbg.hex_put, a, mb:call("get_MagicBindShellHitOwner"))   -- (Examine: Hex on it)
                if not ok then note("Hex failed: " .. tostring(e)) end
            end
            if open and a:button_pressed("Jump") then
                if dbg.lastKind == "burst" and now - (dbg.lastFireT or -10) < 6 and dbg.burst_step then
                    -- after a Burst bind: to the far side of the enemy (user), not Quik Fot's leap
                    dbg.burstWant = { target = mb:call("get_MagicBindShellHitOwner"), mb = mb, t = now }   -- (done in UpdateBehavior)
                else
                    leap.untilT = now + 0.3
                    leap.target = mb:call("get_MagicBindShellHitOwner")
                    leap.mb = mb
                    note("Jump in the Quik Fot window")
                end
            end
        end)
        if leap.untilT > os.clock() then
            local cur = a:current_action(0)
            if cur and tostring(cur):find("MagicBindJustLeap") then
                leap.untilT = 0
                leap.playing = os.clock()
                note("Quik Fot playing: " .. tostring(cur))
            else
                local ok = a:request_action(QUIK_FOT, 0)
                if not leap.asked then note("Quik Fot requested -> " .. tostring(ok) .. " " .. tostring(a.errors and a.errors.request_action or "")) end
                leap.asked = true
            end
        else leap.asked = nil end
        if leap.playing and (a:current_action(0) ~= QUIK_FOT or os.clock() - leap.playing > 3) then
            leap.playing = nil
            unbind(leap.target, leap.mb)
            leap.target, leap.mb = nil, nil
        end
    end
    if lse_fall() then dbg.thief = "Footpad: on | Controlled Fall: left to Lenient Stagger"; return end
    pcall(d.call, d, "processBreakFall")
    dbg.thief = "Footpad: on | Controlled Fall: on"
    if fall.state == "start" then
        fall.state = "play"
    elseif fall.state == "play" then
        fall.state = nil
        pcall(function()
            local L = a.character.FullBodyLayer   -- Thief's roll lives in Thief's motion bank (145)
            L:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                145, L:get_MotionID(), 0.0, 12.0, 1, 1)
        end)
        pcall(a.consume_stamina, a, 100)
        note("Controlled Fall")
    end
end)

-- Onslaught (the light attack chain) 1.30x faster (+30%); every other sped-up attack (Empale, dash / climbing / air
-- attacks, finishing moves, Blink Strike) 1.20x (+20%)
local FAST, FASTER_OTHER = 1.30, 1.20
local ONSLAUGHT = { Job01_AttackLeft = true, Job01_AttackRight = true, Job01_AttackAir = true }
local speeding = false
local combo = { stage = 0, lastPress = -10 }   -- Archfey Combo, in Cloudfall Strike's slot (see below)
local wisps                                     -- the warp wisps (defined further down)
local function basic_attack(name)
    if not name or not name:find("^Job01_") then return false end
    if name:find("Shield") or name:find("Guard") or name:find("Hindsight") or name:find("Cymbal") then return false end
    return name:find("Attack") ~= nil or name:find("FinishingMove") ~= nil
end
local function update_speed(a)
    local cur = a:current_action(0)
    dbg.action = cur
    if live.on and basic_attack(cur) and combo.stage == 0 then
        dbg.lastBasic = os.clock()
        local mot
        pcall(function() local L = a.character.FullBodyLayer; mot = L:get_MotionBankID() * 100000 + L:get_MotionID() end)
        if cur ~= dbg.basicName or mot ~= dbg.basicMot then   -- a new swing started
            dbg.basicName, dbg.basicMot, dbg.basicStart = cur, mot, os.clock()
        end
        local sp = ONSLAUGHT[cur] and FAST or FASTER_OTHER
        a:set_speed(sp)
        dbg.spedSeen = dbg.spedSeen or {}
        if not dbg.spedSeen[cur] then dbg.spedSeen[cur] = true; note(("speed x%.1f: %s"):format(sp, cur)) end
        speeding = true
    elseif speeding then
        dbg.basicName, dbg.basicMot = nil, nil
        a:set_speed(nil)
        speeding = false
    end
end

-- no shield: equipping one is refused while Pactblade is active (fresh equips only, never items already equipped
-- when a save loads); a shield already worn is reported in the menu
local SLOT_SUB = 1
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ItemManager"):get_method(
        "setEquip(app.ItemDefine.StorageData, app.Character, app.EquipData.SlotEnum, System.Boolean, System.Boolean)"),
        function(args)
            if not live.on then return end
            local skip = false
            pcall(function()
                if (sdk.to_int64(args[5]) & 0xFFFFFFFF) ~= SLOT_SUB then return end
                local ch = sdk.to_managed_object(args[4])
                if not ch or ch:get_GameObject():get_address() ~= live.go then return end
                local sd = sdk.to_valuetype(args[3], "app.ItemDefine.StorageData")
                if sd:get_field("_IsEquipped") then return end
                skip = true
            end)
            if skip then
                dbg.shieldRefused = (dbg.shieldRefused or 0) + 1
                note("refused to equip a shield (Pactblade)")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
end)

------------------------------------------------------------------------
-- Eldritch Blast
------------------------------------------------------------------------
local update_glow, boon_clear, colour_shell
local blasts = {}          -- { record, kind, born, ... }
local st = { phase = "idle", t0 = 0, pending = nil }
local lastFire = -100
local lastKind = nil       -- the last blast fired (tap / charged / burst)
local bindBolt = { go = nil, addr = nil, born = 0 }   -- the Forbeding Bolt riding along with the charged blast
local ourSpawn = false     -- our own projectiles are never suppressed

-- the projectile's effect size and launch flash: the shared shell settings are changed for our blast and put back
local params = {}          -- shell id -> app.ShellParam (learned from the first blast of each kind)
local restoreQueue = {}
local function restore_effects(force)
    local now = os.clock()
    for i = #restoreQueue, 1, -1 do
        local r = restoreQueue[i]
        if force or now >= r.at then
            pcall(function()
                r.eff:set_field("UseEffectScale", r.use)
                r.eff:set_field("EffectScale", r.scale)
                r.eff:set_field("StartElementID", r.start)
            end)
            table.remove(restoreQueue, i)
        end
    end
end
local function shape_effects(b)
    if b.noShape then return end
    local param = params[b.shell]
    if not param then return end
    pcall(function()
        local eff = param._ShellParameterBase.effectParam
        for _, r in ipairs(restoreQueue) do if r.eff == eff then return end end
        table.insert(restoreQueue, { at = os.clock() + 1.0, eff = eff, use = eff.UseEffectScale,
                                     scale = eff.EffectScale, start = eff.StartElementID })
        eff:set_field("EffectScale", Vector3f.new(b.fx, b.fx, b.fx))
        eff:set_field("UseEffectScale", true)
        if b.flash == "none" then eff:set_field("StartElementID", -1)
        elseif b.flash == "tap" and params[11] then
            eff:set_field("StartElementID", params[11]._ShellParameterBase.effectParam.StartElementID)
        end
    end)
end
re.on_script_reset(function()
    restore_effects(true)
    if st.armorUntil then pcall(function() local a = runtime.player(); if a then a:set_super_armor(false) end end) end
end)

local function spawn(a, node, opts)
    ourSpawn = true
    local ok, res = pcall(a.spawn_shell, a, node, opts)
    ourSpawn = false
    if not ok then return nil, tostring(res) end
    if not res then return nil, tostring(a.errors and a.errors.spawn_shell) end
    return res
end

function dbg.bolt_face(a, t, holdSecs)   -- (3.80) turn to the bolt's target (flat); 3.81: held for holdSecs
    pcall(function()
        local tr = a.character:get_GameObject():get_Transform()
        local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
        local dx, dz = q.x - p.x, q.z - p.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.05 or not combo.yaw then return end
        dx, dz = dx / l, dz / l
        tr:set_Rotation(combo.yaw(dx, dz))
        if holdSecs then dbg.boltHold = { rot = combo.yaw(dx, dz), deg = math.deg(math.atan(dx, dz)), untilT = os.clock() + holdSecs } end
        pcall(function() dbg.set_facing_deg(a.character["<TargetAngleCtrl>k__BackingField"], math.deg(math.atan(dx, dz))) end)
    end)
end
function dbg.set_facing_deg(tac, deg)   -- (3.83) both of the game's stored angles: Front (body) and Move
    pcall(function() tac:call("setAngleDeg(System.Single)", deg) end)
    pcall(function() tac:call("setFrontAngleDeg(System.Single)", deg) end)
    pcall(function() tac:call("setMoveAngleDeg(System.Single)", deg) end)
    pcall(function() tac.Front["<AngleDeg>k__BackingField"] = deg; tac.Front.IsSet = true end)
    pcall(function() tac.Move["<AngleDeg>k__BackingField"] = deg; tac.Move.IsSet = true end)
end
function dbg.bolt_hold()   -- (a dbg field: the main chunk is at Lua's 200-locals limit)
    local h = dbg.boltHold
    if not h then return end
    if os.clock() > h.untilT then dbg.boltHold = nil; return end
    pcall(function()
        local a = runtime.player()
        a.character:get_GameObject():get_Transform():set_Rotation(h.rot)
        local tac = a.character["<TargetAngleCtrl>k__BackingField"]
        dbg.set_facing_deg(tac, h.deg)
    end)
end
re.on_pre_application_entry("UpdateBehavior", dbg.bolt_hold)
re.on_pre_application_entry("UpdateMotion", dbg.bolt_hold)
re.on_pre_application_entry("LateUpdateBehavior", dbg.bolt_hold)
re.on_application_entry("LateUpdateBehavior", dbg.bolt_hold)
local function spawn_blast(a, kind)
    local b = BLAST[kind]
    shape_effects(b)
    local aimOpts
    local maxRange = (kind == "tap" or kind == "charged") and 20 * (cfg.boltRangeMul or 0.5) or nil   -- (3.77)
    if kind == "tap" or kind == "charged" then   -- (3.75: aimed at the enemy the stick / camera points at)
        pcall(function()
            local bt = dbg.boltTarget
            local t
            if bt and os.clock() - bt.at < 2.0 then t = bt.t   -- (3.82: the target picked at the cast, or none)
            else t = dbg.beam and dbg.beam.aim_pick and dbg.beam.aim_pick(a, cfg.boltRangeMul or 0.5) end   -- (3.76 user: half the beam's)
            dbg.boltTarget = nil
            if not t or not (dbg.misty and dbg.misty.alive(t)) then return end
            local p
            pcall(function() p = t.Hip:get_Position() end)
            if not p then local q = t:get_GameObject():get_Transform():get_Position(); p = Vector3f.new(q.x, q.y + 1.2, q.z) end
            aimOpts = { aim = p }
            pcall(function()   -- (3.82: an aimed bolt reaches its target: distance + 2 m)
                local pm = a.game_object:get_Transform():getJointByName(PB.PALM):get_Position()
                maxRange = math.max(maxRange or 0, math.sqrt((p.x - pm.x) ^ 2 + (p.y - pm.y) ^ 2 + (p.z - pm.z) ^ 2) + 2)
            end)
            pcall(function()   -- (aimed at a flier: as far as the flier pick reaches)
                local me = a.character:get_GameObject():get_Transform():get_Position()
                if p.y - me.y > (dbg.beam.airUp or 4) then maxRange = (dbg.beam.airRange or 35) * (cfg.boltRangeMul or 0.5) end
            end)
            note(("%s aimed (%s) at %s"):format(kind, tostring(dbg.beam.aimBy), tostring(t:get_GameObject():get_Name())))
        end)
    end
    local shellId, axes = b.shell, nil
    local res, err = spawn(a, {
        type = "shell", id = "eldritch_" .. kind, shell = b.file or PB.JOB07_SHELLS, shell_id = shellId, scale_axes = axes,
        cast = b.cast or { mode = "joint", joint = PB.PALM, face = "crosshair", lock_range = PB.LOCK_RANGE },
        scale = b.scale, damage_type = b.damage_type,
        speed = b.speed,
        lifetime = b.lifetime,
    }, aimOpts)
    if not res or not res.record then return note("blast failed: " .. tostring(err)) end
    note("blast spawned: " .. kind .. " shell " .. tostring(shellId))
    res.record.startPos = res.record.pos
    table.insert(blasts, { record = res.record, kind = kind, born = os.clock(), maxRange = maxRange })
    if dbg.boltHold then dbg.boltHold.untilT = math.min(dbg.boltHold.untilT, os.clock() + 0.1) end   -- (3.81: let go after the release)
    if not b.noShape and res.record.param and not params[shellId] then params[shellId] = res.record.param end
    -- every effect the projectile makes is coloured (many never pass a request we see), except the ones set to keep
    -- their own colour ("Coloured effects" list; -1/8/40 and -1/8/43 by default: see-through, they cover the screen)
    if PB.activeVocation == "stormblade" then
        local col = { 0.20, 0.70, 1.0, 1.0 }   -- Bright Electric Lightning Blue
        colour_shell(res.record, col, 6.0, true)
    elseif cfg.blastTint then
        local k = cfg.armBright
        local col = { math.min(1, cfg.armR / 255 * k), math.min(1, cfg.armG / 255 * k), math.min(1, cfg.armB / 255 * k), 1 }
        colour_shell(res.record, col, 6.0)
    end
end

re.on_pre_application_entry("LateUpdateBehavior", function()   -- (3.77) a blast / bolt goes no further than it aims
    for _, b in ipairs(blasts) do
        if b.maxRange and not b.cut then
            pcall(function()
                local r = b.record
                local a0, p = r.startPos, r.pos
                if not (a0 and p) then return end
                local d = math.sqrt((p.x - a0.x) ^ 2 + (p.y - a0.y) ^ 2 + (p.z - a0.z) ^ 2)
                if d < b.maxRange then return end
                b.cut = true
                for _, part in ipairs(r.parts or {}) do
                    if not part.dead and part.shell then pcall(function() part.shell:call("set_RequestKill", true) end) end
                end
                note(("%s ended at %.1f m (its range)"):format(b.kind, d))
            end)
        end
    end
end)
local warmed = false
local function warm_up(a)
    if warmed then return end
    warmed = true
    for _, kind in ipairs({ "tap", "charged", "burst", "small", "wave" }) do
        local b = BLAST[kind] or { shell = kind == "wave" and 6 or 11 }   -- "small": 11's launch flash; "wave": Magike Cut
        local res = spawn(a, { type = "shell", id = "eldritch_warmup", shell = PB.JOB07_SHELLS, shell_id = b.shell,
            cast = { mode = "owner", offset = { 0, -60, 0 } }, cosmetic = true, mute = true,
            scale = 0.01, lifetime = 0.1 })
        if res and res.record and res.record.param and not params[b.shell] then params[b.shell] = res.record.param end
    end
    note("warmed up the blasts")
end

------------------------------------------------------------------------
-- shell colouring (Skill Maker's change_efx2_color): set_Color on every effect player + setRootColor on each container
------------------------------------------------------------------------
local colourJobs = {}
local VIA_COLOR = sdk.find_type_definition("via.Color")
local function via_colour(c)
    local v = ValueType.new(VIA_COLOR)
    v:call(".ctor(via.vec4)", Vector4f.new(c[1], c[2], c[3], c[4] or 1))
    return v
end
function colour_shell(record, c, secs, everyFrame)
    -- everyFrame: the projectile's list is walked every frame (its effects get replaced while it flies - the slash
    -- wave); otherwise 5x a second and the found containers are kept coloured
    table.insert(colourJobs, { record = record, col = via_colour(c), untilT = os.clock() + secs, every = everyFrame, born = os.clock() })
end
PB.colour_shell = colour_shell
local function shell_alive(record)
    local alive = false
    for _, part in ipairs(record.parts or {}) do
        pcall(function()
            local go = part.shell:get_GameObject()
            if go and go:call("get_Valid") ~= false and part.shell:call("get_Valid") ~= false then alive = true end
        end)
    end
    return alive
end
local function colour_container(ce, col)   -- false when the container has finished (then it is not touched)
    local finished = true
    pcall(function() finished = ce:call("get_isFinished") == true end)
    if finished then return false end
    pcall(function()
        local entries = ce.CreatedEffects._entries
        for e = 0, entries:get_size() - 1 do
            local players = entries[e] and entries[e].value
            for q = 0, (players and players._size or 0) - 1 do
                local pl = players._items[q]
                if pl then pl:set_Color(col) end
            end
        end
    end)
    pcall(function() ce:call("setRootColor(via.Color)", col) end)
    return true
end
local function colour_update()
    local now = os.clock()
    local walkAll = now >= (dbg.colourNext or 0)
    if walkAll then dbg.colourNext = now + 0.2 end
    for i = #colourJobs, 1, -1 do
        local j = colourJobs[i]
        j.done = j.done or {}
        j.conts = j.conts or {}
        if now > j.untilT or (now - (j.born or 0) > 0.5 and not shell_alive(j.record)) then   -- (0.5 s: parts still being made)
            table.remove(colourJobs, i)   -- its projectile is gone: nothing of it is touched any more
        else
            -- the containers already found (as in 1.52 - getAllPlayers misses some of the wave's players)
            for k = #j.conts, 1, -1 do
                if not colour_container(j.conts[k], j.col) then table.remove(j.conts, k) end
            end
            if j.every then j.done = {} end   -- coloured anew every frame
            if walkAll or j.every then
                for _, part in ipairs(j.record.parts or {}) do
                    pcall(function()
                        local mgr = part.shell:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
                        local list = mgr.CreatedEffectDataList
                        for k = 0, list._size - 1 do
                            local data = list._items[k]
                            local skip = false
                            pcall(function()
                                local id = data.id
                                local idstr = ("%d/%d/%d"):format(id.DataContainerIndex, id.ContainerID, id.ElementID)
                                skip = (PB.activeVocation ~= "stormblade") and (cfg.noTint[idstr] == true or (dbg.partsIds and dbg.partsIds[idstr]) == true)
                                if not skip and dbg.coloured then dbg.coloured(idstr, "projectile walk", "projectile") end
                                dbg.walkSeen = dbg.walkSeen or {}
                                local r = dbg.walkSeen[idstr] or { n = 0, how = "projectile" }
                                r.n, r.last = r.n + 1, os.clock()
                                dbg.walkSeen[idstr] = r
                            end)
                            local inner = data and not skip and data.list
                            for m = 0, (inner and inner._size or 0) - 1 do
                                local ce = inner._items[m]
                                local ceAddr = ce and ce:get_address()
                                if ce and not j.done[ceAddr] then
                                    j.done[ceAddr] = true
                                    if colour_container(ce, j.col) and not j.every then
                                        pcall(function() j.conts[#j.conts + 1] = ce:add_ref() end)
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
    end
end

local function fire(a, kind)
    local b = BLAST[kind]
    if kind == "charged" then   -- (3.80: facing the enemy it will aim at, from the start of the cast)
        pcall(function()
            local t = dbg.beam and dbg.beam.aim_pick and dbg.beam.aim_pick(a, cfg.boltRangeMul or 0.5)
            dbg.boltTarget = t and { t = t:add_ref(), at = os.clock() } or { at = os.clock() }   -- (3.82: the one pick)
            if t then dbg.bolt_face(a, t, 1.5) end
        end)
    end
    if b.armor then
        a:set_super_armor(true)
        st.armorUntil = os.clock() + b.armor
    end
    local okR = a:request_action(b.action, b.layer)
    note(("fire %s: request %s on layer %d -> %s %s"):format(kind, b.action, b.layer, tostring(okR),
        tostring(a.errors and a.errors.request_action or "")))
    lastFire = os.clock()
    lastKind = kind
    dbg.lastKind, dbg.lastFireT = kind, os.clock()   -- (for code above this point in the file)
    dbg.fxRecReset = true
    st.pending = { kind = kind, asked = os.clock(), started = nil, action = b.action, layer = b.layer }
end

------------------------------------------------------------------------
-- hand glow. A: the .efx file on our own effect player, on an object kept on the arm joint (Dimension Door's way).
-- B: the character's own effect manager plays Mystic Spearhand's effect 25 with the character as parent.
------------------------------------------------------------------------
local glowState = { items = {}, next = 0, res = nil }   -- items: { kind, obj, untilT }
local function glow_clear()
    for _, it in ipairs(glowState.items) do
        pcall(function()
            if it.kind == "A" then it.obj:call("destroy(via.GameObject)", it.obj)
            else it.obj:call("finishAll") end
        end)
    end
    glowState.items = {}
    glowState.next = 0
    glowState.mode = nil
end
re.on_script_reset(glow_clear)
local function make_anchor()
    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_glow", 0)
    go = go:add_ref()
    go:call(".ctor")
    go:set_Name("Pactblade_glow")
    return go
end
local function start_A(a, charging)
    local v = cfg.glowVariant or ""
    if charging and v:find("^h%d+g%d$") then v = v:gsub("g%d$", "g" .. math.floor(cfg.glowLvCharge or 4)) end
    local path = v == "" and GLOW.file
        or ("vfx/effects/pactblade/" .. ((v:find("^pp") or v:find("^h%d+g%d$")) and "pb_arm_" or "pb_arm_no_") .. v .. ".efx")
    glowState.resCache = glowState.resCache or {}   -- (normal + charging files: no reloading between them)
    if glowState.resPath ~= path then glowState.res, glowState.resPath = glowState.resCache[path], glowState.resCache[path] and path or nil end
    if not glowState.res then
        local res = sdk.create_resource("via.effect.EffectResource", path)
        if not res and path ~= GLOW.file then   -- the pak isn't loaded (needs a game restart): the game's own file
            note("arm effect copy not found (" .. path .. ") - restart the game (pak_mods/x0004-PactbladeFx.pak loads at start)")
            path = GLOW.file
            res = sdk.create_resource("via.effect.EffectResource", path)
        end
        if not res then error("effect file not found: " .. path) end
        glowState.res, glowState.resPath = res:add_ref(), path
        glowState.resCache[path] = glowState.res
    end
    local go = make_anchor()
    local holder = glowState.res:create_holder("via.effect.EffectResourceHolder"):add_ref()
    local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
    ep:call("set_Resource", holder)
    pcall(function() ep:call("set_AutoStart", true) end)
    pcall(function() ep:call("set_PlaySpeed", cfg.glowSpeed) end)
    pcall(function() dbg.glowLooped = ep:call("get_Looped") end)
    return go, ep
end
local function ch07_index(a)
    local mgr = a.game_object:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    local conts = mgr.ExternalDataContainers
    for i = 0, conts:get_Count() - 1 do
        local ok, path = pcall(function() return tostring(conts[i].DataContainer:get_Path()) end)
        if ok and path:lower():find("ch07/13_ch07_ns") then return mgr, i end
    end
    return mgr, nil
end
local function start_B(a)
    local mgr, idx = ch07_index(a)
    if not idx then error("Mystic Spearhand's effect file is not on this character") end
    local id = sdk.create_instance("via.effect.script.EffectID")
    id.DataContainerIndex = idx; id.ContainerID = GLOW.id; id.ElementID = GLOW.element
    id.IsContainerIDOnly = false; id.IsElementIDOnly = false
    local c = mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
        id, a.game_object, -1, nil)
    if not c then error("the game returned no effect") end
    c = c:add_ref()
    pcall(function() c:call("setPlaySpeed", cfg.glowSpeed) end)
    return c
end
-- our own light on the arm (via.render.PointLight on an anchor): strength / reach from the menu, colour = the arm's
function glowState.light_update(a)
    local on = cfg.armLight and cfg.glow
    if on then
        on = false
        for _, it in ipairs(glowState.items) do if not it.hidden then on = true end end
    end
    local L = glowState.light
    if not on then
        if L then pcall(function() L.comp:call("set_Enabled", false) end) end
        return
    end
    if not L then
        local go = make_anchor()
        go:set_Name("Pactblade_armlight")
        local comp = go:call("createComponent(System.Type)", sdk.typeof("via.render.PointLight"))
        if not comp then return end
        L = { go = go, comp = comp:add_ref() }
        pcall(function() L.comp:call("set_ShadowEnable", false) end)
        glowState.light = L
    end
    pcall(function()
        local joint = a.game_object:get_Transform():getJointByName(dbg.glowJoint)
        if joint then L.go:get_Transform():set_Position(joint:get_Position()) end
    end)
    local r, g, b = cfg.armR / 255, cfg.armG / 255, cfg.armB / 255
    local gv = tostring(cfg.glowVariant or "")
    local hue = tonumber(gv:match("^ppb?(%d+)$") or gv:match("^h(%d+)g%d$") or "")
    if hue then   -- the baked arm colour's hue, full colour
        local h = (hue % 360) / 60
        local x = 1 - math.abs(h % 2 - 1)
        local t = ({ { 1, x, 0 }, { x, 1, 0 }, { 0, 1, x }, { 0, x, 1 }, { x, 0, 1 }, { 1, 0, x } })[math.floor(h) + 1]
        r, g, b = t[1], t[2], t[3]
    end
    pcall(function()
        L.comp:call("set_Color", Vector3f.new(r, g, b))
        L.comp:call("set_Intensity", cfg.lightLm + 0.0)
        L.comp:call("set_Radius", cfg.lightRadius + 0.0)
        L.comp:call("set_Enabled", true)
    end)
end
re.on_script_reset(function()
    local L = glowState.light
    if L then pcall(function() L.go:call("destroy(via.GameObject)", L.go) end) end
end)
function update_glow(a, now)
    if st.phase == "charging" then glowState.sheathUntil = now + 1.0 end   -- (and a moment after the blast)
    local shown = a:weapon_drawn() or cfg.glowSheathed or now < (glowState.sheathUntil or 0)
    if not (cfg.glow and live.on and shown) then
        if #glowState.items > 0 then glow_clear() end
        dbg.glow = "off"
        return
    end
    local joint
    pcall(function() joint = a.game_object:get_Transform():getJointByName(dbg.glowJoint) end)
    local speed = math.max(0.05, cfg.glowSpeed)
    local every = GLOW.every / speed
    if cfg.freeze then
        -- Each copy of the effect keeps its own effect time (t). Button free: one copy, fast-forwarded to the freeze
        -- moment and frozen there. Button held: the 2.56-3.00 s part (no vibrating air) loops - a relay of copies,
        -- each fast-forwarded to 2.56 s out of sight (anchor 100 m below), shown from there, ended at 3.00 s; the next
        -- one starts early enough to take over without a gap.
        local dt = now - (glowState.lastT or now)
        glowState.lastT = now
        local held = a:button_down("JobSpecialAction")
        local function speed_of(it, sp)
            it.speed = sp
            pcall(function() if it.ep then it.ep:call("set_PlaySpeed", sp) else it.obj:call("setPlaySpeed", sp) end end)
        end
        local function kill(it)
            pcall(function()
                if it.kind == "A" then it.obj:call("destroy(via.GameObject)", it.obj) else it.obj:call("finishAll") end
            end)
        end
        local function new_copy(goal)
            local ok, obj, ep = pcall(dbg.glowMethod == "A" and start_A or start_B, a, glowState.mode == "loop")
            if not ok or not obj then dbg.glow = "method " .. dbg.glowMethod .. " failed: " .. tostring(obj); return nil end
            local it = { kind = dbg.glowMethod, obj = obj, ep = ep, born = now, untilT = math.huge, t = 0, goal = goal, hidden = true }
            speed_of(it, math.max(1.0, goal / PB.GLOW_FF))
            table.insert(glowState.items, it)
            return it
        end
        -- effect time, and keep the copies on the arm (hidden ones below the ground while fast-forwarding)
        for _, it in ipairs(glowState.items) do
            it.t = (it.t or 0) + dt * (it.speed or 0)
            if it.kind == "A" and joint then
                pcall(function()
                    local tr = it.obj:get_Transform()
                    local pos = joint:get_Position()
                    if it.hidden then pos = pos + Vector3f.new(0, -100, 0) end
                    tr:set_Position(pos)
                    tr:set_Rotation(joint:get_Rotation())
                end)
            end
        end
        if not held then
            if glowState.mode ~= "frozen" then
                glow_clear()
                glowState.mode = "frozen"
                glowState.lastT = now
            end
            local it = glowState.items[1]
            if not it then
                if new_copy(cfg.freezeAt) then dbg.glow = "fast-forwarding to the freeze moment" end
            elseif it.speed > 0 and it.t >= cfg.freezeAt then
                speed_of(it, 0.0)
                it.hidden = false
                dbg.glow = ("frozen at %.2f s"):format(cfg.freezeAt)
            end
            return
        end
        -- held
        local L1, L2, LSP = PB.GLOW_LOOP[1], PB.GLOW_LOOP[2], PB.GLOW_LOOP_SPEED
        if cfg.chargeFull then L1, L2, LSP = 0.0, math.max(0.3, cfg.chargeEnd), math.max(0.05, cfg.chargeSpeed) end
        if glowState.mode ~= "loop" then
            glowState.mode = "loop"
            local it = glowState.items[1]
            if cfg.chargeFull then
                glow_clear()                 -- from the start of the effect
                glowState.mode = "loop"
                glowState.lastT = now
            elseif it and it.t >= L1 and it.t < L2 then
                it.hidden = false
                speed_of(it, LSP)  -- the frozen copy plays on into the loop
            else
                glow_clear()
                glowState.mode = "loop"      -- glow_clear resets the mode
                glowState.lastT = now
            end
        end
        for k = #glowState.items, 1, -1 do
            local it = glowState.items[k]
            if it.hidden and it.t >= L1 then
                it.hidden = false
                speed_of(it, LSP)
            elseif not it.hidden and it.t >= L2 then
                kill(it)
                table.remove(glowState.items, k)
            end
        end
        local last = glowState.items[#glowState.items]
        if not last or (not last.hidden and last.t >= L2 - PB.GLOW_FF * LSP) then
            new_copy(L1)
        end
        dbg.glow = ("button held: looping %.2f-%.2f s (%d copies)"):format(L1, L2, #glowState.items)
        return
    end
    for i = #glowState.items, 1, -1 do
        local it = glowState.items[i]
        pcall(function()
            if it.kind == "A" and it.ep then it.ep:call("set_PlaySpeed", speed)
            elseif it.kind == "B" then it.obj:call("setPlaySpeed", speed) end
        end)
        if it.kind == "A" and joint then
            pcall(function()
                local tr = it.obj:get_Transform()
                tr:set_Position(joint:get_Position())
                tr:set_Rotation(joint:get_Rotation())
            end)
        end
        if now > it.untilT then
            pcall(function()
                if it.kind == "A" then it.obj:call("destroy(via.GameObject)", it.obj) else it.obj:call("finishAll") end
            end)
            table.remove(glowState.items, i)
        end
    end
    if now >= glowState.next then
        glowState.next = now + every
        local ok, obj, ep = pcall(dbg.glowMethod == "A" and start_A or start_B, a)
        if ok and obj then
            table.insert(glowState.items, { kind = dbg.glowMethod, obj = obj, ep = ep, untilT = now + every * 1.5 })
            dbg.glow = "method " .. dbg.glowMethod .. ": running"
        else
            dbg.glow = "method " .. dbg.glowMethod .. " failed: " .. tostring(obj)
            glowState.next = now + 5
        end
    end
end

------------------------------------------------------------------------
-- beam: copies of the Eldritch Blast projectile laid along its path (every BEAM.spacing m back to the palm), pinned
-- in place every frame, launch flash removed, harmless; all ended when the blast hits or is gone
------------------------------------------------------------------------
local BEAM = { spacing = 0.4, max = 60, scale = 1.0 }
local mathx = require("DragonCore.game.mathx")
local pieceByGo = {}       -- piece shell GameObject address -> piece
local function beam_kill(b)
    for _, pc in ipairs(b.pieces or {}) do
        for _, c in ipairs(pc.conts) do pcall(function() c:call("killAll") end) end
        pc.conts = {}
        pc.dead = true
    end
    b.beamDone = true
end
local function beam_forget(now)
    for addr, pc in pairs(pieceByGo) do
        if pc.dead and now - (pc.diedAt or now) > 6 then pieceByGo[addr] = nil end
        if pc.dead and not pc.diedAt then pc.diedAt = now end
    end
end
local function beam_update(a, now)
    beam_forget(now)
    for _, b in ipairs(blasts) do
        if b.kind == "tap" and not b.beamDone then
            local r = b.record
            b.pieces = b.pieces or {}
            -- the blast is over: hit something, gone (stopped moving), or old
            if b.hitNow or r.hit or now - b.born > 4 then beam_kill(b)
            elseif r.found and r.pos and r.rot then
                local here = r.pos
                b.beamFrom = b.beamFrom or r.startPos or here
                local moved = (here - (b.beamLast or here)):length()
                if b.beamLast and moved < 0.001 then
                    b.beamStill = (b.beamStill or 0) + 1
                    if b.beamStill > 2 then beam_kill(b) end
                else
                    b.beamStill = 0
                end
                b.beamLast = here
                -- fill from the farthest piece laid so far up to the blast's current position
                local total = (here - b.beamFrom):length()
                b.laid = b.laid or 0
                while not b.beamDone and #b.pieces < BEAM.max and (b.laid + 1) * BEAM.spacing <= total do
                    b.laid = b.laid + 1
                    local back = total - b.laid * BEAM.spacing     -- metres behind the blast
                    local target = here + mathx.rotate(Vector3f.new(0, 0, -back), r.rot)
                    local res = spawn(a, { type = "shell", id = "eldritch_beam", shell = PB.JOB07_SHELLS,
                        shell_id = BLAST.tap.shell, cast = { mode = "previous", offset = { 0, 0, -back } },
                        cosmetic = true, mute = true, scale = BEAM.scale, speed = 0.01, lifetime = 4 }, { from = r })
                    if res and res.record then
                        table.insert(b.pieces, { record = res.record, target = target, conts = {} })
                    else
                        b.beamDone = true
                    end
                end
            end
            -- pin the pieces where they were laid
            for _, pc in ipairs(b.pieces) do
                if not pc.dead and pc.record.found then
                    for _, part in ipairs(pc.record.parts or {}) do
                        pcall(function()
                            if not pc.go then
                                pc.go = part.shell:get_GameObject():get_address()
                                pieceByGo[pc.go] = pc
                            end
                            part.shell:get_GameObject():get_Transform():set_Position(pc.target)
                        end)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- TEST: hand glow colour. (a) the glow effect's own colour slots ("Charge", and Skill Maker's ParticleColor /
-- BaseColor / FireColor / LightningColor) + set_Color; (b) the sleeve glow = a RimLight material mode (category 8,
-- modes 1545610377 / 1704633256): its colour values in the player's MaterialInterpolationRimLight mode lists are
-- changed (Skill Maker's way for blade glows) and put back when the test is off.
------------------------------------------------------------------------
glowCol = { on = false, r = 170, g = 60, b = 255, found = "-", backup = nil,
                  routes = { rim = false, player = true, Charge = false, ParticleColor = false, BaseColor = false,
                             FireColor = false, LightningColor = false } }
do
    local saved = json.load_file(PB.DATA) or {}
    if type(saved.armRoutes) == "table" then
        for k, v in pairs(saved.armRoutes) do
            if type(v) == "boolean" and glowCol.routes[k] ~= nil then glowCol.routes[k] = v end
        end
    end
end
local SLEEVE_MODES = { [1545610377] = true, [1704633256] = true }
local function rim_modes(a)
    local comp = a.game_object:call("getComponent(System.Type)", sdk.typeof("app.MaterialInterpolationRimLight"))
    if not comp then return nil, "no RimLight component" end
    local out, seen = {}, {}
    local function scan(list)
        for i = 0, (list and list._size or 0) - 1 do
            local md = list._items[i]
            local modes = md and md._ModeList
            for k = 0, (modes and modes._size or 0) - 1 do
                local mode = modes._items[k]
                if mode then
                    local v = mode._ModeValue
                    seen[#seen + 1] = v
                    if SLEEVE_MODES[v] then out[#out + 1] = mode end
                end
            end
        end
    end
    pcall(scan, comp.ModeDataList)
    for _, field in ipairs({ "UserDatas", "AddDatas" }) do
        pcall(function()
            local ud = comp[field]
            for i = 0, ud._size - 1 do if ud._items[i] then scan(ud._items[i]._ModeDataList) end end
        end)
    end
    return out, seen
end
local function sleeve_restore()
    if not glowCol.backup then return end
    for _, b in ipairs(glowCol.backup) do pcall(function() b.var._Value = b.orig end) end
    glowCol.backup = nil
end
local function sleeve_apply(a)
    if glowCol.backup then return end
    if os.clock() < (glowCol.retryAt or 0) then return end
    glowCol.retryAt = os.clock() + 1.0
    local modes, seen = rim_modes(a)
    if not modes then glowCol.found = tostring(seen); return end
    glowCol.backup = {}
    local n = 0
    for _, mode in ipairs(modes) do
        local mats = mode._MaterialList
        for i = 0, (mats and mats._size or 0) - 1 do
            local vars = mats._items[i] and mats._items[i]._VariableF4List
            for k = 0, (vars and vars._size or 0) - 1 do
                local var = vars._items[k]
                if var and var._IsColor then
                    local o = var._Value
                    local scale = math.max(o.x, o.y, o.z) > 1.5 and 255 or 1
                    table.insert(glowCol.backup, { var = var, orig = o })
                    local k2 = scale * cfg.armBright / 255
                    var._Value = Vector4f.new(cfg.armR * k2, cfg.armG * k2, cfg.armB * k2, o.w)
                    n = n + 1
                end
            end
        end
    end
    glowCol.found = ("%d sleeve mode(s), %d colour value(s) changed; modes on the component: %d"):format(#modes, n, #seen)
    if n == 0 then glowCol.backup = nil end   -- nothing there yet (still loading): try again in a second
    pcall(json.dump_file, "Pactblade_rimlight_modes.json", seen)
end
local function glow_colour_update(a)
    if not cfg.armTint or not live.on then sleeve_restore(); return end
    if glowCol.routes.rim then pcall(sleeve_apply, a) else sleeve_restore() end
    local k = cfg.armBright
    local r, g, b = cfg.armR / 255, cfg.armG / 255, cfg.armB / 255
    local gv = cfg.glowVariant or ""
    if gv:find("^pp") or gv:find("^h%d+g%d$") then r, g, b = 1, 1, 1 end   -- colour baked into the file: brightness only
    local col = via_colour({ math.min(1, r * k), math.min(1, g * k), math.min(1, b * k), 1 })
    for _, it in ipairs(glowState.items) do
        pcall(function()
            local ep = it.ep
            if not ep then return end
            if glowCol.routes.player then ep:set_Color(col) end
            for _, name in ipairs({ "Charge", "ParticleColor", "BaseColor", "FireColor", "LightningColor" }) do
                if glowCol.routes[name] then
                    local ex = ep:getExternParameter(name)
                    if ex then ex:set_Color(col) end
                end
            end
        end)
    end
end
re.on_script_reset(sleeve_restore)

local update_body
local lastUpdateErr = nil
frame.add("late", "Pactblade.update", function()
    local ok, err = pcall(update_body)
    if not ok and tostring(err) ~= lastUpdateErr then
        lastUpdateErr = tostring(err)
        note("UPDATE ERROR: " .. lastUpdateErr)
    end
end)
update_body = function()
    local a = runtime.player()
    local now = os.clock()
    restore_effects(false)
    for i = #blasts, 1, -1 do if now - blasts[i].born > 15 then table.remove(blasts, i) end end
    if not a or not a:valid() then
        if live.on then note("player not valid: Pactblade off") end
        live.on = false; return
    end
    live.go = a.game_object and a.game_object:get_address()
    live.am = a.action_manager and a.action_manager:get_address()
    live.vsb = vsb_state()
    live.on = ((live.vsb == "picked" and not ignorePick) or forceActive) and a:weapon_job() == 1
    -- (2.13 crash: switching staff -> sword, the warm-up ran while the weapon + its effects were being rebuilt)
    if live.on and not live.onSince then live.onSince = now elseif not live.on then live.onSince = nil end
    if live.on and PB.activeVocation == "stormblade" then
        cfg.nox = false
        cfg.glow = false
        cfg.blastTint = true
        cfg.armTint = false
        cfg.bind = false
        pcall(function()
            if a and a.character and a.character.Locomotion then
                local isRunning = false
                if a:button_down("Dash") then
                    isRunning = true
                else
                    local cc = a.character["<CharaController>k__BackingField"]
                    if cc then
                        local v = cc:call("get_Velocity")
                        if v and (v.x * v.x + v.z * v.z) > 4.84 then -- > 2.2 m/s (running/sprinting)
                            isRunning = true
                        end
                    end
                end
                local rate = isRunning and 1.04 or 1.00
                a.character.Locomotion:call("set_SpeedRate", rate)
            end
        end)
    elseif not live.on or PB.activeVocation ~= "stormblade" then
        pcall(function()
            if a and a.character and a.character.Locomotion then
                a.character.Locomotion:call("set_SpeedRate", 1.0)
            end
        end)
    end
    live.settled = live.on and now - (live.onSince or now) >= 2.0
    pcall(function() live.sc = a.character["<StatusConditionCtrl>k__BackingField"]:get_address() end)
    if live.on then pcall(boon_clear, a) end
    pcall(function()
        live.ctx = a.human["<SkillContext>k__BackingField"]:get_address()
        live.avail = a.human["<SkillAvailability>k__BackingField"]:get_address()
    end)
    live.shieldWorn = false
    pcall(function()
        local left = a.character:get_WeaponAndItemHolder():get_LeftWeapon()
        live.shieldWorn = left ~= nil and left:get_Weapon() ~= nil
    end)
    pcall(update_speed, a)
    if live.settled and not warmed then pcall(warm_up, a) end
    if live.settled or not live.on then
        pcall(update_glow, a, now)
        pcall(glowState.light_update, a)
    end
    if #colourJobs > 0 then pcall(colour_update) end
    pcall(glow_colour_update, a)
    if cfg.beam then
        local okB, errB = pcall(beam_update, a, now)
        if not okB then dbg.beamErr = tostring(errB) end
    end
    local pd = st.pending
    if pd then
        local b = BLAST[pd.kind]
        if not pd.started then
            if a:current_action(pd.layer) == pd.action then
                pd.started = now
                note("animation started: " .. pd.action)
            elseif now - pd.asked > 0.6 then
                st.pending = nil
                note(b.name .. ": the animation did not start (busy with " .. tostring(a:current_action(0)) .. ")")
            else
                -- input buffer: ask again every frame; after 0.2 s try the full-body variant, which can take over
                -- from a full-body attack
                if b.fallback and not pd.fellBack and now - pd.asked > 0.2 then
                    pd.fellBack = true
                    pd.action, pd.layer = b.fallback, b.fallbackLayer
                end
                a:request_action(pd.action, pd.layer)
            end
        elseif now - pd.started >= b.delay then
            st.pending = nil
            spawn_blast(a, pd.kind)
            if b.cancelAfter then st.recover = { from = now + b.cancelAfter, untilT = now + 2.0, action = pd.action } end
        end
    end
    if st.armorUntil and now >= st.armorUntil then
        st.armorUntil = nil
        a:set_super_armor(false)
    end
    local rc = st.recover
    if rc then
        if now > rc.untilT or a:current_action(0) ~= rc.action then
            st.recover = nil
        elseif now >= rc.from and (a:button_pressed("AttackS") or a:button_pressed("AttackL")) then
            st.recover = nil
            a:request_action("NormalLocomotion", 0)
            note("Eldritch Burst recovery cut short for an attack")
        end
    end
    if not live.on then st.phase = "idle"; return end
    -- carrying someone / something (rock, barrel, crate, pawn, enemy): the vocation button is the game's (throw) - no dodge / Eldritch Bolt
    local carrying = false
    if a.is_carrying then
        local ok, c = pcall(a.is_carrying, a)
        if ok and c then carrying = true end
    end
    if not carrying and a.human then
        pcall(function()
            local h = a.human
            if (h.isCarryAnything and h:isCarryAnything())
               or (h.isCarryObject and h:isCarryObject())
               or (h.isCarryCharacter and h:isCarryCharacter())
               or (h.isHold and h:isHold())
               or (h.isCarry and h:isCarry()) then
                carrying = true
            end
        end)
    end
    if not carrying and a.character then
        pcall(function()
            local cc = a.character:call("get_CatchController")
            if cc then
                if cc:get_field("CaughtChara") or cc:get_field("CaughtObject") or cc:get_field("CatchObject") then carrying = true end
            end
            local hc = a.character:call("get_HoldController")
            if hc then
                if hc:get_field("HoldObject") then carrying = true end
            end
        end)
    end
    if not carrying then
        for layer = 0, 1 do
            local cur = tostring(a:current_action(layer) or ""):lower()
            for _, w in ipairs({ "catch", "carry", "lift", "hold", "throw", "grab", "caught", "pick" }) do
                if cur:find(w, 1, true) then carrying = true; break end
            end
            if carrying then break end
        end
    end
    if carrying then
        if st.phase ~= "idle" or st.pending or st.dodgeUntil then note("carrying: vocation button left to the game (throw)") end
        st.phase, st.pending = "idle", nil
        st.dodgeUntil, st.dodgeStarted, st.dodgeYaw = nil, nil, nil
        return
    end
    if dbg.guise and dbg.guise.lev and dbg.guise.lev.active then   -- (4.87 user) no Eldritch Bolt while levitating
        if st.phase ~= "idle" or st.pending then note("levitating: no Eldritch Bolt") end
        st.phase, st.pending = "idle", nil
        return
    end
    if dbg.dd_block() then   -- (i-0.7) Dimension Door's combo: no Eldritch Bolt / dodge from this hold
        if st.phase ~= "idle" or st.pending then note("Dimension Door: Eldritch Bolt cancelled") end
        st.phase, st.pending = "idle", nil
        return
    end
    local down = a:button_down("JobSpecialAction")
    if a:button_pressed("JobSpecialAction") then
        note(("button pressed: phase %s, pending %s, current action %s"):format(st.phase, tostring(st.pending and st.pending.kind),
            tostring(a:current_action(0))))
    end
    if st.dodgeUntil then
        local cur = a:current_action(0)
        if st.dodgeYaw and now - (st.dodgeUntil - 0.3) < 0.1 then face_yaw(a, st.dodgeYaw) end   -- first frames
        if cur == PB.DODGE and not st.dodgeStarted then st.dodgeStarted = true end
        if (cur == PB.DODGE and now - (st.dodgeUntil - 0.3) >= 0.1) or now > st.dodgeUntil then
            if cur ~= PB.DODGE then note("dodge did not start (action " .. tostring(cur) .. ")") end
            st.dodgeUntil, st.dodgeStarted = nil, nil
        elseif cur ~= PB.DODGE then a:request_action(PB.DODGE, 0) end
    end
    if st.phase == "idle" then
        local busyNow, busyCur = dbg.busy_action(a)
        if busyNow and a:button_pressed("JobSpecialAction") then note("vocation button: not now (" .. tostring(busyCur) .. ")") end
        if a:button_pressed("JobSpecialAction") and not st.pending and not busyNow then
            if PB.activeVocation == "stormblade" then
                -- Lightning Step: Pure agile dodge on RB, no palm projectile
                st.dodgeT = now
                st.dodgeUntil = now + 0.3
                st.dodgeYaw = stick_yaw(a)
                if st.dodgeYaw then face_yaw(a, st.dodgeYaw) end
                a:request_action(PB.DODGE, 0)
                note("Stormblade: Lightning Step quickstep executed")
                return
            end
            local win = cfg.burstWindow
            local inSwing = dbg.basicName and a:current_action(0) == dbg.basicName
            local ok = false
            if inSwing and dbg.basicName:find("Heavy") and not dbg.basicName:find("Air") then
                -- Empale on the ground: between two frames of its animation (user: 56.6 - 110.5)
                pcall(function()
                    local fr = a.character.FullBodyLayer:call("get_Frame")
                    ok = fr >= cfg.empaleFrom and fr <= cfg.empaleTo
                end)
            elseif inSwing then
                if dbg.basicName:find("Heavy") then win = cfg.burstWindowEmpaleAir end
                ok = now - (dbg.basicStart or -100) < win
            end
            local curT = tostring(a:current_action(0) or "")
            if not ok and curT:find("^Job01_TuskToss") then
                pcall(function()
                    local fr = a.character.FullBodyLayer:call("get_Frame")
                    ok = fr >= cfg.tuskFrom and fr <= cfg.tuskTo
                end)
            end
            if ok then fire(a, "burst")
            else st.phase = "holding"; st.t0 = now end
        end
    elseif st.phase == "holding" then
        local curA = tostring(a:current_action(0) or "")
        if not down and curA == PB.DODGE and now - (st.dodgeT or -10) < PB.DODGE_LOCK then
            st.phase = "idle"   -- still in the last dodge: this tap does nothing
        elseif not down and curA:find("^Job01_") and curA:find("Heavy") and not empale_recovering(a, curA) then
            st.phase = "idle"   -- no dodge out of Empale (user); only its Burst window
        elseif not down and curA:find("^Job01_TuskToss") and not tusk_recovering(a) then
            st.phase = "idle"   -- no dodge out of Tusk Toss until after its Burst window (user)
        elseif not down and not dbg.can_dodge(a) then
            st.phase = "idle"
            local _, why = dbg.can_dodge(a)
            note("dodge refused: the game doesn't allow it now (" .. tostring(why) .. ")")
        elseif not down then
            st.phase = "idle"
            st.dodgeT = now
            st.dodgeUntil = now + 0.3   -- (re-asked until it plays)
            st.dodgeYaw = stick_yaw(a)
            if st.dodgeYaw then face_yaw(a, st.dodgeYaw) end
            a:request_action(PB.DODGE, 0)
            note(("released after %.2f s: dodge"):format(now - st.t0))
        elseif now - st.t0 >= PB.HOLD_SEC then
            st.phase = "charging"
            note("charging... (held " .. PB.HOLD_SEC .. " s)")
            if dbg.rim_glow then pcall(dbg.rim_glow, a, true, 0.3) end   -- (user: a 0.3 s pulse = "charged")
        end
    elseif st.phase == "charging" then
        if not down then
            st.phase = "idle"
            if dbg.busy_action(a) then note("Eldritch Bolt: not now (" .. tostring(a:current_action(0)) .. ")"); return end
            fire(a, "charged")
        end
    end
end

-- the bolt animations fire Mystic Spearhand's own bolt (flinch / hold): those projectiles are blocked
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ShellManager"):get_method(
        "requestCreateShell(via.GameObject, via.vec3, via.Quaternion, app.ShellRequest.ShellCreateInfo, app.ShellParamData, app.ShellRequest.EventCreateShellSuccess, app.ShellRequest.EventBeforeShellInstantiate)"),
        function(args)
            if not live.on or ourSpawn then return end
            local beamAir = dbg.beam and dbg.beam.stage == "air"
            if not beamAir and os.clock() - lastFire > 1.5 then return end
            local owner = sdk.to_managed_object(args[3])
            if owner and owner:get_address() == live.go and beamAir then
                dbg.suppressed = dbg.suppressed + 1
                return sdk.PreHookResult.SKIP_ORIGINAL   -- (3.40: the air beam's animation fires no bolt of its own)
            end
            if owner and owner:get_address() == live.go then
                if (lastKind == "charged" or lastKind == "burst") and cfg.bind and PB.activeVocation ~= "stormblade" then
                    dbg.bindShots = (dbg.bindShots or 0) + 1
                    note("Forbeding Bolt let through (" .. (lastKind == "burst" and "Eldritch Burst" or "Eldritch Bolt") .. ")")
                    return
                end
                dbg.suppressed = dbg.suppressed + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
end)

------------------------------------------------------------------------
-- explosion size: effects that our blast projectiles request (hit, hit on terrain, finish) are scaled down
------------------------------------------------------------------------
local CHARGE_CLOUD = 160   -- Mystic Spearhand's charge cloud in the common effect file (ch00, index 0)
local clouds = {}          -- { c, born }: charge clouds being kept small
local function scale_clouds()
    local now = os.clock()
    for i = #clouds, 1, -1 do
        local cl = clouds[i]
        local alive = now - cl.born < 10
        local k = (cl.hideUntil and now < cl.hideUntil) and 0.0 or (cl.k or cfg.boom)
        pcall(function()
            if cl.c:call("get_isFinished") then alive = false; return end
            cl.c:call("setUniformScale", k)
            local list = cl.c:call("getAllPlayers")
            local n = list and list:call("get_Count") or 0
            for j = 0, n - 1 do
                local pl = list:call("get_Item", j)
                local tr = pl and pl:call("get_GameObject"):get_Transform()
                if tr then tr:set_LocalScale(Vector3f.new(k, k, k)) end
            end
        end)
        if not alive then table.remove(clouds, i) end
    end
end
re.on_pre_application_entry("LateUpdateBehavior", function() if #clouds > 0 then pcall(scale_clouds) end end)
-- the blast's two see-through layers: their first 0.1 s is not shown (user; tinted they cover the screen)
local BLAST_TRIM = {}   -- (1.01 tried hiding the first 0.1 s of -1/8/40 / 43: still covered the screen)
local function trim_add(rv, secs)
    pcall(function()
        local c = sdk.to_managed_object(rv)
        if not c then return end
        local addr = c:get_address()
        for _, cl in ipairs(clouds) do
            if cl.addr == addr or (cl.c and cl.c:get_address() == addr) then
                cl.hideUntil = cl.hideUntil or (os.clock() + secs)
                return
            end
        end
        c:call("setUniformScale", 0.0)
        table.insert(clouds, { c = c:add_ref(), born = os.clock(), k = 1.0, hideUntil = os.clock() + secs, addr = addr })
    end)
end
-- blast colour: the arm glow's colour (sliders) on every effect player of the collected effects
local TINT_WINDOW = 2.0   -- seconds after a blast press in which the player's own new effects are coloured too
local tints = {}          -- { c, born }
local tintSeen = {}       -- container address -> true
local function blast_colour()
    if PB.activeVocation == "stormblade" then
        return via_colour({ 0.20, 0.70, 1.0, 1.0 })   -- Bright Electric Lightning Blue
    end
    local k = cfg.armBright
    return via_colour({ math.min(1, cfg.armR / 255 * k), math.min(1, cfg.armG / 255 * k), math.min(1, cfg.armB / 255 * k), 1 })
end
local function slash_colour()
    if PB.activeVocation == "stormblade" then
        return via_colour({ 0.20, 0.70, 1.0, 1.0 })   -- Bright Electric Lightning Blue
    end
    local k = cfg.slashBright
    return via_colour({ math.min(1, cfg.slashR / 255 * k), math.min(1, cfg.slashG / 255 * k), math.min(1, cfg.slashB / 255 * k), 1 })
end
local WHITE
local function tint_update()
    local now = os.clock()
    local col = blast_colour()
    for i = #tints, 1, -1 do
        local t = tints[i]
        if t.id and cfg.noTint[t.id] then
            WHITE = WHITE or via_colour({ 1, 1, 1, 1 })
            pcall(function() t.c:call("setRootColor(via.Color)", WHITE) end)
            pcall(function()
                local list = t.c:call("getAllPlayers")
                for j = 0, (list and list:call("get_Count") or 0) - 1 do list:call("get_Item", j):set_Color(WHITE) end
            end)
            tintSeen[t.addr or 0] = nil
            table.remove(tints, i)
            goto continue
        end
        local alive = now - t.born < 10
        pcall(function()
            if t.c:call("get_isFinished") then alive = false; return end
            local tc = t.slash and slash_colour() or col
            pcall(function() t.c:call("setRootColor(via.Color)", tc) end)
            local list = t.c:call("getAllPlayers")
            local n = list and list:call("get_Count") or 0
            for j = 0, n - 1 do
                local pl = list:call("get_Item", j)
                if pl then pl:set_Color(tc) end
            end
        end)
        if not alive then tintSeen[t.addr or 0] = nil; table.remove(tints, i) end
        ::continue::
    end
end
local function bind_follow()
    if not bindBolt.go then return end
    local now = os.clock()
    if now - bindBolt.born > 4 then bindBolt.go, bindBolt.addr = nil, nil; return end
    if lastKind == "burst" then   -- Burst: the bolt goes straight onto the nearest enemy in front (its hit area is tiny)
        if bindBolt.tgtBorn ~= bindBolt.born then
            bindBolt.tgtBorn, bindBolt.tgt = bindBolt.born, nil
            pcall(function() bindBolt.tgt = combo.pick_target(runtime.player(), 4, 100) end)
        end
        if not bindBolt.tgt or now - bindBolt.born > 0.8 then return end
        pcall(function()
            local q = bindBolt.tgt:get_GameObject():get_Transform():get_Position()
            bindBolt.go:get_Transform():set_Position(Vector3f.new(q.x, q.y + 1.0, q.z))
        end)
        return
    end
    local b
    for k = #blasts, 1, -1 do
        if blasts[k].kind == "charged" and blasts[k].born >= bindBolt.born - 0.5 then b = blasts[k]; break end
    end
    if not b or b.boltDone then return end
    local ok = pcall(function()
        local tr = b.record.parts[1].shell:get_GameObject():get_Transform()
        local btr = bindBolt.go:get_Transform()
        btr:set_Position(tr:get_Position())
        btr:set_Rotation(tr:get_Rotation())
        b.boltLast = now
    end)
    -- our blast is gone (hit or ended): the bolt stays where it was last put, right at the target
    if not ok and b.boltLast then b.boltDone = true end
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if live.on and cfg.bind then pcall(bind_follow) end
    if #tints > 0 then
        if cfg.blastTint then pcall(tint_update) else tints = {} end
    end
end)
local blast_shell_info
local function effect_id_of(args, how)
    local idstr = how
    pcall(function()
        if how == "requestEffect" or how == "requestEffectInternal" then
            local id = sdk.to_managed_object(args[3])
            idstr = ("%d/%d/%d"):format(id.DataContainerIndex, id.ContainerID, id.ElementID)
        elseif how == "requestEffectFromFsmOrSequence" or how == "requestEffectFromFsm" then
            idstr = ("fsm %d/%d"):format(sdk.to_int64(args[3]) & 0xFFFFFFFF, sdk.to_int64(args[4]) & 0xFFFFFFFF)
        end
    end)
    return idstr
end
local comboFx = { seen = {}, list = {} }
dbg.rec = { on = false, secs = 8, list = {}, info = "-", near = false, scs = {} }
function dbg.rec_add(e)
    local r = dbg.rec
    if not r.on then return end
    e.t = ("%.2f"):format(os.clock() - r.t0)
    r.list[#r.list + 1] = e
    dbg.save("Pactblade_chant_record.json", r.list)
end
-- body material requests (whole-body glows: rim light, basic ...) of the player while recording
pcall(function()
    local td = sdk.find_type_definition("app.MaterialInterpolationRequestManager")
    for _, m in ipairs(td:get_methods()) do
        local nm = m:get_name()
        local okP, pts = pcall(function() return m:get_param_types() end)
        local generic = false
        pcall(function() for _, t in ipairs(pts) do if t:get_full_name():find("!!") then generic = true end end end)
        if okP and not generic and (nm == "requestMaterialMode" or nm == "requestMaterialModeSub" or nm == "requestMIMode") then
            pcall(sdk.hook, m, function(args)
                if not dbg.rec.on then return end
                pcall(function()
                    local pl = runtime.player()
                    local go = sdk.to_managed_object(args[2]):call("get_GameObject")
                    if not pl or go:get_address() ~= pl.game_object:get_address() then return end
                    local list = ""
                    pcall(function() list = pts[3] and pts[3]:get_full_name():match("<app%.MaterialInterpolation(%w+)>") or "" end)
                    dbg.rec_add({ material = sdk.to_int64(args[3]) & 0xFFFFFFFF, category = sdk.to_int64(args[4]) & 0xFFFFFFFF,
                                  via = nm, list = list })
                end)
            end, function(r) return r end)
        end
    end
end)
local function combo_rec(args, how)
    if dbg.rec.on then
        pcall(function()
            local go = sdk.to_managed_object(args[2]):call("get_GameObject")
            local pl = runtime.player()
            if not pl or go:get_address() ~= pl.game_object:get_address() then return end
            local idd = effect_id_of(args, how)
            local e = { effect = idd, how = how }
            pcall(function()   -- which effect file set the container index points at
                local idx = tonumber(tostring(idd):match("^(%-?%d+)/"))
                if idx and idx >= 0 then
                    local mgr = pl.game_object:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
                    e.set = tostring(mgr.ExternalDataContainers[idx].DataContainer:get_Path())
                end
            end)
            dbg.rec_add(e)
        end)
    end
    if dbg.fxRecReset then dbg.fxRecReset = false; comboFx.seen, comboFx.list = {}, {}; combo.t0 = os.clock() end
    if combo.stage == 0 and os.clock() - lastFire > 4 then return end
    pcall(function()
        local go = sdk.to_managed_object(args[2]):call("get_GameObject")
        local by = go:get_address() == live.go and "player" or tostring(go:get_Name())
        local idd = effect_id_of(args, how)
        local key = combo.stage .. by .. idd
        if comboFx.seen[key] then return end
        comboFx.seen[key] = true
        table.insert(comboFx.list, { part = combo.stage, by = by, id = idd, how = how, t = ("%.2f"):format(os.clock() - (combo.t0 or 0)) })
        dbg.save("Pactblade_fx_record.json", comboFx.list)
    end)
end
local MISTY_FX = { ["13/22/0"] = true, ["13/22/3"] = true, ["13/23/1"] = true, ["13/22/15"] = true, ["13/22/10"] = true }   -- Quik Fot's own leap effects
local BLAST_DROP = {}   -- blast effects not played at all (none now; 1.01: -1/8/40 + 43 only lose their first 0.1 s)
local function blast_trim(args, how)
    if not live.on or #blasts == 0 or not (how == "requestEffect" or how == "requestEffectInternal") then return false end
    local secs = false
    pcall(function()
        local t = BLAST_TRIM[effect_id_of(args, how)]
        if not t then return end
        if blast_shell_info(sdk.to_managed_object(args[2]):call("get_GameObject"):get_address()) then secs = t end
    end)
    return secs
end
-- the blast's two see-through effects (-1/8/40, -1/8/43): tinted whole they cover the screen. Here each part of them
-- can be chosen: its emitters (emit mask bits), its colour slots (extern parameters) and its colour groups - which
-- are coloured and which are drawn at all. Applied to the real blasts and to the effect player.
local parts = { ids = { ["-1/8/40"] = true, ["-1/8/43"] = true, ["-1/10/1"] = true, ["-1/10/3"] = true, ["-1/10/6"] = true },
                live = {}, info = {}, files = {} }
-- the same two effect files sit under other numbers for the other projectile versions (13_ch07_cs_Ref.pfb, Gungnir
-- container 8): launch = cs_008_10 / 11 / 110 / 111, explosion = cs_008_30 / 31 / 130 / 131. All follow 40 / 43.
local PART_ALIAS = {}
for _, n in ipairs({ 0, 10, 40, 50, 100, 110 }) do PART_ALIAS["-1/8/" .. n] = "-1/8/40" end
for _, n in ipairs({ 3, 13, 43, 53, 103, 113 }) do PART_ALIAS["-1/8/" .. n] = "-1/8/43" end
for _, n in ipairs({ 1, 3, 6 }) do PART_ALIAS["-1/10/" .. n] = "-1/10/" .. n end   -- the Eldritch Slash wave
dbg.partsIds = PART_ALIAS
dbg.parts = parts
cfg.parts = cfg.parts or {}
do
    local saved = json.load_file(PB.DATA) or {}
    if type(saved.parts) == "table" then
        for id, p in pairs(saved.parts) do if type(p) == "table" and parts.ids[id] then cfg.parts[id] = p end end
    end
end
local PART_DEFAULTS = {
    ["-1/8/40"] = { mode = "ours", variant = "e285" },   -- our purple copy (colour in the file: no veil)
    ["-1/8/43"] = { mode = "ours", variant = "e285" },
    ["-1/10/1"] = { mode = "ours", variant = "h285", follow = true },   -- the wave flies: our copy goes with it
    ["-1/10/3"] = { mode = "ours", variant = "h285" },
    ["-1/10/6"] = { mode = "ours", variant = "h285" },
}
local function part_cfg(id)
    local p = cfg.parts[id]
    if not p then
        local d = PART_DEFAULTS[id] or {}
        p = { mode = d.mode or "extern", variant = d.variant, follow = d.follow or false, extern = {}, groups = {}, mask = nil }
        for k, v in pairs(d.extern or {}) do p.extern[k] = v end
        cfg.parts[id] = p
    end
    p.extern, p.groups = p.extern or {}, p.groups or {}
    return p
end
-- what the effect is made of (read once per effect, from its first copy)
function parts.read(c, id)
    if parts.info[id] then return end
    local out = { players = {} }
    pcall(function()
        local list = c:call("getAllPlayers")
        for q = 0, (list and list:call("get_Count") or 0) - 1 do
            local pl = list:call("get_Item", q)
            local pi = { mask = 0, maskName = "", emitters = 0, extern = {}, groups = {}, groupNames = {} }
            pcall(function() pi.mask = pl:call("get_EmitMaskBit") end)
            pcall(function() pi.maskName = tostring(pl:call("get_MaskName")) end)
            pcall(function() pi.emitters = pl:call("get_EmitterInstanceNum") end)
            for _, getter in ipairs({ function() return pl:call("get_Resource"):call("get_ResourcePath") end,
                                      function() return pl:call("get_Resource"):call("get_Path") end,
                                      function() return pl:call("get_ResourcePath") end }) do
                if not pi.file then
                    local ok, v = pcall(getter)
                    if ok and v then pi.file = tostring(v) end
                end
            end
            pcall(function()
                local tr = pl:call("get_GameObject"):get_Transform()
                local q = tr:get_Position()
                pi.go = tostring(pl:call("get_GameObject"):get_Name())
                pi.parent = tostring(tr:call("get_Parent") and tr:call("get_Parent"):get_GameObject():get_Name())
            end)
            pcall(function()
                for i = 0, pl:call("getExternParametersCount") - 1 do
                    local ep = pl:call("getExternParameters", i)
                    pi.extern[#pi.extern + 1] = tostring(ep:call("get_Name"))
                end
            end)
            pcall(function()
                for i = 0, pl:call("getGroupParametersCount") - 1 do
                    pi.groups[#pi.groups + 1] = tostring(pl:call("getGroupParameters", i):call("get_Name"))
                end
            end)
            pcall(function()
                for i = 0, pl:call("getGroupNamesCount") - 1 do
                    pi.groupNames[#pi.groupNames + 1] = tostring(pl:call("getGroupNames", i):call("get_Name"))
                end
            end)
            out.players[#out.players + 1] = pi
        end
    end)
    parts.info[id] = out
    local all = json.load_file("Pactblade_parts.json") or {}
    all[id] = out
    pcall(json.dump_file, "Pactblade_parts.json", all)
end
-- this copy, as the settings say
local GROUP_WAYS = { "keep", "clear", "empty", "off" }
function parts.groups_off(c, way)
    if way == "clear" then pcall(function() c:call("clearGroupName") end)
    else
        pcall(function()
            local list = c:call("getAllPlayers")
            for q = 0, (list and list:call("get_Count") or 0) - 1 do
                local pl = list:call("get_Item", q)
                if way == "empty" then pl:call("setGroupNamesCount", 0)
                elseif way == "off" then pl:call("set_GroupEnabled", false) end
            end
        end)
    end
end
local function part_colour(p)
    if PB.activeVocation == "stormblade" then
        return via_colour({ 0.20, 0.70, 1.0, 1.0 })
    end
    local k = cfg.armBright * (p.strength or 1.0)
    return via_colour({ math.min(1, cfg.armR / 255 * k), math.min(1, cfg.armG / 255 * k), math.min(1, cfg.armB / 255 * k), 1 })
end
function parts.apply(c, id)
    local p = part_cfg(id)
    local col = part_colour(p)
    if PB.activeVocation == "stormblade" then
        pcall(function() c:call("setRootColor(via.Color)", col) end)
    end
    if p.group and p.group ~= "keep" then parts.groups_off(c, p.group) end
    pcall(function()
        local list = c:call("getAllPlayers")
        for q = 0, (list and list:call("get_Count") or 0) - 1 do
            local pl = list:call("get_Item", q)
            if p.mask then pcall(function() pl:call("set_EmitMaskBit", p.mask) end) end
            if p.mode == "whole" or PB.activeVocation == "stormblade" then
                pl:set_Color(col)
            elseif p.mode == "extern" then
                pcall(function()
                    for i = 0, pl:call("getExternParametersCount") - 1 do
                        local ep = pl:call("getExternParameters", i)
                        if p.extern[tostring(ep:call("get_Name"))] then ep:call("set_Color", col) end
                    end
                end)
            elseif p.mode == "groups" then
                pcall(function()
                    for i = 0, pl:call("getGroupParametersCount") - 1 do
                        local gp = pl:call("getGroupParameters", i)
                        if p.groups[tostring(gp:call("get_Name"))] then gp:call("set_Color", col) end
                    end
                end)
            end
        end
    end)
    if p.mode == "groups" then
        for name, on in pairs(p.groups) do
            if on then pcall(function() c:call("setGroupColor(System.String, via.Color)", name, col) end) end
        end
    end
end
-- our edited copies (pak_mods/x0002-PactbladeFx-variants.pak): each variant shrinks one layer to a tiny real mesh
-- (debris / wood chip / hook) - to find the layer that covers the screen. 40's all have its light + blur at 0.
local OUR_VARIANTS = {
    ["-1/8/40"] = {
                    { "v0", "light + blur off only" }, { "v1", "+ spiral 1 off" }, { "v2", "+ shockwave off" },
                    { "v3", "+ magic shape off" }, { "v4", "+ cone off" }, { "v5", "+ spiral 2 off" },
                    { "v6", "+ ALL five shapes off" }, { "t1", "blast colour baked into the file", true },
                    { "c285", "purple (baked)", true }, { "c300", "pink-purple (baked)", true }, { "c315", "pink (baked)", true },
                    { "d285", "purple + light", true }, { "d300", "pink-purple + light", true }, { "d315", "pink + light", true },
                    { "e285", "purple, all", true }, { "e300", "pink-purple, all", true }, { "e315", "pink, all", true } },
    ["-1/8/43"] = {
                    { "w0", "unchanged copy" }, { "w1", "heat haze 1 off" }, { "w2", "heat haze 2 off" },
                    { "w3", "both heat hazes off" }, { "t1", "blast colour baked into the file", true },
                    { "t2", "baked colour, no rock / snow / ice debris (x0006 pak)", true },
                    { "c285", "purple (baked, no debris)", true }, { "c300", "pink-purple (baked, no debris)", true },
                    { "c315", "pink (baked, no debris)", true },
                    { "d285", "purple", true }, { "d300", "pink-purple", true }, { "d315", "pink", true },
                    { "e285", "purple, all", true }, { "e300", "pink-purple, all", true }, { "e315", "pink, all", true } },
    ["-1/10/1"] = { { "h285", "purple", true }, { "h300", "pink-purple", true }, { "h315", "pink", true } },
    ["-1/10/3"] = { { "h285", "purple", true }, { "h300", "pink-purple", true }, { "h315", "pink", true } },
    ["-1/10/6"] = { { "h285", "purple", true }, { "h300", "pink-purple", true }, { "h315", "pink", true } },
}
local OUR_FILES = setmetatable({}, { __index = function(_, id)
    local vs = OUR_VARIANTS[id]
    if not vs then return nil end
    local p = cfg.parts and cfg.parts[id]
    local v = (p and p.variant) or vs[1][1]
    -- 3.15 fog test (user: Eldritch Bolt's lingering fog 70 % smaller): one explosion layer at 30 % per test copy
    -- (pak_mods/x0007-PactbladeFx-fogtest.pak: pb_43_e<hue>f<layer>)
    if id == "-1/8/43" and dbg.fogLayer and tostring(v):match("^e%d+$") then v = v .. "f" .. dbg.fogLayer end
    local tail = id:match("^%-1/8/(%d+)$") or id:gsub("^%-1/", ""):gsub("/", "_")   -- 40 / 43, or 10_1 / 10_3 / 10_6
    return ("vfx/effects/pactblade/pb_%s_%s.efx"):format(tail, v)
end })
parts.ours = {}
function parts.play_ours(id, at, rot, creator)
    local path = OUR_FILES[id]
    if not path then return false end
    parts.res = parts.res or {}
    if not parts.res[path] then
        local r = sdk.create_resource("via.effect.EffectResource", path)
        if not r then note("our effect file not found: " .. path); return false end
        parts.res[path] = r:add_ref()
    end
    local go = make_anchor()
    local tr = go:get_Transform()
    tr:set_Position(at)
    if rot then tr:set_Rotation(rot) end
    local holder = parts.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref()
    local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
    ep:call("set_Resource", holder)
    pcall(function() ep:call("set_AutoStart", true) end)
    local baked = path:find("_x%d+%.efx$") ~= nil or path:find("_e%d+f%d+%.efx$") ~= nil   -- (the layer test copies: baked purple)
    for _, v in ipairs(OUR_VARIANTS[id] or {}) do
        if path:find("_" .. v[1] .. ".efx", 1, true) and v[3] then baked = true end
    end
    local follow = creator ~= nil and part_cfg(id).follow == true
    pcall(function() if creator then tr:set_LocalScale(creator:get_Transform():call("get_Scale")) end end)
    if id == "-1/8/40" then   -- (1.0.1 user: the launch flash smaller - Bolt 30 %, Burst 50 %; the air Blast: airLaunchScale)
        local k = 0.5
        pcall(function()
            local bi = creator and blast_shell_info(creator:get_address())
            if bi and bi.kind == "charged" then k = 0.3 end
        end)
        pcall(function() local v = tr:get_LocalScale(); tr:set_LocalScale(Vector3f.new(v.x * k, v.y * k, v.z * k)) end)
    end
    table.insert(parts.ours, { go = go, ep = ep, creator = creator, untilT = os.clock() + (follow and 30.0 or 3.0), id = id,
                               baked = baked, follow = follow, born = os.clock() })
    return true
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if #parts.ours == 0 then return end
    local now = os.clock()
    local col = blast_colour()
    for i = #parts.ours, 1, -1 do
        local o = parts.ours[i]
        -- 3.17 fog test (user: the fog stays with layer sk0 hidden): our explosion copy cut off dbg.fogCut s after it starts
        if o.id == "-1/8/43" and (dbg.fogCut or 0) > 0 and not o.cut and now - (o.born or now) >= dbg.fogCut then
            o.cut = true
            pcall(function() o.ep:call("set_Action", sdk.find_type_definition("via.effect.PlayerAction"):get_field("Kill"):get_data(nil)) end)
            note(("explosion copy cut off after %.1f s (fog test)"):format(dbg.fogCut))
        end
        if now > o.untilT then
            pcall(function() o.go:call("destroy(via.GameObject)", o.go) end)
            table.remove(parts.ours, i)
        else
            pcall(function()
                if o.creator and (o.follow or part_cfg(o.id).follow) then
                    local alive = false
                    pcall(function() alive = o.creator:call("get_Valid") ~= false and o.creator:get_Transform() ~= nil end)
                    if not alive then
                        if o.untilT > now + 0.3 then o.untilT = now + 0.3 end   -- the wave is gone: ours ends with it
                        return
                    end
                    if o.id == "-1/10/1" and not o.killed then   -- the wave ends where its look ends (or at the distance limit)
                        local st = 0
                        pcall(function() st = o.ep:call("get_State") & 0xFFFFFFFF end)
                        local em = -1
                        pcall(function() em = o.ep:call("get_EmitterInstanceNum") end)
                        local here = o.creator:get_Transform():get_Position()
                        o.from = o.from or here
                        o.born2 = o.born2 or now
                        local dist = (here - o.from):length()
                        if st == 2 then o.ran = true end
                        if em and em > 0 then o.seenEmit = true end
                        o.noEmit = (o.seenEmit and em == 0) and (o.noEmit or 0) + 1 or 0
                        if (o.ran and (st == 0 or st == 3 or st == 4 or st == 5)) or o.noEmit >= 3 or dist >= (cfg.slashHitRange or 28) then
                            o.killed = true
                            pcall(function()
                                local sh = o.creator:call("getComponent(System.Type)", sdk.typeof("app.Shell"))
                                local mc = o.creator:call("getComponent(System.Type)", sdk.typeof("app.ShellAdditionalJob07SubNormalAttackShell"))
                                local ow = sh and sh:get_field("<Owner>k__BackingField")
                                if mc and ow and ow:get_address() == live.go then
                                    dbg.slashKilled = dbg.slashKilled or {}
                                    dbg.slashKilled[o.creator:get_address()] = now + 0.5   -- (its end effect is dropped)
                                    sh:call("set_RequestKill", true)
                                    note(("Eldritch Slash: wave ended at %.1f m (state %d, emitters %d)"):format(dist, st, em or -1))
                                end
                            end)
                        end
                    end
                    local ctr, tr = o.creator:get_Transform(), o.go:get_Transform()
                    tr:set_Position(ctr:get_Position())
                    tr:set_Rotation(ctr:get_Rotation())
                    pcall(function() tr:set_LocalScale(ctr:call("get_Scale")) end)
                end
            end)
            if cfg.blastTint and not o.baked then pcall(function() o.ep:set_Color(part_colour(part_cfg(o.id))) end) end
        end
    end
end)
function parts.add(rv, id)
    pcall(function()
        local c = sdk.to_managed_object(rv)
        if not c then return end
        local addr = c:get_address()
        for _, e in ipairs(parts.live) do if e.addr == addr then return end end
        c = c:add_ref()
        parts.read(c, id)
        if part_cfg(id).mode == "hidden" and parts.files[id] then c:call("killAll"); return end   -- not played at all
        if PB.activeVocation ~= "stormblade" and part_cfg(id).mode == "ours" and OUR_FILES[id] then
            local at, rot, creator
            pcall(function()
                creator = c:get_field("Creator")
                if creator then creator = creator:add_ref() end
                local tr = creator:get_Transform()
                at, rot = tr:get_Position(), tr:get_Rotation()
            end)
            if at and parts.play_ours(id, at, rot, creator) then
                c:call("killAll")
                note("effect " .. id .. ": our edited copy plays instead (" .. tostring(OUR_FILES[id]) .. ")")
                return
            end
        end
        parts.apply(c, id)
        table.insert(parts.live, { c = c, id = id, born = os.clock(), addr = addr })
    end)
end
function parts.wanted(args, how)
    if not live.on or #blasts == 0 or not (how == "requestEffect" or how == "requestEffectInternal") then return false end
    local id = false
    pcall(function()
        local idstr = PART_ALIAS[effect_id_of(args, how)]
        if not idstr then return end
        if blast_shell_info(sdk.to_managed_object(args[2]):call("get_GameObject"):get_address()) then id = idstr end
    end)
    return id
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if #parts.live == 0 then return end
    local now = os.clock()
    for i = #parts.live, 1, -1 do
        local e = parts.live[i]
        local dead = now - e.born > 10
        pcall(function() if e.c:call("get_isFinished") then dead = true end end)
        if not dead and not parts.files[e.id] then
            pcall(function()
                local list = e.c:call("getAllPlayers")
                local paths = {}
                for q = 0, (list and list:call("get_Count") or 0) - 1 do
                    local pl = list:call("get_Item", q)
                    local ready = true
                    pcall(function() ready = pl:call("get_ReadyResource") end)
                    local path
                    pcall(function() path = pl:call("get_ResourcePath") end)
                    if ready and path and tostring(path) ~= "" then paths[#paths + 1] = tostring(path) end
                end
                if #paths > 0 then
                    parts.files[e.id] = paths
                    note("effect " .. e.id .. " plays " .. table.concat(paths, ", "))
                    pcall(json.dump_file, "Pactblade_parts_files.json", parts.files)
                end
            end)
        end
        if dead then table.remove(parts.live, i) else parts.apply(e.c, e.id) end
    end
end)
pcall(function()
    local td = sdk.find_type_definition("app.WwiseContainerApp")
    for _, m in ipairs(td:get_methods()) do
        local name = m:get_name()
        if name == "trigger" or name == "triggerLogLess" or name == "triggerWithSyncSpace" then
            sdk.hook(m, function(args)
                if dbg.rec.on then
                    pcall(function()
                        local pl = runtime.player()
                        local cgo = sdk.to_managed_object(args[2]):get_GameObject()
                        if not pl then return end
                        local objName
                        if cgo:get_address() ~= pl.game_object:get_address() then
                            if not dbg.rec.near then return end
                            local p1, p2 = cgo:get_Transform():get_Position(), pl.game_object:get_Transform():get_Position()
                            local dx, dy, dz = p1.x - p2.x, p1.y - p2.y, p1.z - p2.z
                            if dx * dx + dy * dy + dz * dz > 100 then return end
                            objName = tostring(cgo:get_Name())
                        end
                        local id
                        pcall(function() id = sdk.to_managed_object(args[3]):call("get_TriggerId") end)
                        if not id then id = sdk.to_int64(args[3]) & 0xFFFFFFFF end
                        dbg.rec_add({ sound = id, via = name, obj = objName })
                    end)
                end
                if not live.on then return end
                if combo.stage == 0 and os.clock() - (combo.endT or -100) > 3 then return end
                pcall(function()
                    local id
                    pcall(function() id = sdk.to_managed_object(args[3]):call("get_TriggerId") end)
                    if not id then id = sdk.to_int64(args[3]) & 0xFFFFFFFF end
                    local key = "snd" .. combo.stage .. tostring(id)
                    if comboFx.seen[key] then return end
                    comboFx.seen[key] = true
                    table.insert(comboFx.list, { part = combo.stage, sound = id, via = name,
                        warpCue = combo.cueingSnd == true, t = ("%.2f"):format(os.clock() - (combo.t0 or 0)) })
                    dbg.save("Pactblade_fx_record.json", comboFx.list)
                end)
            end, function(r) return r end)
        end
    end
end)
local function combo_dust(args, how)
    if dbg.slashKilled and next(dbg.slashKilled) then   -- an Eldritch Slash wave we ended: no end / hit effect there
        local drop = false
        pcall(function()
            local addr = sdk.to_managed_object(args[2]):call("get_GameObject"):get_address()
            local untilT = dbg.slashKilled[addr]
            if untilT then
                if os.clock() < untilT then drop = true else dbg.slashKilled[addr] = nil end
            end
        end)
        if drop then return true end
    end
    if live.on and #blasts > 0 and (how == "requestEffect" or how == "requestEffectInternal") then
        local drop = false
        pcall(function()
            if not BLAST_DROP[effect_id_of(args, how)] then return end
            drop = blast_shell_info(sdk.to_managed_object(args[2]):call("get_GameObject"):get_address()) ~= nil
        end)
        if drop then return true end
    end
    if live.on and combo.mistyUntil and os.clock() < combo.mistyUntil and not combo.cueing
       and (how == "requestEffect" or how == "requestEffectInternal") then
        local kill = false
        pcall(function()
            if sdk.to_managed_object(args[2]):call("get_GameObject"):get_address() ~= live.go then return end
            kill = MISTY_FX[effect_id_of(args, how)] == true
        end)
        if kill then return true end
    end
    if not live.on or combo.stage == 0 or combo.cueing then return false end
    local rush = combo.stage == 2 or combo.stage == 3
    if not ((cfg.comboNoDust and rush) or dbg.comboNoFxAll) then return false end
    local yes = false
    pcall(function()
        local addr = sdk.to_managed_object(args[2]):call("get_GameObject"):get_address()
        yes = addr == live.go
        if not yes and dbg.comboNoSwordFx then
            local sw = combo.sword_go and combo.sword_go()   -- held_sword_go is defined further down
            yes = sw ~= nil and sw:get_address() == addr
        end
    end)
    return yes
end
local function tint_wanted(args, how)
    if not (live.on and cfg.blastTint) then return false end
    local tint, mine = false, false
    pcall(function()
        if ourSpawn then tint = true; return end
        local mgr = sdk.to_managed_object(args[2])
        local goAddr = mgr:call("get_GameObject"):get_address()
        if goAddr == live.go then tint = os.clock() - lastFire < TINT_WINDOW or (dbg.beam ~= nil and dbg.beam.stage == "air"); mine = true   -- (1.0.1: the air beam too)
        elseif #blasts > 0 and blast_shell_info(goAddr) then tint = true
        elseif os.clock() - lastFire < 6 or os.clock() - (dbg.slashT or -10) < 6 then
            local go = mgr:call("get_GameObject")
            local sh = go:call("getComponent(System.Type)", sdk.typeof("app.Shell"))
            local ow = sh and sh:get_field("<Owner>k__BackingField")
            tint = ow ~= nil and ow:get_address() == live.go
            if tint and (lastKind == "charged" or lastKind == "burst") and cfg.bind and bindBolt.addr ~= goAddr and not dbg.noBindCapture then
                bindBolt.go, bindBolt.addr, bindBolt.born = go:add_ref(), goAddr, os.clock()
            end
        end
    end)
    if not tint then return false end
    local idstr = effect_id_of(args, how)
    if (PB.activeVocation ~= "stormblade") and (cfg.noTint[idstr] or dbg.partsIds[idstr]) then return false end
    -- the character's own effects: only the blast animation's (Mystic Spearhand's effect file = data container 13)
    -- and the charge cloud (0/160) - not water splashes, footsteps, dust or sword trails played in those 2 s
    if mine and not (idstr:find("^13/") or idstr:find("^0/160/")) then return false end
    -- the slash's wave (it fired last, within 6 s): its own colour
    -- (1.56-1.63: the slash's wave had its own colour here - back to the blasts' colour, user)
    return idstr
end
local tintRecent = {}   -- idstr -> { n, last, how }: what was coloured lately (menu list)
local colouredLog = {}
function dbg.coloured(idstr, how, by)
    local key = idstr .. "|" .. tostring(how)
    if colouredLog[key] then return end
    colouredLog[key] = true
    local all = json.load_file("Pactblade_coloured.json") or {}
    all[#all + 1] = { id = idstr, how = how, by = by, t = os.date("%H:%M:%S") }
    pcall(json.dump_file, "Pactblade_coloured.json", all)
end
local function tint_note(idstr, how)
    if dbg.coloured then dbg.coloured(idstr, how, "requested") end
    local r = tintRecent[idstr] or { n = 0, how = how }
    r.n, r.last = r.n + 1, os.clock()
    tintRecent[idstr] = r
end
local function tint_add(rv, how, idstr)
    pcall(function()
        local c = sdk.to_managed_object(rv)
        if not c then return end
        local addr = c:get_address()
        if tintSeen[addr] then return end
        tintSeen[addr] = true
        local isSlash = type(idstr) == "table" and idstr.slash
        if type(idstr) == "table" then idstr = idstr.id end
        idstr = type(idstr) == "string" and idstr or how
        tint_note(idstr, how)
        table.insert(tints, { c = c:add_ref(), born = os.clock(), addr = addr, id = idstr, slash = isSlash })
        dbg.tinted = (dbg.tinted or 0) + 1
        dbg.tintBy = dbg.tintBy or {}
        dbg.tintBy[how] = (dbg.tintBy[how] or 0) + 1
    end)
end
function blast_shell_info(goAddr)
    for _, b in ipairs(blasts) do
        for _, p in ipairs(b.record.parts or {}) do
            local ok, a2 = pcall(function() return p.shell:get_GameObject():get_address() end)
            if ok and a2 == goAddr then return b end
        end
    end
    return nil
end
local function hit_elements(shellId)
    local param = params[shellId]
    if not param then return nil end
    local out = {}
    pcall(function()
        local e = param._ShellParameterBase.effectParam
        for _, f in ipairs({ "HitElementID", "HitAddElementID", "HitTerrainElementID", "HitTerrainAddElementID", "FinishElementID" }) do
            local v = e[f]
            if v and v >= 0 then out[v] = true end
        end
    end)
    return out
end
pcall(function()
    local td = sdk.find_type_definition("via.effect.script.ObjectEffectManager2")
    for _, m in ipairs(td:get_methods()) do
        local okP, pt = pcall(function() return m:get_param_types() end)
        if m:get_name() == "requestEffect" and okP and pt[1] and pt[1]:get_full_name() == "via.effect.script.EffectID" then
            local stack, tstack, rstack = {}, {}, {}
            sdk.hook(m, function(args)
                local want = false
                if live.on and next(pieceByGo) then
                    pcall(function()
                        local mgr = sdk.to_managed_object(args[2])
                        local pc = pieceByGo[mgr:call("get_GameObject"):get_address()]
                        if pc then
                            local id = sdk.to_managed_object(args[3])
                            local flight = -2
                            pcall(function() flight = params[BLAST.tap.shell]._ShellParameterBase.effectParam.ShellElementID end)
                            want = (pc.dead or id.ElementID ~= flight) and "kill" or pc
                        end
                    end)
                end
                if not want and live.on and #blasts > 0 then
                    pcall(function()
                        local mgr = sdk.to_managed_object(args[2])
                        local b = blast_shell_info(mgr:call("get_GameObject"):get_address())
                        if b then
                            local idh = sdk.to_managed_object(args[3])
                            local hits = hit_elements(BLAST[b.kind].shell)
                            if hits and hits[idh.ElementID] then b.hitNow = true end
                        end
                        if b and BLAST[b.kind].hidden then
                            local id = sdk.to_managed_object(args[3])
                            local start = -2
                            pcall(function() start = params[BLAST[b.kind].shell]._ShellParameterBase.effectParam.StartElementID end)
                            if id.ElementID ~= start then want = "kill" end
                        end
                    end)
                end
                -- the Forbeding Bolt that rides along with the charged blast: its own flight / launch visuals hidden
                -- (the bind effect on the enemy stays)
                if not want and live.on and cfg.bind and (lastKind == "charged" or lastKind == "burst") and os.clock() - lastFire < 6 then
                    pcall(function()
                        local mgr = sdk.to_managed_object(args[2])
                        local go = mgr:call("get_GameObject")
                        local addr = go:get_address()
                        if addr == live.go or blast_shell_info(addr) then return end
                        local sh = go:call("getComponent(System.Type)", sdk.typeof("app.Shell"))
                        local ow = sh and sh:get_field("<Owner>k__BackingField")
                        if ow and ow:get_address() == live.go then
                            want = "kill"
                            if not (bindBolt.go and bindBolt.addr == addr) then
                                bindBolt.go, bindBolt.addr, bindBolt.born = go:add_ref(), addr, os.clock()
                            end
                        end
                    end)
                end
                if not want and live.on and cfg.boom < 0.999 then
                    pcall(function()
                        local mgr = sdk.to_managed_object(args[2])
                        local goAddr = mgr:call("get_GameObject"):get_address()
                        if goAddr == live.go then
                            local id = sdk.to_managed_object(args[3])
                            if id.DataContainerIndex == 0 and id.ContainerID == CHARGE_CLOUD then want = "scale" end
                            return
                        end
                        if #blasts == 0 then return end
                        local b = blast_shell_info(goAddr)
                        if b then
                            local id = sdk.to_managed_object(args[3])
                            local hits = not BLAST[b.kind].noScale and hit_elements(BLAST[b.kind].shell)
                            if hits and hits[id.ElementID] then want = "scale" end
                        end
                    end)
                end
                stack[#stack + 1] = want
                combo_rec(args, "requestEffect")
                if dbg.md_seen then pcall(dbg.md_seen, args, "requestEffect") end
                if not want and combo_dust(args, "requestEffect") then
                    want = "kill"
                    local idd = effect_id_of(args, "requestEffect")
                    if not combo.dustSeen then combo.dustSeen = {} end
                    if not combo.dustSeen[idd] then combo.dustSeen[idd] = true; note("combo: switched off effect " .. idd) end
                end
                stack[#stack] = want
                tstack[#tstack + 1] = want ~= "kill" and tint_wanted(args, "requestEffect")
                rstack[#rstack + 1] = want ~= "kill" and parts.wanted(args, "requestEffect")
            end, function(rv)
                local tid = table.remove(tstack)
                if tid then tint_add(rv, "requestEffect", tid) end
                local trimS = table.remove(rstack)
                local want = table.remove(stack)
                if want then
                    pcall(function()
                        local c = sdk.to_managed_object(rv)
                        if not c then return end
                        if want == "kill" then c:call("killAll"); dbg.hidden = (dbg.hidden or 0) + 1; return end
                        if type(want) == "table" then table.insert(want.conts, c:add_ref()); return end
                        if cfg.boom < 0.05 then c:call("finishAll")
                        else
                            c:call("setUniformScale", cfg.boom)
                            table.insert(clouds, { c = c:add_ref(), born = os.clock() })
                        end
                        dbg.booms = (dbg.booms or 0) + 1
                    end)
                end
                if trimS then parts.add(rv, trimS) end
                return rv
            end)
        end
    end
end)

pcall(function()
    local td = sdk.find_type_definition("via.effect.script.ObjectEffectManager2")
    local NAMES = { requestEffectInternal = true, requestEffectFromFsmOrSequence = true, requestEffectFromFsm = true,
                    requestEffectParamFromFsm = true, requestEffectParamAllElementsFromFsm = true }
    for _, m in ipairs(td:get_methods()) do
        local name = m:get_name()
        local okR, rt = pcall(function() return m:get_return_type():get_full_name() end)
        if NAMES[name] and okR and rt == "via.effect.script.CreatedEffectContainer" then
            local stack, rst, mst = {}, {}, {}
            sdk.hook(m, function(args)
                combo_rec(args, name)
                if dbg.md_seen then pcall(dbg.md_seen, args, name) end
                local mdf = false
                if dbg.md_fx then pcall(function() mdf = dbg.md_fx(args, effect_id_of(args, name)) end) end
                mst[#mst + 1] = mdf
                if combo_dust(args, name) then
                    local idd = effect_id_of(args, name)
                    if not combo.dustSeen then combo.dustSeen = {} end
                    if not combo.dustSeen[idd] then combo.dustSeen[idd] = true; note("combo: switched off effect " .. idd) end
                    stack[#stack + 1] = "kill"
                    rst[#rst + 1] = false
                    return
                end
                stack[#stack + 1] = tint_wanted(args, name)
                rst[#rst + 1] = parts.wanted(args, name)
            end, function(rv)
                local mdf = table.remove(mst)
                local tid = table.remove(stack)   -- (all three stacks popped every time: 2.91 returned before these
                local trimS = table.remove(rst)   -- two, so every later effect got another one's colour / kill)
                if mdf then pcall(dbg.md_fx_play, rv, mdf); return rv end   -- (Misty Dive: our copy instead)
                if tid == "kill" then
                    pcall(function() local c = sdk.to_managed_object(rv); if c then c:call("killAll") end end)
                    return rv
                elseif tid then tint_add(rv, name, tid) end
                if trimS then parts.add(rv, trimS) end
                return rv
            end)
        end
    end
end)

------------------------------------------------------------------------
-- test dummies: DLC enemies that stand still (AI decision tree paused, reactions still play); killable, their hits
-- are marked "(dummy)" in the hit log. Spawned with DragonCore's summon; found afterwards in the
-- enemy list by type near the spawn point.
------------------------------------------------------------------------
local DUMMIES = {
    { name = "Beorcan Warrior (DLC bandit)", path = "AppSystem/ch/ch230/prefab/ch230004_05.pfb", tag = "ch230004" },
    { name = "Beorcan Fighter (DLC bandit)", path = "AppSystem/ch/ch230/prefab/ch230004_01.pfb", tag = "ch230004" },
    { name = "Cyclops", path = "AppSystem/ch/ch250/prefab/ch250000_00.pfb", tag = "ch250000" },
    { name = "Chimera", path = "AppSystem/ch/ch254/prefab/ch254000_00.pfb", tag = "ch254000" },
    { name = "Griffin", path = "AppSystem/ch/ch253/prefab/ch253000_00.pfb", tag = "ch253000" },   -- (3.60 user)
    { name = "Gagana", path = "AppSystem/ch/ch253/prefab/ch253012_00.pfb", tag = "ch253012" },   -- (1.0.1 user: fire tests)
}
local dummy = { wanted = {}, set = {}, hits = {}, count = 0, status = "-" }   -- set: chara address -> { chara, paused }
local function dummy_spawn(d)
    local a = runtime.player()
    if not a or not a:valid() then return end
    local ok = a:summon({ summon = d.path, count = 1, duration = 3600, hostile = true, at = "front", distance = 4 })
    local before = {}
    pcall(function()
        local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
        for i = 0, list._size - 1 do
            local e = list._items[i]
            if e and e._Chara then before[e._Chara:get_address()] = true end
        end
    end)
    local at
    pcall(function()
        local tr = a.game_object:get_Transform()
        at = tr:get_Position() + require("DragonCore.game.mathx").rotate(Vector3f.new(0, 0, 4), tr:get_Rotation())
    end)
    table.insert(dummy.wanted, { tag = d.tag, untilT = os.clock() + 20, before = before, at = at })
    dummy.status = ok and ("spawning " .. d.name .. "...") or ("spawn failed: " .. tostring(a.errors and a.errors.summon))
end
function dummy.real(d)   -- (3.59) the same summon, but not paused and not a dummy: a normal enemy that fights
    local a = runtime.player()
    if not a or not a:valid() then return end
    local ok = a:summon({ summon = d.path, count = 1, duration = 3600, hostile = true, at = "front", distance = 8 })
    dummy.status = ok and ("spawned a normal " .. d.name) or ("spawn failed: " .. tostring(a.errors and a.errors.summon))
end
local dumped = {}
local function pause_ai(chara)
    local go = chara:get_GameObject()
    local n = 0
    local comps = go:call("get_Components")
    local list = {}
    for i = 0, comps:get_size() - 1 do
        pcall(function()
            local c = comps[i]
            local td = c:get_type_definition()
            local tn = td:get_full_name()
            local okT, isTree = pcall(td.is_a, td, "via.behaviortree.BehaviorTree")
            isTree = okT and isTree
            local okM, isFsm = pcall(td.is_a, td, "via.motion.MotionFsm2")
            local isMotion = (okM and isFsm) or tn:find("Motion") ~= nil
            list[#list + 1] = tn .. (isTree and (isMotion and "  [tree, animation: left running]" or "  [tree: PAUSED]") or "")
            if tn == "app.AIDecisionMaker" then
                c:call("set_Enabled", false); n = n + 1
                list[#list] = list[#list] .. "  [SWITCHED OFF]"
            end
        end)
    end
    -- components of each dummy once, for choosing exactly what to pause
    if not dumped[chara:get_address()] then
        dumped[chara:get_address()] = true
        pcall(json.dump_file, "Pactblade_dummy_components.json", list)
    end
    return n
end
local function dummy_update()
    if #dummy.wanted == 0 and dummy.count == 0 then return end
    local now = os.clock()
    local mgr = sdk.get_managed_singleton("app.EnemyManager")
    local list = mgr and mgr._EnemyList
    local items, size = list and list._items, list and list._size or 0
    for i = 0, size - 1 do
        local e = items[i]
        local ch = e and e._Chara
        if ch then
            local addr = ch:get_address()
            local d = dummy.set[addr]
            if not d and #dummy.wanted > 0 then
                local okP, pos = pcall(function() return ch:get_GameObject():get_Transform():get_Position() end)
                for k, w in ipairs(dummy.wanted) do
                    local near = okP and w.at and (pos - w.at):length() < 6
                    if near and not w.before[addr] then
                        d = { chara = ch:add_ref(), seen = now }
                        pcall(function() dummy.hits[ch["<Hit>k__BackingField"]:get_address()] = true end)
                        dummy.set[addr] = d
                        dummy.count = dummy.count + 1
                        table.remove(dummy.wanted, k)
                        break
                    end
                end
            end
            -- pause its AI a moment after it appears (once its parts are set up), and keep it paused
            if d and now - d.seen > 3.0 then
                local okP, n = pcall(pause_ai, ch)
                if okP and not d.paused then d.paused = n; dummy.status = ("dummy ready (%d AI part(s) paused)"):format(n) end
            end
        end
    end
    for k = #dummy.wanted, 1, -1 do if now > dummy.wanted[k].untilT then table.remove(dummy.wanted, k) end end
end
re.on_pre_application_entry("UpdateBehavior", function() pcall(dummy_update) end)
local function is_dummy_hit(info)
    if dummy.count == 0 then return false end
    local ok, hc = pcall(function() return info:get_DamageOwnerHitController() end)
    return ok and hc and dummy.hits[hc:get_address()] == true
end
local function is_dummy(go)
    if dummy.count == 0 or not go then return false end
    local ok, ch = pcall(function() return go:call("getComponent(System.Type)", sdk.typeof("app.Character")) end)
    return ok and ch and dummy.set[ch:get_address()] ~= nil
end


------------------------------------------------------------------------
-- debug: the game's damage math for the player's hits -> reframework/data/Pactblade_calc.json
-- app.PlayerDamageCalculator.calcMagicAttack / calcPhysicsAttack wrap calcAttack(4 floats) and calcDamage(5 floats)
------------------------------------------------------------------------
local calc = { rows = {}, scope = nil, humanAddr = nil }
local function calc_row(r)
    r.t = os.date("%H:%M:%S")
    table.insert(calc.rows, r)
    while #calc.rows > 80 do table.remove(calc.rows, 1) end
    dbg.save("Pactblade_calc.json", calc.rows)
end
local function mine(this)
    local ok, h = pcall(function() return sdk.to_managed_object(this).Human end)
    return ok and h and live.go and h:get_GameObject():get_address() == live.go
end
pcall(function()
    local td = sdk.find_type_definition("app.PlayerDamageCalculator")
    for _, spec in ipairs({ { "calcMagicAttack", "magick" }, { "calcPhysicsAttack", "physical" } }) do
        local m = td:get_method(spec[1] .. "(app.HitController.DamageInfo, app.PlayerAttackParameter, app.PlayerDamageCalculator.SpecialAttackFactor)")
        sdk.hook(m, function(args)
            if mine(args[2]) then calc.scope = spec[2] end
        end, function(r) calc.scope = nil; return r end)
    end
    local function floats(args, n)
        local out = {}
        for i = 1, n do
            local ok, v = pcall(sdk.to_float, args[2 + i])
            out[i] = ok and math.floor(v * 1000 + 0.5) / 1000 or "?"
        end
        return out
    end
    for _, spec in ipairs({ { "calcAttack(System.Single, System.Single, System.Single, System.Single)", "calcAttack", 4 },
                            { "calcDamage(System.Single, System.Single, System.Single, System.Single, System.Single)", "calcDamage", 5 } }) do
        local m = td:get_method(spec[1])
        local stack = {}
        sdk.hook(m, function(args)
            local rec = false
            if mine(args[2]) then rec = { fn = spec[2], part = calc.scope or "?", args = floats(args, spec[3]) } end
            stack[#stack + 1] = rec
        end, function(r)
            local rec = table.remove(stack)
            if rec then
                local ok, v = pcall(sdk.to_float, r)
                rec.result = ok and math.floor(v * 1000 + 0.5) / 1000 or "?"
                calc_row(rec)
            end
            return r
        end)
    end
end)

------------------------------------------------------------------------
-- holy magick sword: while Pactblade is active the sword in hand gets Magick equal to its Strength (like a duospear,
-- whose Strength and Magick are always equal) and the Holy element like The Exalted (_Element 4, _ElementStore 100). Written into the weapon's data
-- (app.ItemWeaponParam, shared by every copy of that weapon, as Stalwart Nox does) and put back when Pactblade is off,
-- another weapon is drawn, or on script reset. Nothing goes into the save.
------------------------------------------------------------------------
local swordMod = nil   -- { param, id, mag, el, store }
local HOLY, HOLY_STORE = 4, 100
local ELEMENT_CHOICES = { { "Holy", 4 }, { "Fire", 1 }, { "Ice", 2 }, { "Thunder", 3 }, { "none", 0 } }
local swordEl = { pick = 4 }   -- index into ELEMENT_CHOICES: Thunder (damage, swing trail and sounds; user's choice)
local function sword_element() return ELEMENT_CHOICES[swordEl.pick][2] end
-- (1.0.2 user: a NEW sword got no magick / element) the equipped main weapon's storage data + its own item-data copy
function dbg.main_weapon_sd()
    local im = sdk.get_managed_singleton("app.ItemManager")
    local a = runtime.player()
    if not im or not a then return nil end
    local ed = im:call("getEquipData(app.Character)", a.character)
    local data = ed and ed:get_field("Data")
    local MAIN = sdk.find_type_definition("app.EquipData.SlotEnum"):get_field("Main"):get_data(nil)
    local sd = data and data:call("get(app.EquipData.SlotEnum)", MAIN)
    return sd, data, im, a
end
function dbg.equip_recalc()   -- the equipment totals fully recomputed (the guise's way: clear first, calc() adds)
    pcall(function()
        local _, data, im, a = dbg.main_weapon_sd()
        if not data then return end
        pcall(data.call, data, "clearParam")
        pcall(data.call, data, "calc")
        pcall(im.call, im, "applyEquipDataForCharacter(app.Character)", a.character)
    end)
end
local function refresh_equipment(itemId)
    local im = sdk.get_managed_singleton("app.ItemManager")
    if not im then return end
    if itemId then
        pcall(function()
            local members = im:call("getStorageMembers")
            for i = 0, members:call("get_Count") - 1 do
                local cid = members:call("get_Item", i)
                local list = im:call("getStorageMasterList(app.CharacterID)", cid)
                local ed = im:call("getEquipData(app.CharacterID)", cid)
                local data = ed and ed:get_field("Data")
                if list and data then
                    for j = 0, list:call("get_Count") - 1 do
                        local md = list:call("get_Item", j)
                        local sd = md and md:get_field("_Param")
                        if sd and sd:get_field("_ItemId") == itemId and sd:get_field("_IsEquipped") then
                            pcall(data.call, data, "updateEnhanceEquip(app.ItemDefine.StorageData)", sd)
                            dbg.swordRefresh = (dbg.swordRefresh or 0) + 1
                        end
                    end
                end
            end
        end)
    end
    pcall(function() im:call("applyEquipDataForCharacter()") end)
    pcall(dbg.equip_recalc)
end
local function sword_restore()
    if not swordMod then return end
    pcall(function()
        swordMod.param._MagicAttack = swordMod.mag
        swordMod.param._Element = swordMod.el
        swordMod.param._ElementStore = swordMod.store
    end)
    if swordMod.own then pcall(function()   -- (1.0.2) the sword's own copy back too
        local o = swordMod.own
        o.obj._MagicAttack, o.obj._Element, o.obj._ElementStore = o.mag, o.el, o.store
    end) end
    local itemId = swordMod.itemId
    swordMod = nil
    refresh_equipment(itemId)
end
-- the weapon in my right hand, read from the weapon slot's own field. (CRASH 2026-10-24 00:03, Pactblade -> Mystic
-- Spearhand -> Pactblade: WeaponElementController.getWeapon threw inside the game ~180 times in 2 s while the vocation
-- changed, crash 14 s later.) Nothing is called on the game here; nil while the slot is switching or empty.
function dbg.right_weapon()
    local w, why = nil, "?"
    pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local p = cm and cm["<ManualPlayer>k__BackingField"]
        local holder = p and p:get_WeaponAndItemHolder()
        local slot = holder and holder:get_RightWeapon()
        if not slot then why = "no slot"; return end
        local prep = slot:get_field("IsStartPrepare")
        if prep == true then why = "switching"; return end
        w = slot:get_field("<Weapon>k__BackingField")
        if not w then   -- (the weapon component on the slot's object)
            local go = slot:get_field("<Object>k__BackingField")
            w = go and go:call("getComponent(System.Type)", sdk.typeof("app.Weapon"))
        end
        why = w and "ok" or "empty slot"
    end)
    if why ~= dbg.rwWhy then dbg.rwWhy = why; note("right-hand weapon: " .. why) end
    return w
end
local function held_weapon() return dbg.right_weapon() end
local function held_weapon_id()
    local w = held_weapon()
    return w and w.ID or nil
end
local heldEl = nil   -- { weapon, el }: the sword object whose element we changed
local function held_restore()
    if not heldEl then return end
    pcall(function() heldEl.weapon.ElementType = heldEl.el end)
    heldEl = nil
end
local function held_apply()
    local w = held_weapon()
    if not w then return end
    if heldEl and heldEl.weapon:get_address() ~= w:get_address() then held_restore() end
    if not heldEl then heldEl = { weapon = w:add_ref(), el = w.ElementType } end
    if w.ElementType ~= sword_element() then
        w.ElementType = sword_element()
        dbg.heldEl = ("sword object element: %s -> %s"):format(tostring(heldEl.el), ELEMENT_CHOICES[swordEl.pick][1])
    end
end
local lastSword = 0
local function sword_update()
    if dbg.guardHold then return end   -- (4.98) a save / an online upload is being built: the sword stays plain
    if os.clock() - lastSword < 0.5 then return end
    lastSword = os.clock()
    if PB.activeVocation == "stormblade" then return end
    if not live.on then sword_restore(); held_restore(); return end
    pcall(held_apply)
    if swordEl.dirty and swordMod then
        swordEl.dirty = false
        refresh_equipment(swordMod.itemId)
    end
    local id = held_weapon_id()
    if not id then return end
    if swordMod and swordMod.id == id then
        -- keep it applied (another mod or the game could have reset the value)
        pcall(function()
            local o = swordMod.own and swordMod.own.obj
            if swordMod.param._MagicAttack ~= swordMod.param._PhysicalAttack or swordMod.param._Element ~= sword_element()
               or (o and (o._MagicAttack ~= o._PhysicalAttack or o._Element ~= sword_element())) then
                if o then o._MagicAttack, o._Element, o._ElementStore = o._PhysicalAttack, sword_element(), HOLY_STORE end
                swordMod.param._MagicAttack = swordMod.param._PhysicalAttack
                swordMod.param._Element = sword_element()
                swordMod.param._ElementStore = HOLY_STORE
                refresh_equipment(swordMod.itemId)
            end
        end)
        return
    end
    sword_restore()
    local im = sdk.get_managed_singleton("app.ItemManager")
    local ok, param = pcall(function() return im:call("getItemData(app.WeaponID)", id) end)
    if not ok or not param then return end
    swordMod = { param = param:add_ref(), id = id, itemId = param._Id, mag = param._MagicAttack, el = param._Element,
                 store = param._ElementStore }
    param._MagicAttack = param._PhysicalAttack
    param._Element = sword_element()
    param._ElementStore = HOLY_STORE
    pcall(function()   -- (1.0.2) a sword with its OWN item-data copy (e.g. a newly found / enhanced one): that copy too
        local sd = dbg.main_weapon_sd()
        local own = sd and sd:get_field("_ItemData")
        if own and own:get_address() ~= param:get_address() and own:get_field("_PhysicalAttack") ~= nil then
            swordMod.own = { obj = own:add_ref(), mag = own._MagicAttack, el = own._Element, store = own._ElementStore }
            own._MagicAttack = own._PhysicalAttack
            own._Element = sword_element()
            own._ElementStore = HOLY_STORE
            note(("sword: its own item copy too (Strength %s -> Magick %s)"):format(tostring(own._PhysicalAttack), tostring(own._MagicAttack)))
        end
    end)
    dbg.sword = ("sword: Strength %s -> Magick %s (was %s), Holy %s (was element %s)"):format(tostring(param._PhysicalAttack),
        tostring(param._MagicAttack), tostring(swordMod.mag), tostring(HOLY_STORE), tostring(swordMod.el))
    note(dbg.sword)
    refresh_equipment(swordMod.itemId)
end
re.on_frame(function() pcall(sword_update) end)
re.on_script_reset(function() sword_restore(); held_restore() end)

------------------------------------------------------------------------
-- no boons: Fire / Ice / Thunder enchant (StatusConditionEnum 15 / 16 / 17) can't be put on you while Pactblade is
-- active, and one already on you is cured when Pactblade becomes active
------------------------------------------------------------------------
local BOONS = { [15] = "fire_boon", [16] = "ice_boon", [17] = "thunder_boon" }
pcall(function()
    sdk.hook(sdk.find_type_definition("app.StatusConditionCtrl"):get_method(
        "reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean)"),
        function(args)
            if not live.on or not live.sc or sdk.to_int64(args[2]) ~= live.sc then return end
            if PB.activeVocation == "stormblade" then
                -- Allow thunder_boon on Stormblade
                local boonId = sdk.to_int64(args[3]) & 0xFFFFFFFF
                if boonId == 17 then return end
            end
            if BOONS[sdk.to_int64(args[3]) & 0xFFFFFFFF] then
                dbg.boons = (dbg.boons or 0) + 1
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
end)
local boonCheck = 0
function boon_clear(a)
    if PB.activeVocation == "stormblade" then return end -- Don't clear boons on Stormblade
    if os.clock() - boonCheck < 1.0 then return end
    boonCheck = os.clock()
    local st = require("DragonCore.game.statuses")
    for _, kind in pairs(BOONS) do
        pcall(function()
            if a:status_active(kind) then st.cure(a.character, kind); note("removed " .. kind .. " (Pactblade)") end
        end)
    end
end

-- damage element: the sword keeps its element for sounds / behaviour (e.g. Fire), the hit's element is swapped when
-- the game writes it (CharacterDamageCalculator.setElemntTypeOnEnchant) - Holy by default
local dmgEl = { pick = 2, names = { "Holy (not working yet)", "same as the sword" } }
pcall(function()
    sdk.hook(sdk.find_type_definition("app.CharacterDamageCalculator"):get_method(
        "setElemntTypeOnEnchant(app.AttackUserData.ElementType, app.HitController.DamageInfo)"), function(args)
        if not live.on or dmgEl.pick ~= 1 then return end
        local ok, mine = pcall(function()
            local h = sdk.to_managed_object(args[2]).Human
            return h and h:get_GameObject():get_address() == live.go
        end)
        if ok and mine then
            dbg.elSwaps = (dbg.elSwaps or 0) + 1
            dbg.elFrom = sdk.to_int64(args[3]) & 0xFFFFFFFF
            args[3] = sdk.to_ptr(4)
        end
    end, function(r) return r end)
end)

pcall(function()
    local td = sdk.find_type_definition("app.PlayerDamageCalculator")
    local stack = {}
    sdk.hook(td:get_method("getElementTypeByEnchant(app.HitController.DamageInfo)"), function(args)
        local mineNow = false
        if live.on and dmgEl.pick == 1 then
            pcall(function()
                local h = sdk.to_managed_object(args[2]).Human
                mineNow = h and h:get_GameObject():get_address() == live.go
            end)
        end
        stack[#stack + 1] = mineNow
    end, function(r)
        if not table.remove(stack) then return r end
        local v = sdk.to_int64(r)
        if (v & 0xFF) == 0 then return r end              -- no element: leave it
        dbg.elReads = (dbg.elReads or 0) + 1
        return sdk.to_ptr((v & 0xFFFFFFFF) | (4 << 32))   -- HasValue kept, value = Holy
    end)
end)

-- recorder: effects and blade-glow modes requested on the sword in hand (to find the element's own visuals)
local swordFx = { rows = {}, ours = false }
local function sword_fx_row(r)
    r.t = os.date("%H:%M:%S")
    r.swordEl = ELEMENT_CHOICES[swordEl.pick][1]
    table.insert(swordFx.rows, r)
    while #swordFx.rows > 80 do table.remove(swordFx.rows, 1) end
    dbg.save("Pactblade_sword_fx.json", swordFx.rows)
end
local function held_sword_go()
    local w = held_weapon()
    return w and w:get_GameObject() or nil
end
pcall(function()
    local td = sdk.find_type_definition("via.effect.script.ObjectEffectManager2")
    for _, m in ipairs(td:get_methods()) do
        local okP, pt = pcall(function() return m:get_param_types() end)
        if m:get_name() == "requestEffect" and okP and pt[1] and pt[1]:get_full_name() == "via.effect.script.EffectID" then
            sdk.hook(m, function(args)
                if not live.on then return end
                pcall(function()
                    local go = held_sword_go()
                    local mgr = sdk.to_managed_object(args[2])
                    if not go or mgr:call("get_GameObject"):get_address() ~= go:get_address() then return end
                    local id = sdk.to_managed_object(args[3])
                    sword_fx_row({ what = "effect", id = ("%s/%s/%s"):format(id.DataContainerIndex, id.ContainerID, id.ElementID),
                                   ours = noxStarting == true })
                    if noxStarting ~= true then thread.get_hook_storage().pbKillSword = true end
                end)
            end, function(r)
                local st5 = thread.get_hook_storage()
                if st5.pbKillSword then
                    st5.pbKillSword = nil
                    pcall(function() local c = sdk.to_managed_object(r); if c then c:call("killAll"); dbg.swordFxKilled = (dbg.swordFxKilled or 0) + 1 end end)
                end
                return r
            end)
        end
    end
end)
for _, tname in ipairs({ "app.MaterialInterpolation", "app.MaterialInterpolationEnchant" }) do pcall(function()
    local td = sdk.find_type_definition(tname)
    for _, m in ipairs(td:get_methods()) do
        if m:get_name() == "requestMaterialModeSub" or m:get_name() == "requestMaterialMode" then
            sdk.hook(m, function(args)
                if not live.on or not dbg.noxGlowMode then return end   -- (3.03: game glow requests left alone)
                pcall(function()
                    local go = held_sword_go()
                    local mi = sdk.to_managed_object(args[2])
                    if not go or mi:get_GameObject():get_address() ~= go:get_address() then return end
                    sword_fx_row({ what = "blade glow " .. m:get_name(), mode = sdk.to_int64(args[3]) & 0xFFFFFFFF,
                                   ours = noxStarting == true })
                    if noxStarting ~= true then thread.get_hook_storage().pbSkipGlow = true; noxGlowAgain = true end
                end)
                if thread.get_hook_storage().pbSkipGlow then
                    dbg.swordGlowBlocked = (dbg.swordGlowBlocked or 0) + 1
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r)
                local st6 = thread.get_hook_storage()
                if st6.pbSkipGlow then st6.pbSkipGlow = nil; return sdk.to_ptr(0) end
                return r
            end)
        end
    end
end) end

------------------------------------------------------------------------
-- damage: blast = Magick Bolt formula x 5 / 10; passive on everything else
------------------------------------------------------------------------
local function blast_of(attacker)
    if not attacker then return nil end
    local addr = attacker:get_address()
    for _, b in ipairs(blasts) do
        for _, p in ipairs(b.record.parts or {}) do
            local ok, hc = pcall(function() return p.shell["<HitCtrl>k__BackingField"] end)
            if ok and hc and hc:get_address() == addr then return b end
        end
    end
    return nil
end
-- Mystic Spearhand's own Forbeding Bolt fired by the charged animation: a shell owned by the player, not ours
local function is_bind_bolt(attacker)
    if not (cfg.bind and (lastKind == "charged" or lastKind == "burst") and os.clock() - lastFire < 6) or not attacker then return false end
    local yes = false
    pcall(function()
        local go = attacker:get_GameObject()
        if go:get_address() == live.go then return end
        local sh = go:call("getComponent(System.Type)", sdk.typeof("app.Shell"))
        local ow = sh and sh:get_field("<Owner>k__BackingField")
        yes = ow ~= nil and ow:get_address() == live.go
    end)
    return yes
end
local function blast_kind_of(attacker)
    local b = blast_of(attacker)
    if b then b.hitNow = true end
    return b and b.kind or nil
end

function PB.player_strength()
    local str = 0
    pcall(function()
        local a = runtime.player()
        if not a or not a.character then return end
        local human = a.character:get_Human()
        local sc = human and human["<StatusContext>k__BackingField"]
        if sc then
            local atk = tonumber(sc:call("get_Attack")) or tonumber(sc:call("get_Strength")) or tonumber(sc:get_field("_Attack"))
            if atk and atk > str then str = atk end
        end
        local im = sdk.get_managed_singleton("app.ItemManager")
        if im then
            local ed = im:call("getEquipData(app.Character)", a.character)
            local data = ed and ed:get_field("Data")
            local eq = data and data:call("get_EqParam")
            if eq then
                local eqAtk = eq:get_field("_PhysicalAttack") or 0
                if eqAtk > 0 and str < eqAtk then
                    str = eqAtk + 80
                end
            end
        end
    end)
    if swordMod and swordMod.param and swordMod.param._PhysicalAttack then
        local swordAtk = swordMod.param._PhysicalAttack
        local totalWithSword = swordAtk + 80
        if totalWithSword > str then str = totalWithSword end
    end
    if str <= 0 then str = 160 end
    return str
end

pcall(function()
    sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageValue(app.HitController.DamageInfo)"),
        function(args)
            local s = thread.get_hook_storage()
            s.pbInfo, s.pbKind = nil, nil
            if not live.go then return end
            local info = sdk.to_managed_object(args[3])
            local owner = info and info["<AttackOwnerObject>k__BackingField"]
            if not owner or owner:get_address() ~= live.go then return end
            s.pbInfo = info
            if dbg.misty and dbg.misty.stage == "dive" then dbg.misty.hitLanded = true end   -- (3.50)
            if dbg.smite and dbg.smite.stage == 2 and dbg.smite_hit then
                pcall(function()
                    local hc = info:get_AttackHitController()
                    if hc and hc:get_GameObject():get_address() == live.go then dbg.smite_hit(info) end
                end)
            end
            local okK, kind = pcall(blast_kind_of, info:get_AttackHitController())
            s.pbKind = okK and kind or nil

            if not s.pbKind and is_bind_bolt(info:get_AttackHitController()) then s.pbKind = "bind" end
            if not s.pbKind and (lastKind == "charged" or lastKind == "tap" or lastKind == "burst") and os.clock() - (lastFire or 0) < 4.0 then
                pcall(function()
                    local hc = info:get_AttackHitController()
                    local go = hc and hc:get_GameObject()
                    if go and go:get_address() ~= live.go and go:call("getComponent(System.Type)", sdk.typeof("app.Shell")) then
                        s.pbKind = lastKind
                    end
                end)
            end
            if not s.pbKind and dbg.slashT and os.clock() - dbg.slashT < 4 then   -- (1.0.2 user: the wave did ~nothing)
                pcall(function()   -- its damage comes from the wave's own sub-shells, not the shell we spawned: any shell of mine
                    local hc = info:get_AttackHitController()
                    local go = hc and hc:get_GameObject()
                    if go and go:get_address() ~= live.go and go:call("getComponent(System.Type)", sdk.typeof("app.Shell")) then s.pbKind = "slash" end
                end)
            end
            if not s.pbKind and PB.activeVocation == "stormblade" then
                if PB.thunderstrikeT and os.clock() - PB.thunderstrikeT < 2.0 then s.pbKind = "thunderstrike"
                elseif PB.javelinT and os.clock() - PB.javelinT < 2.5 then s.pbKind = "javelin"
                elseif PB.levinT and os.clock() - PB.levinT < 3.5 then s.pbKind = "levin"
                elseif PB.novaT and os.clock() - PB.novaT < 2.5 then s.pbKind = "nova" end
            end
            if combo.stage == 4 and not combo.finalHit then combo.finalHit = true; note("final strike hit") end
            if combo.stage == 1 and not combo.target then
                pcall(function()
                    local v = info["<DamageGameObject>k__BackingField"]
                    local ch = v and v:call("getComponent(System.Type)", sdk.typeof("app.Character"))
                    if ch then combo.target = ch:add_ref(); note("combo target: " .. tostring(v:get_Name())) end
                end)
            end
            if s.pbKind == "burst" then
                s.pbOutside = false
                pcall(function()
                    local b = BLAST.burst
                    local tr = owner:get_Transform()
                    local victim = info["<DamageGameObject>k__BackingField"]
                    local d = victim:get_Transform():get_Position() - tr:get_Position()
                    d.y = 0
                    local dist = d:length()
                    local fwd = require("DragonCore.game.mathx").rotate(Vector3f.new(0, 0, 1), tr:get_Rotation())
                    fwd.y = 0
                    local cosang = dist > 0.01 and (d:normalized():dot(fwd:normalized())) or 1
                    if dist > b.range or cosang < math.cos(math.rad(b.arc / 2)) then s.pbOutside = true end
                end)
            end
        end, function(r)
            local s = thread.get_hook_storage()
            local info, kind = s.pbInfo, s.pbKind
            s.pbInfo, s.pbKind = nil, nil
            local outside = s.pbOutside
            s.pbOutside = nil
            if not info then return r end
            pcall(function()
                local phys = (info.SlashDamage or 0) + (info.ShootDamage or 0)
                local mag = (info.MagicDamage or 0) + (info.EnchantDamage or 0)
                local before = info.Damage
                local data = info["<AttackUserData>k__BackingField"]
                local ELEMENTS = { [0] = "none", "Fire", "Ice", "Thunder", "Holy" }
                local el = data and data:get_field("_ElementType")
                local row = { kind = kind or "hit", before = before, phys = phys, mag = mag,
                              rate = data and data:get_field("ActionRate") or 0,
                              magic = tostring(info.IsMagicAttack), element = ELEMENTS[tonumber(el) or -1] or tostring(el) }
                pcall(function() row.element = row.element .. " | hit element " .. tostring(info:call("get_ElementType")) end)
                pcall(function() row.swordEl = ELEMENT_CHOICES[swordEl.pick][1] end)
                pcall(function()
                    row.attack = tostring(data:get_field("Name"))
                    row.stagger = info.DamageReaction                     -- stagger / knock power dealt
                    row.staggerBase, row.staggerAction = data:get_field("DmgReactionValue"), data:get_field("ActionDmgReactionValue")
                    row.staggerRate = data:get_field("DmgReactionRate")
                    row.reaction = tostring(info.DamageType) .. " / lv " .. tostring(info.DmgReactionLv)
                    row.reactionTypes = ("%s, lean %s, blown %s"):format(tostring(data:get_field("DamageType")),
                        tostring(data:get_field("DamageTypeLean")), tostring(data:get_field("DamageTypeBlown")))
                    row.pushBack = ("z %.2f, y %.2f"):format(info.HitBackZ or 0, info.HitBackY or 0)
                    row.staminaDamage = info.StaminaDamage
                end)
                row.enchant = info.EnchantDamage
                row.elemental = info.NonMagicElementDamage
                if PB.activeVocation == "stormblade" and (kind == "charged" or kind == "tap" or kind == "burst" or kind == "bind" or kind == "levin" or kind == "nova" or kind == "thunderstrike" or kind == "javelin") then
                    local str = PB.player_strength()
                    local mul = (kind == "javelin" and 1.85) or (kind == "thunderstrike" and 0.60) or (kind == "levin" and 3.2) or (kind == "nova" and 2.0) or (kind == "charged" and 2.2) or (kind == "burst" and 1.5) or 1.0
                    local rate = (kind == "thunderstrike" or kind == "javelin") and 1.0 or (info.DamageRate or 1)
                    local dmg = math.floor(str * mul * rate)
                    info.Damage = dmg
                    pcall(function() info.IsMagicAttack = true end)
                    pcall(function() info.MagicDamage = dmg end)
                    pcall(function() info.EnchantDamage = 0 end)
                    pcall(function() info.NonMagicElementDamage = dmg end)
                    pcall(function() info.SlashDamage = 0; info.ShootDamage = 0; info.StrikeDamage = 0 end)
                    if kind == "javelin" then
                        pcall(function()
                            info.DamageType = 6                     -- Hitback_M (clean flinch impact, NO stun / NO knockdown)
                            info.DamageActType = 1                  -- Flinch (NOT Down / Stun)
                            info.OverwriteBlownType = 6
                            info.DamageReaction = 120               -- Moderate flinch stagger
                            info.BlownReactionRate = 0
                            info.BlownReactionConvertLevel = 0
                            info.IsTwoRankUpReaction = false
                            info.ForceFactor = 0
                            info.HitBackZ = math.min(info.HitBackZ or 0, 1.2)
                            info.HitBackY = 0                       -- Grounded, no lift!
                            info.HitBackAddZ = 0
                            info.HitBackVec = Vector3f.new(0, 0, 0)
                        end)
                        pcall(function()
                            local victim = info["<DamageGameObject>k__BackingField"]
                            if victim then
                                local ch = victim:call("getComponent(System.Type)", sdk.typeof("app.Character"))
                                local target = ch or victim
                                PB.javelin_unbind_targets = PB.javelin_unbind_targets or {}
                                table.insert(PB.javelin_unbind_targets, { target = target, untilT = os.clock() + 0.45 })
                                local bc = nil
                                pcall(function() bc = target:get_field("<BindCtrl>k__BackingField") end)
                                if not bc and target.call then pcall(function() bc = target:call("get_BindCtrl") end) end
                                if bc then
                                    local mod = bc:call("get_MagicBind")
                                    if mod then
                                        mod:call("stop(System.Boolean)", false)
                                        pcall(mod.call, mod, "deleteBindEffect")
                                    end
                                end
                            end
                            info.IsDirectDamageEnableAllDamageType = true
                        end)
                    else
                        pcall(function() info.DamageType = 6; info.DamageActType = 6; info.IsDirectDamageEnableAllDamageType = true end)
                        pcall(function() info.DamageReaction = (kind == "thunderstrike" and 350) or (kind == "charged" and 450) or 250 end)
                    end
                    pcall(function() info:call("set_ElementType", 3) end)
                    pcall(function() if info["<AttackUserData>k__BackingField"] then info["<AttackUserData>k__BackingField"]:set_field("_ElementType", 3) end end)
                    row.kind = (kind == "javelin" and "Lightning Javelin") or (kind == "thunderstrike" and "Thunderstrike") or (kind == "levin" and "Levin Storm") or (kind == "nova" and "Nova Eléctrica") or ("Storm Bolt (" .. tostring(kind) .. ")")
                    dbg.boltMag = str
                    note(("Stormblade %s hit: %.0f lightning damage (strength %.0f x%.2f)"):format(row.kind, dmg, str, mul))
                elseif kind == "bind" then
                    info.Damage = 1
                    row.kind = "Forbeding Bolt"
                    note("Forbeding Bolt hit")
                elseif kind == "burst" and outside then
                    info.Damage = 0
                    row.kind = "burst (outside the arc)"
                elseif kind and live.on and BLAST[kind].factor then
                    local base = mag > 0 and mag or (phys + mag)
                    info.Damage = base * (info.DamageRate or 1) * BLAST[kind].factor
                elseif live.on and phys + mag > 0 then
                    info.Damage = before * (phys * PB.PHYS_BONUS + mag * PB.MAG_BONUS) / (phys + mag)
                end
                if kind and live.on and BLAST[kind] and BLAST[kind].dmgMul then info.Damage = info.Damage * BLAST[kind].dmgMul end
                if not kind and live.on and combo.slash and combo.slash.on then   -- (1.0.1 user) Eldritch Slash's sword swing x3
                    info.Damage = info.Damage * (combo.slash.swordMul or 2)   -- (1.0.2 user: x2)
                    row.kind = "Eldritch Slash (sword)"
                end
                if kind == "charged" and live.on then   -- (3.34: the beam's damage base: the game's raw magick value)
                    dbg.boltMag = (PB.activeVocation == "stormblade") and PB.player_strength() or (mag * (info.DamageRate or 1))
                end
                if dbg.hex_mul then info.Damage = info.Damage * dbg.hex_mul(info) end   -- (Hex: -10 % defence)
                if dbg.smite and dbg.smite.stage and dbg.smite.dmgMul then info.Damage = info.Damage * dbg.smite.dmgMul end   -- (3.54: low damage)
                row.after = info.Damage
                if is_dummy_hit(info) or is_dummy(info["<DamageGameObject>k__BackingField"]) then
                    row.kind = row.kind .. " (dummy)"
                end
                row.t = os.date("%H:%M:%S")
                table.insert(dbg.hits, row)
                while #dbg.hits > 5 do table.remove(dbg.hits, 1) end
                dbg.hitFile = dbg.hitFile or {}
                table.insert(dbg.hitFile, row)
                while #dbg.hitFile > 40 do table.remove(dbg.hitFile, 1) end
                dbg.save("Pactblade_hits.json", dbg.hitFile)
            end)
            return r
        end)
end)

------------------------------------------------------------------------
-- Nox look on the sword in hand (ported from Stalwart Nox 1.6): the Frost Boon's shimmer (effect 25) on the
-- sword's own effect manager, tinted purple, and the blade's enchant glow coloured through Enchant_Color1/2.
-- Started/stopped inside the game's update step (starting it at the end of the frame detached the body).
------------------------------------------------------------------------
local NOX = { shimmer = 25, tint = { 126 / 255, 0, 54 / 255, 1 }, bright = 1.3,
              glowMode = 2834278566, bladeColor = { 91 / 255, 26 / 255, 142 / 255, 1 },
              boosted = false, boostGlow = 2.5 }   -- (boost: Eldritch Smite's second part - the blade glow only)
dbg.NOX = NOX
local NOX_REQ = "requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)"
local GLOW_SUB = "requestMaterialModeSub(System.UInt32, System.Int32, System.Int32, System.Boolean, System.Boolean)"
local GLOW_FINISH = "finishMaterialMode(System.UInt32, System.Int32, System.Int32)"
local noxPlaying = nil     -- { addr, go, cont, glowComp }
local nox_start
noxStarting = false        -- global on purpose: read by the recorder defined later
noxGlowAgain = false       -- global: set by the recorder when it blocked a game glow request
-- 3.06: the blade glow without the glow MODE (it crashed weapon switches): the mode's only own value (dump 3.05, mode
-- 2834278566, material 2180083513) = float var hash 2797575560 0 -> 0.15, written directly with the colour
NOX.glowVar, NOX.glowRate = 2797575560, 0.15
NOX.GETF = "getMaterialFloat(System.UInt32, System.UInt32)"
NOX.SETF = "setMaterialFloat(System.UInt32, System.UInt32, System.Single)"
dbg.fogCut = 0.0           -- 3.17 fog test (cut the explosion copy after N s; 0 = off) - 3.20: off by default
dbg.noxGlowMode = false    -- 3.03 crash test (3.02 crash in MaterialInterpolation 1.5 s after the sword's glow mode was
                           -- finished at setDirectAndDestroyOld): no enchant glow MODE on the sword, game glow requests
                           -- not blocked. Shimmer + blade colour stay. Menu: Nox look settings.
local function comp_of(go, t)
    local ok, c = pcall(function() return go:call("getComponent(System.Type)", sdk.typeof(t)) end)
    return ok and c or nil
end
local function held_sword()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local p = cm and cm["<ManualPlayer>k__BackingField"]
    if not p then return nil end
    local sword = dbg.right_weapon()   -- (not getWeapon: it throws inside the game during a vocation change)
    if not sword then return nil end
    local go = sword:get_GameObject()
    return sword, go, comp_of(go, "via.effect.script.ObjectEffectManager2")
end
-- user (crash after ~5 switches, every round): our shimmer plays on the sword OUTSIDE the game's enchant system, so
-- nobody stopped it when the game deleted the sword -> an effect left on a deleted parent (the EffectManager crash
-- rule). Now it is killed the moment the game starts changing / clearing a weapon slot of mine, while the sword is
-- still there (hooks below, after nox_stop).
local function nox_stop()
    if not noxPlaying then return end
    pcall(function() if noxPlaying.cont and not noxPlaying.cont:call("get_isFinished") then noxPlaying.cont:call("finishAll()") end end)
    pcall(function() if noxPlaying.glowComp then noxPlaying.glowComp:call(GLOW_FINISH, NOX.glowMode, -1, -1) end end)
    noxPlaying = nil
end
-- 3.04: what the blade glow mode (NOX.glowMode) sets, read from the sword's MaterialInterpolationEnchant by FIELDS only
-- (ModeDataList -> _ModeList -> the mode whose _ModeValue = glowMode -> _MaterialList -> variables) -> data/Pactblade_glow_mode.json
function dbg.glow_mode_dump(go)
    if dbg.glowDumped then return end
    local mi = comp_of(go, "app.MaterialInterpolationEnchant")
    if not mi then return end
    dbg.glowDumped = true
    local function val(v, depth)
        if depth > 6 or v == nil then return v == nil and nil or "..." end
        local tv = type(v)
        if tv == "number" or tv == "boolean" or tv == "string" then return v end
        if tv == "userdata" then
            local out = {}
            local ok = pcall(function()
                local td = v:get_type_definition()
                out._type = td:get_full_name()
                if out._type:find("List`1") then
                    out.items = {}
                    for k = 0, math.min(v:get_field("_size") - 1, 40) do out.items[#out.items + 1] = val(v:get_field("_items")[k], depth + 1) end
                    return
                end
                if out._type == "System.String" then out = v:ToString(); return end
                while td and td:get_full_name() ~= "System.Object" do
                    for _, f in ipairs(td:get_fields()) do
                        if not f:is_static() then
                            local okf, fv = pcall(f.get_data, f, v)
                            if okf then
                                if type(fv) == "userdata" and fv.x ~= nil then out[f:get_name()] = { fv.x, fv.y, fv.z, fv.w }
                                else out[f:get_name()] = val(fv, depth + 1) end
                            end
                        end
                    end
                    td = td:get_parent_type()
                end
            end)
            if not ok then return "?" end
            return out
        end
        return tostring(v)
    end
    local out = { want = NOX.glowMode, modes = {} }
    local function scan(mdl, where)   -- a List<ModeData>
        pcall(function()
            for a = 0, mdl:get_field("_size") - 1 do
                local ml = mdl:get_field("_items")[a]:get_field("_ModeList")
                for b = 0, ml:get_field("_size") - 1 do
                    local mode = ml:get_field("_items")[b]
                    local mv = mode:get_field("_ModeValue")
                    out.modes[#out.modes + 1] = where .. ":" .. tostring(mv)
                    if mv == NOX.glowMode and not out.mode then out.mode = val(mode, 0); out.from = where end
                end
            end
        end)
    end
    scan(mi:get_field("ModeDataList"), "own")
    for _, lf in ipairs({ "UserDatas", "AddDatas" }) do   -- (the modes come from the game's data files)
        pcall(function()
            local l = mi:get_field(lf)
            for k = 0, l:get_field("_size") - 1 do
                local ud = l:get_field("_items")[k]
                scan(ud:get_field("_ModeDataList"), lf .. k)
            end
        end)
    end
    pcall(function() out.default = val(mi:get_field("_DefaultModeData"), 0) end)
    pcall(json.dump_file, "Pactblade_glow_mode.json", out)
    note(("blade glow mode read: %d modes, ours %s"):format(#out.modes, out.mode and "found" or "NOT found"))
end
function nox_start(go, mgr)
    pcall(dbg.glow_mode_dump, go)
    noxStarting = true
    local cont
    pcall(function()
        local eid = sdk.create_instance("via.effect.script.EffectID")
        eid.DataContainerIndex = -1; eid.ContainerID = 0; eid.ElementID = NOX.shimmer
        eid.IsContainerIDOnly = false; eid.IsElementIDOnly = false
        local c = mgr:call(NOX_REQ, eid, go, -1, nil)
        if c then cont = c:add_ref() end
    end)
    local glowComp
    local mi = comp_of(go, "app.MaterialInterpolationEnchant")
    if dbg.noxGlowMode and mi and pcall(function() mi:call(GLOW_SUB, NOX.glowMode, -1, -1, false, false) end) then glowComp = mi:add_ref() end
    noxPlaying = { addr = go:get_address(), go = go, cont = cont, glowComp = glowComp, orig = {} }
    noxStarting = false
end
;(function()   -- the weapon slots of mine: before any change / clear, our sword look goes (killAll: gone this frame)
    local function my_slot(slot)
        local mine = false
        pcall(function()
            local p = sdk.get_managed_singleton("app.CharacterManager")["<ManualPlayer>k__BackingField"]
            local h = p:get_WeaponAndItemHolder()
            local addr = slot:get_address()
            for _, g in ipairs({ "get_RightWeapon", "get_LeftWeapon" }) do
                local sl = h:call(g)
                if sl and sl:get_address() == addr then mine = true end
            end
        end)
        return mine
    end
    local function before_change(why)
        dbg.noxHoldUntil = os.clock() + 1.0
        if not noxPlaying then return end
        pcall(function() if noxPlaying.cont then noxPlaying.cont:call("killAll") end end)
        pcall(function() if noxPlaying.glowComp then noxPlaying.glowComp:call(GLOW_FINISH, NOX.glowMode, -1, -1) end end)
        noxPlaying = nil
        dbg.noxDropBlade = true
        dbg.noxStops = (dbg.noxStops or 0) + 1
        note("Nox look stopped before the weapon change (" .. why .. ")")
    end
    local WANT = { clear = true, release = true, equipPrepared = true, createWeapon = true, requestEquipWeapon = true,
                   prepareWeapon = true, changeWeapon = true, setDirectAndDestroyOld = true, onStartPreparing = true,
                   cancelPreparing = true }
    local n = 0
    for _, tn in ipairs({ "app.WeaponAndItemHolder.Slot", "app.WeaponAndItemHolder.WeaponSlot" }) do
        local td = sdk.find_type_definition(tn)
        for _, m in ipairs(td and td:get_methods() or {}) do
            local name = m:get_name()
            if WANT[name] then
                local ok = pcall(sdk.hook, m, function(args)
                    if noxPlaying == nil then return end   -- (3.16: every NPC's slots come through here - nothing to do)
                    pcall(function()
                        if my_slot(sdk.to_managed_object(args[2])) then before_change(name) end
                    end)
                end, function(r) return r end)
                if ok then n = n + 1 end
            end
        end
    end
    dbg.noxSlotHooks = n
end)()
local colorType = sdk.find_type_definition("via.Color")
local function make_color(r, g, b, a)
    local c = ValueType.new(colorType)
    c:call(".ctor(via.vec4)", Vector4f.new(r, g, b, a))
    return c
end
-- the boost (Eldritch Smite's second part): the blade glow gets brighter (user: the mist stays as it is)
function dbg.nox_boost(on) NOX.boosted = on end
-- which Nox look shows: the smite's (user's sliders for the skill) while it boosts, else the everyday one
if not cfg.noxSmite then   -- (once: the values set so far were meant for the skill; everyday goes back to the defaults)
    cfg.noxSmite = { bladeR = cfg.noxBladeR, bladeG = cfg.noxBladeG, bladeB = cfg.noxBladeB, bladeBright = cfg.noxBladeBright,
                     mistR = cfg.noxMistR, mistG = cfg.noxMistG, mistB = cfg.noxMistB, mistBright = cfg.noxMistBright }
    cfg.noxBladeR, cfg.noxBladeG, cfg.noxBladeB, cfg.noxBladeBright = 91, 26, 142, 1.0
    cfg.noxMistR, cfg.noxMistG, cfg.noxMistB, cfg.noxMistBright = 126, 0, 54, 1.3
    pcall(save_cfg)
end
function dbg.nox_look()
    if PB.activeVocation == "stormblade" then
        -- Electric lightning: sharp cyan-white blade core, minimal diffuse fog
        return 180, 230, 255, 3.0, 120, 200, 255, 0.4
    end
    local t = NOX.boosted and cfg.noxSmite
    if t then return t.bladeR, t.bladeG, t.bladeB, t.bladeBright, t.mistR, t.mistG, t.mistB, t.mistBright end
    return cfg.noxBladeR, cfg.noxBladeG, cfg.noxBladeB, cfg.noxBladeBright, cfg.noxMistR, cfg.noxMistG, cfg.noxMistB, cfg.noxMistBright
end
local function nox_tint()
    local np = noxPlaying
    if not np or not np.cont then return end
    for _, cont in ipairs({ np.cont }) do pcall(function()
        local entries = cont.CreatedEffects._entries
        for i = 0, entries:get_size() - 1 do
            local list = entries[i] and entries[i].value
            if list then
                for j = 0, list._size - 1 do
                    local effect = list._items[j]
                    if effect and effect:get_Valid() then
                        local key = tostring(effect:get_address())
                        pcall(function()
                            if not np.orig[key] then
                                local c = effect:get_Color()
                                np.orig[key] = { c:call("get_r"), c:call("get_g"), c:call("get_b"), c:call("get_a") }
                            end
                            local o = np.orig[key]
                            if o[4] == 0 or (o[1] + o[2] + o[3]) == 0 then return end
                            local _, _, _, _, mr, mg, mb, mbr = dbg.nox_look()
                            local mist = { mr / 255, mg / 255, mb / 255 }
                            local function ch(k) return math.min(1, (o[k] / 255) * mist[k] * mbr) end
                            effect:set_Color(make_color(ch(1), ch(2), ch(3), o[4] / 255))
                        end)
                    end
                end
            end
        end
    end) end
end
re.on_pre_application_entry("UpdateBehavior", function()
    pcall(function()
        local sword, go, mgr = held_sword()
        dbg.heldAddr = go and go:get_address() or nil   -- (user: crash after ~5 weapon switches - only THIS sword is touched)
        local want = cfg.nox and live.on and sword ~= nil and mgr ~= nil and sword:get_IsDrawed()
        if not want then
            if noxPlaying and noxPlaying.addr ~= dbg.heldAddr then   -- its sword is gone (switch): forgotten, not touched
                noxPlaying = nil
                dbg.noxDropBlade = true
            else nox_stop() end   -- (the same sword, sheathed / Nox off: put back properly)
            return
        end
        if noxPlaying and noxPlaying.addr ~= go:get_address() then
            noxPlaying = nil   -- (the old sword may be gone already: nothing of it is touched - the game cleans up)
            dbg.noxDropBlade = true
        end
        if dbg.noxSword ~= go:get_address() then dbg.noxSword, dbg.noxSwordT = go:get_address(), os.clock() end
        if not noxPlaying and os.clock() - (dbg.noxSwordT or 0) >= 1.5 and os.clock() >= (dbg.noxHoldUntil or 0) then nox_start(go, mgr) end   -- (a new sword settles first)
        -- the game tried to put its element glow on the blade (blocked): set the Nox glow again so it stays the last one
        if noxGlowAgain and noxPlaying and noxPlaying.glowComp then
            noxGlowAgain = false
            noxStarting = true
            pcall(function() noxPlaying.glowComp:call(GLOW_SUB, NOX.glowMode, -1, -1, false, false) end)
            noxStarting = false
            dbg.noxGlowAgain = (dbg.noxGlowAgain or 0) + 1
        end
        nox_tint()
    end)
end)
-- blade glow colour: Enchant_Color1 (main) / Enchant_Color2 (lighter highlight), written right before rendering;
-- kept for 2 s after sheathing while the glow fades, then the material's own colours come back
local nameHash = sdk.find_type_definition("app.StringExtension"):get_method("hash(System.String)")
local SET4 = "setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)"
local blade, fadeUntil = nil, 0
local function blade_restore()
    if not blade then return end
    pcall(function()
        for _, e in ipairs(blade.entries) do
            if e.float then blade.mesh:call(NOX.SETF, e.m, e.v, e.orig)
            else blade.mesh:call(SET4, e.m, e.v, Vector4f.new(e.orig[1], e.orig[2], e.orig[3], e.orig[4])) end
        end
    end)
    blade = nil
end
re.on_pre_application_entry("BeginRendering", function()
    if dbg.noxDropBlade then dbg.noxDropBlade = nil; blade = nil end   -- (sword changed: the old blade is not restored)
    if blade and blade.addr ~= dbg.heldAddr then blade = nil end   -- (its sword left my hand: never touched again)
    local active = noxPlaying ~= nil and (noxPlaying.glowComp ~= nil or not dbg.noxGlowMode) and noxPlaying.addr == dbg.heldAddr
    if active then fadeUntil = os.clock() + 2.0 end
    if not active and os.clock() > fadeUntil then blade_restore(); return end
    pcall(function()
        local mesh = active and comp_of(noxPlaying.go, "via.render.Mesh") or (blade and blade.mesh)
        if not mesh then return end
        if not blade or blade.mesh ~= mesh then
            blade_restore()
            local entries = {}
            for m = 0, mesh:get_MaterialNum() - 1 do
                for _, name in ipairs({ "Enchant_Color1", "Enchant_Color2" }) do
                    pcall(function()
                        local v = mesh:getMaterialVariableIndex(m, nameHash:call(nil, name))
                        if v == nil or v >= 65535 then return end   -- (this material has no such slot)
                        local f = mesh:getMaterialFloat4(m, v)
                        entries[#entries + 1] = { m = m, v = v, second = name == "Enchant_Color2", orig = { f.x, f.y, f.z, f.w } }
                    end)
                end
            end
            for m = 0, mesh:get_MaterialNum() - 1 do   -- (3.06) the glow mode's one value, set directly (no mode)
                pcall(function()
                    local v = mesh:getMaterialVariableIndex(m, NOX.glowVar)
                    if v == nil or v >= 65535 then return end
                    local f = mesh:call(NOX.GETF, m, v)
                    entries[#entries + 1] = { m = m, v = v, float = true, orig = f }
                end)
            end
            blade = { mesh = mesh:add_ref(), entries = entries, addr = noxPlaying.addr }
        end
        local br, bg, bb, bbr = dbg.nox_look()   -- (everyday, or the smite's look while it boosts)
        local c = { br / 255, bg / 255, bb / 255, 1 }
        local k = (NOX.boosted and NOX.boostGlow or 1) * bbr   -- (Eldritch Smite: brighter)
        for _, e in ipairs(blade.entries) do
            if e.float then mesh:call(NOX.SETF, e.m, e.v, NOX.glowRate)
            else
                local r, g, b = c[1] * k, c[2] * k, c[3] * k
                if e.second then r, g, b = (c[1] + 1) / 2 * k, (c[2] + 1) / 2 * k, (c[3] + 1) / 2 * k end
                mesh:call(SET4, e.m, e.v, Vector4f.new(r, g, b, c[4]))
            end
        end
    end)
end)
re.on_script_reset(function() blade_restore(); pcall(nox_stop) end)

-- stagger (knockdown) power of each blast kind: BLAST[kind].stagger x the game's value (from calcDamageReaction)
pcall(function()
    sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageReaction(app.HitController.DamageInfo)"),
        function(args)
            local s = thread.get_hook_storage()
            s.pbBurst = nil
            if not live.on or #blasts == 0 then return end
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                local b = blast_of(info:get_AttackHitController())
                if b and BLAST[b.kind].stagger then s.pbBurst = info; s.pbStagger = BLAST[b.kind].stagger end
            end)
        end, function(r)
            local s = thread.get_hook_storage()
            local info = s.pbBurst
            s.pbBurst = nil
            if info then pcall(function() info.DamageReaction = info.DamageReaction * (s.pbStagger or 1) end) end
            return r
        end)
end)

-- Eldritch Burst only makes enemies flinch: a heavier reaction the game picks (knocked down, blown away, launched,
-- slammed, quake, heavy hitback) becomes Hitback_M (app.AttackUserData.DamageTypeEnum values)
local FLINCH = 6                                   -- Hitback_M
local HEAVIER = { [3] = true, [4] = true }         -- Quake_S / Quake_L
for v = 7, 19 do HEAVIER[v] = true end             -- Hitback_L .. Blown_L
HEAVIER[22] = true                                 -- FlashFlood
pcall(function()
    sdk.hook(sdk.find_type_definition("app.HitController"):get_method("getReactionDamageType(app.HitController.DamageInfo)"),
        function(args)
            local s2 = thread.get_hook_storage()
            s2.pbCap = nil
            s2.pbJavelin = nil
            if not live.on then return end
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                if #blasts > 0 then
                    local b = blast_of(info:get_AttackHitController())
                    if b and BLAST[b.kind].flinchOnly then s2.pbCap = info end
                end
                if PB.activeVocation == "stormblade" and PB.javelinT and (os.clock() - PB.javelinT < 3.0) then
                    s2.pbJavelin = info
                end
            end)
        end, function(r)
            local s2 = thread.get_hook_storage()
            local isJav = s2.pbJavelin
            local info = s2.pbCap or isJav
            s2.pbCap = nil
            s2.pbJavelin = nil
            if not info then return r end
            if isJav then
                pcall(function()
                    info.DamageType = 6                     -- Hitback_M (clean flinch impact, NO stun)
                    info.DamageActType = 1                  -- Flinch
                    info.OverwriteBlownType = 6
                    info.DamageReaction = 120               -- Moderate flinch stagger
                    info.BlownReactionRate = 0
                    info.BlownReactionConvertLevel = 0
                    info.HitBackZ = math.min(info.HitBackZ or 0, 1.2)
                    info.HitBackY = 0
                    info.HitBackAddZ = 0
                    info.HitBackVec = Vector3f.new(0, 0, 0)
                end)
                return sdk.to_ptr(6)                        -- Return Hitback_M (flinch) to engine
            end
            local v = sdk.to_int64(r) & 0xFFFFFFFF
            if not HEAVIER[v] then return r end
            pcall(function() info.DamageType, info.DamageActType, info.OverwriteBlownType = FLINCH, FLINCH, FLINCH end)
            dbg.capped = (dbg.capped or 0) + 1
            return sdk.to_ptr(FLINCH)
        end)
end)

------------------------------------------------------------------------
-- menu
------------------------------------------------------------------------
;(function()   -- Archfey Combo + warp wisps: its own function, so its locals don't count against the main chunk's 200
------------------------------------------------------------------------
-- Archfey Combo (user's name): Cloudfall Strike's slot plays this while Pactblade is active (user's design):
--   Job02_StartFlightShot 0-71.6 -> warp to the target's left or right side -> Job01_RushAttack 34-67 -> warp
--   behind it -> Job01_RushAttackFinish 25-54 -> warp in front of it above its head -> Job01_EndRisingLunge to its
--   end (the game's landing follows). Target = the first enemy the opening hits; no hit = it ends after the opening.
--   Each warp: Blink Behind's cues (Skydragon's Fangtooth takeoff here, its arrival there).
------------------------------------------------------------------------
local COMBO = {
    { action = "Job02_StartFlightShot", from = 0.0, to = 71.6 },
    { action = "Job01_RushAttack", from = 34.0, to = 67.0, warp = "side" },
    { action = "Job01_RushAttackFinish", from = 25.0, to = 54.0, warp = "behind" },
    { action = "Job01_EndRisingLunge", from = 0.0, warp = "head" },
}
local COMBO_STAMINA = 250
local WARP_GAP = 1.2         -- metres between the target's body and us
local HEAD_ABOVE = 0.4       -- metres above the target's head for the falling strike
local HEAD_GAP = 0.6         -- ... and this close in front of its body
local CUES = {
    -- Quik Fot (recorded: takeoff 13/22/0 + 13/22/3 and its whoosh; arrival 13/23/1, 13/22/15, 13/22/10)
    quikfot = { depart_efx = { { 13, 22, 0 }, { 13, 22, 3 } }, depart_snd = { 1781269347 },   -- (4087819823, 4052369681 loop)
                arrive_efx = { { 13, 23, 1 }, { 13, 22, 15 }, { 13, 22, 10 } }, arrive_snd = { 1863385021 } },   -- (1840818767 loops)
    -- Blink Behind (Skydragon's Fangtooth takeoff / arrival)
    blink = { depart_efx = { { 14, 7, 10 } }, depart_snd = { 1717783091 },
              arrive_efx = { { 14, 7, 11 }, { 13, 0, 10 } }, arrive_snd = { 2823464530 } },
}
local CUE_SECS = 1.0
local ourReq = false
local cueLive = {}

local function flat_dir(x, z)
    local len = math.sqrt(x * x + z * z)
    if len < 0.0001 then return nil end
    return x / len, z / len, len
end
local function forward_of(q) return 2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y) end
local function yaw_rotation(dx, dz)
    local yaw = math.atan(dx, dz)
    return Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
end
local function is_alive(chara)
    if not chara then return false end
    local ok, valid = pcall(chara.get_Valid, chara)
    if not ok or not valid then return false end
    local okH, hp = pcall(function() return chara:get_Hit():get_Hp() end)
    if okH and type(hp) == "number" then return hp > 0 end
    return true
end
local function components_of(go, typeName)
    local found = {}
    local ok, comps = pcall(function() return go:call("get_Components") end)
    if not ok or not comps then return found end
    for _, c in ipairs(comps:get_elements()) do
        local td = c:get_type_definition()
        while td do
            if td:get_full_name() == typeName then found[#found + 1] = c; break end
            td = td:get_parent_type()
        end
    end
    return found
end

-- cues (Blink Behind's way): effects faded out with finishAll after CUE_SECS, sounds from the player's containers
local function cue_efx(a, ids, pos, rot)
    for _, mgr in ipairs(components_of(a.character:get_GameObject(), "via.effect.script.ObjectEffectManager2")) do
        combo.cueing = true
        local ok, res = pcall(function()
            local id = sdk.create_instance("via.effect.script.EffectID")
            id.DataContainerIndex, id.ContainerID, id.ElementID = ids[1], ids[2], ids[3]
            id.IsContainerIDOnly, id.IsElementIDOnly = false, false
            return mgr:call("requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, via.GameObject, System.String, via.effect.script.EffectManager.WwiseTriggerInfo)",
                id, pos, rot, nil, "root", nil)
        end)
        combo.cueing = false
        if ok and res then
            pcall(function()
                local c = res:add_ref()
                cueLive[#cueLive + 1] = { c = c, untilT = os.clock() + CUE_SECS }
                local idstr = ("%d/%d/%d"):format(ids[1], ids[2], ids[3])
                if cfg.blastTint and not cfg.noTint[idstr] and not tintSeen[c:get_address()] then
                    tintSeen[c:get_address()] = true
                    tint_note(idstr, "warp cue")
                    table.insert(tints, { c = c, born = os.clock(), addr = c:get_address(), id = idstr })
                end
            end)
            return true
        end
    end
    return false
end
local function cue_sound(a, triggerId)
    local go = a.character:get_GameObject()
    for _, sc in ipairs(components_of(go, "soundlib.SoundContainer")) do
        local ok, done = pcall(function()
            for _, info in pairs(sc._TriggerInfoList._items) do
                if info and info._TriggerId == triggerId then
                    local req = sc:call("createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)",
                        info, go, go, info._OffsetJointHash, false, false, 0, 0, nil, nil, nil, nil)
                    if req then
                        req = req:add_ref()
                        req["<Container>k__BackingField"] = sc
                        sc:call("trigger(soundlib.SoundManager.RequestInfo)", req)
                        return true
                    end
                end
            end
            return false
        end)
        if ok and done then return true end
    end
    return false
end
combo.cue_sound = cue_sound   -- (the cast test, outside this function, plays sounds with it)
-- a looping sound started with cue_sound stops only when told: SoundContainer.stopTriggered(id, object, fade ms)
function combo.stop_sound(a, triggerId, fadeMs)
    local go = a.character:get_GameObject()
    for _, sc in ipairs(components_of(go, "soundlib.SoundContainer")) do
        pcall(function() sc:call("stopTriggered(System.UInt32, via.GameObject, System.UInt32)", triggerId, go, fadeMs or 300) end)
    end
end
local function cues(a, efx, snd, pos, rot)
    for _, ids in ipairs(efx) do cue_efx(a, ids, pos, rot) end
    if dbg.noWarpSounds then return end
    combo.cueingSnd = true
    for _, id in ipairs(snd) do cue_sound(a, id) end
    combo.cueingSnd = false
end
re.on_frame(function()
    if #cueLive == 0 then return end
    local now = os.clock()
    for i = #cueLive, 1, -1 do
        if now >= cueLive[i].untilT then
            local c = cueLive[i].c
            for _, m in ipairs({ "finishAll", "finish", "killAll", "kill" }) do
                if pcall(function() c:call(m .. "()") end) then break end
            end
            table.remove(cueLive, i)
        end
    end
end)

-- terrain checks with _SharedCore's raycast (Blink Behind), when installed
local castOk, shared = pcall(require, "_SharedCore/Functions")
local cast_ray = castOk and type(shared) == "table" and shared.cast_ray or nil
local function nearest_hit(from, to, radius)
    if not cast_ray then return nil end
    local ok, best, bestD = pcall(function()
        local best, bestD
        for _, r in ipairs(cast_ray(from, to, 2, 0, radius or 0.05, 0) or {}) do
            local p = r[2]
            if p then
                p = Vector3f.new(p.x, p.y, p.z)
                local dx, dy, dz = p.x - from.x, p.y - from.y, p.z - from.z
                local d = dx * dx + dy * dy + dz * dz
                if not bestD or d < bestD then best, bestD = p, d end
            end
        end
        return best, bestD
    end)
    if not ok or not best then return nil end
    return best, math.sqrt(bestD)
end

combo.nearest_hit = nearest_hit   -- (3.96: Misty Strike's landing check)
local function face(a, dx, dz)
    pcall(function()
        local tac = a.character["<TargetAngleCtrl>k__BackingField"]
        local deg = math.deg(math.atan(dx, dz))
        tac.Front["<AngleDeg>k__BackingField"] = deg
        tac.Move["<AngleDeg>k__BackingField"] = deg
    end)
end

-- the spot next to the target for this part; nil + why when there is none
local function warp_spot(a, how, forced)
    local t = combo.target
    local tTr = t:get_GameObject():get_Transform()
    local tPos = tTr:get_Position()
    local pPos = a.character:get_GameObject():get_Transform():get_Position()
    local fx, fz = flat_dir(forward_of(tTr:get_Rotation()))
    if not fx then fx, fz = flat_dir(pPos.x - tPos.x, pPos.z - tPos.z) end
    if not fx then fx, fz = 0, 1 end
    local radius = 0.5
    pcall(function()
        local r = t["<CharaController>k__BackingField"]:call("get_Radius")
        if type(r) == "number" and r > 0 and r < 10 then radius = r end
    end)
    local dirs
    if forced then dirs = forced
    elseif how == "side" then
        local sgn = math.random() < 0.5 and 1 or -1
        dirs = { { fz * sgn, -fx * sgn }, { -fz * sgn, fx * sgn } }   -- one side, else the other
    elseif how == "behind" then dirs = { { -fx, -fz } }
    else dirs = { { fx, fz } } end
    local want = radius + (how == "head" and HEAD_GAP or WARP_GAP)
    local chest = Vector3f.new(tPos.x, tPos.y + 1.0, tPos.z)
    for _, d in ipairs(dirs) do
        local dist = want
        local _, hitD = nearest_hit(chest, Vector3f.new(chest.x + d[1] * want, chest.y, chest.z + d[2] * want), 0.4)
        if hitD then dist = hitD - 0.5 end
        if dist >= radius + 0.3 then
            local dest = Vector3f.new(tPos.x + d[1] * dist, tPos.y, tPos.z + d[2] * dist)
            if how == "head" then
                local headY = tPos.y + 1.7
                pcall(function()
                    for _, jn in ipairs({ "Head", "head", "Neck", "neck" }) do
                        local j = tTr:getJointByName(jn)
                        if j then headY = j:get_Position().y; return end
                    end
                end)
                dest.y = headY + cfg.finisherHeight   -- (was HEAD_ABOVE 0.4)
            else
                local g = nearest_hit(Vector3f.new(dest.x, tPos.y + 1.8, dest.z), Vector3f.new(dest.x, tPos.y - 3.0, dest.z), 0.05)
                if g and math.abs(g.y - tPos.y) < 2.5 then dest.y = g.y end
            end
            return dest, yaw_rotation(tPos.x - dest.x, tPos.z - dest.z), (tPos.x - dest.x), (tPos.z - dest.z), d.name
        end
    end
    return nil, "wall next to the target"
end

local hiddenMeshes = {}
local function meshes_of(go, out)
    for _, m in ipairs(components_of(go, "via.render.Mesh")) do out[#out + 1] = m end
    pcall(function()
        local c = go:get_Transform():call("get_Child")
        while c do
            meshes_of(c:get_GameObject(), out)
            c = c:call("get_Next")
        end
    end)
    return out
end
local function sword_shown(on)
    if on then
        for _, m in ipairs(hiddenMeshes) do pcall(function() m:call("set_Enabled", true) end) end
        hiddenMeshes = {}
        return
    end
    pcall(function()
        local go = held_sword_go()
        if not go then return end
        for _, m in ipairs(meshes_of(go, {})) do
            local en = true
            pcall(function() en = m:call("get_Enabled") end)
            if en then
                m:call("set_Enabled", false)
                local known = false
                for _, h in ipairs(hiddenMeshes) do if h == m then known = true end end
                if not known then hiddenMeshes[#hiddenMeshes + 1] = m:add_ref() end
            end
        end
    end)
end
local function combo_end(why)
    if combo.stage ~= 0 then
        combo.endT = os.clock()
        if combo.stage == 4 then
            combo.result = { text = combo.finalHit and "Archfey Combo: final strike HIT" or "Archfey Combo: final strike MISSED",
                             ok = combo.finalHit == true, t = os.clock() }
        else
            combo.result = { text = ("Archfey Combo stopped in part %d: %s"):format(combo.stage, tostring(why)), ok = false, t = os.clock() }
        end
    end
    if combo.stage == 4 and not combo.finalHit then note("final strike MISSED") end
    if combo.stage ~= 0 then note("combo ended: " .. why) end
    if combo.swordHidden then combo.swordWait = os.clock() end   -- shown again once the Archer animation is over
    combo.stage, combo.target, combo.reapply, combo.stick = 0, nil, nil, nil
end
local function combo_request(a, name)
    ourReq = true
    local ok = a:request_action(name, 0)
    ourReq = false
    return ok
end
local function motion_key(L)
    return L:call("get_MotionBankID") * 100000 + L:call("get_MotionID")
end
-- the enemy's four sides (unit directions from it), and the one we are on now
local SIDE_OPP = { front = "back", back = "front", left = "right", right = "left" }
local function enemy_sides(a)
    local tTr = combo.target:get_GameObject():get_Transform()
    local tPos = tTr:get_Position()
    local pPos = a.character:get_GameObject():get_Transform():get_Position()
    local fx, fz = flat_dir(forward_of(tTr:get_Rotation()))
    if not fx then fx, fz = 0, 1 end
    local sides = { front = { fx, fz }, back = { -fx, -fz }, right = { fz, -fx }, left = { -fz, fx } }
    local cur, best = "front", -2
    local dx, dz = flat_dir(pPos.x - tPos.x, pPos.z - tPos.z)
    if dx then
        for name, d in pairs(sides) do
            local dot = d[1] * dx + d[2] * dz
            if dot > best then cur, best = name, dot end
        end
    end
    return sides, cur
end
-- nk = the part about to start (2 / 3 / 4): which sides to try, in order
local function dynamic_spot(a, nk)
    local sides, cur = enemy_sides(a)
    combo.used = combo.used or {}
    local order = {}
    if nk == 2 then
        combo.used = { [cur] = true }
        order[1] = SIDE_OPP[cur]
        local perp = (cur == "front" or cur == "back") and { "left", "right" } or { "front", "back" }
        if math.random() < 0.5 then perp[1], perp[2] = perp[2], perp[1] end
        order[2], order[3] = perp[1], perp[2]
    elseif nk == 3 then
        local free = {}
        for _, n in ipairs({ "back", "front", "left", "right" }) do if not combo.used[n] then free[#free + 1] = n end end
        if free[1] ~= "back" and #free >= 2 and math.random() < 0.5 then free[1], free[2] = free[2], free[1] end
        order = free
    else
        for _, n in ipairs({ "back", "front", "left", "right" }) do if not combo.used[n] then order[#order + 1] = n end end
        for _, n in ipairs({ "back", "front", "left", "right" }) do if combo.used[n] and n ~= cur then order[#order + 1] = n end end
    end
    local forced = {}
    for _, n in ipairs(order) do forced[#forced + 1] = { sides[n][1], sides[n][2], name = n } end
    local dest, rot, dx, dz, name = warp_spot(a, nk == 4 and "head" or "side", forced)
    if dest then
        combo.used[name] = true
        note(("warp to part %d: from the enemy's %s to its %s"):format(nk, cur, name))
    end
    return dest, rot, dx, dz
end
local function combo_stage(a, k)
    local part = COMBO[k]
    combo.stage, combo.asked, combo.started, combo.framed = k, os.clock(), nil, false
    if k == 4 then combo.stick, combo.finalHit = nil, false end
    if part.action:find("^Job02_") then sword_shown(false); combo.swordHidden = true; combo.swordWait = nil
    elseif combo.swordHidden then sword_shown(true); combo.swordHidden = false end
    pcall(function() combo.prevMot = motion_key(a.character.FullBodyLayer) end)
    combo_request(a, part.action)
    note(("combo %d: %s (frames %.1f-%s)"):format(k, part.action, part.from, part.to and ("%.1f"):format(part.to) or "end"))
    combo.everUsed = true
end

local function combo_update(a)
    local now = os.clock()
    if combo.bufferUntil then
        if now > combo.bufferUntil or a:is_staggered() then
            combo.bufferUntil = nil
        elseif a:weapon_drawn() then
            combo.bufferUntil = nil
            local can = false
            pcall(function()
                local track = a.character:get_Human().Track
                can = track.All or track.Skill
            end)
            if can and combo.stage == 0 then
                combo.lastPress = now
                combo.want = true
                note("Archfey Combo: weapon drawn - executing buffered combo")
            end
        end
    end
    if combo.want then
        combo.want = false
        if combo.stage == 0 then
            combo.target = nil
            combo.t0 = now
            comboFx.seen, comboFx.list = {}, {}
            pcall(a.consume_stamina, a, COMBO_STAMINA)
            combo.aim, combo.aimT, combo.used = nil, now, nil
            if cfg.comboTurn and combo.pick_target then
                local ok, t, d = pcall(combo.pick_target, a, cfg.comboTurnRange, cfg.comboTurnCone)
                if ok and t then combo.aim = t:add_ref(); note(("Archfey Combo: turning to an enemy %.1f m away"):format(d)) end
            end
            combo_stage(a, 1)
        end
    end
    if combo.swordWait then
        local cur0 = tostring(a:current_action(0) or "")
        -- user: 1.5 s after the combo stops (the sword takes that long to fly back into the hand)
        local waited = now - combo.swordWait
        if waited >= 1.5 then   -- user: 1.5 s, no waiting for the Archer animation
            sword_shown(true)
            combo.swordHidden, combo.swordWait = false, nil
        else sword_shown(false) end
    end
    if combo.stage == 0 then return end
    local tr = a.character:get_GameObject():get_Transform()
    if combo.reapply then   -- the character controller can put us back for a frame or two after a warp
        tr:set_Position(combo.reapply.dest)
        tr:set_Rotation(combo.reapply.rot)
        face(a, combo.reapply.dx, combo.reapply.dz)
        combo.reapply.n = combo.reapply.n - 1
        if combo.reapply.n <= 0 then combo.reapply = nil end
    end
    if combo.swordHidden then sword_shown(false) end
    if combo.stage == 1 and combo.aim and not combo.target and combo.turn_to then   -- the opening: toward the enemy
        local dt = math.min(now - (combo.aimT or now), 0.1)
        combo.aimT = now
        pcall(combo.turn_to, a, combo.aim, dt, cfg.comboTurnSpeed)
    end
    if combo.target and not combo.reapply and (combo.stage == 1 or (combo.stage == 4 and not combo.finalHit)) then
        pcall(function()
            local t = combo.target:get_GameObject():get_Transform():get_Position()
            local p = tr:get_Position()
            if not combo.stick then
                combo.stick = { x = p.x - t.x, z = p.z - t.z }
                note(("part %d: staying %.1f m from the target"):format(combo.stage, math.sqrt(combo.stick.x ^ 2 + combo.stick.z ^ 2)))
            end
            tr:set_Position(Vector3f.new(t.x + combo.stick.x, p.y, t.z + combo.stick.z))
            local dx, dz = -combo.stick.x, -combo.stick.z
            if dx * dx + dz * dz > 0.0001 then
                tr:set_Rotation(yaw_rotation(dx, dz))
                face(a, dx, dz)
            end
        end)
    end
    local part = COMBO[combo.stage]
    local cur = a:current_action(0)
    if not combo.started then
        if cur == part.action then combo.started = now
        elseif now - combo.asked > 0.4 then return combo_end(part.action .. " did not start (now " .. tostring(cur) .. ")")
        else combo_request(a, part.action); return end
    end
    if cur ~= part.action then
        if not part.to then return combo_end("done") end
        return combo_end("interrupted by " .. tostring(cur))
    end
    local L = a.character.FullBodyLayer
    if motion_key(L) == combo.prevMot and now - combo.started < 0.25 then return end   -- not on the new animation yet
    local fr = L:call("get_Frame")
    if not combo.framed then
        combo.framed = true
        if part.from > 0 and fr < part.from then L:call("set_Frame", part.from); return end
    end
    if part.to and fr >= part.to then
        if combo.stage == 1 and not combo.target then
            pcall(function() combo_request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion") end)
            return combo_end("the opening hit nothing")
        end
        if not is_alive(combo.target) then return combo_end("target gone") end
        local nk = combo.stage + 1
        local dest, rot, dx, dz
        if cfg.comboDynamic then dest, rot, dx, dz = dynamic_spot(a, nk)
        else dest, rot, dx, dz = warp_spot(a, COMBO[nk].warp) end
        if not dest then return combo_end("no spot: " .. tostring(rot)) end
        local useWisps = cfg.warpFx == "wisps" and not dbg.comboNoWisps
        local CUE = CUES[cfg.warpFx] or CUES.quikfot
        if useWisps then
            CUE = CUES.quikfot
            local ok, err = pcall(wisps.burst, a, false)
            if not ok then note("warp wisps: " .. tostring(err)) end
        end
        if dbg.ai then pcall(dbg.ai.warp, a) end
        cues(a, useWisps and {} or CUE.depart_efx, CUE.depart_snd, tr:get_Position(), tr:get_Rotation())
        tr:set_Position(dest)
        tr:set_Rotation(rot)
        pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
        face(a, dx, dz)
        combo.reapply = { dest = dest, rot = rot, dx = dx, dz = dz, n = 2 }
        cues(a, useWisps and {} or CUE.arrive_efx, CUE.arrive_snd, dest, rot)
        if useWisps then pcall(wisps.burst, a, true) end
        combo_stage(a, nk)
    end
end
re.on_pre_application_entry("UpdateBehavior", function()
    if combo.stage == 0 and not combo.want and not combo.swordWait and not combo.bufferUntil then return end
    local a = runtime.player()
    if not a or not a:valid() or not live.on then combo.want = false; combo_end("Pactblade off"); return end
    local ok, err = pcall(combo_update, a)
    if not ok then combo_end("error: " .. tostring(err)) end
end)

-- the Archfey Combo's slot (cfg.comboSkill, default Riotous Fury) pressed while Pactblade is active: the combo instead
local SKILL_IDS, SKILL_NAMES = {}, {}
pcall(function()
    for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
        if f:is_static() then
            local v = f:get_data(nil)
            if type(v) == "number" then SKILL_IDS[f:get_name()] = v & 0xFFFFFFFF; SKILL_NAMES[v & 0xFFFFFFFF] = f:get_name() end
        end
    end
end)
pcall(function()
    local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
    sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
        if not live.on or not dbg.press_ok() then return end
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if combo.binding then   -- 'put it in the next skill I press'
            combo.binding = false
            if SKILL_NAMES[id] then cfg.comboSkill = SKILL_NAMES[id]; save_cfg(); combo.slotInfo = "now in " .. SKILL_NAMES[id] .. "'s slot" end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        if id ~= SKILL_IDS[cfg.comboSkill or ""] then return end
        local now = os.clock()
        if combo.stage == 0 and now - combo.lastPress > 0.6 then
            local a = runtime.player()
            if a and not a:weapon_drawn() then
                dbg.ensure_drawn(a)
                combo.bufferUntil = now + 1.2
                combo.lastPress = now
                note("Archfey Combo: weapon sheathed - unsheathe triggered")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            local can = false
            pcall(function()
                local track = a and a.character:get_Human().Track or runtime.player().character:get_Human().Track
                can = track.All or track.Skill
            end)
            if can then
                combo.lastPress = now
                combo.want = true
                note(tostring(cfg.comboSkill) .. " pressed: Archfey Combo")
            end
        end
        return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays (also not queued for later)
    end, function(r) return r end)
end)
-- Misty Step = Quik Fot after the bind: its own leap effects are switched off (combo_dust) and the warp wisps play
-- where we leave and on us where we land (Quik Fot's sounds stay)
local misty = { started = nil }
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if not live.on or cfg.warpFx ~= "wisps" or (misty.started and os.clock() - misty.started < 1.0) then return end
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                if name ~= "Job07_MagicBindJustLeap" then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                misty.started, misty.seen, misty.done = os.clock(), false, false
                combo.mistyUntil = os.clock() + 2.0
                local a = runtime.player()
                if a then pcall(wisps.burst, a, false) end
                if a and dbg.ai then pcall(dbg.ai.warp, a) end
                note("Misty Step: wisps")
            end)
        end, function(r) return r end)
end)
re.on_pre_application_entry("UpdateBehavior", function()
    if not misty.started or misty.done then return end
    local a = runtime.player()
    if not a or not a:valid() then misty.done = true; return end
    local cur = a:current_action(0)
    if cur == "Job07_MagicBindJustLeap" then misty.seen = true; return end
    if misty.seen or os.clock() - misty.started > 2.0 then
        misty.done = true
        if misty.seen then pcall(wisps.burst, a, true) end
    end
end)

-- any other way the vanilla Cloudward / Cloudfall starts (a queued press...) is turned into the combo too
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if ourReq or not live.on then return end
            -- during the combo's opening: Kite Arrow's own follow-up (the kick-off jump after a hit) is refused, so the
            -- opening plays on to its end frame and the combo warps
            if combo.stage == 1 then
                local skipF = false
                pcall(function()
                    local name = sdk.to_managed_object(args[4]):ToString()
                    if not name:find("^Job02_") or name == "Job02_StartFlightShot" then return end
                    if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                    skipF = true
                    if combo.refused ~= name then combo.refused = name; note("Kite Arrow follow-up refused: " .. name) end
                end)
                if skipF then return sdk.PreHookResult.SKIP_ORIGINAL end
                return
            end
            if combo.stage ~= 0 or dbg.INTEGRATED then return end   -- (i-0.1: no takeover of the vanilla action)
            if dbg.beam and (dbg.beam.ourReq or dbg.beam.stage) then return end   -- (3.21: the beam uses Riotous Fury's opening)
            if dbg.blink and (dbg.blink.ourReq or dbg.blink.stage) then return end   -- (3.85: Blink Strike uses Riotous Fury's last hit)
            local skip = false
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                local cs = cfg.comboSkill or "?"
                if name:sub(1, #cs) ~= cs or name:find("Landing$") then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                skip = true
                if os.clock() - combo.lastPress > 0.6 then
                    local a = runtime.player()
                    if a and not a:weapon_drawn() then
                        dbg.ensure_drawn(a)
                        combo.bufferUntil = os.clock() + 1.2
                        combo.lastPress = os.clock()
                        note("Archfey Combo: weapon sheathed - unsheathe triggered")
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                    combo.lastPress = os.clock()
                    combo.want = true
                    note("vanilla " .. name .. " requested: combo instead")
                end
            end)
            if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
end)

------------------------------------------------------------------------
-- TEST: our own warp look - enchantment wisps (weapon effect element 20, Dimension Door's way: they only show when a
-- weapon's own effect manager plays them, so a hidden Stalwart Sword is spawned once as the "donor") on the body:
-- feet and hips (butt / groin). "Show on me now" keeps them on for a look.
------------------------------------------------------------------------
wisps = { on = false, items = {}, donor = nil, joints = nil, info = "-", element = 30, useDonor = false, from = "-",
                layerNames = {}, layers = 0 }
local WISP_POINTS = {   -- user: feet and butt / groin are enough (also wisps.POINTS, for the menu)
    { key = "feet", name = "feet", find = { "L_Foot", "R_Foot", "L_Leg_Foot", "R_Leg_Foot", "L_Ankle", "R_Ankle" } },
    { key = "hips", name = "butt and groin", find = { "Hip", "Pelvis", "Waist", "C_Hip" } },
}
wisps.POINTS = WISP_POINTS
cfg.wispPts = cfg.wispPts or { feet = true, hips = true }
cfg.wispSize, cfg.wispMode, cfg.wispFreeze, cfg.wispA, cfg.wispB, cfg.wispSpeed = 1.0, "loop", 1.0, 0.0, 5.0, 1.0
cfg.wispTint, cfg.wispLayers, cfg.warpWispSecs = true, {}, 0.5   -- user: 0.5 s
cfg.wispElement = 30   -- user: 30 looks best
local WISP_KEYS = { "wispElement", "wispSize", "wispMode", "wispFreeze", "wispA", "wispB", "wispSpeed", "wispTint", "warpWispSecs" }
do
    local saved = json.load_file(PB.DATA) or {}
    if type(saved.wispPts) == "table" then
        for k, v in pairs(saved.wispPts) do if type(v) == "boolean" then cfg.wispPts[k] = v end end
    end
    for _, k in ipairs(WISP_KEYS) do
        if saved[k] ~= nil and type(saved[k]) == type(cfg[k]) then cfg[k] = saved[k] end
    end
    wisps.element = cfg.wispElement
    if type(saved.wispLayers) == "table" then
        for k, v in pairs(saved.wispLayers) do if type(v) == "boolean" then cfg.wispLayers[tonumber(k) or k] = v end end
    end
end
do
    local save0 = save_cfg
    save_cfg = function()
        save0()
        local d = json.load_file(PB.DATA) or {}
        d.wispPts = cfg.wispPts
        for _, k in ipairs(WISP_KEYS) do d[k] = cfg[k] end
        local L = {}
        for k, v in pairs(cfg.wispLayers) do L[tostring(k)] = v end
        d.wispLayers = L
        json.dump_file(PB.DATA, d)
    end
end

local DONOR_WEAPON = 3368873434   -- app.WeaponID of the Stalwart Sword (wp00_009)
function wisps.donor_mgr(a)
    local dn = wisps.donor
    if dn then
        local alive = false
        pcall(function() alive = dn.go:get_Name() ~= nil end)
        if alive then return dn.mgr end
        wisps.donor = nil
    end
    local owner = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_wisp_donor", 0):add_ref()
    owner:call(".ctor"); owner:set_Name("Pactblade_wisp_donor")
    local pos = a.character:get_GameObject():get_Transform():get_Position()
    owner:get_Transform():set_Position(Vector3f.new(pos.x, pos.y - 50, pos.z))    -- out of sight
    local em = sdk.get_managed_singleton("app.EquipmentManager")
    em:call("requestInstantiate(app.WeaponID, via.Component, System.Action`1<app.PrefabInstantiateResults>, System.Func`2<app.PrefabInstantiateArgs.DummyArg2,System.Boolean>)",
        DONOR_WEAPON, owner:get_Transform(), nil, nil)
    -- our copy = the child of our owner object (never the Stalwart Sword in someone's hand)
    local child = owner:get_Transform():call("get_Child")
    local go = child and child:get_GameObject()
    if not go then wisps.info = "donor sword did not spawn"; return nil end
    go = go:add_ref()
    pcall(function() go:call("set_DrawSelf", false) end)
    local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    if not mgr then wisps.info = "donor sword has no effect manager"; return nil end
    wisps.donor = { go = go, mgr = mgr:add_ref(), owner = owner }
    wisps.info = "donor sword ready"
    return wisps.donor.mgr
end

local function make_anchor(name)
    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, name, 0)
    go = go:add_ref()
    go:call(".ctor")
    go:set_Name(name)
    return go
end

-- user: use the enchanted sword's own (hidden) wisps -> the held sword's effect manager plays element 20 on our
-- anchor (our sword-effect blocker lets it through via noxStarting); the donor sword only when there is none
wisps.swapped = {}
function wisps.play_on(a, go)
    local function req(mgr)
        local eid = sdk.create_instance("via.effect.script.EffectID")
        eid.DataContainerIndex = -1; eid.ContainerID = 0; eid.ElementID = wisps.element
        eid.IsContainerIDOnly = false; eid.IsElementIDOnly = false
        return mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
            eid, go, -1, nil)
    end
    local c
    local sw = held_sword_go()
    local smgr = sw and sw:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    if smgr and not wisps.useDonor then
        noxStarting = true
        local ok, r = pcall(req, smgr)
        noxStarting = false
        if ok then c = r end
        wisps.from = "the sword in hand"
    end
    if not c then
        local mgr = wisps.donor_mgr(a)
        if not mgr then return nil end
        c = req(mgr)
        wisps.from = "the hidden donor sword"
    end
    if not c then return nil end
    return c:add_ref()
end
-- our file into the sword's wisp players (also retried each frame for a moment: players can come a frame later)
function wisps.swap(c)   -- (name kept) the sword's wisps in our colour through their own colour parameters
    local v = part_cfg("-1/8/40").variant
    local hue = part_cfg("-1/8/40").mode == "ours" and tonumber(tostring(v or ""):match("^e(%d+)$") or "")
    if not hue then return end
    local h = hue / 60
    local x = 1 - math.abs(h % 2 - 1)
    local rgb = ({ { 1, x, 0 }, { x, 1, 0 }, { 0, 1, x }, { 0, x, 1 }, { x, 0, 1 }, { 1, 0, x } })[math.floor(h) % 6 + 1]
    wisps.paramCol = wisps.paramCol or {}
    wisps.paramCol[hue] = wisps.paramCol[hue] or via_colour({ rgb[1], rgb[2], rgb[3], 1 })
    local col = wisps.paramCol[hue]
    local done = 0
    pcall(function()
        local list = c:call("getAllPlayers")
        for q = 0, (list and list:call("get_Count") or 0) - 1 do
            local pl = list:call("get_Item", q)
            for _, name in ipairs({ "BaseColor", "FireColor" }) do
                pcall(function()
                    local xp = pl:call("getExternParameter", name)
                    if xp then xp:call("set_Color", col); done = done + 1 end
                end)
            end
        end
    end)
    if done > 0 then
        wisps.swapped[c:get_address()] = true
        if not wisps.swapNoted then wisps.swapNoted = true; note(("warp wisps: coloured through %d colour parameter(s)"):format(done)) end
    end
end

-- the player's joints, found by name once (all names saved to data/Pactblade_joints.json)
function wisps.find_joints(a)
    if wisps.joints then return wisps.joints end
    local tr = a.character:get_GameObject():get_Transform()
    local names, byName = {}, {}
    pcall(function()
        for _, j in ipairs(tr:call("get_Joints"):get_elements()) do
            local n = j:call("get_Name")
            names[#names + 1] = n
            byName[n] = j
        end
    end)
    pcall(json.dump_file, "Pactblade_joints.json", names)
    local out = {}
    for _, pt in ipairs(WISP_POINTS) do
        out[pt.key] = {}
        local wantTwo = pt.key == "feet" or pt.key == "shoulders"
        for _, n in ipairs(pt.find) do
            if byName[n] then
                table.insert(out[pt.key], byName[n])
                if not wantTwo or #out[pt.key] >= 2 then break end
            end
        end
    end
    wisps.joints = out
    return out
end

function wisps.clear()
    for _, slot in ipairs(wisps.items) do
        for _, cp in ipairs(slot.copies or {}) do
            pcall(function() cp.c:call("killAll") end)
            pcall(function() cp.go:call("destroy(via.GameObject)", cp.go) end)
        end
    end
    wisps.items = {}
end

-- effect player (like the hand glow's): each copy keeps its own effect time; hidden copies (100 m down) are
-- fast-forwarded to where they should start. normal = plays at a speed; freeze = stopped at a moment;
-- loop = only the A-B part, a relay of copies so there is no gap
local WISP_FF = 0.15
local function wisp_speed(cp, sp)
    cp.speed = sp
    pcall(function() cp.c:call("setPlaySpeed", sp) end)
end
local function wisp_copy(a, slot, goal)
    local go = make_anchor("Pactblade_wisp")
    local cp = { go = go, t = 0, hidden = goal > 0, goal = goal }
    local ok, c = pcall(wisps.play_on, a, go)
    if not ok or not c then pcall(function() go:call("destroy(via.GameObject)", go) end); return nil end
    cp.c = c
    wisp_speed(cp, goal > 0 and math.max(1.0, goal / WISP_FF) or cfg.wispSpeed)
    table.insert(slot.copies, cp)
    return cp
end
local function wisp_kill(slot, k)
    local cp = slot.copies[k]
    pcall(function() cp.c:call("killAll") end)
    pcall(function() cp.go:call("destroy(via.GameObject)", cp.go) end)
    table.remove(slot.copies, k)
end

function wisps.update(a)
    local js = wisps.find_joints(a)
    local tr = a.character:get_GameObject():get_Transform()
    local rot = tr:get_Rotation()
    local now = os.clock()
    local dt = now - (wisps.lastT or now)
    wisps.lastT = now
    -- (re)build when the points or the player settings changed
    local want = {}
    for _, pt in ipairs(WISP_POINTS) do
        if cfg.wispPts[pt.key] then
            for _, j in ipairs(js[pt.key] or {}) do want[#want + 1] = { pt = pt, j = j } end
        end
    end
    local sig = ("%d:%s:%.2f:%.2f:%.2f:%.2f:%d"):format(#want, cfg.wispMode, cfg.wispFreeze, cfg.wispA, cfg.wispB, cfg.wispSpeed, wisps.element)
    for _, w in ipairs(want) do sig = sig .. w.pt.key end
    if sig ~= wisps.sig then
        wisps.clear()
        wisps.sig = sig
        for _, w in ipairs(want) do table.insert(wisps.items, { pt = w.pt, j = w.j, copies = {} }) end
    end
    local col = blast_colour()
    local n, shownT, layers = 0, nil, 0
    for _, slot in ipairs(wisps.items) do
        pcall(function()
            for _, cp in ipairs(slot.copies) do cp.t = cp.t + dt * (cp.speed or 0) end
            local mode = cfg.wispMode
            if mode == "normal" then
                local cp = slot.copies[1]
                local dead = not cp
                if cp then pcall(function() dead = cp.c:call("get_isFinished") end) end
                if dead then
                    if cp then wisp_kill(slot, 1) end
                    wisp_copy(a, slot, 0)
                end
            elseif mode == "freeze" then
                local cp = slot.copies[1]
                if not cp then wisp_copy(a, slot, cfg.wispFreeze)
                elseif cp.speed > 0 and cp.t >= cfg.wispFreeze then wisp_speed(cp, 0); cp.hidden = false end
            else   -- loop A-B
                local A, B = math.min(cfg.wispA, cfg.wispB - 0.05), cfg.wispB
                for k = #slot.copies, 1, -1 do
                    local cp = slot.copies[k]
                    if cp.hidden and cp.t >= A then cp.hidden = false; wisp_speed(cp, cfg.wispSpeed)
                    elseif not cp.hidden and cp.t >= B then wisp_kill(slot, k) end
                end
                local last = slot.copies[#slot.copies]
                if not last or (not last.hidden and last.t >= B - WISP_FF * cfg.wispSpeed) then wisp_copy(a, slot, A) end
            end
            -- place the copies on the body (hidden ones below the ground) and colour the chosen layers
            local p = slot.j:get_Position()
            if slot.pt.back then   -- behind the back: away from the character's facing
                local fx, fz = forward_of(rot)
                p = Vector3f.new(p.x - fx * slot.pt.back, p.y, p.z - fz * slot.pt.back)
            end
            for _, cp in ipairs(slot.copies) do
                local t2 = cp.go:get_Transform()
                t2:set_Position(cp.hidden and Vector3f.new(p.x, p.y - 100, p.z) or p)
                t2:set_Rotation(rot)
                t2:set_LocalScale(Vector3f.new(cfg.wispSize, cfg.wispSize, cfg.wispSize))
                if not cp.hidden then
                    n = n + 1
                    shownT = shownT or cp.t
                end
                if cfg.wispTint then
                    pcall(function()
                        local list = cp.c:call("getAllPlayers")
                        local cnt = list and list:call("get_Count") or 0
                        layers = math.max(layers, cnt)
                        for q = 0, cnt - 1 do
                            local pl = list:call("get_Item", q)
                            if pl and cfg.wispLayers[q + 1] ~= false then pl:set_Color(col) end
                            if pl and not wisps.layerNames[q + 1] then
                                pcall(function() wisps.layerNames[q + 1] = pl:call("get_Resource"):call("get_ResourcePath") end)
                                wisps.layerNames[q + 1] = wisps.layerNames[q + 1] or "?"
                            end
                        end
                    end)
                end
            end
        end)
    end
    wisps.layers = layers
    local miss = {}
    for _, pt in ipairs(WISP_POINTS) do
        if cfg.wispPts[pt.key] and #(js[pt.key] or {}) == 0 then miss[#miss + 1] = pt.name end
    end
    wisps.now = shownT
    wisps.info = ("%d wisps showing (from %s)%s"):format(n, wisps.from, #miss > 0 and (" | no joint found for: " .. table.concat(miss, ", ")) or "")
end

-- the warp look: a burst of wisps on the chosen points for warpWispSecs, then faded out (finishAll). follow = they
-- stay on the body (arrival), else they stay where we were (departure). Uses the effect player's settings: starts at
-- A (loop) / the frozen moment (freeze) / 0 (normal), at its speed
wisps.bursts = {}
local function wisp_layers_colour(c, col)
    pcall(function()
        local list = c:call("getAllPlayers")
        for q = 0, (list and list:call("get_Count") or 0) - 1 do
            local pl = list:call("get_Item", q)
            if pl and cfg.wispLayers[q + 1] ~= false then pl:set_Color(col) end
        end
    end)
end
function wisps.burst(a, follow)
    local js = wisps.find_joints(a)
    local goal = (cfg.wispMode == "loop" and cfg.wispA) or (cfg.wispMode == "freeze" and cfg.wispFreeze) or 0
    local now = os.clock()
    for _, pt in ipairs(WISP_POINTS) do
        if cfg.wispPts[pt.key] then
            for _, j in ipairs(js[pt.key] or {}) do
                local go = make_anchor("Pactblade_warpwisp")
                local ok, c = pcall(wisps.play_on, a, go)
                if ok and c then
                    local b = { go = go, c = c, t = 0, hidden = goal > 0, goal = goal, j = j, follow = follow, born = now,
                                pos = j:get_Position(), untilT = now + cfg.warpWispSecs + (goal > 0 and WISP_FF or 0) }
                    wisp_speed(b, goal > 0 and math.max(1.0, goal / WISP_FF) or cfg.wispSpeed)
                    table.insert(wisps.bursts, b)
                else
                    pcall(function() go:call("destroy(via.GameObject)", go) end)
                end
            end
        end
    end
end
function wisps.update_bursts(a)
    local now = os.clock()
    local dt = now - (wisps.burstT or now)
    wisps.burstT = now
    local col = blast_colour()
    for k = #wisps.bursts, 1, -1 do
        local b = wisps.bursts[k]
        b.t = b.t + dt * (b.speed or 0)
        if b.hidden and b.t >= b.goal then
            b.hidden = false
            wisp_speed(b, cfg.wispMode == "freeze" and 0 or cfg.wispSpeed)
        end
        if not b.ending and now >= b.untilT then
            b.ending = now
            wisp_speed(b, math.max(cfg.wispSpeed, 0.5))   -- a frozen one has to run to fade out
            pcall(function() b.c:call("finishAll") end)
        end
        if b.ending and now - b.ending > 2 then
            pcall(function() b.go:call("destroy(via.GameObject)", b.go) end)
            table.remove(wisps.bursts, k)
        else
            pcall(function()
                local p = b.follow and b.j:get_Position() or b.pos
                local t2 = b.go:get_Transform()
                t2:set_Position(b.hidden and Vector3f.new(p.x, p.y - 100, p.z) or p)
                t2:set_LocalScale(Vector3f.new(cfg.wispSize, cfg.wispSize, cfg.wispSize))
                wisps.swap(b.c)   -- every frame (the game may set them back)
                if cfg.wispTint and not wisps.swapped[b.c:get_address()] then wisp_layers_colour(b.c, col) end
            end)
        end
    end
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if #wisps.bursts > 0 then
        local a0 = runtime.player()
        if a0 and a0:valid() then pcall(wisps.update_bursts, a0) end
    end
    if not wisps.on then
        if #wisps.items > 0 then wisps.clear(); wisps.sig = nil end
        return
    end
    local a = runtime.player()
    if not a or not a:valid() then return end
    local ok, err = pcall(wisps.update, a)
    if not ok then wisps.info = "error: " .. tostring(err) end
end)
re.on_script_reset(function()
    wisps.clear()
    pcall(function() if wisps.donor then wisps.donor.owner:call("destroy(via.GameObject)", wisps.donor.owner) end end)
end)




------------------------------------------------------------------------
-- Eldritch Slash (user's design): Hindsight Sweep's slot plays Warrior's Job05_CrescentSlashNormal (frames 0-97)
-- and, at cfg.slashFrame, fires Magike Cut's wave (Mystic Spearhand's shell 6) from the sword hand, aimed like the
-- blasts (crosshair + lock-on), coloured with the blast colour. Super armour while it plays (user).
------------------------------------------------------------------------
local SLASH = { action = "Job05_CrescentSlashNormal", to = 97, shell = 6, stamina = 160, range = 8 }   -- (4.01 user: 160)
local slash = { on = false, lastPress = -10, waves = {}, rangeBase = {} }
combo.slash = slash
local function slash_end(why)
    if slash.on then note("Eldritch Slash ended: " .. why) end
    slash.on = false
    if slash.fast then
        slash.fast = false
        pcall(function() local a = runtime.player(); if a then a:set_speed(nil) end end)
    end
    if slash.armor then
        slash.armor = false
        pcall(function() local a = runtime.player(); if a then a:set_super_armor(false) end end)
    end
end
local function slash_lifetime()
    if SLASH.baseDur then return SLASH.baseDur * 5 end   -- 5x as far (user)
    note("Eldritch Slash: wave flight time not measured yet - normal distance this time")
    return nil
end
local function slash_learn(rec)
    if SLASH.baseLife or not rec then return end
    pcall(function()
        local p = rec.param or (rec.parts and rec.parts[1] and rec.parts[1].shell:get_ShellParameter())
        local b = p._ShellParameterBase and p._ShellParameterBase.ShellBaseParam or p.ShellBaseParam
        note(("Eldritch Slash: wave UseLifeTime %s, LifeTime %s"):format(tostring(b.UseLifeTime), tostring(b.LifeTime)))
        if b.LifeTime and b.LifeTime > 0 then SLASH.baseLife = b.LifeTime end
    end)
end
-- the nearest living enemy within cfg.slashTurnRange m and cfg.slashTurnCone degrees of where the character faces
local function slash_pick_target(a, range, cone, gap)
    range, cone, gap = range or cfg.slashTurnRange, cone or cfg.slashTurnCone, gap or 4
    local tr = a.character:get_GameObject():get_Transform()
    local p = tr:get_Position()
    local fx, fz = flat_dir(forward_of(tr:get_Rotation()))
    if not fx then return nil end
    local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
    local best, bestD
    for i = 0, list._size - 1 do
        pcall(function()
            local ch = list._items[i]._Chara
            if not is_alive(ch) then return end
            local q = ch:get_GameObject():get_Transform():get_Position()
            local dx, dz, d = flat_dir(q.x - p.x, q.z - p.z)
            if not dx or d > range or math.abs(q.y - p.y) > gap then return end
            if math.deg(math.acos(math.max(-1, math.min(1, dx * fx + dz * fz)))) > cone then return end
            if not bestD or d < bestD then best, bestD = ch, d end
        end)
    end
    return best, bestD
end
-- turns at most cfg.slashTurnSpeed degrees a second toward the target (slight tracking until the wave fires)
local function slash_turn(a, dt)
    local t = slash.target
    if not t or not is_alive(t) then return end
    local tr = a.character:get_GameObject():get_Transform()
    local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
    local tx, tz = flat_dir(q.x - p.x, q.z - p.z)
    local fx, fz = flat_dir(forward_of(tr:get_Rotation()))
    if not tx or not fx then return end
    local gap = math.atan(tx * fz - tz * fx, fx * tx + fz * tz)   -- yaw (atan(x, z)) still to turn
    local step = math.rad(cfg.slashTurnSpeed) * dt
    if math.abs(gap) > step then gap = gap > 0 and step or -step end
    local yaw = math.atan(fx, fz) + gap
    local dx, dz = math.sin(yaw), math.cos(yaw)
    tr:set_Rotation(yaw_rotation(dx, dz))
    face(a, dx, dz)
end
-- the same for the Archfey Combo opening (combo_update is defined above these: it reaches them through combo)
combo.pick_target = slash_pick_target
function combo.turn_to(a, t, dt, speed)
    if not t or not is_alive(t) then return end
    local tr = a.character:get_GameObject():get_Transform()
    local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
    local tx, tz = flat_dir(q.x - p.x, q.z - p.z)
    local fx, fz = flat_dir(forward_of(tr:get_Rotation()))
    if not tx or not fx then return end
    local gap = math.atan(tx * fz - tz * fx, fx * tx + fz * tz)
    local step = math.rad(speed) * dt
    if math.abs(gap) > step then gap = gap > 0 and step or -step end
    local yaw = math.atan(fx, fz) + gap
    local dx, dz = math.sin(yaw), math.cos(yaw)
    tr:set_Rotation(yaw_rotation(dx, dz))
    face(a, dx, dz)
end
local function slash_update(a)
    local now = os.clock()
    if slash.bufferUntil then
        if now > slash.bufferUntil or a:is_staggered() then
            slash.bufferUntil = nil
        elseif a:weapon_drawn() then
            slash.bufferUntil = nil
            local can = false
            pcall(function()
                local track = a.character:get_Human().Track
                can = track.All or track.Skill
            end)
            if can and not slash.on and combo.stage == 0 then
                slash.lastPress = now
                slash.want = true
                note("Eldritch Slash: weapon drawn - executing buffered skill")
            end
        end
    end
    if slash.want then
        slash.want = false
        if not slash.on and combo.stage == 0 then
            pcall(a.consume_stamina, a, SLASH.stamina)
            slash.on, slash.asked, slash.started, slash.fired = true, now, nil, false
            pcall(function() a:set_super_armor(true); slash.armor = true end)
            pcall(function() slash.prevMot = motion_key(a.character.FullBodyLayer) end)
            combo_request(a, SLASH.action)
            slash.target, slash.lastT = nil, now
            if cfg.slashTurn then
                local ok, t, d = pcall(slash_pick_target, a)
                if ok and t then slash.target = t:add_ref(); note(("Eldritch Slash: turning to an enemy %.1f m away"):format(d)) end
            end
            note("Eldritch Slash")
        end
    end
    if not slash.on then return end
    local cur = a:current_action(0)
    if not slash.started then
        if cur == SLASH.action then slash.started = now
        elseif now - slash.asked > 0.4 then return slash_end("did not start (now " .. tostring(cur) .. ")")
        else combo_request(a, SLASH.action); return end
    end
    if cur ~= SLASH.action then
        if slash.fast and tostring(cur or ""):find("^Job05_") then   -- the recovery is its own action: keep it fast
            pcall(function() a:set_speed(1.2) end)
            pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.2) end)
            return
        end
        return slash_end((slash.fired and "done" or "interrupted") .. " (next action " .. tostring(cur) .. ")")
    end
    local L = a.character.FullBodyLayer
    if motion_key(L) == slash.prevMot and now - slash.started < 0.25 then return end   -- not on the new animation yet
    local fr = L:call("get_Frame")
    local dt = now - (slash.lastT or now); slash.lastT = now
    if slash.target and fr < cfg.slashFrame then pcall(slash_turn, a, math.min(dt, 0.1)) end
    if fr >= cfg.slashFastFrom then
        if not slash.fast then note(("Eldritch Slash: 1.2x from frame %.1f"):format(fr)) end
        slash.fast = true
        pcall(function() a:set_speed(1.2) end)   -- every frame (user: the recovery 1.2x)
        pcall(function() L:call("set_Speed", 1.2) end)
    end
    if not slash.fired and fr >= cfg.slashFrame then
        slash.fired = true
        dbg.slashT = os.clock()
        local skel = false   -- (1.66 Skeleton Lord wave: only dust + a shockwave without its own effect files)
        local res, err = spawn(a, {
            type = "shell", id = "eldritch_slash",
            shell = skel and PB.SKELETON_SHELLS or PB.JOB07_SHELLS, shell_id = skel and 0 or SLASH.shell,
            cast = { mode = "owner", offset = { 0, 1.2, 1.3 }, face = "owner" },
            scale_axes = { 1, 2, 1 },                      -- 2x taller (user)
            -- (range: what ends its flight is still being looked for - data/Pactblade_wave_params.json)
        })
        if res and res.record then
            slash.rec = res.record
            -- Magike Cut's wave counts as a blast (coloured like them); the Skeleton Lord's keeps its own look
            if not skel then table.insert(blasts, { record = res.record, kind = "slash", born = os.clock() }) end
            slash.waveBorn, slash.waveMeasure, slash.waveDumped, slash.rangeSet = os.clock(), false, false, false
            note(("Eldritch Slash: wave at frame %.1f"):format(fr))
            if PB.activeVocation == "stormblade" and not skel then
                colour_shell(res.record, { 0.20, 0.70, 1.0, 1.0 }, 6.0, true)
            elseif cfg.blastTint and not skel then   -- the blasts' colour, exactly as they get it
                local k = cfg.armBright
                colour_shell(res.record, { math.min(1, cfg.armR / 255 * k), math.min(1, cfg.armG / 255 * k), math.min(1, cfg.armB / 255 * k), 1 }, 6.0)
            end
        else note("Eldritch Slash: wave failed: " .. tostring(err)) end
    end
    -- (no cut at SLASH.to: the recovery after it plays out, sped up from cfg.slashFastFrom; ends with the animation)
end
-- the wave's own built-in effect (the shell's ShellEffectContainer) in the slash colour, every frame while it flies
local function wave_meshes(rec)
    local out = {}
    for _, part in ipairs(rec.parts or {}) do
        pcall(function()
            local go = part.shell:get_GameObject()
            for _, m in ipairs(meshes_of(go, {})) do out[#out + 1] = m end
        end)
    end
    return out
end
local function wave_mesh_dump(meshes)
    if SLASH.meshDumped or #meshes == 0 then return end
    SLASH.meshDumped = true
    local all = {}
    for _, m in ipairs(meshes) do
        local md = { materials = {} }
        pcall(function() md.go = tostring(m:get_GameObject():get_Name()) end)
        pcall(function()
            for i = 0, m:call("get_MaterialNum") - 1 do
                local mat = { name = tostring(m:call("getMaterialName", i)), vars = {} }
                for v = 0, m:call("getMaterialVariableNum", i) - 1 do
                    local vr = { name = tostring(m:call("getMaterialVariableName", i, v)), type = m:call("getMaterialVariableType", i, v) }
                    pcall(function()
                        local f = m:call("getMaterialFloat4(System.UInt32, System.UInt32)", i, v)
                        vr.value = { f.x, f.y, f.z, f.w }
                    end)
                    mat.vars[#mat.vars + 1] = vr
                end
                md.materials[#md.materials + 1] = mat
            end
        end)
        all[#all + 1] = md
    end
    pcall(json.dump_file, "Pactblade_wave_mesh.json", all)
    note(("Eldritch Slash: wave has %d mesh(es) - materials written to data/Pactblade_wave_mesh.json"):format(#meshes))
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    local rec = slash.rec
    if not rec then return end
    local now = os.clock()
    if false then   -- (1.59-1.60 flight measurement: ended at once, gave 0.01 s - off)
        local alive = false
        pcall(function()
            local go = rec.parts[1].shell:get_GameObject()
            alive = go ~= nil and go:call("get_Valid") ~= false and rec.parts[1].shell:call("get_Valid") ~= false
        end)
        if not alive then
            slash.waveMeasure = false
            SLASH.baseDur = now - slash.waveBorn
            note(("Eldritch Slash: the wave flies %.2f s normally - next ones fly 5x that"):format(SLASH.baseDur))
        end
    end
    if now - (dbg.slashT or -10) > 30 then slash.rec = nil; return end
    if false then   -- (its own colour on the child effect player: off)
        local col = slash_colour()
        for _, part in ipairs(rec.parts or {}) do
            pcall(function()
                local ch = part.shell:get_GameObject():get_Transform():call("get_Child")
                while ch do
                    pcall(function()
                        local ep = ch:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer"))
                        if ep then ep:set_Color(col) end
                    end)
                    ch = ch:call("get_Next")
                end
            end)
        end
    end
    -- range: remember which wave shells are ours (the update() hook below scales their range)
    if not slash.rangeSet then
        pcall(function()
            local comp = rec.parts[1].shell:get_GameObject():call("getComponent(System.Type)", sdk.typeof("app.ShellAdditionalJob07SubNormalAttackShell"))
            if not comp then return end
            slash.waves[comp:get_address()] = os.clock()
            slash.rangeSet = true
        end)
    end
    for k, t in pairs(slash.waves) do if now - t > 30 then slash.waves[k] = nil end end
    local meshes = wave_meshes(rec)
    wave_mesh_dump(meshes)
    if true then return end   -- (mesh colouring + the TEST dumps below: off)
    local col = slash_colour and slash_colour()
    if not col then return end
    -- the wave's mesh: every colour value of its materials in the slash colour (alpha kept)
    local k = cfg.slashBright
    for _, m in ipairs(meshes) do
        pcall(function()
            for i = 0, m:call("get_MaterialNum") - 1 do
                for v = 0, m:call("getMaterialVariableNum", i) - 1 do
                    local name = tostring(m:call("getMaterialVariableName", i, v)):lower()
                    if name:find("color") or name:find("colour") then
                        pcall(function()
                            local f = m:call("getMaterialFloat4(System.UInt32, System.UInt32)", i, v)
                            m:call("setMaterialFloat(System.UInt32, System.UInt32, via.Float4)", i, v,
                                Vector4f.new(cfg.slashR / 255 * k, cfg.slashG / 255 * k, cfg.slashB / 255 * k, f.w))
                        end)
                    end
                end
            end
        end)
    end
    for _, part in ipairs(rec.parts or {}) do
        pcall(function()
            local c = part.shell:get_field("<ShellEffectContainer>k__BackingField")
            if not c then return end
            pcall(function() c:call("setRootColor(via.Color)", col) end)
            local list = c:call("getAllPlayers")
            for q = 0, (list and list:call("get_Count") or 0) - 1 do list:call("get_Item", q):set_Color(col) end
        end)
    end
end)
re.on_pre_application_entry("UpdateBehavior", function()
    if not slash.on and not slash.want and not slash.bufferUntil then return end
    local a = runtime.player()
    if not a or not a:valid() or not live.on then slash.want = false; slash_end("Pactblade off"); return end
    local ok, err = pcall(slash_update, a)
    if not ok then slash_end("error: " .. tostring(err)) end
end)

pcall(function()
    local scaled = {}
    sdk.hook(sdk.find_type_definition("app.ShellAdditionalJob07SubNormalAttackShell"):get_method("update()"), function(args)
        local this = sdk.to_managed_object(args[2])
        if not this or not slash.waves[this:get_address()] then return end
        local prm = this:get_field("<DetailParam>k__BackingField")
        if not prm then return end
        local key = prm:get_address()
        if not slash.rangeBase[key] then
            slash.rangeBase[key] = prm:get_field("DefaultRangeDist")
            note(("Eldritch Slash: wave range %.1f m normally, x%.1f now"):format(slash.rangeBase[key], cfg.slashRange))
        end
        prm:set_field("DefaultRangeDist", slash.rangeBase[key] * cfg.slashRange)
        scaled[#scaled + 1] = prm
    end, function(r)
        while #scaled > 0 do
            local prm = table.remove(scaled)
            pcall(function() prm:set_field("DefaultRangeDist", slash.rangeBase[prm:get_address()]) end)
        end
        return r
    end)
end)

-- (Misty Dive) a spot above an enemy's head, a bit toward us, facing it; and the combo's warp look + move to a spot
function combo.dive_spot(a, t, above, back)
    local tTr = t:get_GameObject():get_Transform()
    local tPos = tTr:get_Position()
    local pPos = a.character:get_GameObject():get_Transform():get_Position()
    local dx, dz = flat_dir(pPos.x - tPos.x, pPos.z - tPos.z)
    if not dx then dx, dz = 0, 1 end
    local headY
    pcall(function()   -- the highest joint with "head" in its name (big monsters name theirs differently)
        local joints = tTr:call("get_Joints")
        for k = 0, joints:call("get_Length") - 1 do
            local j = joints:call("Get", k)
            local nm = tostring(j:call("get_Name")):lower()
            if nm:find("head") then   -- (only joints on the creature: helper points can sit far away)
                local jp = j:get_Position()
                local near = math.abs(jp.x - tPos.x) < 6 and math.abs(jp.z - tPos.z) < 6 and jp.y > tPos.y and jp.y < tPos.y + 15
                if near and (not headY or jp.y > headY) then headY = jp.y end
            end
        end
    end)
    if not headY then   -- else the creature's own height
        pcall(function() local h = t["<CharaController>k__BackingField"]:call("get_Height"); if h and h > 0.5 then headY = tPos.y + h end end)
    end
    headY = headY or tPos.y + 1.7
    local dest = Vector3f.new(tPos.x + dx * back, headY + above, tPos.z + dz * back)
    return dest, yaw_rotation(-dx, -dz), -dx, -dz   -- (facing the enemy as seen from where I was)
end
function combo.warp_to(a, dest, rot, dx, dz)
    local tr = a.character:get_GameObject():get_Transform()
    local useWisps = cfg.warpFx == "wisps" and not dbg.comboNoWisps
    local CUE = CUES[cfg.warpFx] or CUES.quikfot
    if useWisps then
        CUE = CUES.quikfot
        pcall(wisps.burst, a, false)
    end
    if dbg.ai then pcall(dbg.ai.warp, a) end
    cues(a, useWisps and {} or CUE.depart_efx, CUE.depart_snd, tr:get_Position(), tr:get_Rotation())
    tr:set_Position(dest)
    tr:set_Rotation(rot)
    pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
    face(a, dx, dz)
    cues(a, useWisps and {} or CUE.arrive_efx, CUE.arrive_snd, dest, rot)
    if useWisps then pcall(wisps.burst, a, true) end
end
combo.face = face
combo.yaw = yaw_rotation   -- (3.10: for the Burst step, outside this function)

-- Hindsight Sweep (Job01_HindsightSlash) pressed while Pactblade is active: Eldritch Slash instead
local HINDSIGHT_ID = -1
pcall(function()
    for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
        if f:is_static() and f:get_name() == "Job01_HindsightSlash" then HINDSIGHT_ID = f:get_data(nil) & 0xFFFFFFFF end
    end
end)
pcall(function()
    local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
    sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
        if not live.on or not dbg.press_ok() then return end
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if id ~= HINDSIGHT_ID then return end
        local now = os.clock()
        if not slash.on and combo.stage == 0 and now - slash.lastPress > 0.6 then
            local a = runtime.player()
            if a and not a:weapon_drawn() then
                dbg.ensure_drawn(a)
                slash.bufferUntil = now + 1.2
                slash.lastPress = now
                note("Eldritch Slash: weapon sheathed - unsheathe triggered")
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            local can = false
            pcall(function()
                local track = a and a.character:get_Human().Track or runtime.player().character:get_Human().Track
                can = track.All or track.Skill
            end)
            if can then slash.lastPress = now; slash.want = true end
        end
        return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
    end, function(r) return r end)
end)
-- the vanilla Hindsight Sweep started any other way (a queued press...) becomes Eldritch Slash too
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if ourReq or not live.on or slash.on or dbg.INTEGRATED then return end
            local skip = false
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                if not name:find("^Job01_HindsightSlash") then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                skip = true
                if os.clock() - slash.lastPress > 0.6 then
                    local a = runtime.player()
                    if a and not a:weapon_drawn() then
                        dbg.ensure_drawn(a)
                        slash.bufferUntil = os.clock() + 1.2
                        slash.lastPress = os.clock()
                        note("Eldritch Slash: weapon sheathed - unsheathe triggered")
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                    slash.lastPress = os.clock(); slash.want = true
                end
            end)
            if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
end)

end)()

------------------------------------------------------------------------
-- STORMBLADE: LEVIN STORM & NOVA ELÉCTRICA EXECUTOR (Phase 3)
------------------------------------------------------------------------
;(function()
    PB.JOBMAGIC_SHELLS = "AppSystem/Shell/UserData/HumanShellParamData_JobMagic.user"
    PB.JOB08_SHELLS = "AppSystem/Shell/UserData/HumanShellParamData_Job08.user"
    pcall(function()
        local fx = require("DragonCore.game.actor_fx")
        if fx and fx.preload_shell then
            fx.preload_shell(PB.JOBMAGIC_SHELLS)
            fx.preload_shell(PB.JOB08_SHELLS)
        end
    end)

    local function update_stormblade_skills()
        if PB.activeVocation ~= "stormblade" then return end
        local a = runtime.player()
        if not a or not a:valid() then return end
        local now = os.clock()
        -- Heavy attack (Triangle / Y):
        -- Quick tap (< 0.35s) = 100% vanilla Fighter Heavy stab / Downed finisher (Untouched, no stutter, no delay!)
        -- Hold (>= 0.35s) = Stormblade Lightning Javelin Charge & Throw (No catapulting Unto Heven!)
        local cur_act = a:current_action(0) or ""
        local is_finisher = cur_act:find("FinishingMove") or cur_act:find("DownAttack")

        if a:button_down("AttackL") and not is_finisher then
            if not PB.heavy_hold_t0 then
                PB.heavy_hold_t0 = now
            end
            local hold_time = now - PB.heavy_hold_t0
            if hold_time >= 0.35 then
                if not PB.heavy_charge or PB.heavy_charge.phase == "idle" then
                    PB.heavy_charge = { phase = "charged", t0 = now }
                    note("Stormblade: Lightning Javelin charged!")
                end
            end
        else
            if PB.heavy_charge and PB.heavy_charge.phase == "charged" then
                -- Player released after a full charge: Unleash Lightning Javelin!
                PB.heavy_charge.phase = "idle"
                PB.heavy_hold_t0 = nil
                -- Use clean forward cast/throw (Job07_MagicBindComplete), NEVER Unto Heven's baseball catapult!
                pcall(function()
                    a:request_action("Job07_MagicBindComplete", 0)
                end)
                pcall(function()
                    if a.character and a.character.FullBodyLayer then
                        a.character.FullBodyLayer:call("set_PlaySpeed", 1.4)
                    end
                end)
                PB.javelin_active = true
                PB.javelin_t0 = now
                PB.javelinT = now
                PB.javelin_spawned = false
                note("Stormblade: Lightning Javelin unleashed from charged release!")
            else
                -- Released without charging: Reset timer, normal heavy stab finishes cleanly
                PB.heavy_charge = nil
                PB.heavy_hold_t0 = nil
            end
        end

        if PB.javelin_active then
            local elapsed = now - (PB.javelin_t0 or now)
            if not PB.javelin_spawned and elapsed >= 0.12 then
                PB.javelin_spawned = true
                PB.javelinT = now
                local shell_node = {
                    type = "shell",
                    id = "sb_javelin",
                    shell = PB.JOB07_SHELLS or "AppSystem/Shell/UserData/HumanShellParamData_Job07.user",
                    shell_id = 12,
                    scale_axes = { 0.7, 0.7, 4.5 },
                    cast = { mode = "joint", joint = "L_Hand_Palm", face = "crosshair" },
                    element = "Thunder",
                    damage_type = "Hitback_M",
                    color = { 50, 200, 255, 255 },
                    speed = 5.5
                }
                local res, err = spawn(a, shell_node, nil)
                if res and res.record then
                    colour_shell(res.record, { 0.30, 0.85, 1.0, 1.0 }, 6.0, true)
                    note("Stormblade: Lightning Javelin hurled!")
                end
            end
            if elapsed >= 0.75 then
                PB.javelin_active = false
            end
        end

        -- Cleanse any residual MagicBind paralysis on javelin targets (Zero stun, pure damage)
        if PB.javelin_unbind_targets and #PB.javelin_unbind_targets > 0 then
            local now_t = os.clock()
            for i = #PB.javelin_unbind_targets, 1, -1 do
                local entry = PB.javelin_unbind_targets[i]
                if now_t > entry.untilT then
                    table.remove(PB.javelin_unbind_targets, i)
                else
                    pcall(function()
                        local t = entry.target
                        local bc = nil
                        pcall(function() bc = t:get_field("<BindCtrl>k__BackingField") end)
                        if not bc and t.call then pcall(function() bc = t:call("get_BindCtrl") end) end
                        if bc then
                            local mod = bc:call("get_MagicBind")
                            if mod then
                                mod:call("stop(System.Boolean)", false)
                                pcall(mod.call, mod, "deleteBindEffect")
                            end
                        end
                    end)
                end
            end
        end
        if a.character and PB.javelinT and (now - PB.javelinT < 1.0) then
            pcall(function()
                local h = a.character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("app.Human"))
                if h then
                    local j7 = h:get_field("<Job07ActionCtrl>k__BackingField")
                    local mb = j7 and j7:get_field("<MagicBindCtrl>k__BackingField")
                    if mb then mb:call("resetHitMagicBindInfo") end
                end
            end)
        end

        -- Maintain native Thunder Boon crackling electricity on the sword
        if a.character and a:weapon_drawn() then
            pcall(function()
                local st = require("DragonCore.game.statuses")
                if not st.active(a.character, "thunder_boon") then
                    st.apply(a.character, "thunder_boon")
                end
            end)
        end

        -- 1. Levin Storm (Triggered by Job01_RisingLunge)
        if PB.levinWant and (now - PB.levinWant < 1.2) then
            local cur = a:current_action(0)
            if cur and cur:find("RisingLunge") then
                PB.levinWant = nil
                PB.levinT = now
                local t = dbg.beam and dbg.beam.aim_pick and dbg.beam.aim_pick(a, 1.5)
                local targetPos = nil
                if t then
                    pcall(function() targetPos = t:get_GameObject():get_Transform():get_Position() end)
                end
                local castOpts = targetPos and { mode = "target", lock_range = 35 } or { mode = "owner", offset = { 0, 0, 5 }, face = "owner" }
                local res, err = spawn(a, {
                    type = "shell",
                    id = "sb_levin",
                    shell = PB.JOBMAGIC_SHELLS,
                    shell_id = 8,
                    cast = castOpts,
                    scale = 1.4
                }, targetPos and { aim = targetPos } or nil)
                if res and res.record then
                    colour_shell(res.record, { 0.20, 0.70, 1.0, 1.0 }, 6.0, true)
                    note("Stormblade: Levin Storm celestial bolt unleashed!")
                else
                    note("Stormblade: Levin spawn: " .. tostring(err))
                end
            end
        elseif PB.levinWant and (now - PB.levinWant >= 1.2) then
            PB.levinWant = nil
        end

        -- 2. Nova Eléctrica (Triggered by Job01_FullMoonSlash)
        if PB.novaWant and (now - PB.novaWant < 1.2) then
            local cur = a:current_action(0)
            if cur and cur:find("FullMoonSlash") then
                PB.novaWant = nil
                PB.novaT = now
                local res, err = spawn(a, {
                    type = "shell",
                    id = "sb_nova",
                    shell = PB.JOBMAGIC_SHELLS,
                    shell_id = 36,
                    cast = { mode = "owner", offset = { 0, 0.3, 0 }, face = "owner" },
                    scale_axes = { 2.5, 1.5, 2.5 }
                })
                if not (res and res.record) then
                    res = spawn(a, {
                        type = "shell",
                        id = "sb_nova_alt",
                        shell = PB.JOB07_SHELLS,
                        shell_id = 3,
                        cast = { mode = "owner", offset = { 0, 0.3, 0 }, face = "owner" }
                    })
                end
                if res and res.record then
                    colour_shell(res.record, { 0.20, 0.70, 1.0, 1.0 }, 6.0, true)
                    note("Stormblade: Nova Eléctrica 360 shockwave unleashed!")
                else
                    note("Stormblade: Nova spawn: " .. tostring(err))
                end
            end
        elseif PB.novaWant and (now - PB.novaWant >= 1.2) then
            PB.novaWant = nil
        end
    end

    re.on_pre_application_entry("UpdateBehavior", update_stormblade_skills)
end)()

re.on_frame(function()
    local r = combo.result
    if not r or os.clock() - r.t > 4 then return end
    pcall(function()
        local col = r.ok and 0xFF40FF40 or 0xFF4040FF   -- ABGR: green / red
        draw.text(r.text, 60, 220, 0xFF000000)
        draw.text(r.text, 59, 219, col)
    end)
end)

-- time skip to `hour`:00 where the player stands (app.TimeSkipManager.requestPlayerWarp, as Nick's Devtools do)
function dbg.day_skip(hour)
    local tm, ts = sdk.get_managed_singleton("app.TimeManager"), sdk.get_managed_singleton("app.TimeSkipManager")
    local tr = runtime.player().character:get_GameObject():get_Transform()
    local h, d = tm:get_InGameHour(), tm:get_InGameDay()
    if h >= hour then d = d + 1 end
    ts:call("requestPlayerWarp", hour, 0, d, tr:get_UniversalPosition(), tr:get_Rotation(), nil, true, true)
    note(("time skip: %d:00 -> %d:00"):format(h, hour))
end
-- keep it daytime: once it gets dark (19:00-4:59), skip to 10:00 - not while a Pactblade skill plays
re.on_frame(function()
    if not cfg.keepDay then return end
    local now = os.clock()
    if now - (dbg.dayCheck or 0) < 5 then return end
    dbg.dayCheck = now
    pcall(function()
        if combo.stage ~= 0 or (combo.slash and combo.slash.on) then return end
        local h = sdk.get_managed_singleton("app.TimeManager"):get_InGameHour()
        if (h >= 19 or h < 5) and now - (dbg.daySkipped or -100) > 30 then
            dbg.daySkipped = now
            dbg.day_skip(10)
        end
    end)
end)
;(function()   -- (4.92) game time: real time minus menus / pauses (Hellish Rebuke's fire + cooldown, Hex)
    local paused, last = 0, nil
    function dbg.gclock() return os.clock() - paused end
    re.on_application_entry("LateUpdateBehavior", function()
        local t = os.clock()
        local dt = t - (last or t)
        last = t
        local p = dt > 0.25
        if not p then pcall(function() local gm = sdk.get_managed_singleton("app.GuiManager"); if gm and gm:call("isPausedGUI") then p = true end end) end
        if not p then pcall(function() local tm = sdk.get_managed_singleton("app.TimeManager"); if tm and tm:call("get_IsTimeStop") then p = true end end) end
        if p then paused = paused + dt end
    end)
end)()
;(function()   -- (4.96) no aiming reticle for Pactblade (it never aims)
    dbg.noReticle = false   -- (4.97: the dot was VSB's own crosshair option, not the game's reticle - this stays off)
    local noted = false
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.Player"):get_method("drawReticle"), function(args)
            if not live.on or not dbg.noReticle then return end
            local mine = false
            pcall(function() mine = sdk.to_managed_object(args[2]):get_GameObject():get_address() == live.go end)
            if not mine then return end
            if not noted then
                noted = true
                local act = "?"
                pcall(function() act = tostring(runtime.player():current_action(0)) end)
                note(("reticle: the game draws one for me (action %s, Archfey Combo used before: %s) - hidden"):format(act, tostring(combo.everUsed == true)))
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(r) return r end)
    end)
end)()
local ai = { secs = 0.3, log = {}, nextOk = 0 }
dbg.ai = ai   -- (the warps, inside the combo function, reach it through dbg)
local function ai_note(sx) table.insert(ai.log, 1, sx); while #ai.log > 8 do table.remove(ai.log) end; note("afterimage: " .. sx) end
function ai.handler(a)
    return a.character:get_Human()["<Job07ActionCtrl>k__BackingField"]["<AfterImageHandler>k__BackingField"]
end
function ai.inspect(a)
    local h = ai.handler(a)
    local inst = h:call("get_Instance")
    if not inst then ai_note("inspect: no clone"); return end
    local out = {}
    for _, g in ipairs({ "get_InProcess", "get_Appeared" }) do out[#out + 1] = "handler." .. g:sub(5) .. "=" .. tostring(h:call(g)) end
    for _, g in ipairs({ "get_Status", "get_NextStatus" }) do
        local ok, v = pcall(inst.call, inst, g)
        out[#out + 1] = g:sub(5) .. "=" .. tostring(ok and v)
    end
    pcall(function()
        local go = inst:get_GameObject()
        out[#out + 1] = "draw=" .. tostring(go:call("get_DrawSelf"))
        local d = (go:get_Transform():get_Position() - a.character:get_GameObject():get_Transform():get_Position()):length()
        out[#out + 1] = ("%.1f m from me"):format(d)
        if ai.spot then out[#out + 1] = ("%.1f m from the spot"):format((go:get_Transform():get_Position() - ai.spot):length()) end
    end)
    ai_note("inspect: " .. table.concat(out, " "))
end
ai.fx = 3   -- which Mirage Dance effects: 1 = element 0, 2 = element 20, 3 = both, 4 = none
ai.FX = { { 0 }, { 20 }, { 0, 20 }, {} }
ai.src = 1
ai.anchors = {}
function ai.play_ours(cgo, el, hue)
    local path = ("vfx/effects/pactblade/pb_ai%02d_h%d.efx"):format(el, hue)
    ai.res = ai.res or {}
    if ai.res[path] == nil then
        local r = sdk.create_resource("via.effect.EffectResource", path)
        ai.res[path] = r and r:add_ref() or false
    end
    if not ai.res[path] then return "copy not found (restart the game for the pak)" end
    local go = make_anchor()
    go:set_Name("Pactblade_afterimage_fx")
    local tr = go:get_Transform()
    tr:call("set_Parent", cgo:get_Transform())
    tr:set_LocalPosition(Vector3f.new(0, 0, 0))
    local holder = ai.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref()
    local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
    ep:call("set_Resource", holder)
    pcall(function() ep:call("set_AutoStart", true) end)
    table.insert(ai.anchors, { go = go, ep = ep })
    return "ours"
end
function ai.play_fx(a, cgo)
    local p40 = part_cfg("-1/8/40")
    local hue = p40.mode == "ours" and tonumber(tostring(p40.variant or ""):match("^e(%d+)$") or "")
    local mine = {}
    if hue and ai.src ~= 2 then
        for _, el in ipairs(ai.FX[ai.fx] or {}) do mine[#mine + 1] = el .. ":" .. ai.play_ours(cgo, el, hue) end
        if ai.src == 1 then return "aura " .. table.concat(mine, " ") end
    end
    local mgr = a.game_object:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    local conts = mgr.ExternalDataContainers
    local idx
    for i = 0, conts:get_Count() - 1 do
        local ok, path = pcall(function() return tostring(conts[i].DataContainer:get_Path()) end)
        if ok and path:lower():find("ch07/13_ch07_cs") then idx = i end
    end
    if not idx then return "Mystic Spearhand's cs effects are not on this character" end
    local got = {}
    for _, el in ipairs(ai.FX[ai.fx] or {}) do
        local id = sdk.create_instance("via.effect.script.EffectID")
        id.DataContainerIndex = idx; id.ContainerID = 10; id.ElementID = el
        id.IsContainerIDOnly = false; id.IsElementIDOnly = false
        local ok, c = pcall(mgr.call, mgr, "requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
            id, cgo, -1, nil)
        got[#got + 1] = ("%d:%s"):format(el, tostring(ok and c ~= nil))
        if ok and c then ai.conts = ai.conts or {}; table.insert(ai.conts, c:add_ref()) end
    end
    return "effects " .. table.concat(got, " ") .. (#mine > 0 and (" + ours " .. table.concat(mine, " ")) or "")
end
function ai.snapshot(a)
    local snap = {}
    local tr = a.character:get_GameObject():get_Transform()
    local joints = tr:call("get_Joints")
    for k = 0, (joints and joints:call("get_Length") or 0) - 1 do
        pcall(function()
            local j = joints:call("Get", k)
            snap[#snap + 1] = { name = j:call("get_Name"), pos = j:call("get_LocalPosition"), rot = j:call("get_LocalRotation") }
        end)
    end
    return snap
end
function ai.apply_pose(inst)
    if ai.poseOf ~= ai.snap then   -- a new pose: its joints on the clone, looked up once
        local ctr = inst:get_GameObject():get_Transform()
        ai.cj, ai.pose, ai.poseOf = ai.cj or {}, {}, ai.snap
        for _, e in ipairs(ai.snap or {}) do
            local j = ai.cj[e.name]
            if j == nil then
                local okJ, jj = pcall(ctr.call, ctr, "getJointByName", e.name)
                j = okJ and jj or false
                ai.cj[e.name] = j
            end
            if j then ai.pose[#ai.pose + 1] = { j = j, pos = e.pos, rot = e.rot } end
        end
    end
    for _, e in ipairs(ai.pose or {}) do
        pcall(e.j.call, e.j, "set_LocalPosition", e.pos)
        pcall(e.j.call, e.j, "set_LocalRotation", e.rot)
    end
end
function ai.meshes(go, out, depth)
    out = out or {}
    pcall(function()
        local m = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
        if m then out[#out + 1] = m end
    end)
    if (depth or 0) < 4 then
        pcall(function()
            local ch = go:get_Transform():call("get_Child")
            while ch do
                ai.meshes(ch:get_GameObject(), out, (depth or 0) + 1)
                ch = ch:call("get_Next")
            end
        end)
    end
    return out
end
function ai.hsv(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    if mx <= 0 then return 0, 0, 0 end
    local s0, h = (mx - mn) / mx, 0
    if mx > mn then
        if mx == r then h = (g - b) / (mx - mn) elseif mx == g then h = 2 + (b - r) / (mx - mn) else h = 4 + (r - g) / (mx - mn) end
        h = (h * 60 + 360) % 360
    end
    return h, s0, mx
end
function ai.rgb(h, s0, v)
    local c = v * s0
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local t = ({ { c, x, 0 }, { x, c, 0 }, { 0, c, x }, { 0, x, c }, { x, 0, c }, { c, 0, x } })[math.floor(h / 60) % 6 + 1]
    return t[1] + m, t[2] + m, t[3] + m
end
-- the clone's teal material colours: found once (0.3 s in), then kept in the picker's hue right before rendering
ai.GHOST = { { name = "RimLight_Emissive_Color_A", rgb = { 0.118, 0.235, 1.0 } },
             { name = "RimLight_Emissive_Color_B", rgb = { 0.235, 1.0, 0.784 } } }
function ai.find_colours(inst)
    local found = {}
    for _, g in ipairs(ai.GHOST) do g.h, g.s, g.v = ai.hsv(g.rgb[1], g.rgb[2], g.rgb[3]); g.hash = g.hash or nameHash:call(nil, g.name) end
    for _, mesh in ipairs(ai.meshes(inst:get_GameObject())) do
        pcall(function()
            for i = 0, mesh:call("get_MaterialNum") - 1 do
                for _, g in ipairs(ai.GHOST) do
                    pcall(function()
                        local v = mesh:call("getMaterialVariableIndex", i, g.hash)
                        if v ~= nil and v < 65535 then
                            found[#found + 1] = { mesh = mesh:add_ref(), m = i, v = v, w = 1.0, s = g.s, val = g.v }
                        end
                    end)
                end
            end
        end)
    end
    return found
end
re.on_pre_application_entry("BeginRendering", function()
    if not ai.t0 or not ai.colours then return end
    local p40 = part_cfg("-1/8/40")
    local hue = p40.mode == "ours" and tonumber(tostring(p40.variant or ""):match("^e(%d+)$") or "")
    if not hue then return end
    for _, e in ipairs(ai.colours) do
        pcall(function()
            local r, g, b = ai.rgb(hue, e.s, e.val)
            e.mesh:call("setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)", e.m, e.v, Vector4f.new(r, g, b, e.w))
        end)
    end
end)
-- a warp starts (before the player is moved): the afterimage here, in this pose
function ai.blocked()   -- (4.60) the guise holds the SHARED afterimage clone right now
    local g = dbg.guise
    return g ~= nil and (g.on or g.parked or g.ending) and g.isOwn == false
end
function ai.warp(a)
    if not cfg.afterimage or ai.blocked() then return end
    ai.secs = cfg.afterimageSecs
    if ai.t0 and ai.inst and ai.step and ai.step >= 1 then   -- still showing: it moves to this warp's spot + pose
        local tr = a.character:get_GameObject():get_Transform()
        ai.spot, ai.rot, ai.snap, ai.t0 = tr:get_Position(), tr:get_Rotation(), ai.snapshot(a), os.clock()
        return
    end
    ai.spawn(a)
end
function ai.spawn(a)
    local now = os.clock()
    local h = ai.handler(a)
    if ai.t0 or now < ai.nextOk or h:call("get_InProcess") then ai_note("not now: the last one is still running (wait a few seconds)"); return end
    local inst = h:call("get_Instance")
    if not inst then ai_note("no clone (asked the game to make one - from the next warp)"); pcall(ai.ensure, a, true); return end
    local tr = a.character:get_GameObject():get_Transform()
    ai.spot, ai.rot = tr:get_Position(), tr:get_Rotation()
    local okI, eI = pcall(h.call, h, "init(System.Boolean)", false)
    local info = sdk.create_instance("app.CloneCharacter.StartInformation"):add_ref()
    pcall(function() info:call(".ctor") end)
    info:call("set_Position", tr:get_UniversalPosition())
    info:call("set_Rotation", ai.rot)
    local okS, eS = pcall(h.call, h, "start(app.CloneCharacter.StartInformation)", info)
    ai.snap, ai.cj, ai.conts, ai.colours, ai.poseOf = ai.snapshot(a), nil, nil, nil, nil
    ai.inst, ai.t0, ai.step = inst, now, 0
    ai_note(("spawn: init %s / start %s"):format(tostring(okI and true or eI), tostring(okS and true or eS)))
end
-- (1.0 user: no clones on the warps) the game makes the Job07 clone only in some states (a Spearhand around): when
-- it's missing, its OWN handler is asked to create() it (the game's way, as the Guise's decoy - never a handler of ours)
function ai.ensure(a, now)
    if not cfg.afterimage or ai.t0 or ai.blocked() then return end
    if not now and os.clock() < (ai.nextEnsure or 0) then return end
    ai.nextEnsure = os.clock() + 5
    local h = ai.handler(a)
    if h:call("get_Instance") or h:call("get_InProcess") then return end
    if os.clock() < (ai.createdAt or -100) + 10 then return end   -- (asked lately: give it time)
    local pfb
    pcall(function() pfb = h:call("get_Prefab") end)
    if not pfb then if not ai.noPrefabNoted then ai.noPrefabNoted = true; ai_note("the game has no clone prefab here") end; return end
    ai.createdAt = os.clock()
    local ok, e = pcall(h.call, h, "create")
    ai_note("asked the game for the warp clone: " .. tostring(ok and "ok" or e))
end
re.on_frame(function()
    if not live.settled then return end
    local a = runtime.player()
    if a then pcall(ai.ensure, a, false) end
end)
-- after the game's own late update: the clone stays on the spot (no following), frozen in our pose, ghost look asked
re.on_application_entry("LateUpdateBehavior", function()
    if ai.dying then
        local t = os.clock()
        for k = #ai.dying, 1, -1 do
            local an = ai.dying[k]
            if t >= an.dieAt then
                pcall(function() an.go:call("destroy(via.GameObject)", an.go) end)
                table.remove(ai.dying, k)
            end
        end
    end
    if not ai.t0 or ai.blocked() then return end
    local inst, now = ai.inst, os.clock()
    pcall(function()
        inst:set_field("RootMoveScale", 0.0)
        local tr = inst:get_GameObject():get_Transform()
        tr:set_Position(ai.spot)
        tr:set_Rotation(ai.rot)
    end)
    pcall(ai.apply_pose, inst)
    if ai.step == 0 then
        ai.step = 1
        local r = {}
        for _, f in ipairs({ "requestStartEffect()", "requestBodyEffect()" }) do
            local ok, e = pcall(inst.call, inst, f)
            r[#r + 1] = f .. " " .. tostring(ok and true or e)
        end
        local okM, eM = pcall(function()
            local cat = inst:get_field("Basic")
            local none = ValueType.new(sdk.find_type_definition("System.Nullable`1<System.UInt32>"))
            inst:call("requestMaterialMode(app.MaterialInterpolationRequestManager.RequestListCategory, System.Nullable`1<System.UInt32>)", cat, none)
            ai.cat = cat
        end)
        r[#r + 1] = "material mode (Basic = " .. tostring(ai.cat) .. ") " .. tostring(okM and true or eM)
        if not ai.dumped then
            ai.dumped = true
            pcall(function()
                local out = { Basic = tostring(inst:get_field("Basic")), settings = {} }
                local arr = inst:get_field("_MaterialInterpolationSettings")
                for k = 0, (arr and arr:call("get_Length") or 0) - 1 do
                    local st = arr:call("Get", k)
                    local e = { category = tostring(st:get_field("_Category")), userdatas = {} }
                    local uds = st:get_field("_MaterialInterpolationUserDatas")
                    for q = 0, (uds and uds:call("get_Length") or 0) - 1 do
                        local ud = uds:call("Get", q)
                        local path
                        pcall(function() path = ud:call("get_Path") end)
                        if not path then pcall(function() path = ud:call("ToString") end) end
                        e.userdatas[#e.userdatas + 1] = tostring(path)
                    end
                    out.settings[#out.settings + 1] = e
                end
                json.dump_file("Pactblade_afterimage_materials.json", out)
            end)
        end
        local okC, cC = pcall(ai.find_colours, inst)
        if okC then ai.colours = cC; r[#r + 1] = ("ghost colour in %d material(s)"):format(#cC) else r[#r + 1] = "colours failed: " .. tostring(cC) end
        local okP, eP = pcall(function() inst:call("get_Motion"):call("set_Enabled", false) end)
        r[#r + 1] = ("pose: %d joints, motion off %s"):format(#(ai.snap or {}), tostring(okP and true or eP))
        local a1 = runtime.player()
        if a1 then
            local okE, eE = pcall(ai.play_fx, a1, inst:get_GameObject())
            r[#r + 1] = tostring(okE and eE or ("effects failed: " .. tostring(eE)))
        end
        ai_note(table.concat(r, " / "))
    elseif ai.step == 1 and now - ai.t0 > 0.3 then
        ai.step = 2
        local a1 = runtime.player()
        if a1 then pcall(ai.inspect, a1) end

    end
    if now - ai.t0 >= ai.secs then
        local a1 = runtime.player()
        pcall(function() inst:call("get_Motion"):call("set_Enabled", true) end)   -- (the clone is reused)
        for _, c in ipairs(ai.conts or {}) do pcall(function() c:call("finishAll") end) end
        local fin
        pcall(function() fin = sdk.find_type_definition("via.effect.PlayerAction"):get_field("Finish"):get_data(nil) end)
        for _, an in ipairs(ai.anchors) do
            pcall(function() if fin ~= nil then an.ep:call("set_Action", fin) end end)
            an.dieAt = now + 2.0
            ai.dying = ai.dying or {}
            table.insert(ai.dying, an)
        end
        ai.anchors = {}
        local okF = pcall(function() ai.handler(a1):call("finish") end)
        ai_note("ended (finish " .. tostring(okF) .. ")")
        ai.t0, ai.nextOk = nil, now + 0.3
    end
end)


-- TASHA'S OTHERWORLDLY GUISE (user, 4.39 - visual test): the afterimage clone on me, in my pose every frame, wearing a
-- chosen chest + legs (the game's style table), everything else hidden, scaled, the ghost look in purple.
;(function()
    local gu = { secs = 36, chest = 1, legs = 1, scale = { 1.10, 1.04, 1.06 }, yOff = 0.0, hue = 269, sat = 0.81, glow = 1.90,
                 ownClone = false, src = 2,   -- (4.59: the Trickster decoy = default; enemies ignore it)
                 fxSel = 1, bodyFx = true, startFx = true,
                 cloudSpeed = 0.70, cloudAlpha = 0.20, cloudBright = 0.52,   -- (4.64 user: the cloud weaker, 70 % speed; 4.66 user's values)
                 cloudTint = { 3.79, 0.34, 1.82 },   -- (4.67 user: pinker / brighter; 4.68 user's values)   -- (4.60 user: the decoy's start effect at every show)
                 info = "-", on = false,
                 CHESTS = { { "Grand Cuirass", "Tops_015" }, { "Allegoric Plate", "Tops_401" }, { "Kibisis Coat", "Tops_402" } },
                 LEGS = { { "Raptor Claws", "Pants_012" }, { "Brutal Cuisses", "Pants_015" } } }
    dbg.guise = gu
    local function ev(t, f) local td = sdk.find_type_definition(t); local fd = td and td:get_field(f); return fd and fd:get_data(nil) end
    local function cem() return sdk.get_managed_singleton("app.CharacterEditManager") end
    local function file_of(pfb, ext)   -- AppSystem/.../tops/wb/mesh/tops_039_wb_m.pfb -> Character/_kit/_equipment/tops/039/tops_039_wb_m.<ext>
        local base = tostring(pfb or ""):match("([^/]+)%.pfb$")
        if not base then return nil end
        local kind, num = base:match("^(%a+)_(%d+)_")
        if not kind then return nil end
        return ("Character/_kit/_equipment/%s/%s/%s.%s"):format(kind, num, base, ext)
    end
    -- one style's parts: { slot, mesh, mdf, mask }
    function gu.style_parts(kind, style)
        local c = cem()
        local db = c:get_field(kind == "Tops" and "_TopsDB" or "_PantsDB"):call("get_Item", ev("app.Gender", "Male"))
        local item = db:call("get_Item", ev(kind == "Tops" and "app.TopsStyle" or "app.PantsStyle", style))
        local slots = kind == "Tops" and { "Wb", "WbSub", "Am", "AmSub", "Bd", "BdSub", "Bt", "BtSub" } or { "Wl", "WlSub", "Lg", "LgSub" }
        local out = {}
        for _, sl in ipairs(slots) do
            pcall(function()
                local mid = item:get_field("_" .. sl .. "MeshID")
                if not mid or mid == 0 then return end
                local base = sl:gsub("Sub$", "")
                local function pf(cat, id)
                    local cc = c:get_field("_" .. kind .. base .. cat .. "Catalog")
                    if not id or id == 0 or not cc or not cc:call("ContainsKey", id) then return nil end
                    return cc:call("get_Item", id):call("get_ResourcePath")
                end
                local mp, sp = pf("Mesh", mid), pf("Skin", item:get_field("_" .. sl .. "SkinID"))
                out[#out + 1] = { slot = kind .. sl, mesh = file_of(mp, "mesh"), mdf = file_of(sp, "mdf2"), meshPfb = mp, skinPfb = sp,
                                  mask = item:get_field("_" .. sl .. "PartsEnable") }
            end)
        end
        return out
    end
    local function kids(go)   -- direct children of the clone root with a mesh
        local out = {}
        pcall(function()
            local ch = go:get_Transform():call("get_Child")
            while ch do
                local g = ch:get_GameObject()
                local m = g:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                if m then out[#out + 1] = { name = g:get_Name(), mesh = m:add_ref() } end
                ch = ch:call("get_Next")
            end
        end)
        return out
    end
    local function res_path(h) local p; pcall(function() p = h:call("get_ResourcePath") end); return p end
    function gu.probe(a)
        local out = { styles = {}, clone = {}, me = {} }
        for _, c in ipairs(gu.CHESTS) do local ok, r = pcall(gu.style_parts, "Tops", c[2]); out.styles[c[1]] = ok and r or tostring(r) end
        for _, c in ipairs(gu.LEGS) do local ok, r = pcall(gu.style_parts, "Pants", c[2]); out.styles[c[1]] = ok and r or tostring(r) end
        for _, k in ipairs(kids(a.character:get_GameObject())) do out.me[#out.me + 1] = k.name .. " = " .. tostring(res_path(k.mesh:call("getMesh"))) end
        pcall(function()
            local inst = ai.handler(a):call("get_Instance")
            for _, k in ipairs(kids(inst:get_GameObject())) do out.clone[#out.clone + 1] = k.name .. " = " .. tostring(res_path(k.mesh:call("getMesh"))) end
        end)
        dbg.save("Pactblade_guise_probe.json", out)
        for nm, r in pairs(out.styles) do
            local t = {}
            if type(r) == "table" then for _, e in ipairs(r) do t[#t + 1] = e.slot .. " " .. tostring(e.mesh and e.mesh:match("[^/]+$")) end else t[1] = r end
            note("Guise probe: " .. nm .. ": " .. table.concat(t, ", "))
        end
        note(("Guise probe: %d part(s) on me, %d on the clone (data/Pactblade_guise_probe.json)"):format(#out.me, #out.clone))
    end
    local SPARE_OK = { "^tops", "^pants", "^underwear", "^mantle" }   -- (4.40) body-level parts only (head = own skeleton: crash)
    local function dress(inst)   -- the clone's parts -> the chosen armour; the rest hidden. Keeps what to restore.
        local want = {}
        for _, e in ipairs(gu.style_parts("Tops", gu.CHESTS[gu.chest][2])) do want[#want + 1] = e end
        for _, e in ipairs(gu.style_parts("Pants", gu.LEGS[gu.legs][2])) do want[#want + 1] = e end
        local parts, byName, spare, used = kids(inst:get_GameObject()), {}, {}, {}
        gu.restore = {}
        for _, k in ipairs(parts) do
            local skip = true
            for _, pat in ipairs(SPARE_OK) do if k.name:lower():find(pat) then skip = false end end
            table.insert(gu.restore, { mesh = k.mesh, enabled = k.mesh:call("get_Enabled"), holder = k.mesh:call("getMesh"), mat = k.mesh:call("get_Material"), name = k.name })
            if not skip then byName[k.name] = k; spare[#spare + 1] = k end
        end
        local log = {}
        gu.dressed = {}
        for _, w in ipairs(want) do
            local k = byName[w.slot]
            if not k or used[k.name] then
                k = nil
                for _, sp in ipairs(spare) do if not used[sp.name] then
                    local claimed = false
                    for _, w2 in ipairs(want) do if w2.slot == sp.name then claimed = true end end
                    if not claimed then k = sp; break end
                end end
            end
            if k and w.mesh then
                used[k.name] = true
                note("Guise: " .. w.slot .. " -> " .. k.name .. " (" .. tostring(w.mesh:match("[^/]+$")) .. ")")
                local ok, err = pcall(function()
                    local mr = sdk.create_resource("via.render.MeshResource", w.mesh)
                    k.mesh:call("setMesh", mr:add_ref():create_holder("via.render.MeshResourceHolder"):add_ref())
                    if w.mdf then
                        local mm = sdk.create_resource("via.render.MeshMaterialResource", w.mdf)
                        k.mesh:call("set_Material", mm:add_ref():create_holder("via.render.MeshMaterialResourceHolder"):add_ref())
                    end
                    k.mesh:call("set_Enabled", true)
                end)
                gu.dressed[#gu.dressed + 1] = { mesh = k.mesh, mask = w.mask, slot = w.slot }
                log[#log + 1] = w.slot .. "->" .. k.name .. (ok and "" or (" FAILED " .. tostring(err)))
            else
                log[#log + 1] = w.slot .. ": no free part"
            end
        end
        note("Guise: dressed " .. table.concat(log, ", ") .. " - hiding the rest")
        for _, k in ipairs(parts) do if not used[k.name] then pcall(k.mesh.call, k.mesh, "set_Enabled", false) end end
        note("Guise: the rest hidden")
    end

    local ARMOUR_OBJS = { "_TopsWbObj", "_TopsWbSubObj", "_TopsAmObj", "_TopsAmSubObj", "_TopsBdObj", "_TopsBdSubObj",
                          "_TopsBtObj", "_TopsBtSubObj", "_PantsWlObj", "_PantsWlSubObj", "_PantsLgObj", "_PantsLgSubObj" }
    local function all_meshes(go, out, depth)
        out = out or {}
        pcall(function()
            local m = go:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
            if m then out[#out + 1] = { go = go, mesh = m:add_ref() } end
        end)
        if (depth or 0) < 5 then
            pcall(function()
                local ch = go:get_Transform():call("get_Child")
                while ch do all_meshes(ch:get_GameObject(), out, (depth or 0) + 1); ch = ch:call("get_Next") end
            end)
        end
        return out
    end
    function gu.restyle(inst, on)   -- (4.41) the clone's swapper: our styles (on) / its own back (off)
        local ps = inst:call("get_PartSwapper")
        if not ps then return "no part swapper" end
        local meta = ps:get_field("_Meta")
        if not meta then return "no meta" end
        local T = sdk.find_type_definition("app.PartSwapper.Parts")
        local function swap(part) pcall(ps.call, ps, "requestSwap(app.PartSwapper.Parts)", T:get_field(part):get_data(nil)) end
        if on then
            local src = meta
            pcall(function()   -- (4.43) my own styles (the clone may still hold an old guise's)
                local mine = runtime.player().character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("app.PartSwapper"))
                local mm = mine and mine:get_field("_Meta")
                if mm then src = mm end
            end)
            gu.oldStyles = { tops = src:get_field("_TopsStyle"), pants = src:get_field("_PantsStyle"),
                             topsV = src:get_field("_TopsVariationStyle"), pantsV = src:get_field("_PantsVariationStyle") }
            meta:set_field("_TopsStyle", ev("app.TopsStyle", gu.CHESTS[gu.chest][2]))
            meta:set_field("_PantsStyle", ev("app.PantsStyle", gu.LEGS[gu.legs][2]))
            pcall(function() meta:set_field("_TopsVariationStyle", 0); meta:set_field("_PantsVariationStyle", 0) end)
        elseif gu.oldStyles then
            meta:set_field("_TopsStyle", gu.oldStyles.tops)
            meta:set_field("_PantsStyle", gu.oldStyles.pants)
            pcall(function() meta:set_field("_TopsVariationStyle", gu.oldStyles.topsV); meta:set_field("_PantsVariationStyle", gu.oldStyles.pantsV) end)
            gu.oldStyles = nil
        end
        swap("Tops"); swap("Pants")
        return ("styles %s, swap asked"):format(on and "ours" or "back")
    end

    function gu.wanted_ready(inst)   -- (4.42) every slot of the chosen styles holds its mesh (loaded)?
        local ps = inst:call("get_PartSwapper")
        local want = {}
        for _, e in ipairs(gu.style_parts("Tops", gu.CHESTS[gu.chest][2])) do want[#want + 1] = e end
        for _, e in ipairs(gu.style_parts("Pants", gu.LEGS[gu.legs][2])) do want[#want + 1] = e end
        gu.want = want
        local n, miss = 0, {}
        for _, w in ipairs(want) do
            local ok = false
            pcall(function()
                local o = ps:get_field("_" .. w.slot .. "Obj")
                local m = o and o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                local path = m and m:call("getMesh"):call("get_ResourcePath") or ""
                local base = tostring(w.mesh or ""):match("([^/]+)%.mesh$") or "?"
                ok = path:lower():find(base:lower(), 1, true) ~= nil and m:call("get_MeshReady")
            end)
            if ok then n = n + 1 else miss[#miss + 1] = w.slot end
        end
        return #miss == 0 and n > 0, n, table.concat(miss, ",")
    end
    function gu.keep(inst)   -- wanted armour meshes on, every other mesh off; returns (turned on, turned off)
        local ps = inst:call("get_PartSwapper")
        local keep = {}
        for _, w in ipairs(gu.want or {}) do pcall(function() local o = ps:get_field("_" .. w.slot .. "Obj"); if o then keep[o:get_address()] = true end end) end
        local on, off = 0, 0
        for _, e in ipairs(all_meshes(inst:get_GameObject())) do
            local en = e.mesh:call("get_Enabled")
            if keep[e.go:get_address()] then
                if not en then pcall(e.mesh.call, e.mesh, "set_Enabled", true); on = on + 1 end
            elseif en then
                gu.hidden = gu.hidden or {}
                table.insert(gu.hidden, { mesh = e.mesh, enabled = true })
                pcall(e.mesh.call, e.mesh, "set_Enabled", false); off = off + 1
            end
        end
        return on, off
    end
    function gu.hide_rest(inst, on)   -- every mesh on the clone but the armour objects off (on) / back (off)
        if not on then
            for _, r in ipairs(gu.hidden or {}) do pcall(r.mesh.call, r.mesh, "set_Enabled", r.enabled) end
            gu.hidden = nil
            return 0
        end
        local ps = inst:call("get_PartSwapper")
        local keep = {}
        for _, w in ipairs(gu.want or {}) do pcall(function() local o = ps:get_field("_" .. w.slot .. "Obj"); if o then keep[o:get_address()] = true end end) end
        gu.hidden = gu.hidden or {}
        local n = 0
        for _, e in ipairs(all_meshes(inst:get_GameObject())) do
            if not keep[e.go:get_address()] then
                local en = e.mesh:call("get_Enabled")
                if en then
                    table.insert(gu.hidden, { mesh = e.mesh, enabled = en })
                    pcall(e.mesh.call, e.mesh, "set_Enabled", false)
                    n = n + 1
                end
            end
        end
        return n
    end
    local function masks()   -- the style's mesh groups, once the new meshes are loaded
        local n = 0
        for _, d in ipairs(gu.dressed or {}) do
            pcall(function()
                local mask = math.tointeger(d.mask) or -1
                local cnt = d.mesh:call("getPartsEnableCount")
                for i = 0, cnt - 1 do
                    d.mesh:call("setPartsEnable", i, mask == -1 or ((mask >> i) & 1) == 1)
                end
                n = n + 1
            end)
        end
        return n
    end
    local function pairs_build(pgo, cgo)
        local list, ptr, ctr = {}, pgo:get_Transform(), cgo:get_Transform()
        local js = ptr:call("get_Joints")
        for k = 0, (js and js:call("get_Length") or 0) - 1 do
            pcall(function()
                local j = js:call("Get", k)
                local cj = ctr:call("getJointByName", j:call("get_Name"))
                if cj then list[#list + 1] = { p = j, c = cj } end
            end)
        end
        return list
    end

    -- (4.54) our own clone handler (the warps keep the Job07 one): made once, its clone parked between casts
    function gu.handler(a)
        if gu.src == 2 then   -- (4.55) the Trickster's decoy (the warps keep the afterimage)
            local h = a.character:get_Human()["<Job09ActionCtrl>k__BackingField"]["<DecoyHandler>k__BackingField"]
            return h, true
        end
        return ai.handler(a), false
    end
    function gu.make_own(a)
        if gu.h or gu.ownFailed then return end
        local shared = ai.handler(a)
        local ctrl = shared:call("get_Prefab")
        local pfb = ctrl and ctrl:get_field("_Item")
        if not pfb then gu.ownFailed = true; note("Guise: no afterimage prefab - using the shared clone"); return end
        local h = sdk.create_instance("app.AfterImageHandler"):add_ref()
        pcall(function() h:call(".ctor") end)
        local okS, eS = pcall(h.call, h, "setup(app.Human, via.Prefab)", a.character:get_Human(), pfb)
        local okC, eC = pcall(h.call, h, "create")
        gu.h, gu.hBorn = h, os.clock()
        note(("Guise: own clone handler: setup %s, create %s - waiting for its clone"):format(tostring(okS and true or eS), tostring(okC and true or eC)))
    end
    function gu.own_wait()   -- each frame until the own clone exists (3 s, then the shared one)
        if not gu.h or gu.hReady or gu.ownFailed then return end
        local inst
        pcall(function() inst = gu.h:call("get_Instance") end)
        if not inst and os.clock() - gu.hBorn > 0.5 then pcall(gu.h.call, gu.h, "updateClone") end
        if inst then
            gu.hReady = true
            note(("Guise: own clone ready (%x) after %.2f s"):format(inst:get_address(), os.clock() - gu.hBorn))
            if gu.pendShow then gu.pendShow = nil; pcall(gu.show, runtime.player()) end
        elseif os.clock() - gu.hBorn > 3.0 then
            gu.ownFailed = true
            note("Guise: own clone never came - using the shared one")
            if gu.pendShow then gu.pendShow = nil; pcall(gu.show, runtime.player()) end
        end
    end
    function gu.prepare(a)   -- (4.61) the decoy clone ready? (asks its handler once; true = go on)
        if gu.src == 2 and not gu.decoyAsked then   -- (4.55) the decoy's clone: made by its own handler once
            local h = gu.handler(a)
            local has = false
            pcall(function() has = h:call("get_Instance") ~= nil end)
            local info = "?"
            pcall(function() info = ("has %s, in process %s, requested %s, prefab %s"):format(tostring(has), tostring(h:call("get_InProcess")),
                tostring(h:call("get_RequestedInstantiate")), tostring(h:call("get_Prefab") ~= nil)) end)
            note("Guise: Trickster decoy handler: " .. info)
            gu.decoyAsked = true
            if not has then
                local okC, eC = pcall(h.call, h, "create")
                note("Guise: decoy create " .. tostring(okC and true or eC) .. " - waiting for its clone")
                gu.decoyWait = os.clock()
                return false
            end
        end
        if gu.decoyWait then
            local ok, inst = pcall(function() return gu.handler(a):call("get_Instance") end)
            if not (ok and inst) then
                if os.clock() - gu.decoyWait < 3 then note("Guise: the decoy clone isn't there yet - press again in a moment"); return false end
                gu.decoyWait, gu.src = nil, 1
                note("Guise: no decoy clone - back to the shared afterimage")
            else
                gu.decoyWait = nil
                note(("Guise: decoy clone ready (%x)"):format(inst:get_address()))
            end
        end
        return true
    end
    function gu.show(a)
        if gu.ending then note("Guise: still ending - a moment"); return end
        if gu.on then gu.stop("ended (button)"); return end
        if not gu.prepare(a) then return end
        if false then
            local h = gu.handler(a)
            local has = false
            pcall(function() has = h:call("get_Instance") ~= nil end)
            local info = "?"
            pcall(function() info = ("has %s, in process %s, requested %s, prefab %s"):format(tostring(has), tostring(h:call("get_InProcess")),
                tostring(h:call("get_RequestedInstantiate")), tostring(h:call("get_Prefab") ~= nil)) end)
            note("Guise: Trickster decoy handler: " .. info)
            gu.decoyAsked = true
            if not has then
                local okC, eC = pcall(h.call, h, "create")
                note("Guise: decoy create " .. tostring(okC and true or eC) .. " - waiting for its clone")
                gu.decoyWait = os.clock()
                return
            end
        end
        if gu.decoyWait then
            local ok, inst = pcall(function() return gu.handler(a):call("get_Instance") end)
            if not (ok and inst) then
                if os.clock() - gu.decoyWait < 3 then note("Guise: the decoy clone isn't there yet - press again in a moment"); return end
                gu.decoyWait, gu.src = nil, 1
                note("Guise: no decoy clone - back to the shared afterimage")
            else
                gu.decoyWait = nil
                note(("Guise: decoy clone ready (%x)"):format(inst:get_address()))
            end
        end
        if gu.parked and gu.inst then   -- (4.47) the parked clone again: no init / start
            gu.t0, gu.step, gu.on, gu.pairs, gu.colours, gu.followErr = os.clock(), 0, true, nil, nil, nil
            gu.hipP, gu.hipC, gu.fix, gu.lastOff, gu.parked = nil, nil, nil, nil, nil
            gu.info = "on (" .. gu.CHESTS[gu.chest][1] .. " + " .. gu.LEGS[gu.legs][1] .. ", parked clone)"
            note("Guise: the parked clone again")
            pcall(function()
                local nR = gu.replay_sounds(gu.inst)
                if nR ~= 0 then note("Guise: its sound(s) again: " .. tostring(nR)) end
            end)
            return
        end
        local h, own = gu.handler(a)
        gu.isOwn = own
        if ai.t0 and not own then note("Guise: a warp afterimage is showing - try again in a moment"); return end
        if h:call("get_InProcess") and gu.justReleased and os.clock() - gu.justReleased < 10 then   -- (4.95) still ending after our release
            gu.retryAt = os.clock() + 0.5
            note("Guise: the released clone is still ending - starting in a moment")
            return
        end
        if h:call("get_InProcess") and h:call("get_Instance") and (own or gu.src == 1) then   -- (4.66) still running from before a script reset: ADOPT it (no finish)
            gu.inst, gu.parked = h:call("get_Instance"), true
            note(("Guise: adopted the running clone %x (from before a script reset) - no finish"):format(gu.inst:get_address()))
            return gu.show(a)
        end
        if h:call("get_InProcess") then   -- (4.43) a clone left running (not ours): let it go, try again by itself
            gu.retries = (gu.retries or 0) + 1
            if gu.retries > 2 then gu.retries = 0; note("Guise: the clone stays busy - try again in a few seconds"); return end
            gu.releasing = true
            pcall(h.call, h, "finish")
            gu.releasing = nil
            gu.retryAt = os.clock() + 0.6
            note("Guise: a clone was still running - released it, starting again")
            return
        end
        gu.retries = 0
        local inst = h:call("get_Instance")
        if not inst then note("Guise: no clone"); return end
        local tr = a.character:get_GameObject():get_Transform()
        pcall(h.call, h, "init(System.Boolean)", false)
        local info = sdk.create_instance("app.CloneCharacter.StartInformation"):add_ref()
        pcall(function() info:call(".ctor") end)
        info:call("set_Position", tr:get_UniversalPosition())
        info:call("set_Rotation", tr:get_Rotation())
        pcall(function() gu.recordGo, gu.recordUntil = inst:get_GameObject():get_address(), os.clock() + 3.0 end)
        local okS, eS = pcall(h.call, h, "start(app.CloneCharacter.StartInformation)", info)
        gu.inst, gu.t0, gu.step, gu.on, gu.pairs, gu.colours, gu.followErr = inst, os.clock(), 0, true, nil, nil, nil
        gu.hipP, gu.hipC, gu.fix, gu.lastOff = nil, nil, nil, nil
        ai.guise = nil   -- (4.60: no flag any more - ai.blocked() looks at the guise itself)
        note("Guise: using " .. (own and "OUR OWN clone" or "the shared (warp) clone"))
        gu.info = "on (" .. gu.CHESTS[gu.chest][1] .. " + " .. gu.LEGS[gu.legs][1] .. ")"
        note("Guise: clone started " .. tostring(okS and true or eS))
    end
    function gu.stop(why)   -- (4.45) styles back while the clone still runs (hidden); the finish comes once that's done
        if gu.ending then return end
        local inst = gu.inst
        gu.on = false
        gu.illSlots, gu.illAgain = nil, nil
        pcall(gu.fx_off)
        gu.fxNone, gu.fxCount = nil, nil
        do local okB, eB = pcall(gu.armour_bonus, false); note("Guise bonus: " .. tostring(eB)) end
        -- (4.88: its own effects are no longer finished here - that didn't stop the sound and may break the parked clone)
        local okH, nH = pcall(gu.hush, inst)
        note(("Guise: sounds stopped on the clone: %s (%s container(s), %s playing)"):format(tostring(nH), tostring(gu.hushInfo and gu.hushInfo.containers),
            tostring(gu.hushInfo and gu.hushInfo.playing)))
        gu.hushUntil, gu.hushAt = os.clock() + 5.0, os.clock() + 1.0
        note("Guise: ending - styles back (hidden)")
        pcall(function() note("Guise: " .. tostring(gu.restyle(inst, false))) end)
        pcall(function()   -- every mesh off (remembered, so the clone gets them all back at the finish)
            gu.hidden = gu.hidden or {}
            for _, e in ipairs(all_meshes(inst:get_GameObject())) do
                if e.mesh:call("get_Enabled") then table.insert(gu.hidden, { mesh = e.mesh, enabled = true }) end
                pcall(e.mesh.call, e.mesh, "set_Enabled", false)
            end
        end)
        gu.colours = nil
        gu.ending = { t = os.clock(), why = why }
    end
    function gu.finish_end()
        local inst, why = gu.inst, gu.ending and gu.ending.why
        gu.ending = nil
        if gu.isOwn and not gu.parkDecoy and not gu.releasing then gu.releasing = true end   -- (4.95 test) the decoy: released, not parked
        if gu.park ~= false and not gu.releasing then   -- (4.47) parked: hidden, alive, ready for the next show
            gu.parked = true
            gu.info = "off, clone parked (" .. tostring(why) .. ")"
            note("Guise: parked the clone (hidden) - " .. tostring(why))
            return
        end
        gu.parked, gu.releasing = nil, nil
        note("Guise: ending - meshes back on")
        pcall(gu.hide_rest, inst, false)
        pcall(function()
            local ps = inst:call("get_PartSwapper")
            for _, f in ipairs(ARMOUR_OBJS) do
                pcall(function()
                    local o = ps:get_field(f)
                    local m = o and o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                    if m then m:call("set_Enabled", true) end
                end)
            end
        end)
        gu.hidden, gu.restore, gu.dressed = nil, nil, nil
        note("Guise: ending - scale, motion, finish")
        pcall(function() inst:get_GameObject():get_Transform():set_LocalScale(Vector3f.new(1, 1, 1)) end)
        pcall(function() inst:call("get_Motion"):call("set_Enabled", true) end)
        pcall(function() gu.handler(runtime.player()):call("finish") end)
        gu.justReleased = os.clock()   -- (4.95) a cast in the next seconds must not adopt the dying clone
        if not gu.isOwn then ai.nextOk = os.clock() + 0.5 end
        gu.info = "off (" .. tostring(why) .. ")"
        note("Guise: " .. tostring(why))
    end

    function gu.ghost(inst)   -- (4.48) the new parts into the clone's material system, the ghost mode fresh
        local r = {}
        local ok1, e1 = pcall(inst.call, inst, "setupMaterialInterpolation()")
        r[#r + 1] = "setup all " .. tostring(ok1 and true or e1)
        local n = 0
        pcall(function()
            local ps = inst:call("get_PartSwapper")
            for _, w in ipairs(gu.want or {}) do
                pcall(function()
                    local o = ps:get_field("_" .. w.slot .. "Obj")
                    if o and pcall(inst.call, inst, "setupMaterialInterpolation(via.GameObject)", o) then n = n + 1 end
                end)
            end
        end)
        r[#r + 1] = ("setup parts %d"):format(n)
        if gu.kind(inst) == "after" then   -- (4.59) the afterimage material mode (an afterimage only)
            local cat = inst:get_field("Basic")
            local ok2, e2 = pcall(inst.call, inst, "finishMaterialMode(app.MaterialInterpolationRequestManager.RequestListCategory, System.UInt32)", cat, 0)
            r[#r + 1] = "finish " .. tostring(ok2 and true or e2)
            local ok3, e3 = pcall(function()
                local none = ValueType.new(sdk.find_type_definition("System.Nullable`1<System.UInt32>"))
                inst:call("requestMaterialMode(app.MaterialInterpolationRequestManager.RequestListCategory, System.Nullable`1<System.UInt32>)", cat, none)
            end)
            r[#r + 1] = "request " .. tostring(ok3 and true or e3) .. " (Basic = " .. tostring(cat) .. ")"
        end
        local okC, cC = pcall(ai.find_colours, inst)
        gu.colours = okC and cC or nil
        r[#r + 1] = okC and (#cC .. " glow colour(s)") or ("colours failed " .. tostring(cC))
        pcall(function() gu.illSlots = gu.ill_slots(inst) end)
        if gu.bodyFx and gu.kind(inst) == "after" then local okB, eB = pcall(inst.call, inst, "requestBodyEffect()"); r[#r + 1] = "body effect " .. tostring(okB and true or eB) end
        if gu.startFx and (gu.kind(inst) == "decoy" or gu.startFxAfter) then local okS, eS = pcall(inst.call, inst, "requestStartEffect()"); r[#r + 1] = "start effect " .. tostring(okS and true or eS) end
        pcall(gu.fx_off)
        local before = #ai.anchors
        local keepFx = ai.fx
        ai.fx = gu.fxSel
        local okF, eF = pcall(ai.play_fx, runtime.player(), inst:get_GameObject())   -- (4.49) Mirage Dance's MI effects
        ai.fx = keepFx
        gu.fx = {}
        for k = before + 1, #ai.anchors do gu.fx[#gu.fx + 1] = ai.anchors[k] end
        for k = #ai.anchors, before + 1, -1 do table.remove(ai.anchors, k) end   -- (ours, not the warp's)
        r[#r + 1] = "Mirage Dance " .. tostring(okF and eF or ("failed " .. tostring(eF))) .. (" (%d player(s))"):format(#gu.fx)
        pcall(gu.fx_tune, true)
        return table.concat(r, ", ")
    end
    function gu.fx_tune(force)   -- (4.64) our cloud players: speed + colour (once each, or all again after a slider move)
        local key = ("%.2f/%.2f/%.2f/%.2f/%.2f/%.2f"):format(gu.cloudSpeed, gu.cloudAlpha, gu.cloudBright, gu.cloudTint[1], gu.cloudTint[2], gu.cloudTint[3])
        if gu.tunedKey ~= key then gu.tunedKey, force = key, true end
        for _, an in ipairs(gu.fx or {}) do
            if force or not an.tuned then
                an.tuned = true
                pcall(function()
                    local st = an.ep:call("get_State") & 0xFFFFFFFF
                    if st == 0 and an.tunedOnce then return end   -- (ended: leave it alone)
                    an.tunedOnce = true
                    an.ep:call("set_PlaySpeed", gu.cloudSpeed)
                    local b, t = gu.cloudBright, gu.cloudTint
                    an.ep:set_Color(via_colour({ b * t[1], b * t[2], b * t[3], gu.cloudAlpha }))
                end)
            end
        end
    end
    function gu.fx_off()   -- our Mirage Dance players: finish, their anchors destroyed 2 s later
        local fin
        pcall(function() fin = sdk.find_type_definition("via.effect.PlayerAction"):get_field("Finish"):get_data(nil) end)
        local now = os.clock()
        for _, an in ipairs(gu.fx or {}) do
            pcall(function() if fin ~= nil then an.ep:call("set_Action", fin) end end)
            an.dieAt = now + 2.0
            ai.dying = ai.dying or {}
            table.insert(ai.dying, an)
        end
        gu.fx = {}
    end
    function gu.fx_keep(inst)   -- one ended (Running -> Idle): the whole set again
        local ended = false
        for _, an in ipairs(gu.fx or {}) do
            local st
            pcall(function() st = an.ep:call("get_State") & 0xFFFFFFFF end)
            if st == 0 then ended = true end
        end
        if ended or (gu.fx and #gu.fx == 0 and not gu.fxNone) then
            gu.fxCount = (gu.fxCount or 0) + 1
            local before = #ai.anchors
            pcall(gu.fx_off)
            local keepFx = ai.fx
            ai.fx = gu.fxSel
            pcall(ai.play_fx, runtime.player(), inst:get_GameObject())
            ai.fx = keepFx
            gu.fx = {}
            for k = before + 1, #ai.anchors do gu.fx[#gu.fx + 1] = ai.anchors[k] end
            for k = #ai.anchors, before + 1, -1 do table.remove(ai.anchors, k) end
            if #gu.fx == 0 then gu.fxNone = true end
            pcall(gu.fx_tune, true)
            return true
        end
        return false
    end

    gu.seeThrough, gu.seeOn = 0.5, false
    local SEE = { "dither", "alpha", "dissol", "fade", "opac", "transp", "translu", "erase", "vanish" }
    function gu.matvars(inst)   -- every material variable of the armour parts -> data/Pactblade_guise_matvars.json
        local ps = inst:call("get_PartSwapper")
        local names, list = {}, {}
        gu.seeSlots = {}
        for _, w in ipairs(gu.want or {}) do
            pcall(function()
                local o = ps:get_field("_" .. w.slot .. "Obj")
                local m = o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")):add_ref()
                for mi = 0, m:call("get_MaterialNum") - 1 do
                    for vi = 0, m:call("getMaterialVariableNum", mi) - 1 do
                        pcall(function()
                            local nm = m:call("getMaterialVariableName", mi, vi)
                            local ty = m:call("getMaterialVariableType", mi, vi)
                            if not names[nm] then names[nm] = ty; list[#list + 1] = ("%s (type %s)"):format(nm, tostring(ty)) end
                            local l = tostring(nm):lower()
                            for _, k in ipairs(SEE) do
                                if l:find(k, 1, true) then
                                    local v0
                                    pcall(function() v0 = m:call("getMaterialFloat", mi, vi) end)
                                    gu.seeSlots[#gu.seeSlots + 1] = { mesh = m, m = mi, v = vi, name = nm, ty = ty, orig = v0 }
                                    break
                                end
                            end
                        end)
                    end
                end
            end)
        end
        table.sort(list)
        dbg.save("Pactblade_guise_matvars.json", list)
        local seen, out = {}, {}
        for _, e in ipairs(gu.seeSlots) do if not seen[e.name] then seen[e.name] = true; out[#out + 1] = e.name .. "=" .. tostring(e.orig) end end
        note(("Guise: %d material variable name(s) (data/Pactblade_guise_matvars.json); see-through candidates: %s"):format(#list, table.concat(out, ", ")))
    end
    re.on_pre_application_entry("BeginRendering", function()
        if not gu.on or not gu.seeOn or not gu.seeSlots then return end
        for _, e in ipairs(gu.seeSlots) do pcall(e.mesh.call, e.mesh, "setMaterialFloat", e.m, e.v, gu.seeThrough) end
    end)

    gu.ill = { on = true, enable = 1.0, front = 0.25, rim = 0.80, fade = 0.30, fadeLegs = 0.38, grad = 1.0, noise = 0.0, dither = 1.0, dissolve = 0.0 }   -- (4.52 user: FadeRate = the see-through control, 0 = gone)
    gu.ILL = { { "Illusion_Enable", "enable" }, { "Illusion_AlphaRate_Front", "front" }, { "Illusion_AlphaRate_Rim", "rim" },
               { "Illusion_FadeRate", "fade" }, { "Illusion_RimAlphaGrad", "grad" }, { "Illusion_NoiseBlend", "noise" },
               { "DitherFadeRate", "dither" }, { "DissolveRate", "dissolve" } }
    function gu.ill_slots(inst, quiet)   -- (4.52) the illusion variables on every armour mesh / material, by name hash
        local ps = inst:call("get_PartSwapper")
        local out, orig = {}, {}
        for _, g in ipairs(gu.ILL) do g.hash = g.hash or nameHash:call(nil, g[1]) end
        for _, w in ipairs(gu.want or {}) do
            pcall(function()
                local o = ps:get_field("_" .. w.slot .. "Obj")
                local m = o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh")):add_ref()
                for mi = 0, m:call("get_MaterialNum") - 1 do
                    for _, g in ipairs(gu.ILL) do
                        pcall(function()
                            local v = m:call("getMaterialVariableIndex", mi, g.hash)
                            if v == nil or v >= 65535 then return end
                            if orig[g[1]] == nil then pcall(function() orig[g[1]] = m:call("getMaterialFloat", mi, v) end) end
                            local key = g[2]
                            if key == "fade" and w.slot:find("^Pants") then key = "fadeLegs" end   -- (4.53 user: the legs on their own)
                            out[#out + 1] = { mesh = m, m = mi, v = v, key = key }
                        end)
                    end
                end
            end)
        end
        local t = {}
        for _, g in ipairs(gu.ILL) do t[#t + 1] = g[1] .. "=" .. tostring(orig[g[1]]) end
        if not quiet then note(("Guise: illusion slots %d | originals: %s"):format(#out, table.concat(t, ", "))) end
        return out
    end
    re.on_pre_application_entry("BeginRendering", function()
        if not gu.on or not gu.ill.on or not gu.illSlots then return end
        for _, e in ipairs(gu.illSlots) do pcall(e.mesh.call, e.mesh, "setMaterialFloat", e.m, e.v, gu.ill[e.key]) end
    end)

    function gu.no_ui(inst)   -- (4.56) the decoy's health bar: every GUI under the clone off
        local found, n = {}, 0
        local function walk(go, depth)
            pcall(function()
                local g = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
                if g then
                    if g:call("get_Enabled") then g:call("set_Enabled", false); n = n + 1 end
                    found[#found + 1] = go:get_Name()
                end
            end)
            if depth < 6 then
                pcall(function()
                    local ch = go:get_Transform():call("get_Child")
                    while ch do walk(ch:get_GameObject(), depth + 1); ch = ch:call("get_Next") end
                end)
            end
        end
        walk(inst:get_GameObject(), 0)
        if not gu.uiNoted and #found > 0 then gu.uiNoted = true; note("Guise: GUI on the clone switched off: " .. table.concat(found, ", ")) end
        return n
    end
    function gu.kind(inst)   -- (4.59) "after" / "decoy" / "other", found once per clone
        if gu.kindOf == inst:get_address() then return gu.kindIs end
        local td = inst:get_type_definition()
        gu.kindOf = inst:get_address()
        gu.kindIs = td:is_a("app.AfterImage") and "after" or (td:is_a("app.SmokeDecoy") and "decoy" or "other")
        note("Guise: the clone is a " .. tostring(td:get_full_name()))
        return gu.kindIs
    end

    function gu.hush(inst)   -- (4.69) every sound still playing on the clone stopped; returns how many
        local stop = sdk.find_type_definition("soundlib.SoundManager"):get_method("stopEventByRequestId(via.GameObject, System.UInt32, System.UInt32)")
        if not stop then return -1 end
        local n, seen = 0, {}
        gu.hushInfo = { containers = 0, playing = 0 }
        local function walk(go, depth)
            pcall(function()
                local sc = go:call("getComponent(System.Type)", sdk.typeof("app.WwiseContainerApp"))
                if not sc then sc = go:call("getComponent(System.Type)", sdk.typeof("soundlib.SoundContainer")) end
                if sc then
                    gu.hushInfo.containers = gu.hushInfo.containers + 1
                    pcall(function() gu.hushInfo.playing = gu.hushInfo.playing + sc:call("get_PlayingCount") end)
                    local dict = sc:call("get_PlayingRequestIdDict")
                    local entries = dict and dict._entries
                    local cnt = 0
                    pcall(function() cnt = entries:call("get_Length") end)
                    for k = 0, cnt - 1 do
                        pcall(function()
                            local e = entries[k]
                            local hc = e.hashCode
                            if hc == nil then hc = e._hashCode end
                            if hc ~= nil and hc < 0 then return end   -- (4.88) a free slot (stale id)
                            local id = e.key
                            if id and id ~= 0 and not seen[id] then
                                seen[id] = true
                                stop:call(nil, go, id, 0)
                                n = n + 1
                            end
                        end)
                    end
                end
            end)
            if depth < 4 then
                pcall(function()
                    local ch = go:get_Transform():call("get_Child")
                    while ch do walk(ch:get_GameObject(), depth + 1); ch = ch:call("get_Next") end
                end)
            end
        end
        walk(inst:get_GameObject(), 0)
        return n
    end

    gu.cloneTrig, gu.cloneTrigList = {}, {}
    pcall(function()   -- (4.73) the triggers recorded earlier
        local saved = json.load_file("Pactblade_guise_sounds.json")
        if type(saved) == "table" then for _, id in ipairs(saved) do if type(id) == "number" and not gu.cloneTrig[id] then gu.cloneTrig[id] = true; gu.cloneTrigList[#gu.cloneTrigList + 1] = id end end end
    end)
    local function rec_trigger(sc, id)
        if not id or id == 0 or not gu.recordUntil or os.clock() > gu.recordUntil then return end
        local go = sc and sc:call("get_GameObject")
        if not go or go:get_address() ~= gu.recordGo then return end
        if not gu.cloneTrig[id] then
            gu.cloneTrig[id] = true
            gu.cloneTrigList[#gu.cloneTrigList + 1] = id
            note(("Guise: the clone's own sound trigger %d (recorded)"):format(id))
            pcall(dbg.save, "Pactblade_guise_sounds.json", gu.cloneTrigList)   -- (4.73: kept over script resets)
        end
    end
    local SC = sdk.find_type_definition("soundlib.SoundContainer")
    for _, sig in ipairs({ "trigger(System.UInt32)", "trigger(soundlib.SoundTriggerInfo)",
                           "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)" }) do
        pcall(function()
            sdk.hook(SC:get_method(sig), function(args)
                if not gu.recordUntil or os.clock() > gu.recordUntil then return end
                pcall(function()
                    local sc = sdk.to_managed_object(args[2])
                    local id
                    if sig == "trigger(System.UInt32)" then id = sdk.to_int64(args[3]) & 0xFFFFFFFF
                    else local info = sdk.to_managed_object(args[3]); id = info and info._TriggerId end
                    rec_trigger(sc, id)
                end)
            end, function(r) return r end)
        end)
    end
    function gu.replay_sounds(inst)   -- the recorded triggers again on the clone's container
        if #gu.cloneTrigList == 0 then return 0 end
        local sc = inst:get_GameObject():call("getComponent(System.Type)", sdk.typeof("app.WwiseContainerApp"))
        if not sc then sc = inst:get_GameObject():call("getComponent(System.Type)", sdk.typeof("soundlib.SoundContainer")) end
        if not sc then return -1 end
        local n = 0
        for _, id in ipairs(gu.cloneTrigList) do if pcall(sc.call, sc, "trigger(System.UInt32)", id) then n = n + 1 end end
        return n
    end

    -- (4.72) THE BONUSES while the guise is on: in the game's own status numbers (the status screen shows them)
    gu.bonus = { on = true, def = 0.20, resist = 1.0, calls = 0, notedDef = false, notedRes = false }
    local function arr_get(arr, i) local v; pcall(function() v = arr:call("Get", i) end); if v == nil then pcall(function() v = arr[i] end) end; return v end
    local function arr_set(arr, i, v) if not pcall(arr.call, arr, "Set", i, v) then pcall(function() arr[i] = v end) end end
    local function mine(calc)
        local ok, yes = pcall(function()
            local a = runtime.player()
            return calc:get_field("CharaID") == a.character:get_CharaID()
        end)
        return ok and yes
    end
    local ST = sdk.find_type_definition("app.PlayerAttackDefenceStatus")
    pcall(function()
        sdk.hook(ST:get_method("updateDefenceParameters(app.PlayerStatusCalculatorParameter)"), function(args)
            local stg = thread.get_hook_storage()
            stg.st, stg.calc = args[2], args[3]
        end, function(r)
            local stg = thread.get_hook_storage()
            if not gu.bonus.on or not live.on then return r end
            pcall(function()
                local st, calc = sdk.to_managed_object(stg.st), sdk.to_managed_object(stg.calc)
                if not st or not calc or not mine(calc) then return end
                gu.bonus.calls = gu.bonus.calls + 1
                if not gu.on then return end
                local okD, eD = pcall(gu.bonus_def, st, "in-game")
                if not okD and not gu.bonus.errDef then gu.bonus.errDef = true; note("Guise bonus (in-game defence) failed: " .. tostring(eD)) end
            end)
            return r
        end)
    end)
    pcall(function()
        sdk.hook(ST:get_method("updateStatusConditionResistParameters(app.PlayerStatusCalculatorParameter)"), function(args)
            local stg = thread.get_hook_storage()
            stg.st, stg.calc = args[2], args[3]
        end, function(r)
            local stg = thread.get_hook_storage()
            if not gu.bonus.on or not live.on then return r end
            pcall(function()
                local st, calc = sdk.to_managed_object(stg.st), sdk.to_managed_object(stg.calc)
                if not st or not calc or not mine(calc) then return end
                gu.bonus.calls = gu.bonus.calls + 1
                if not gu.bonus.liveSt or gu.bonus.liveSt:get_address() ~= st:get_address() then gu.bonus.liveSt = st:add_ref() end
                if not gu.on then return end
                gu.bonus_mark(st)
                if not gu.bonus.liveSt or gu.bonus.liveSt:get_address() ~= st:get_address() then gu.bonus.liveSt = st:add_ref() end
                local reg = st:get_field("StatusDamageRegist")
                local el = st:get_field("<ElementResistFactor>k__BackingField")
                local before = ("poison %s, virulent %s, burning %s, fire %s"):format(tostring(arr_get(reg, 1)), tostring(arr_get(reg, 7)),
                    tostring(arr_get(reg, 5)), tostring(el and arr_get(el, 1)))
                for _, i in ipairs({ 1, 7, 5 }) do arr_set(reg, i, gu.bonus.resist) end
                if el then arr_set(el, 1, gu.bonus.resist) end
                if not gu.bonus.notedRes then
                    gu.bonus.notedRes = true
                    note(("Guise bonus: resist before: %s | after: poison %s, burning %s, fire %s"):format(before, tostring(arr_get(reg, 1)),
                        tostring(arr_get(reg, 5)), tostring(el and arr_get(el, 1))))
                end
            end)
            return r
        end)
    end)

    -- (4.73) the status screen's calculator
    gu.bonus.errs = {}
    local function berr(k, e) if not gu.bonus.errs[k] then gu.bonus.errs[k] = true; note("Guise bonus " .. k .. " failed: " .. tostring(e)) end end
    local function my_calc(calcObj)
        local a = runtime.player()
        return a and calcObj:get_field("CharaID") == a.character:get_CharaID()
    end
    gu.bonus.lastSet = {}
    function gu.bonus_def(st, where)
        if not gu.bonus.viaGetters then return end   -- (4.75: the bonus lives in the chest item now)
        local addr = st:get_address()
        local ad, am = st:get_field("<AdditionalDefence>k__BackingField") or 0, st:get_field("<AdditionalMagicDefence>k__BackingField") or 0
        local last = gu.bonus.lastSet[addr]
        if last and math.abs(ad - last.d) < 0.01 and math.abs(am - last.m) < 0.01 then return end   -- (ours still in: no piling up)
        local d0, m0 = st:call("get_Defence"), st:call("get_MagicDefence")
        st:set_field("<AdditionalDefence>k__BackingField", ad + d0 * gu.bonus.def)
        st:set_field("<AdditionalMagicDefence>k__BackingField", am + m0 * gu.bonus.def)
        gu.bonus.lastSet[addr] = { d = ad + d0 * gu.bonus.def, m = am + m0 * gu.bonus.def }
        if not gu.bonus["noted" .. where] then
            gu.bonus["noted" .. where] = true
            note(("Guise bonus (%s): defence %.0f -> %.0f, magick defence %.0f -> %.0f"):format(where, d0, st:call("get_Defence"), m0, st:call("get_MagicDefence")))
        end
    end
    local PSC = sdk.find_type_definition("app.PlayerStatusCalculator")
    for _, sig in ipairs({ "calcAttackDefenceWithEquipmentAndBuff()", "calcAttackDefenceWithEquipmentAndBuff(app.PlayerStatusCalculatorParameter)" }) do
        pcall(function()
            sdk.hook(PSC:get_method(sig), function(args)
                thread.get_hook_storage().me = args[2]
            end, function(r)
                if not gu.on or not gu.bonus.on or not live.on then return r end
                local ok, e = pcall(function()
                    local me = sdk.to_managed_object(thread.get_hook_storage().me)
                    if not me or not my_calc(me) then return end
                    local st = sdk.to_managed_object(r)
                    if st then gu.bonus_mark(st); if gu.bcnt then gu.bcnt("calcAttackDefence") end; gu.bonus_def(st, "calculator") end
                end)
                if not ok then berr("calc defence", e) end
                return r
            end)
        end)
    end
    pcall(function()
        sdk.hook(PSC:get_method("calcStatusConditionResistWithEquipmentAndBuff(app.StatusConditionDef.StatusConditionEnum)"), function(args)
            local stg = thread.get_hook_storage()
            stg.me, stg.cond = args[2], sdk.to_int64(args[3]) & 0xFFFFFFFF
        end, function(r)
            if not gu.on or not gu.bonus.on or not live.on then return r end
            local stg = thread.get_hook_storage()
            if stg.cond ~= 1 and stg.cond ~= 7 and stg.cond ~= 5 then return r end
            local out = r
            local ok, e = pcall(function()
                local me = sdk.to_managed_object(stg.me)
                if not me or not my_calc(me) then return end
                if not gu.bonus.notedOne then gu.bonus.notedOne = true; note(("Guise bonus: the screen asked resist %d = %s -> 1.0"):format(stg.cond, tostring(sdk.to_float(r)))) end
                out = sdk.float_to_ptr(gu.bonus.resist)
            end)
            if not ok then berr("calc resist", e) end
            return out
        end)
    end)
    pcall(function()
        sdk.hook(PSC:get_method("calcStatusConditionResistWithEquipmentAndBuff(app.PlayerStatusCalculatorParameter)"), function(args)
            thread.get_hook_storage().me = args[2]
        end, function(r)
            if not gu.on or not gu.bonus.on or not live.on then return r end
            local ok, e = pcall(function()
                local me = sdk.to_managed_object(thread.get_hook_storage().me)
                if not me or not my_calc(me) then return end
                local st = sdk.to_managed_object(r)
                gu.bonus_mark(st); if gu.bcnt then gu.bcnt("calcResistList") end
                local reg = st and st:get_field("StatusDamageRegist")
                if reg then for _, i in ipairs({ 1, 7, 5 }) do pcall(reg.call, reg, "Set", i, gu.bonus.resist) end end
                if not gu.bonus.notedArr then gu.bonus.notedArr = true; note("Guise bonus: the screen's resist list set") end
            end)
            if not ok then berr("calc resist list", e) end
            return r
        end)
    end)

    gu.bonus.mineSt, gu.bonus.cnt = {}, {}
    local function cnt(k) gu.bonus.cnt[k] = (gu.bonus.cnt[k] or 0) + 1 end
    gu.bcnt = cnt
    function gu.bonus_mark(st) if st and gu.bonus.viaGetters then gu.bonus.mineSt[st:get_address()] = true end end   -- (4.95: off - it only grew)
    local PB = sdk.find_type_definition("app.PlayerBasicAttackDefenceStatus")
    for _, g in ipairs({ "get_Defence", "get_MagicDefence" }) do
        pcall(function()
            sdk.hook(PB:get_method(g), function(args)
                thread.get_hook_storage().me = args[2]
            end, function(r)
                if not gu.on or not gu.bonus.on or not live.on then return r end
                local me = thread.get_hook_storage().me
                local addr = me and sdk.to_managed_object(me)
                addr = addr and addr:get_address()
                if not addr or not gu.bonus.mineSt[addr] or not gu.bonus.viaGetters then return r end
                cnt(g)
                local v = sdk.to_float(r)
                return sdk.float_to_ptr(v * (1 + gu.bonus.def))
            end)
        end)
    end
    for _, sig in ipairs({ "calcBasicAttackDefence()", "calcBasicAttackDefence(app.PlayerStatusCalculatorParameter)" }) do
        pcall(function()
            sdk.hook(PSC:get_method(sig), function(args)
                thread.get_hook_storage().me = args[2]
            end, function(r)
                if not gu.on or not gu.bonus.on then return r end
                pcall(function()
                    local me = sdk.to_managed_object(thread.get_hook_storage().me)
                    if me and my_calc(me) then cnt(sig); gu.bonus_mark(sdk.to_managed_object(r)) end
                end)
                return r
            end)
        end)
    end

    -- (4.75) the bonus in the worn chest item's own data (what the status screen shows), like the 0.35 magick sword
    gu.bonus.viaGetters = false
    gu.bonus.FIELDS = { "_PhysicalDefence", "_MagicDefence", "_FireDefence", "_FireResist", "_PoisonResist" }
    function gu.equip_refresh(im, a, data, sd)   -- (4.76) the cached equipment totals recomputed
        local r = {}
        local function tot()
            local t = "?"
            pcall(function() local eq = data:call("get_EqParam"); t = ("def %s mdef %s str %s"):format(tostring(eq:get_field("_PhysicalDefence")), tostring(eq:get_field("_MagicDefence")), tostring(eq:get_field("_PhysicalAttack"))) end)
            return t
        end
        r[#r + 1] = "before: " .. tot()
        if data then   -- (4.78) clear first: calc() adds onto the old totals
            r[#r + 1] = "clear " .. tostring(pcall(data.call, data, "clearParam"))
            r[#r + 1] = "calc " .. tostring(pcall(data.call, data, "calc"))
        end
        r[#r + 1] = "apply " .. tostring(pcall(im.call, im, "applyEquipDataForCharacter()"))
        r[#r + 1] = "apply(me) " .. tostring(pcall(im.call, im, "applyEquipDataForCharacter(app.Character)", a.character))
        pcall(function()
            local eq = data:call("get_EqParam")
            r[#r + 1] = ("totals now: def %s mdef %s poison %s"):format(tostring(eq:get_field("_PhysicalDefence")), tostring(eq:get_field("_MagicDefence")), tostring(eq:get_field("_PoisonResist")))
        end)
        return table.concat(r, ", ")
    end
    local function keep(o) local ok, r = pcall(function() return o:add_ref() end); return (ok and r) or o end
    gu.bonus.origById = {}
    pcall(function()
        local t = json.load_file("Pactblade_guise_items.json")
        if type(t) == "table" then gu.bonus.origById = t end
    end)
    function gu.armour_bonus(on)
        local im = sdk.get_managed_singleton("app.ItemManager")
        local a = runtime.player()
        if not im or not a then return "no item manager / player" end
        if not on then
            local m = gu.bonus.itemMod
            if not m then return "nothing to put back" end
            for f, v in pairs(m.orig) do
                pcall(function() m.param:set_field(f, v) end)
                if m.own then pcall(function() m.own:set_field(f, v) end) end
            end
            gu.bonus.itemMod = nil
            local rf = gu.equip_refresh(im, a, m.data, m.sd)
            return "chest item back: " .. tostring(m.name) .. " | " .. rf
        end
        if gu.bonus.itemMod then gu.armour_bonus(false) end
        local ed = im:call("getEquipData(app.Character)", a.character)
        local data = ed and ed:get_field("Data")
        local sd = data and data:call("get(app.EquipData.SlotEnum)", 3)   -- Upper
        local id = sd and sd:get_field("_ItemId")
        if not id or id == 0 then return "no chest item worn" end
        local param = im:call("getItemData(System.Int32)", id)
        if not param then return "no item data for " .. tostring(id) end
        local key = tostring(id)
        local orig = gu.bonus.origById[key]
        if type(orig) ~= "table" then   -- the first time ever for this item: its untouched values, kept on disk
            orig = {}
            for _, f in ipairs(gu.bonus.FIELDS) do pcall(function() orig[f] = param:get_field(f) end) end
            gu.bonus.origById[key] = orig
            pcall(dbg.save, "Pactblade_guise_items.json", gu.bonus.origById)
        end
        local totD, totM = 0, 0
        pcall(function()   -- (4.79) the status screen's total: my base + the equipment totals (still without our bonus)
            local eq = data:call("get_EqParam")
            local st = gu.bonus.liveSt
            local bD = st and st:get_field("<BasicDefence>k__BackingField") or 0
            local bM = st and st:get_field("<BasicMagicDefence>k__BackingField") or 0
            totD = bD + (eq:get_field("_PhysicalDefence") or 0) - ((param:get_field("_PhysicalDefence") or 0) - (orig._PhysicalDefence or 0))
            totM = bM + (eq:get_field("_MagicDefence") or 0) - ((param:get_field("_MagicDefence") or 0) - (orig._MagicDefence or 0))
        end)
        if totD <= 0 then totD = (orig._PhysicalDefence or 0) * 3 end
        if totM <= 0 then totM = (orig._MagicDefence or 0) * 3 end
        local addD, addM = math.floor(totD * gu.bonus.def + 0.5), math.floor(totM * gu.bonus.def + 0.5)
        local own
        pcall(function()   -- the worn item's own item data, if it's a separate copy
            local o2 = sd:get_field("_ItemData")
            if o2 and o2:get_address() ~= param:get_address() then own = keep(o2) end
        end)
        for _, obj in ipairs({ param, own }) do
            pcall(function() obj:set_field("_PhysicalDefence", (orig._PhysicalDefence or 0) + addD) end)
            pcall(function() obj:set_field("_MagicDefence", (orig._MagicDefence or 0) + addM) end)
            for _, f in ipairs({ "_FireDefence", "_FireResist", "_PoisonResist" }) do pcall(function() obj:set_field(f, 100) end) end
        end
        local name = tostring(id)
        pcall(function() name = param:call("get_Name") or name end)
        gu.bonus.itemMod = { param = keep(param), own = own, orig = orig, name = name, id = id, data = keep(data), sd = keep(sd) }
        local rf = gu.equip_refresh(im, a, data, sd)
        local o = {}
        for _, f in ipairs(gu.bonus.FIELDS) do o[#o + 1] = ("%s %s->%s"):format(f:sub(2), tostring(orig[f]), tostring(param:get_field(f))) end
        return ("chest item %s (my total def %.0f / mdef %.0f; own copy %s): %s | %s"):format(name, totD, totM, tostring(own ~= nil), table.concat(o, ", "), rf)
    end
    re.on_script_reset(function() pcall(gu.armour_bonus, false) end)

    -- (4.81) LEVITATE (Sorcerer's) while the guise is on: in the air, hold jump
    gu.lev = { on = true, hold = 0.25, info = "-", heldT = 0, used = false, lastT = os.clock(),
               rise = 1.5, maxRise = 2.5, maxKeep = 4.0, staminaPerSec = 60, hSpeed = 5.0 }
    re.on_pre_application_entry("UpdateBehavior", function()
        local L = gu.lev
        local now = os.clock()
        local dt = math.min(0.1, now - L.lastT)
        L.lastT = now
        if not gu.on or not L.on or not live.on then L.heldT = 0; return end
        local a = runtime.player()
        if not a then return end
        local grounded = true
        pcall(function() grounded = a:is_grounded() end)
        if grounded then L.heldT, L.used, L.jumpY0 = 0, false, nil; return end
        if L.used and not L.active and now >= (L.reAt or 0) then L.used = false end   -- (1.0 user: levitate again in the same jump)
        if L.used then
            if L.watchUntil and now < L.watchUntil and now >= (L.watchAt or 0) then
                L.watchAt = now + 0.25
                note("Levitate: action now " .. tostring(a:current_action(0)))
            end
            return
        end
        local held = false
        pcall(function() held = a:button_down("Jump") end)
        if not held then L.heldT = 0; return end
        local okAir = true
        if dbg.air_ok then pcall(function() okAir = dbg.air_ok(a) end) end
        if not okAir then return end
        L.heldT = L.heldT + dt
        if L.heldT < L.hold then return end
        L.used = true
        pcall(function()   -- (4.88) from an air attack etc.: that action ends first (in the air it becomes the fall)
            local cur = tostring(a:current_action(0)):lower()
            if not (cur:find("jump", 1, true) or cur:find("fall", 1, true)) then
                a:request_action("NormalLocomotion", 0)
                note("Levitate: ended the air action " .. cur .. " first")
            end
        end)
        local y0 = a.character:get_GameObject():get_Transform():get_Position().y
        local p0 = a.character:get_GameObject():get_Transform():get_Position()
        L.jumpY0 = L.jumpY0 or y0   -- (the rise is capped from the jump's first float: no climbing by re-floating)
        L.active = { t0 = now, y0 = math.min(y0, L.jumpY0), y = y0, tl = now, x = p0.x, z = p0.z }
        L.info = ("floating from %s"):format(tostring(a:current_action(0)))
        note("Levitate: " .. L.info)
    end)

    gu.lev.anim = { on = true, start = 5010, keep = 5000, startFrames = 172, keepFrames = 296, fps = 60, speed = 1.0,
                    tries = { { 3, nil }, { 9113, "animation/ch/ch00/motlist/ch00_006_com.motlist" }, { 9114, "animation/ch/ch00/motlist/ch00_006_comnm.motlist" } } }
    local CHANGE_M = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"
    local function has_motion(a, bank, id)
        local info = sdk.create_instance("via.motion.MotionInfo", true)
        local ok, r = pcall(function() return a.character:get_Motion():call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank, id, info) end)
        return ok and r
    end
    local function load_bank(a, bank, path)   -- a motlist as our own dynamic bank (castT.bank's way)
        local mo = a.character:get_Motion()
        for i = 0, mo:getDynamicMotionBankCount() - 1 do
            local b = mo:getDynamicMotionBank(i)
            if b and b:get_BankID() == bank then return end
        end
        local holder = sdk.create_resource("via.motion.MotionListResource", path):add_ref():create_holder("via.motion.MotionListResourceHolder"):add_ref()
        local n = mo:getDynamicMotionBankCount()
        mo:setDynamicMotionBankCount(n + 1)
        local b = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
        b:set_MotionList(holder)
        b:set_OverwriteBankID(true)
        b:set_BankID(bank)
        mo:setDynamicMotionBank(n, b)
    end
    function gu.lev_bank(a)   -- the bank that has the levitate motions (loading the candidates once)
        local A = gu.lev.anim
        if A.bank then return A.bank end
        for _, t in ipairs(A.tries) do
            if has_motion(a, t[1], A.start) and has_motion(a, t[1], A.keep) then
                A.bank = t[1]
                note(("Levitate animation: bank %d has the motions"):format(t[1]))
                return A.bank
            end
        end
        if not A.loaded then
            A.loaded = true
            for _, t in ipairs(A.tries) do if t[2] then pcall(load_bank, a, t[1], t[2]) end end
            note("Levitate animation: Mage motlists loaded as banks 9113 / 9114 (ready in a moment)")
        end
        return nil
    end
    re.on_pre_application_entry("UpdateMotion", function()
        local L, A = gu.lev, gu.lev.anim
        local F = L.active
        if not F or not A.on then
            if A.playing then   -- the float ended: the game's motion again
                A.playing = nil
                pcall(function() runtime.player().character.FullBodyLayer:call("set_Speed", 1.0) end)
            end
            return
        end
        pcall(function()
            local a = runtime.player()
            local bank = gu.lev_bank(a)
            if not bank then return end
            local Ly = a.character.FullBodyLayer
            local now = os.clock()
            F.at = F.at or now
            local fr = (now - F.at) * A.fps * A.speed
            local id, frame = A.start, fr
            if fr >= A.startFrames - 1 then id, frame = A.keep, (fr - (A.startFrames - 1)) % (A.keepFrames - 1) end
            if Ly:call("get_MotionBankID") ~= bank or Ly:call("get_MotionID") ~= id then
                Ly:call(CHANGE_M, bank, id, frame + 0.0, (id == A.start and fr < 1) and 8.0 or 4.0, 0, 0)
            end
            Ly:call("set_Speed", 0.0)
            Ly:call("set_Frame", frame + 0.0)
            A.playing = true
        end)
    end)
    function gu.lev_calm(a)   -- (4.84) no built-up fall: fall time / speed / height from now
        local ch = a.character
        pcall(function() ch:set_field("SecFall", 0.0) end)
        pcall(function()
            local ff = ch:get_field("<FreeFallCtrl>k__BackingField")
            ff:set_field("Frame", 0.0)
            local v = ff:get_field("<InitialFrameSpeed>k__BackingField")
            if v then ff:set_field("<InitialFrameSpeed>k__BackingField", Vector3f.new(v.x, 0.0, v.z)) end
        end)
        pcall(function()
            local fi = ch:get_field("<FallInfo>k__BackingField")
            fi:call("resetBaseHeight")
            fi:call("resetFallHeight")
        end)
    end
    re.on_application_entry("LateUpdateBehavior", function()   -- (4.82) our float: the height, every frame
        local L = gu.lev
        local F = L.active
        if not F then return end
        local a = runtime.player()
        local now = os.clock()
        local why
        if not a or not gu.on or not L.on or not live.on then why = "off" end
        local held, grounded = false, false
        if not why then
            pcall(function() held = a:button_down("Jump") end)
            pcall(function() grounded = a:is_grounded() end)
            if not held then why = "let go" elseif grounded then why = "ground" elseif now - F.t0 > L.maxKeep then why = "time" end
        end
        local dt = math.min(0.1, math.max(0, now - F.tl))
        F.tl = now
        if not why and L.staminaPerSec > 0 then
            pcall(function()
                local smg = a.character:get_StaminaManager()
                local left = smg:get_RemainingAmount()
                if left <= 0 then why = "no stamina"; return end
                smg:call("setRemainingAmount(System.Single)", math.max(0, left - L.staminaPerSec * dt))
            end)
        end
        if why then
            L.active = nil
            L.reAt, L.heldT = now + 0.3, 0
            if a then pcall(gu.lev_calm, a) end
            L.info = ("ended (%s) after %.1f s"):format(why, now - F.t0)
            note("Levitate: " .. L.info)
            return
        end
        pcall(function()
            local tr = a.character:get_GameObject():get_Transform()
            F.y = math.min(F.y0 + L.maxRise, F.y + L.rise * dt)
            local yaw = stick_yaw(a)   -- (4.90) steering: the stick at a fixed speed, facing that way
            if yaw then
                local mag = 1.0
                pcall(function() local ax = a.input:call("get_AxisL"); mag = math.min(1.0, math.sqrt(ax.x * ax.x + ax.y * ax.y)) end)
                local r = math.rad(yaw)
                local dx, dz = math.sin(r), math.cos(r)
                F.x, F.z = F.x + dx * L.hSpeed * mag * dt, F.z + dz * L.hSpeed * mag * dt
                if combo.yaw then pcall(function() tr:set_Rotation(combo.yaw(dx, dz)) end) end
            end
            tr:set_Position(Vector3f.new(F.x, F.y, F.z))
            pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
            gu.lev_calm(a)
        end)
    end)

    -- (4.91) the decoy's own Trickster reactions never run on the guise clone
    gu.decoyBlocked = {}
    local SD = sdk.find_type_definition("app.SmokeDecoy")
    for _, mname in ipairs({ "onOwnerDamageReaction", "onOwnerCalcDamageEnd", "onDamageHit", "onCalcDamageValueDefenseHandler",
                             "failTransferSmoke", "failPossessionSmoke", "releasePossesion", "hitHealingSmoke" }) do   -- (4.93: setTarget / setStay free again)
        pcall(function()
            for _, m in ipairs(SD:get_methods()) do
                if m:get_name() == mname then
                    sdk.hook(m, function(args)
                        if not gu.inst or not (gu.on or gu.parked or gu.ending) then return end
                        local ok, me = pcall(sdk.to_managed_object, args[2])
                        if not ok or not me or me:get_address() ~= gu.inst:get_address() then return end
                        if not gu.decoyBlocked[mname] then gu.decoyBlocked[mname] = true; note("Guise: blocked the decoy's own " .. mname) end
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end, function(r) return r end)
                end
            end
        end)
    end

    -- (4.94) the decoy never ends itself while the guise has it
    gu.endBlocked = {}
    local function block_on(tn, mnames, isHandler)
        local td = sdk.find_type_definition(tn)
        if not td then return end
        for _, m in ipairs(td:get_methods()) do
            local mn = m:get_name()
            for _, want in ipairs(mnames) do
                if mn == want then
                    pcall(function()
                        sdk.hook(m, function(args)
                            if gu.releasing or not gu.inst or not (gu.on or gu.parked or gu.ending) then return end
                            local ok, me = pcall(sdk.to_managed_object, args[2])
                            if not ok or not me then return end
                            local mine = false
                            if isHandler then pcall(function() local i = me:call("get_Instance"); mine = i and i:get_address() == gu.inst:get_address() end)
                            else mine = me:get_address() == gu.inst:get_address() end
                            if not mine then return end
                            local k = tn .. "." .. mn
                            gu.endBlocked[k] = (gu.endBlocked[k] or 0) + 1
                            if gu.endBlocked[k] == 1 then note("Guise: blocked the clone's own end: " .. k) end
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end, function(r) return r end)
                    end)
                end
            end
        end
    end
    block_on("app.SmokeDecoy", { "finish" })
    block_on("app.CloneCharacter", { "finish", "vanish", "sleep", "requestEndEffect", "triggerEndSE" })
    block_on("app.CloneCharacterHandler`1<app.SmokeDecoy>", { "finish", "vanish" }, true)
    block_on("app.DecoyHandler", { "finish", "vanish" }, true)
    function gu.alive(inst)   -- (4.44) the clone may not end by itself
        local kind = gu.kind(inst)
        if kind == "decoy" then pcall(function()   -- (4.57) the Trickster decoy's own life (time / death)
            if gu.decoyEl == nil then pcall(function() gu.decoyEl = inst:get_field("<ElapsedSecond>k__BackingField") end) end
            inst:set_field("<ElapsedSecond>k__BackingField", 0.0)
            inst:set_field("<IsDie>k__BackingField", false)
            inst:set_field("<FinishDamage>k__BackingField", false)
        end) end
        if kind == "decoy" then pcall(function()   -- (4.93) never a lure for enemies
            inst:set_field("<AttensionTimer>k__BackingField", 0.0)
            if inst:get_field("<IsTargetResistered>k__BackingField") then inst:set_field("<IsTargetResistered>k__BackingField", false) end
        end) end
        if kind == "decoy" and gu.colOffFor ~= inst:get_address() then   -- (4.93) its colliders off (enemies can't find / hit it)
            gu.colOffFor = inst:get_address()
            pcall(function()
                local names, off = {}, 0
                local function walk(go, depth)
                    pcall(function()
                        local comps = go:call("get_Components")
                        for c = 0, (comps and comps:call("get_Length") or 0) - 1 do
                            pcall(function()
                                local comp = comps:call("Get", c)
                                local tn = comp:get_type_definition():get_full_name()
                                if depth == 0 then names[#names + 1] = tn end
                                if tn == "via.physics.Colliders" or tn:find("RequestSetCollider", 1, true) or tn == "via.physics.CharacterController" then
                                    comp:call("set_Enabled", false); off = off + 1
                                end
                            end)
                        end
                    end)
                    if depth < 3 then pcall(function()
                        local ch = go:get_Transform():call("get_Child")
                        while ch do walk(ch:get_GameObject(), depth + 1); ch = ch:call("get_Next") end
                    end) end
                end
                walk(inst:get_GameObject(), 0)
                note(("Guise: the decoy's colliders off (%d) | its components: %s"):format(off, table.concat(names, ", "):sub(1, 900)))
            end)
        end
        if kind == "decoy" then pcall(function()   -- (4.65) never hidden by the decoy itself
            inst:set_field("<TemporaryHidden>k__BackingField", false)
            local go = inst:get_GameObject()
            if not go:call("get_DrawSelf") then go:call("set_DrawSelf", true) end
        end) end
        if gu.on and gu.want then pcall(function()
            local ps = inst:call("get_PartSwapper")
            for _, w in ipairs(gu.want) do
                pcall(function()
                    local o = ps:get_field("_" .. w.slot .. "Obj")
                    if o and not o:call("get_DrawSelf") then o:call("set_DrawSelf", true); gu.drawFixed = (gu.drawFixed or 0) + 1 end
                end)
            end
        end) end
        if kind == "decoy" and os.clock() >= (gu.hateAt or 0) then
            gu.hateAt = os.clock() + 1.0
            pcall(inst.call, inst, "clearHate")
        end
        if kind ~= "after" then return end
        pcall(function() inst:set_field("IsEnd", false) end)
        pcall(function() inst:set_field("IsMotionEnd", false) end)
        pcall(function() inst:set_field("<IsForceContinueMirageDance>k__BackingField", true) end)
        pcall(function()
            local t = inst:get_field("EndTimer")
            if t then t:set_field("_ElapsedFrame", 0.0); t:set_field("_IsFinish", false); t:set_field("_Ratio", 0.0) end
        end)
    end
    function gu.alive_info(inst)
        local t = {}
        for _, f in ipairs({ "IsEnd", "IsMotionEnd", "IsPlayed", "IsForceContinueMirageDance", "IsMirageDance" }) do
            pcall(function() t[#t + 1] = f .. "=" .. tostring(inst:get_field(f)) end)
        end
        pcall(function()
            local et = inst:get_field("EndTimer")
            t[#t + 1] = ("end %.0f/%.0f %s"):format(et:get_field("_ElapsedFrame") or -1, et:get_field("_FinishFrame") or -1, tostring(et:get_field("_IsFinish")))
        end)
        pcall(function() t[#t + 1] = "next " .. tostring(inst:call("get_NextStatus")) end)
        pcall(function() t[#t + 1] = ("decoy elapsed %.2f die %s"):format(inst:get_field("<ElapsedSecond>k__BackingField"), tostring(inst:get_field("<IsDie>k__BackingField"))) end)
        return table.concat(t, " ")
    end
    re.on_pre_application_entry("LateUpdateBehavior", function()
        if (gu.on or gu.parked or gu.ending) and gu.inst then gu.alive(gu.inst) end
    end)

    -- (4.61) THE SKILL: Perfect Defense / Divine Defense's slot -> Caustic Brew's chant -> the guise for 60 s
    gu.skill = { on = true, secs = 60, staminaPct = 0.25,   -- (1.1 user: half)
                  info = "-", lastPress = -10 }
    local DIVINE = -1
    pcall(function()
        for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
            if f:is_static() and f:get_name() == "Job01_DivineDefense" then DIVINE = f:get_data(nil) & 0xFFFFFFFF end
        end
    end)
    function gu.press()
        local sk2, now = gu.skill, os.clock()
        if not sk2.on or gu.castWant or now - sk2.lastPress < 0.6 then return end
        local a = runtime.player()
        if not a then return end
        local busy, bc = dbg.busy_action and dbg.busy_action(a)
        if busy then sk2.info = "not now (" .. tostring(bc) .. ")"; return end
        local can = false
        pcall(function() local track = a.character:get_Human().Track; can = track.All or track.Skill end)
        if not can then sk2.info = "not now (the game's skill track is closed)"; return end
        if dbg.slots and dbg.slots.free() < 1 then dbg.slots.deny(); sk2.info = "no spell slot free"; note("Otherworldly Guise: no spell slot free"); return end   -- (1.1)
        pcall(gu.prepare, a)   -- the decoy made now, ready by the release
        sk2.lastPress, gu.castWant, gu.castWantT = now, true, now
    end
    function gu.release(a)   -- the chant is over: a spell slot, 25 % stamina, the guise on (or renewed)
        if dbg.slots and not dbg.slots.use() then dbg.slots.deny(); note("Otherworldly Guise: no spell slot free at the release - fizzled"); return end   -- (1.1)
        pcall(function()
            local smg = a.character:get_StaminaManager()
            local b0, cost = smg:get_RemainingAmount(), smg:get_MaxValue() * gu.skill.staminaPct
            smg:call("setRemainingAmount(System.Single)", math.max(0, b0 - cost))
            note(("stamina: Otherworldly Guise paid %.0f (%.0f -> %.0f)"):format(cost, b0, smg:get_RemainingAmount()))
        end)
        gu.secs = gu.skill.secs
        if gu.on then
            gu.t0 = os.clock() - 3.0   -- (renewed: the full minute from now; its first 3 s are the building steps)
            gu.t0 = os.clock()
            pcall(function()   -- (4.89 user: a recast re-applies the look too)
                if gu.inst and not gu.ending then
                    pcall(gu.restyle, gu.inst, true)
                    gu.step, gu.t0w, gu.lostAt = 1, os.clock(), nil
                end
            end)
            gu.skill.info = "renewed"
            note("Otherworldly Guise: renewed for " .. gu.secs .. " s")
        else
            local ok, e = pcall(gu.show, a)
            gu.skill.info = ok and "on" or ("failed: " .. tostring(e))
            note("Otherworldly Guise: on for " .. gu.secs .. " s")
        end
    end
    re.on_pre_application_entry("UpdateBehavior", function()
        if not gu.castWant then return end
        local a = runtime.player()
        if not a or not live.on then gu.castWant = false; return end
        local castT = dbg.castT
        if castT.t0 or (combo and combo.stage ~= 0) then return end
        castT.secs = (dbg.brew and dbg.brew.castSecs) or castT.secs
        local okS, eS = pcall(castT.start, a)
        if okS and castT.t0 then
            gu.castWant = false
            castT.onRelease = gu.release
            castT.onEnd = function() end
            gu.skill.info = "chanting"
        elseif os.clock() - gu.castWantT > 2.5 then
            gu.castWant = false
            gu.skill.info = "could not start: " .. tostring(okS and castT.info or eS)
        end
    end)
    pcall(function()
        local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
        sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
            if not live.on or not gu.skill.on or not dbg.press_ok() then return end
            if (sdk.to_int64(args[3]) & 0xFFFFFFFF) ~= DIVINE then return end
            gu.press()
            return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
        end, function(r) return r end)
    end)
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
            function(args)
                if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
                if not live.on or not gu.skill.on or dbg.INTEGRATED then return end
                local skip = false
                pcall(function()
                    local name = sdk.to_managed_object(args[4]):ToString()
                    if not name:find("^Job01_DivineDefense") then return end
                    if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                    skip = true
                    gu.press()
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
    end)
    -- a shield skill without a shield: usable for MY character while Pactblade is on
    for _, mname in ipairs({ "isCustomSkillAvailable(app.HumanCustomSkillID)", "isCustomSkillAvailableWithoutItemCondition(app.HumanCustomSkillID)" }) do
        pcall(function()
            sdk.hook(sdk.find_type_definition("app.HumanSkillAvailability"):get_method(mname), function(args)
                local st = thread.get_hook_storage()
                st.guYes = nil
                if not live.on or not gu.skill.on or not dbg.press_ok() then return end
                if (sdk.to_int64(args[3]) & 0xFFFFFFFF) ~= DIVINE then return end
                pcall(function()
                    local ch = sdk.to_managed_object(args[2]).Chara
                    if ch and ch:get_GameObject():get_address() == live.go then st.guYes = true end
                end)
            end, function(r)
                local st = thread.get_hook_storage()
                if st.guYes then st.guYes = nil; return sdk.to_ptr(1) end
                return r
            end)
        end)
    end
    function gu.release_clone()   -- the real end: meshes back, scale, motion, finish (the warps get the clone back)
        if gu.on then gu.stop("released") end
        gu.releasing = true
        if gu.parked then gu.finish_end() end
    end
    re.on_application_entry("LateUpdateBehavior", function()
        pcall(gu.own_wait)
        if (gu.on or gu.parked or gu.ending) and gu.inst then gu.alive(gu.inst) end
        if gu.parked and gu.inst and gu.hushUntil and os.clock() < gu.hushUntil and os.clock() >= (gu.hushAt or 0) then
            gu.hushAt = os.clock() + 1.0
            local okH, nH = pcall(gu.hush, gu.inst)
            if okH and nH and nH > 0 then note("Guise: parked - stopped " .. nH .. " more sound(s)") end
        end
        if gu.parked and gu.inst then   -- (4.47) parked: kept on me, every mesh off
            pcall(function()
                local p = runtime.player().character:get_GameObject():get_Transform():get_Position()
                gu.inst:get_GameObject():get_Transform():set_Position(p)
                for _, e in ipairs(all_meshes(gu.inst:get_GameObject())) do
                    if e.mesh:call("get_Enabled") then e.mesh:call("set_Enabled", false) end
                end
            end)
        end
        if gu.retryAt and os.clock() >= gu.retryAt and not gu.on then
            gu.retryAt = nil
            pcall(gu.show, runtime.player())
        end
        if gu.ending then   -- (4.45) the back-swap done (no wanted mesh left) or 2 s: then finish
            local inst, back = gu.inst, true
            pcall(function()
                local ps = inst:call("get_PartSwapper")
                for _, w in ipairs(gu.want or {}) do
                    pcall(function()
                        local o = ps:get_field("_" .. w.slot .. "Obj")
                        local m = o and o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                        local path = m and m:call("getMesh"):call("get_ResourcePath") or ""
                        local base = tostring(w.mesh or ""):match("([^/]+)%.mesh$") or "?"
                        if path:lower():find(base:lower(), 1, true) then back = false end
                        if m then m:call("set_Enabled", false) end
                    end)
                end
            end)
            if back or os.clock() - gu.ending.t > 2.0 then
                note(("Guise: back-swap %s after %.2f s"):format(back and "done" or "NOT done", os.clock() - gu.ending.t))
                gu.finish_end()
            end
            return
        end
        if gu.on then   -- (4.80) menus / pauses don't count
            local t = os.clock()
            local dt = t - (gu.lastFrameT or t)
            gu.lastFrameT = t
            local paused = dt > 0.25
            if not paused then pcall(function()
                local gm = sdk.get_managed_singleton("app.GuiManager")
                if gm and gm:call("isPausedGUI") then paused = true end
            end) end
            if not paused then pcall(function()
                local tm = sdk.get_managed_singleton("app.TimeManager")
                if tm and tm:call("get_IsTimeStop") then paused = true end
            end) end
            if paused and gu.t0 then gu.t0 = gu.t0 + dt; gu.pausedSecs = (gu.pausedSecs or 0) + dt end
        else
            gu.lastFrameT = nil
        end
        if not gu.on then return end
        local a = runtime.player()
        if not a then gu.stop("no player"); return end
        pcall(function()   -- (4.46) the handler's CURRENT clone (start may have made a new one)
            local cur = gu.handler(a):call("get_Instance")
            if cur and gu.inst and cur:get_address() ~= gu.inst:get_address() then
                note(("Guise: the handler has a NEW clone (%x -> %x) - dressing that one"):format(gu.inst:get_address(), cur:get_address()))
                gu.inst, gu.step, gu.pairs, gu.colours, gu.hipP, gu.hipC, gu.fix, gu.hidden = cur, 0, nil, nil, nil, nil, nil, nil
            end
        end)
        local now, inst = os.clock(), gu.inst
        if now - gu.t0 >= gu.secs then gu.stop("time up"); return end
        local okF, eF = pcall(function()   -- on me, my pose
            local ptr = a.character:get_GameObject():get_Transform()
            local cgo = inst:get_GameObject()
            local ctr = cgo:get_Transform()
            if gu.kind(inst) == "after" then pcall(function() inst:set_field("RootMoveScale", 0.0) end) end
            local p = ptr:get_Position()
            local fx0 = gu.fix or { x = 0, z = 0 }
            local sx, sz = 0, 0
            if gu.sideTest then   -- (4.58) 3 m to my right (enemy interest test); the hip fix paused
                local f = mathx.rotate(Vector3f.new(0, 0, 1), ptr:get_Rotation())
                local l = math.sqrt(f.x * f.x + f.z * f.z)
                if l > 0.01 then sx, sz = -f.z / l * 3.0, f.x / l * 3.0 end
                fx0 = { x = 0, z = 0 }
            end
            ctr:set_Position(Vector3f.new(p.x + fx0.x + sx, p.y + gu.yOff, p.z + fx0.z + sz))
            ctr:set_Rotation(ptr:get_Rotation())
            ctr:set_LocalScale(Vector3f.new(gu.scale[1], gu.scale[2], gu.scale[3]))
            if not gu.pairs then gu.pairs = pairs_build(a.character:get_GameObject(), cgo) end
            for _, e in ipairs(gu.pairs) do
                pcall(e.c.call, e.c, "set_LocalPosition", e.p:call("get_LocalPosition"))
                pcall(e.c.call, e.c, "set_LocalRotation", e.p:call("get_LocalRotation"))
            end
            pcall(function()   -- (4.45) its Hip onto mine (x/z): the offset stays from frame to frame
                gu.hipP = gu.hipP or ptr:call("getJointByName", "Hip")
                gu.hipC = gu.hipC or ctr:call("getJointByName", "Hip")
                local a1, b1 = gu.hipP:call("get_Position"), gu.hipC:call("get_Position")
                local dx, dz = a1.x - b1.x, a1.z - b1.z
                gu.fix = gu.fix or { x = 0, z = 0 }
                local me = ptr:get_Position()
                local hipFar = math.sqrt((a1.x - me.x) ^ 2 + (a1.z - me.z) ^ 2) > 1.0   -- (4.90) carried / ragdoll: no fixing
                if hipFar then dx, dz = 0, 0 end
                if gu.alignOn ~= false and not gu.sideTest and math.abs(dx) + math.abs(dz) < 5 then gu.fix.x, gu.fix.z = gu.fix.x + dx * 0.5, gu.fix.z + dz * 0.5 end
                local fl = math.sqrt(gu.fix.x ^ 2 + gu.fix.z ^ 2)
                if fl > 0.5 then gu.fix.x, gu.fix.z = gu.fix.x / fl * 0.5, gu.fix.z / fl * 0.5 end   -- (4.90) never more than 0.5 m
                gu.lastOff = math.sqrt(dx * dx + dz * dz)
            end)
        end)
        if not okF and not gu.followErr then gu.followErr = true; note("Guise: follow failed: " .. tostring(eF)) end
        if gu.step == 0 then
            gu.step = 1
            pcall(function() inst:call("get_Motion"):call("set_Enabled", false) end)
            note(("Guise: clone %x: status %s | %s"):format(inst:get_address(), tostring(inst:call("get_Status")), gu.alive_info(inst)))
            pcall(gu.no_ui, inst)
            if gu.bonus.on then local okB, eB = pcall(gu.armour_bonus, true); note("Guise bonus: " .. tostring(eB)) end
            pcall(gu.lev_bank, runtime.player())
            note("Guise: restyling the clone")
            local okR, eR = pcall(gu.restyle, inst, true)
            note("Guise: " .. tostring(okR and eR or ("restyle failed: " .. tostring(eR))) .. (" - following with %d joint(s)"):format(#(gu.pairs or {})))
        elseif gu.step == 1 then   -- the game builds the parts: wait until each wanted slot holds the wanted mesh (max 5 s)
            local okW, ready, n, miss = pcall(gu.wanted_ready, inst)
            if not okW then ready, n, miss = false, 0, tostring(ready) end
            if ready or now - (gu.t0w or gu.t0) > 5.0 then
                gu.t0w = nil
                gu.step = 2
                note(("Guise: %d armour part(s) in place, all %s%s - hiding the rest"):format(n or 0, tostring(ready), ready and "" or (" (missing " .. tostring(miss) .. ")")))
                local okH, nH = pcall(gu.hide_rest, inst, true)
                note("Guise: hidden " .. tostring(okH and nH or ("failed " .. tostring(nH))) .. " - ghost look")
                local okG, eG = pcall(gu.ghost, inst)
                note("Guise: ghost look: " .. tostring(eG))
                gu.keepAt, gu.statAt = now + 0.25, now + 1.0
            end
        elseif gu.step == 2 and now >= (gu.keepAt or 0) then   -- (4.42) keep it so: wanted on, the rest off
            gu.keepAt = now + 0.25
            local okW, inPlace = pcall(function()   -- (4.89) watchdog: still our styles + our meshes?
                local meta = inst:call("get_PartSwapper"):get_field("_Meta")
                local styleOk = meta:get_field("_TopsStyle") == ev("app.TopsStyle", gu.CHESTS[gu.chest][2])
                    and meta:get_field("_PantsStyle") == ev("app.PantsStyle", gu.LEGS[gu.legs][2])
                local partsOk = gu.wanted_ready(inst)
                return styleOk and partsOk, styleOk
            end)
            if okW and inPlace == false then
                gu.lostAt = gu.lostAt or now
                if now - gu.lostAt > 0.5 then
                    gu.lostAt = nil
                    gu.relooks = (gu.relooks or 0) + 1
                    local act = "?"
                    pcall(function() act = tostring(a:current_action(0)) end)
                    note(("Guise watchdog: the clone lost the look (my action %s) - dressing it again (#%d)"):format(act, gu.relooks))
                    pcall(gu.restyle, inst, true)
                    gu.step, gu.t0w = 1, now
                end
            else
                gu.lostAt = nil
            end
            if now >= (gu.stateAt or 0) then
                gu.stateAt = now + 5.0
                pcall(function()
                    local go = inst:get_GameObject()
                    local cl = {}
                    for k2, an in ipairs(gu.fx or {}) do pcall(function() cl[#cl + 1] = tostring(an.ep:call("get_State") & 0xFFFFFFFF) end) end
                    local d = (go:get_Transform():get_Position() - a.character:get_GameObject():get_Transform():get_Position()):length()
                    note(("Guise state: draw %s, look kept %s, cloud players [%s], re-dressed %d x, %.2f m from me, hip fix %.2f/%.2f"):format(tostring(go:call("get_DrawSelf")),
                        tostring(okW and inPlace), table.concat(cl, ","), gu.relooks or 0, d, gu.fix and gu.fix.x or 0, gu.fix and gu.fix.z or 0))
                end)
            end
            local okK, k1, k2 = pcall(gu.keep, inst)
            pcall(gu.no_ui, inst)
            local okX, again = pcall(gu.fx_keep, inst)
            pcall(gu.fx_tune, false)
            if okX and again then note(("Guise: Mirage Dance effects again (#%d)"):format(gu.fxCount or 0)) end
            if now >= (gu.colAt or 0) then   -- (4.50) glow colour slots again (parts finish later)
                gu.colAt = now + ((now - gu.t0 < 3.0) and 0.25 or 1.0)   -- (4.60: fast at first; 4.90: then every 1 s)
                pcall(function() gu.colours = ai.find_colours(inst) end)
                pcall(function() gu.illSlots = gu.ill_slots(inst, true) end)   -- (4.90: always - rebuilt parts)
            end
            if now >= (gu.statAt or 0) then
                gu.statAt = now + 1.0
                if now >= (gu.bonusNoteAt or 0) then   -- (4.74) the bonus counters every 3 s, the whole guise
                    gu.bonusNoteAt = now + 3.0
                    pcall(function()
                        local t = {}
                        for k, v in pairs(gu.bonus.cnt) do t[#t + 1] = k .. " " .. v end
                        local n = 0
                        for _ in pairs(gu.bonus.mineSt) do n = n + 1 end
                        note(("Guise bonus: %d status object(s) of mine; ran: %s"):format(n, table.concat(t, ", ")))
                    end)
                end
                local st = "?"
                pcall(function() st = tostring(inst:call("get_Status")) .. " draw " .. tostring(inst:get_GameObject():call("get_DrawSelf")) end)
                if okK and (k1 > 0 or k2 > 0) or now - gu.t0 < 4 then
                    local parts = {}
                    pcall(function()
                        local ps = inst:call("get_PartSwapper")
                        for _, w in ipairs(gu.want or {}) do
                            pcall(function()
                                local o = ps:get_field("_" .. w.slot .. "Obj")
                                local m = o:call("getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
                                local vis, cnt = 0, m:call("getPartsEnableCount")
                                for i = 0, cnt - 1 do if m:call("getPartsEnable", i) then vis = vis + 1 end end
                                parts[#parts + 1] = ("%s %s %d/%d"):format(w.slot, m:call("get_Enabled") and "on" or "OFF", vis, cnt)
                            end)
                        end
                    end)
                    local ex = {}
                    pcall(function()
                        local go = inst:get_GameObject()
                        local me = a.character:get_GameObject():get_Transform():get_Position()
                        ex[#ex + 1] = ("clone draw %s hidden %s, %.2f m from me, draw fixes %d"):format(tostring(go:call("get_DrawSelf")),
                            tostring(inst:get_field("<TemporaryHidden>k__BackingField")), (go:get_Transform():get_Position() - me):length(), gu.drawFixed or 0)
                        local ps = inst:call("get_PartSwapper")
                        for _, w in ipairs(gu.want or {}) do
                            pcall(function()
                                local o = ps:get_field("_" .. w.slot .. "Obj")
                                ex[#ex + 1] = ("%s draw %s %.2f m"):format(w.slot, tostring(o:call("get_DrawSelf")), (o:get_Transform():get_Position() - me):length())
                            end)
                        end
                        for k, an in ipairs(gu.fx or {}) do
                            pcall(function() ex[#ex + 1] = ("cloud%d state %d speed %s"):format(k, an.ep:call("get_State") & 0xFFFFFFFF, tostring(an.ep:call("get_PlaySpeed"))) end)
                        end
                    end)
                    if false then pcall(function()
                        local t = {}
                        for k, v in pairs(gu.bonus.cnt) do t[#t + 1] = k .. " " .. v end
                        local n = 0
                        for _ in pairs(gu.bonus.mineSt) do n = n + 1 end
                        note(("Guise bonus: %d status object(s) of mine; ran: %s"):format(n, table.concat(t, ", ")))
                    end) end
                    note(("Guise: hip off %.2f m, fix %.2f/%.2f | turned on %s / off %s | %s | %s"):format(gu.lastOff or -1, gu.fix and gu.fix.x or 0,
                        gu.fix and gu.fix.z or 0, tostring(k1), tostring(k2), table.concat(parts, ", "), table.concat(ex, "; ")))
                end
            end
            if gu.colours and okK and k1 and k1 > 0 then pcall(function() gu.colours = ai.find_colours(inst) end) end
        end
    end)
    re.on_pre_application_entry("BeginRendering", function()
        if not gu.on or not gu.colours then return end
        for _, e in ipairs(gu.colours) do
            pcall(function()
                local r, g, b = ai.rgb(gu.hue, gu.sat, e.val * gu.glow)
                e.mesh:call("setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)", e.m, e.v, Vector4f.new(r, g, b, e.w))
            end)
        end
    end)
end)()


re.on_frame(function()
    local r = dbg.rec
    if not r.on then return end
    pcall(function()
        local L = runtime.player().character.FullBodyLayer
        local key = L:call("get_MotionBankID") .. "/" .. L:call("get_MotionID")
        if key ~= r.lastMotion then
            r.lastMotion = key
            local nm
            pcall(function() nm = tostring(runtime.player():current_action(0)) end)
            dbg.rec_add({ motion = key, frame = L:call("get_Frame"), action = nm })
        end
    end)
    if os.clock() - r.t0 >= r.secs then
        r.on = false
        pcall(json.dump_file, "Pactblade_chant_record.json", r.list)
        r.info = ("done: %d entries -> data/Pactblade_chant_record.json"):format(#r.list)
    else
        r.info = ("recording... %.1f s left (%d entries)"):format(r.secs - (os.clock() - r.t0), #r.list)
    end
end)

local castT = { secs = 3.0, info = "-", BANK = 9112, PATH = "animation/ch/ch00/motlist/ch00_006_atk.motlist",
                CHANGE = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)" }
dbg.castT = castT
function castT.bank(a)
    local mo = a.character:get_Motion()
    for i = 0, mo:getDynamicMotionBankCount() - 1 do
        local b = mo:getDynamicMotionBank(i)
        if b and b:get_BankID() == castT.BANK then return true end
    end
    local holder = sdk.create_resource("via.motion.MotionListResource", castT.PATH):add_ref()
        :create_holder("via.motion.MotionListResourceHolder"):add_ref()
    local n = mo:getDynamicMotionBankCount()
    mo:setDynamicMotionBankCount(n + 1)
    local bank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
    bank:set_MotionList(holder)
    bank:set_OverwriteBankID(true)
    bank:set_BankID(castT.BANK)
    mo:setDynamicMotionBank(n, bank)
    return false
end
function castT.ready(a)
    local info = sdk.create_instance("via.motion.MotionInfo", true)
    return a.character:get_Motion():call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", castT.BANK, 712, info)
end
function castT.play(a, id, interp)
    a.character:get_Motion():getLayer(0):call(castT.CHANGE, castT.BANK, id, 0.0, interp or 8.0, 1, 1)
end
function castT.fsm(a, on)
    pcall(function()
        if on then
            local fsm = a.character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
            if fsm then fsm:call("set_Paused", true); castT.paused = fsm:add_ref() end
        elseif castT.paused then castT.paused:call("set_Paused", false); castT.paused = nil end
    end)
end
-- one effect from a Mage effect set (by path) on the player
-- the anchor in front of the chest the chant circle sits on (a Mage's is on the staff): follows the player while chanting
castT.frontDist, castT.frontHeight, castT.frontTilt, castT.frontSide = 0.65, 0.0, 90, 0.47   -- from the head (user's spot)
castT.frontScale = 0.6   -- (user: 60 % of its size)
function castT.front(a)
    local tr = a.character:get_GameObject():get_Transform()
    local rot = tr:get_Rotation()
    local fwd = rot * Vector3f.new(0, 0, 1)
    if not castT.anchor then
        castT.anchor = make_anchor()
        castT.anchor:set_Name("Pactblade_cast_circle")
    end
    local h = math.rad(castT.frontTilt) / 2   -- tilted around its own sideways axis: upright, facing forward
    local q = Quaternion.new(math.cos(h), math.sin(h), 0, 0)
    local r = Quaternion.new(rot.w * q.w - rot.x * q.x - rot.y * q.y - rot.z * q.z, rot.w * q.x + rot.x * q.w + rot.y * q.z - rot.z * q.y,
                             rot.w * q.y - rot.x * q.z + rot.y * q.w + rot.z * q.x, rot.w * q.z + rot.x * q.y - rot.y * q.x + rot.z * q.w)
    local base = tr:get_Position() + Vector3f.new(0, 1.6, 0)
    pcall(function() local hj = tr:call("getJointByName", "Head"); if hj then base = hj:get_Position() end end)
    local at = castT.anchor:get_Transform()
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    local fx, fz = len > 0.001 and fwd.x / len or 0, len > 0.001 and fwd.z / len or 1
    -- (the character's right is (-fz, fx) of its flat forward: 2.46 had it the other way round)
    at:set_Position(base + Vector3f.new(fx * castT.frontDist - fz * castT.frontSide, castT.frontHeight, fz * castT.frontDist + fx * castT.frontSide))
    at:set_Rotation(r)
    at:set_LocalScale(Vector3f.new(castT.frontScale, castT.frontScale, castT.frontScale))
    return castT.anchor
end
-- which element / parts of the file show: the game's player's mask, groups and extern parameters onto our copy
function castT.copy_look(src, ep)
    if not src then return end
    local got = {}
    pcall(function() ep:call("set_EmitMaskBit", src:call("get_EmitMaskBit")); got[#got + 1] = "mask " .. tostring(src:call("get_EmitMaskBit")) end)
    pcall(function() local m = src:call("get_MaskName"); if m and tostring(m) ~= "" then ep:call("set_MaskName", m); got[#got + 1] = "name " .. tostring(m) end end)
    pcall(function() ep:call("set_GroupEnabled", src:call("get_GroupEnabled")) end)
    for _, kind in ipairs({ "GroupNames", "GroupParameters", "ExternParameters" }) do
        pcall(function()
            local n = src:call("get" .. kind .. "Count")
            if not n or n == 0 then return end
            ep:call("set" .. kind .. "Count", n)
            for q = 0, n - 1 do ep:call("set" .. kind, q, src:call("get" .. kind, q)) end
            got[#got + 1] = ("%d %s"):format(n, kind)
        end)
    end
    castT.lookInfo = table.concat(got, ", ")
end
-- the game's circle -> the same effect file(s) on our own effect players on the anchor; the game's copy is killed
function castT.move_front(a)
    for k = #(castT.frontPending or {}), 1, -1 do
        local e = castT.frontPending[k]
        local done = false
        local okM, errM = pcall(function()
            local list = e.c:call("getAllPlayers")
            local paths = {}
            e.src = {}
            local n = list and list:call("get_Count") or 0
            for q = 0, n - 1 do
                local pl = list:call("get_Item", q)
                local path
                for _, getter in ipairs({ function() return pl:call("get_Resource"):call("get_ResourcePath") end,
                                          function() return pl:call("get_ResourcePath") end }) do
                    if not path then
                        local ok, v = pcall(getter)
                        if ok and v and tostring(v) ~= "" then path = tostring(v) end
                    end
                end
                if path then paths[#paths + 1] = path; e.src = e.src or {}; e.src[#paths] = pl:add_ref() end
            end
            castT.frontInfo = ("%d effect player(s), %d file(s)"):format(n, #paths)
            if #paths == 0 then return end
            local go = castT.front(a)
            castT.res = castT.res or {}
            for pi, path in ipairs(paths) do
                if castT.res[path] == nil then
                    local r = sdk.create_resource("via.effect.EffectResource", path)
                    castT.res[path] = r and r:add_ref() or false
                end
                if castT.res[path] then
                    local child = make_anchor()   -- (one EffectPlayer per game object)
                    child:set_Name("Pactblade_cast_fx")
                    local ctr = child:get_Transform()
                    ctr:call("set_Parent", go:get_Transform())
                    ctr:set_LocalPosition(Vector3f.new(0, 0, 0))
                    ctr:set_LocalRotation(Quaternion.new(1, 0, 0, 0))
                    castT.frontGos = castT.frontGos or {}
                    table.insert(castT.frontGos, child)
                    local ep = child:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
                    ep:call("set_Resource", castT.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref())
                    castT.copy_look(e.src and e.src[pi], ep)
                    pcall(function() ep:call("set_AutoStart", true) end)
                    castT.frontPlayers = castT.frontPlayers or {}
                    table.insert(castT.frontPlayers, ep)
                end
            end
            e.c:call("killAll")
            castT.moved = (castT.moved or 0) + 1
            castT.frontInfo = ("moved %d effect(s) in front; last: %s"):format(castT.moved, paths[1]:match("([^/]+)$") or paths[1])
            done = true
        end)
        if not okM then castT.frontInfo = "move failed: " .. tostring(errM); done = true end
        if done then table.remove(castT.frontPending, k)
        elseif os.clock() - e.t > 0.5 then
            table.remove(castT.frontPending, k)
            castT.frontInfo = "an effect could not be moved (" .. tostring(castT.frontInfo) .. ")"
        end
    end
end
function castT.drop_front()   -- our players fade out, then our anchor goes (2 s later)
    castT.frontPending = nil
    if not castT.anchor then return end
    pcall(function()
        local fin = sdk.find_type_definition("via.effect.PlayerAction"):get_field("Finish"):get_data(nil)
        for _, ep in ipairs(castT.frontPlayers or {}) do pcall(function() ep:call("set_Action", fin) end) end
    end)
    castT.frontPlayers = nil
    local t = os.clock() + 2.0
    castT.dying = castT.dying or {}
    for _, child in ipairs(castT.frontGos or {}) do table.insert(castT.dying, { go = child, t = t }) end   -- (children first)
    table.insert(castT.dying, { go = castT.anchor, t = t + 0.1 })
    castT.frontGos, castT.anchor = nil, nil
end
re.on_frame(function()
    for k = #(castT.dying or {}), 1, -1 do
        local d = castT.dying[k]
        if os.clock() >= d.t then pcall(function() d.go:call("destroy(via.GameObject)", d.go) end); table.remove(castT.dying, k) end
    end
end)
re.on_script_reset(function()
    for _, child in ipairs(castT.frontGos or {}) do pcall(function() child:call("destroy(via.GameObject)", child) end) end
    if castT.anchor then local o = castT.anchor; pcall(function() o:call("destroy(via.GameObject)", o) end) end
    for _, d in ipairs(castT.dying or {}) do pcall(function() d.go:call("destroy(via.GameObject)", d.go) end) end
end)
function castT.fx(a, set, cont, el, front)
    local mgr = a.character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    local conts, idx = mgr.ExternalDataContainers, nil
    for i = 0, conts:get_Count() - 1 do
        local ok, path = pcall(function() return tostring(conts[i].DataContainer:get_Path()) end)
        if ok and path:lower():find(set, 1, true) then idx = i end
    end
    if not idx then return set .. " not on this character" end
    local id = sdk.create_instance("via.effect.script.EffectID")
    id.DataContainerIndex = idx; id.ContainerID = cont; id.ElementID = el
    id.IsContainerIDOnly = false; id.IsElementIDOnly = false
    local c = mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
        id, a.character:get_GameObject(), -1, nil)
    if c then
        castT.conts = castT.conts or {}
        table.insert(castT.conts, c:add_ref())
        if front then   -- moved in front of the chest as soon as its files are known (castT.move_front)
            castT.frontPending = castT.frontPending or {}
            table.insert(castT.frontPending, { c = c:add_ref(), t = os.clock() })
        end
    end
    return c and "ok" or "no effect"
end
castT.STEPS = {
    { t = 0.0, fx = { { "ch03/13_ch03_ns", 0, 40, true }, { "ch03/13_ch03_cs", 0, 104, true } }, snd = 2921097576, motion = 710 },
    { t = 0.2, snd = 3366100101, loop = true },
    { t = 0.4, fx = { { "ch03/13_ch03_cs", 0, 304, true } }, motion = 712 },   -- (true: in front of the chest)
}
castT.LOOP = 3366100101   -- the chant loop (a looping sound: triggered once, stopped at the release)
castT.STOP = 2605810471   -- the sound that ends the chant (user found it in the recorded cast: 2.16)
-- sheathing during the chant: the chant ends (no release)
pcall(function()   -- (i-0.4) a hit reaction during the chant: the cast stops, the reaction plays
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if not castT.t0 or not live.on then return end
            pcall(function()
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                local name = sdk.to_managed_object(args[4]):ToString()
                if name:find("^Dmg") or name:find("^Caught") or name:find("Down") or name:find("Blown") or name:find("Slam") then
                    note("chant interrupted by a hit: " .. name)
                    castT.cancel(runtime.player(), "hit: " .. name)
                end
            end)
        end, function(r) return r end)
end)
function castT.cancel(a, why)
    if not castT.t0 then return end
    castT.onRelease = nil
    for _, c in ipairs(castT.conts or {}) do pcall(function() c:call("finishAll") end) end
    castT.drop_front()
    if combo.cue_sound then pcall(combo.cue_sound, a, castT.STOP) end
    castT.fsm(a, false)
    castT.t0, castT.released = nil, false
    castT.info = "cancelled: " .. tostring(why)
    if castT.onEnd then local f = castT.onEnd; castT.onEnd = nil; pcall(f, a) end
end
function castT.start(a)
    if castT.t0 then return end
    castT.bank(a)
    if not castT.ready(a) then castT.info = "animations loading - press again in a moment"; return end
    castT.t0, castT.step, castT.conts, castT.log, castT.moved, castT.cancelWith = os.clock(), 1, {}, {}, 0, nil
    castT.fsm(a, true)
end
re.on_pre_application_entry("UpdateBehavior", function()
    if not castT.t0 then return end
    local a = runtime.player()
    if not a then return end
    local t = os.clock() - castT.t0
    if a:button_pressed("Sheathe") then castT.cancel(a, "sheathe pressed"); return end   -- (user: sheathing cancels)
    pcall(function()
        while castT.STEPS[castT.step] and t >= castT.STEPS[castT.step].t do
            local st = castT.STEPS[castT.step]
            if st.motion then pcall(castT.play, a, st.motion) end
            for _, f in ipairs(st.fx or {}) do
                local ok, r = pcall(castT.fx, a, f[1], f[2], f[3], f[4])
                castT.log[#castT.log + 1] = ("fx %s %d/%d: %s"):format(f[1], f[2], f[3], tostring(ok and r or r))
            end
            if st.snd and combo.cue_sound and (not st.loop or castT.loopOn) then
                local ok, r = pcall(combo.cue_sound, a, st.snd)
                castT.log[#castT.log + 1] = ("sound %d: %s"):format(st.snd, tostring(ok and r or r))
            end
            castT.step = castT.step + 1
        end
        if castT.frontPending and #castT.frontPending > 0 then pcall(castT.move_front, a) end
        if castT.anchor then pcall(castT.front, a) end   -- the circle stays in front
        -- keep the chant looping
        local L = a.character:get_Motion():getLayer(0)
        if t < castT.secs and t > 0.4 and (L:get_MotionBankID() ~= castT.BANK or L:get_MotionID() ~= 712) then castT.play(a, 712, 6.0) end
        if t >= castT.secs and not castT.released then   -- ready flash + chime, release motion
            castT.released = true
            for _, f in ipairs({ { "ch03/13_ch03_ns", 0, 41, true }, { "ch03/13_ch03_cs", 0, 3, true } }) do pcall(castT.fx, a, f[1], f[2], f[3], f[4]) end
            if combo.cue_sound then pcall(combo.cue_sound, a, 3990051307) end
            if combo.cue_sound then pcall(combo.cue_sound, a, castT.STOP) end
            castT.play(a, 750, 6.0)
            if castT.onRelease then local f = castT.onRelease; castT.onRelease = nil; pcall(f, a) end
        end
        if t >= castT.secs + 0.9 then
            for _, c in ipairs(castT.conts or {}) do pcall(function() c:call("finishAll") end) end
            castT.drop_front()
            if combo.cue_sound then pcall(combo.cue_sound, a, castT.STOP) end   -- (in case the release was skipped)
            castT.fsm(a, false)
            castT.ourReq = true
            pcall(function() a:request_action("NormalLocomotion", 0) end)
            castT.ourReq = false
            castT.t0, castT.released = nil, false
            castT.info = table.concat(castT.log, " | ")
            if castT.onEnd then local f = castT.onEnd; castT.onEnd = nil; pcall(f, a) end
        end
    end)
end)

------------------------------------------------------------------------
-- TASHA'S CAUSTIC BREW (user's skill, in Full Moon Slash's slot)
--   The recorded Mage chant (castT, 3 s). At the release the green acid (our pb_acid_v3 effect, 8 copies over 15 m)
--   pours forward from 1 m ahead, a splash sound at every splash. The damage: every 0.3 s the enemies inside the
--   acid's strip take a little damage (HitManager.directDamage) and poison build-up (own meter: 100 = poisoned).
------------------------------------------------------------------------
;(function()
local sk = { castSecs = 3.0, ahead = 1.0, lingerSecs = 5.0, halfWidth = 1.25, tickSecs = 0.3, tickDmg = 72, poisonPts = 35, stagger = false,
             file = "pactblade/pb_acid_v3", info = "-", lastPress = -10, hitCount = 0, meters = {}, poisonQ = {} }
dbg.brew = sk   -- (the menu reaches it through dbg)

-- the look: our acid effect on anchors, a wave of 8 copies 1.9 m apart, 0.07 s after each other
local acidRes, acidLive = nil, {}
local function acid_at(pos, rot)
    if acidRes == nil then
        local r = sdk.create_resource("via.effect.EffectResource", "vfx/effects/" .. sk.file .. ".efx")
        acidRes = r and r:add_ref() or false
    end
    if not acidRes then sk.info = "acid effect not found (restart the game for the effect pak)"; return nil end
    local go = make_anchor()
    go:set_Name("Pactblade_acid")
    local tr = go:get_Transform()
    tr:set_Position(pos)
    tr:set_Rotation(rot)
    local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
    ep:call("set_Resource", acidRes:create_holder("via.effect.EffectResourceHolder"):add_ref())
    pcall(function() ep:call("set_AutoStart", true) end)
    table.insert(acidLive, { go = go, dieAt = os.clock() + 6 })
    return go
end
re.on_frame(function()
    local w = sk.wave
    if w then
        local due = math.floor((os.clock() - w.t0) / 0.07) + 1
        while w.n < math.min(due, 8) do
            w.n = w.n + 1
            local d = sk.ahead + (w.n - 1) * 1.9
            local g = acid_at(Vector3f.new(w.pos.x + w.fx * d, w.pos.y, w.pos.z + w.fz * d), w.rot)
            if g then pcall(sk.play, sk.splashSnd(), g:get_Transform():get_Position(), "splash") end
        end
        if w.n >= 8 then sk.wave = nil end
    end
    for k = #acidLive, 1, -1 do
        if os.clock() > acidLive[k].dieAt then
            pcall(function() acidLive[k].go:call("destroy(via.GameObject)", acidLive[k].go) end)
            table.remove(acidLive, k)
        end
    end
end)

-- sounds: my own (combo.cue_sound, the chant's way) or the acid monster's (its projectile sound set, loaded by the game)
-- a trigger's info in a container: its own list, or the trigger lists of the sound sets loaded into it
local function find_info(c, id)
    local found
    pcall(function()
        local l = c._TriggerInfoList
        for k = 0, l._size - 1 do if l._items[k] and l._items[k]._TriggerId == id then found = l._items[k]; return end end
    end)
    if found then return found end
    pcall(function()
        local L = c["<AllTriggerInfoListData>k__BackingField"]
        for k = 0, L._size - 1 do
            local items = L._items[k] and L._items[k]._TriggerInfoList
            for q = 0, (items and items._size or 0) - 1 do
                if items._items[q] and items._items[q]._TriggerId == id then found = items._items[q]; return end
            end
        end
    end)
    return found
end
local REQ_INFO = "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)"
-- a trigger played as cue_sound plays mine: a request made from its info, sent through the container
local request_play
dbg.snd_find_info = find_info
function request_play(c, info, go)
    local req = c:call(REQ_INFO, info, go, go, info._OffsetJointHash, false, false, 0, 0, nil, nil, nil, nil)
    if not req then return "no request" end
    req = req:add_ref()
    req["<Container>k__BackingField"] = c
    c:call("trigger(soundlib.SoundManager.RequestInfo)", req)
    return "asked"
end
-- the acid monster's projectile sound set (its trigger lists + banks: ch254001_fx, ch221000_fx)
dbg.snd_request = request_play
sk.SOUNDSET = "Sound/Resource/EM/ch254001/Containers/shl_ch254001_fx_ContainerListData.user"
sk.SPLASH = { src = "monster", id = 3870869112, label = "monster splash (random: B 02 / 06 / 08 / 10)" }
sk.pool, sk.poolNext = {}, 1
local function sound_set()
    if sk.soundSet == nil then
        local ud = sdk.create_userdata("soundlib.SoundContainerListData", sk.SOUNDSET)
        sk.soundSet = ud and ud:add_ref() or false
    end
    return sk.soundSet or nil
end
local function pool_clear()
    for _, e in ipairs(sk.pool) do local o = e.go; pcall(function() o:call("destroy(via.GameObject)", o) end) end
    sk.pool, sk.poolNext = {}, 1
end
-- the set into my own container (once per character) and 8 fresh sound objects of ours, one per splash (made anew for every cast:
-- nothing old is touched after a scene change)
function sk.prepare_sounds(a)
    local set = sound_set()
    if not set then sk.sndInfo = "the monster's sound set was not found"; return end
    local go = a.character:get_GameObject()
    if sk.soundsFor ~= go:get_address() then
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            if c:get_type_definition():get_full_name() == "app.WwiseContainerApp" then
                c:call("loadContainableUserData", set)
                sk.soundsFor = go:get_address()
                break
            end
        end
    end
    pool_clear()
    local at = go:get_Transform():get_Position()
    for k = 1, 8 do
        local o = make_anchor()
        o:set_Name("Pactblade_sound")
        o:get_Transform():set_Position(at)
        local c = o:call("createComponent(System.Type)", sdk.typeof("app.WwiseContainerApp")):add_ref()
        pcall(function() c._UserDataList:call("Add", set) end)
        pcall(c.call, c, "loadContainableUserData", set)
        sk.pool[k] = { go = o, c = c }
    end
end
-- one sound of the set at a spot: the next sound object goes there and plays it (else from my own container)
local function play_at_spot(a, id, pos)
    local e = sk.pool[sk.poolNext]
    sk.poolNext = sk.poolNext % math.max(1, #sk.pool) + 1
    if e and pos then
        local info = find_info(e.c, id)
        if info then
            e.go:get_Transform():set_Position(pos)
            return "at the spot: " .. request_play(e.c, info, e.go)
        end
    end
    local go = a.character:get_GameObject()
    for _, c in ipairs(go:call("get_Components"):get_elements()) do
        if c:get_type_definition():get_full_name() == "app.WwiseContainerApp" then
            local info = find_info(c, id)
            if info then return "from me: " .. request_play(c, info, go) end
        end
    end
    return "not loaded yet (the sounds load when the chant starts)"
end
re.on_script_reset(pool_clear)
function sk.play(snd, pos, what)
    if not snd then sk.sndInfo = "no " .. (what or "") .. " sound picked"; return end
    local a = runtime.player()
    if not a then return end
    local r
    if snd.src == "player" then
        r = tostring(combo.cue_sound(a, snd.id))
    else
        if #sk.pool == 0 then pcall(sk.prepare_sounds, a) end
        local ok, rr = pcall(play_at_spot, a, snd.id, pos)
        r = tostring(rr)
    end
    sk.sndInfo = ("%s %d (%s): %s"):format(what or "sound", snd.id, snd.label or snd.src, r)
end
-- picked: { src = "player" | "monster" | "obj" | "vase", id, label } (saved: the container itself is never kept)
local function saved_pick(c) return c and type(c.id) == "number" and { src = c.src or "obj", id = c.id, label = c.label } or nil end
sk.releaseSnd, sk.pourSnd = saved_pick(cfg.brewLand), saved_pick(cfg.brewPour)
if not sk.pourSnd or sk.pourSnd.src == "vase" then sk.pourSnd = sk.SPLASH end   -- (the vase's sound: pottery, not a splash)
function sk.splashSnd() return sk.pourSnd end
-- every sound of the last recording, once each
function sk.candidates()
    local out, seen = {}, {}
    for _, e in ipairs(dbg.rec.list) do
        if e.sound then
            local key = (e.obj or "player") .. "/" .. e.sound
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = { src = e.obj and "obj" or "player", id = e.sound, label = (e.obj or "me") .. " " .. e.sound }
            end
        end
    end
    return out
end

function sk.poison_value()
    if sk.poison ~= nil then return sk.poison end
    sk.poison = false
    pcall(function()
        for _, f in ipairs(sdk.find_type_definition("app.StatusConditionDef.StatusConditionEnum"):get_fields()) do
            if f:is_static() and f:get_name() == "Poison" then sk.poison = f:get_data(nil) end
        end
    end)
    return sk.poison
end
local APPLY_STATUS = "reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean)"
-- the damage: enemies in the acid's strip (from 1 m ahead to where the wave has got, sk.halfWidth to each side,
-- 2.5 m up / down) take sk.tickDmg and sk.poisonPts on their poison meter - called every sk.tickSecs while the acid lies
function sk.tick(a)
    local ar = sk.area
    local reach = math.min(sk.ahead + 7 * 1.9 + 1.0, sk.ahead + (os.clock() - ar.t0) / 0.07 * 1.9 + 1.0)   -- the wave's front
    local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
    local hm = sdk.get_managed_singleton("app.HitManager")
    local me, myHit = a.character:get_GameObject(), a.character["<Hit>k__BackingField"]
    for k = 0, list._size - 1 do
        pcall(function()
            local ch = list._items[k] and list._items[k]._Chara
            local hit = ch and ch["<Hit>k__BackingField"]
            if not hit or hit:get_Hp() <= 0 then return end
            local p = (ch.Hip or ch["<Transform>k__BackingField"]):get_Position()
            local dx, dz = p.x - ar.pos.x, p.z - ar.pos.z
            local along, side = dx * ar.fx + dz * ar.fz, math.abs(dx * ar.fz - dz * ar.fx)
            if along < sk.ahead - 1.0 or along > reach or side > sk.halfWidth or math.abs(p.y - ar.pos.y) > 2.5 then return end
            local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()
            info.Damage = sk.tickDmg
            if sk.stagger and not ar.staggered[ch:get_address()] then   -- (test) one flinch per enemy
                ar.staggered[ch:get_address()] = true
                info.DamageType, info.DamageActType, info.IsDirectDamageEnableAllDamageType = 6, 6, true   -- Hitback_M
            end
            local ok = pcall(hm.call, hm, "directDamage", info, hit, me, false, myHit)
            if not ok then hm:call("directDamage", info, hit, nil, false, nil) end
            sk.hitCount = sk.hitCount + 1
            local key, now = ch:get_address(), os.clock()
            local m = sk.meters[key]
            if not m or now - m.at > 10 then m = { value = 0 } end
            m.value, m.at = m.value + sk.poisonPts, now
            if m.value >= 100 then m.value = 0; sk.poisonQ[#sk.poisonQ + 1] = ch:add_ref() end
            sk.meters[key] = m
        end)
    end
end
-- the chant is over: the acid pours and starts to hurt
function sk.release(a)
    pcall(function()   -- (4.05 user: the cost when the acid splashes; checked - the chant ignored it)
        local smg = a.character:get_StaminaManager()
        local b0 = smg:get_RemainingAmount()
        local en = "?"
        pcall(function() en = tostring(smg:get_IsEnableConsume()) end)
        smg:call("setRemainingAmount(System.Single)", math.max(0, b0 - (sk.stamina or 150)))   -- (4.06: set directly - 'use' is off)
        note(("stamina: Tasha's Caustic Brew paid %.0f as the acid pours (%.0f -> %.0f; consumption on: %s)"):format(sk.stamina or 150, b0, smg:get_RemainingAmount(), en))
    end)
    local tr = a.character:get_GameObject():get_Transform()
    local pos, rot = tr:get_Position(), tr:get_Rotation()
    local fwd = rot * Vector3f.new(0, 0, 1)
    local len = math.sqrt(fwd.x * fwd.x + fwd.z * fwd.z)
    local fx, fz = len > 0.001 and fwd.x / len or 0, len > 0.001 and fwd.z / len or 1
    local yaw = math.atan(fx, fz)
    pcall(sk.play, sk.releaseSnd, nil, "release")
    sk.area = { pos = pos, fx = fx, fz = fz, t0 = os.clock(), nextT = os.clock() + 0.25, staggered = {} }
    sk.info = "acid out"
    sk.wave = { pos = pos, rot = Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0), fx = fx, fz = fz, t0 = os.clock(), n = 0 }
    sk.stage, sk.t0 = "pour", os.clock()
end
function sk.finish(why)
    sk.stage, sk.on, sk.wave, sk.area = nil, false, nil, nil
    if why then sk.info = why end
end
re.on_application_entry("LateUpdateBehavior", function()
    for k = #sk.poisonQ, 1, -1 do   -- poison, asked outside the damage calculation
        local ch = table.remove(sk.poisonQ, k)
        pcall(function()
            if ch:get_IsDead() then return end
            local req = sdk.create_instance("app.StatusConditionDef.RequestInfo"):add_ref()
            ch["<StatusConditionCtrl>k__BackingField"]:call(APPLY_STATUS, sk.poison_value(), nil, req, false)
            sk.poisoned = (sk.poisoned or 0) + 1
            sk.ourPoison[ch:get_address()] = os.clock()
        end)
    end
    if sk.area and os.clock() >= sk.area.nextT then
        sk.area.nextT = os.clock() + sk.tickSecs
        local a = runtime.player()
        if a then
            local okT, eT = pcall(sk.tick, a)
            if not okT then sk.info = "damage failed: " .. tostring(eT) end
        end
    end
    if sk.stage == "pour" and os.clock() - sk.t0 >= sk.lingerSecs then
        sk.finish(("done: %d hit(s) on enemies, %d poisoned"):format(sk.hitCount, sk.poisoned or 0))
    end
end)
-- the press: the chant starts as soon as its animations are loaded (first time: a moment)
re.on_pre_application_entry("UpdateBehavior", function()
    if not sk.want then return end
    local a = runtime.player()
    if not a or not live.on then sk.want = false; return end
    if castT.t0 or combo.stage ~= 0 then return end
    castT.secs = sk.castSecs
    local okS, eS = pcall(castT.start, a)
    if okS and castT.t0 then
        sk.want, sk.on, sk.stage, sk.hitCount, sk.poisoned = false, true, "cast", 0, 0
        pcall(sk.prepare_sounds, a)   -- (loaded by the release, 3 s later)
        castT.onRelease = sk.release
        castT.onEnd = function() if sk.stage == "cast" then sk.finish("the chant ended without a release") end end
        sk.info = "chanting"
    elseif os.clock() - sk.wantT > 2.5 then
        sk.want = false
        sk.info = "could not start: " .. tostring(okS and castT.info or eS)
    end
end)
re.on_script_reset(function() sk.finish() end)
-- our poison hurts sk.poisonMul x as much: the game's poison ticks on enemies Caustic Brew poisoned
sk.ourPoison, sk.poisonMul, sk.poisonTicks = {}, 2.0, 0
pcall(function()
    sdk.hook(sdk.find_type_definition("app.StatusConditionActionSlipDamage"):get_method("setDirectDamage(System.Single, System.Boolean, app.StatusConditionInfo)"),
        function(args)
            if sk.poisonMul == 1 or next(sk.ourPoison) == nil then return end
            pcall(function()
                local act = sdk.to_managed_object(args[2])
                local ch = act["<OwnerCharacter>k__BackingField"]
                local at = ch and sk.ourPoison[ch:get_address()]
                if not at then return end
                if os.clock() - at > 120 then sk.ourPoison[ch:get_address()] = nil; return end
                if (act.ActionParam._ElementType or 0) ~= 0 then return end   -- (burning: fire)
                args[3] = sdk.float_to_ptr(sdk.to_float(args[3]) * sk.poisonMul)
                sk.poisonTicks = sk.poisonTicks + 1
            end)
        end, function(r) return r end)
end)
local FULLMOON_ID = -1
pcall(function()
    for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
        if f:is_static() and f:get_name() == "Job01_FullMoonSlash" then FULLMOON_ID = f:get_data(nil) & 0xFFFFFFFF end
    end
end)
function sk.press()
    local now = os.clock()
    if sk.on or sk.want or now - sk.lastPress < 0.6 then return end
    local can = false
    pcall(function()
        local track = runtime.player().character:get_Human().Track
        can = track.All or track.Skill
    end)
    if can then sk.lastPress, sk.want, sk.wantT = now, true, now end   -- (4.05: paid when the acid pours, sk.release)
end
pcall(function()
    local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
    sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
        if not live.on or not dbg.press_ok() then return end
        if (sdk.to_int64(args[3]) & 0xFFFFFFFF) ~= FULLMOON_ID then return end
        sk.press()
        return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
    end, function(r) return r end)
end)
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if not live.on then return end
            local skip = false
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                if dbg.INTEGRATED or not name:find("^Job01_FullMoonSlash") then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                skip = true
                sk.press()
            end)
            if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
end)
end)()

------------------------------------------------------------------------
-- ELDRITCH SMITE (user's skill): Warrior's short-range heavy attack (0 - 66.6) into Arc of Obliteration's end (from 50,
-- 1.5x from 150, back to normal locomotion at 347). In Burst Strike's slot (Job01_BlinkStrike), rebindable from the menu.
------------------------------------------------------------------------
;(function()
local sm = { info = "-", lastPress = -10, fast = 1.5,
             PARTS = { { action = "Job05_ShortRangeHeavyAttack", from = 0.0, to = 66.6 },
                       { action = "Job05_ArcOfObliterationEnd", from = 50.0, fastFrom = 150.0, to = 347.0 } } }
sm.blend = 12   -- frames of crossfade into a part's start frame
local CHANGE = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"
dbg.smite = sm
-- the skill ids (app.HumanCustomSkillID) by name and the other way round
local IDS, NAMES = {}, {}
pcall(function()
    for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            if ok and type(v) == "number" then IDS[f:get_name()] = v & 0xFFFFFFFF; NAMES[v & 0xFFFFFFFF] = f:get_name() end
        end
    end
end)
local function request(a, name)
    sm.ourReq = true
    local ok = a:request_action(name, 0)
    sm.ourReq = false
    return ok
end
local function mkey(L) return L:call("get_MotionBankID") * 100000 + L:call("get_MotionID") end
sm.boomScale, sm.boomFx = 1.5, "-1/8/43"   -- (user: 60 % of 2.5)
sm.lightOn, sm.lightUntil, sm.lightLm, sm.lightRadius = true, 132, 562, 3.0   -- (user's values, 2026-10-23)
sm.lookAfter = 0.3   -- (user: the smite look from 0.3 s into the first animation; the light follows the look)
sm.lookUntil = 86    -- (user: ... until about frame 86 of the second animation)
sm.lookExtra = 0.2   -- (user: and 0.2 s longer)
sm.downType, sm.downPower = 15, 150   -- (user: every enemy knocked down: Slam_L; 3.68 user FINAL: x150)
sm.dmgMul = 1.0   -- (3.54 test 0.1: proved the flights are deaths; 3.55 back to full)
sm.lethalSkip = true    -- (3.55: a killing blow gets no forced Slam_L / x100; 3.56: softened instead - the game threw it anyway)
sm.deathType, sm.deathPower = 12, 0.05   -- (3.56: Hitdown_L, 5 % reaction power on the killing blow)
sm.deadSecs, sm.deadMaxH, sm.deadMaxUp = 2.0, 2.5, 1.0   -- (3.57: the killed body's ragdoll speed cap, m/s)
function sm.mark_dead(info)
    pcall(function()
        local v = info["<DamageGameObject>k__BackingField"]
        sm.dead = { go = v:add_ref(), untilT = os.clock() + sm.deadSecs, noted = false }
    end)
end
pcall(function()
    sdk.hook(sdk.find_type_definition("app.DamageRagdollBlow"):get_method("start(via.behaviortree.ActionArg)"), function(args)
        local isJav = (PB.javelinT and os.clock() - PB.javelinT < 3.0)
        if not isJav and (not sm.dead or os.clock() > sm.dead.untilT) then return end
        pcall(function()
            local this = sdk.to_managed_object(args[2])
            pcall(function() this:call("set_IsBlownWithAttackVelocity", false) end)
            pcall(function() this.IsDisableCalcVelocity = true end)
            note("Eldritch Smite: the killed body's blow - no attack velocity, no velocity calc")
        end)
    end, function(r) return r end)
end)
re.on_pre_application_entry("LateUpdateBehavior", function()
    local d = sm.dead
    if not d then return end
    if os.clock() > d.untilT then sm.dead = nil; return end
    pcall(function()
        local rg = d.go:call("getComponent(System.Type)", sdk.typeof("app.CharacterRagdoll"))
        if not rg then return end
        local ok = pcall(rg.call, rg, "limitLinearVelocity(System.Single, System.Single)", sm.deadMaxH, sm.deadMaxUp)
        if not ok then pcall(rg.call, rg, "limitLinearVelocity(System.Single)", sm.deadMaxH) end
        if not d.noted then d.noted = true; note("Eldritch Smite: killed body's ragdoll speed capped (" .. (ok and "2 values" or "1 value") .. ")") end
    end)
end)
function sm.soften(info)
    pcall(function() info.DamageType, info.DamageActType, info.OverwriteBlownType = sm.deathType, sm.deathType, sm.deathType end)
    pcall(function() info.ForceFactor = 0 end)
    pcall(function() info.BlownReactionRate = 0 end)
    pcall(function() info.HitBackZ, info.HitBackY, info.HitBackAddZ = 0, 0, 0 end)
end
function sm.lethal(info)
    local yes = false
    pcall(function()
        local v = info["<DamageGameObject>k__BackingField"]
        local ch = v:call("getComponent(System.Type)", sdk.typeof("app.Character"))
        yes = (info.Damage or 0) >= ch["<Hit>k__BackingField"]:get_Hp()
    end)
    return yes
end
sm.push = 1.0   -- (3.49 test; 3.54: off again - the push was 0 anyway)
sm.noBlown = false   -- (3.52 test; 3.54: off again)
re.on_frame(function()
    local w = sm.watch
    if not w or os.clock() < w.at then return end
    sm.watch = nil
    pcall(function()
        local ch = w.go:call("getComponent(System.Type)", sdk.typeof("app.Character"))
        local nm = "?"
        pcall(function() local e = ch:get_ActionManager().CurrentActionList[0]; nm = tostring(e and e.Name or "?") end)
        note("Eldritch Smite: the enemy's reaction: " .. nm)
    end)
end)
sm.chargeDelay = -0.2  -- s from the smite look's start; minus = sooner, down to the smite's start (user: a bit sooner)
local function my_smite_hit(info)
    if not sm.stage or not live.on then return false end
    local hc = info:get_AttackHitController()
    return hc ~= nil and hc:get_GameObject():get_address() == live.go
end
pcall(function()
    sdk.hook(sdk.find_type_definition("app.HitController"):get_method("getReactionDamageType(app.HitController.DamageInfo)"),
        function(args)
            local st = thread.get_hook_storage()
            st.smDown = nil
            if not sm.stage then return end
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                if my_smite_hit(info) then st.smDown = info end
            end)
        end, function(r)
            local st = thread.get_hook_storage()
            local info = st.smDown
            st.smDown = nil
            if not info then return r end
            if sm.lethalSkip and sm.lethal(info) then   -- (3.56: dying - a soft knock-down, no ragdoll throw)
                sm.soften(info)
                sm.mark_dead(info)
                note(("Eldritch Smite: killing blow (damage %.0f) - soft knock-down"):format(info.Damage or -1))
                return sdk.to_ptr(sm.deathType)
            end
            pcall(function() info.DamageType, info.DamageActType, info.OverwriteBlownType = sm.downType, sm.downType, sm.downType end)
            sm.downs = (sm.downs or 0) + 1
            return sdk.to_ptr(sm.downType)
        end)
end)
pcall(function()
    sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageReaction(app.HitController.DamageInfo)"),
        function(args)
            local st = thread.get_hook_storage()
            st.smPow = nil
            st.pbJavPow = nil
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                if sm.stage and my_smite_hit(info) then st.smPow = info end
                if live.on and PB.activeVocation == "stormblade" and PB.javelinT and (os.clock() - PB.javelinT < 3.0) then
                    st.pbJavPow = info
                end
            end)
        end, function(r)
            local st = thread.get_hook_storage()
            local jInfo = st.pbJavPow
            st.pbJavPow = nil
            if jInfo then
                pcall(function()
                    jInfo.DamageReaction = 120
                    jInfo.ForceFactor = 0
                    jInfo.BlownReactionRate = 0
                    jInfo.HitBackY = 0
                    jInfo.HitBackVec = Vector3f.new(0, 0, 0)
                end)
            end
            local info = st.smPow
            st.smPow = nil
            if info then
                local lethal = sm.lethal(info)   -- (3.53/3.55: a killing blow keeps the game's own death reaction)
                if lethal and sm.lethalSkip then
                    pcall(function() info.DamageReaction = info.DamageReaction * sm.deathPower end)
                    sm.soften(info)
                    sm.mark_dead(info)
                    note("Eldritch Smite: killing blow - reaction power x" .. sm.deathPower)
                else pcall(function() info.DamageReaction = info.DamageReaction * sm.downPower end) end
            end
            return r
        end)
end)
local function smite_push(info, where)
    if sm.lethalSkip and sm.lethal(info) then sm.soften(info) end
    local before = ("z %.2f, y %.2f, addZ %.2f"):format(info.HitBackZ or 0, info.HitBackY or 0, info.HitBackAddZ or 0)
    local rx = "?"
    pcall(function()
        rx = ("type %s, power %.0f, blownRate %.2f, blownLv %s, leanRate %.2f, twoUp %s, lvDown %s, force %.2f, ignoreBlown %s"):format(
            tostring(info.DamageType), info.DamageReaction or -1, info.BlownReactionRate or -1, tostring(info.BlownReactionConvertLevel),
            info.LeanReactionRate or -1, tostring(info.IsTwoRankUpReaction), tostring(info.LevelDownReaction), info.ForceFactor or -1,
            tostring(info.IgnoreCheckBlownThreshold))
    end)
    if sm.noBlown then
        pcall(function() info.BlownReactionRate = 0 end)
        pcall(function() info.BlownReactionConvertLevel = 0 end)
        pcall(function() info.IsTwoRankUpReaction = false end)
    end
    pcall(function()   -- what the enemy does a moment later
        local v = info["<DamageGameObject>k__BackingField"]
        if v then sm.watch = { go = v:add_ref(), at = os.clock() + 0.35 } end
    end)
    pcall(function() info.HitBackZ = (info.HitBackZ or 0) * sm.push end)
    pcall(function() info.HitBackY = (info.HitBackY or 0) * sm.push end)
    pcall(function() info.HitBackAddZ = (info.HitBackAddZ or 0) * sm.push end)
    pcall(function() local v = info.HitBackVec; info.HitBackVec = Vector3f.new(v.x * sm.push, v.y * sm.push, v.z * sm.push) end)
    pcall(function() info.ForceFactor = (info.ForceFactor or 0) * sm.push end)
    if not sm.pushNoted or os.clock() - sm.pushNoted > 1 then
        sm.pushNoted = os.clock()
        note(("Eldritch Smite: push %s -> x%.2f (%s) | reaction %s"):format(before, sm.push, where, rx))
    end
end
for _, mn in ipairs({ "updateDamageReaction(app.HitController.DamageInfo)", "setDamageType(app.HitController.DamageInfo)" }) do
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method(mn), function(args)
            if not sm.stage then return end
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                if my_smite_hit(info) then smite_push(info, mn:match("^(%w+)")) end
            end)
        end, function(r) return r end)
    end)
end
-- Mystic Spearhand's whole-body charge look: its RimLight material mode, recoloured
sm.RIM = { mode = 1704633256, cat = 8, secs = 1.0 }   -- (user: a ~1 s pulse, just a signal)
local RIM_REQ = "requestMaterialMode(System.UInt32, app.MaterialInterpolationRequestManager.RequestListCategory, System.Int32, System.Int32)"
local RIM_FIN = "finishMaterialMode(System.UInt32, app.MaterialInterpolationRequestManager.RequestListCategory, System.Int32, System.Int32)"
local function pick_hue()
    local gv = tostring(cfg.glowVariant or "")
    return tonumber(gv:match("^ppb?(%d+)$") or gv:match("^h(%d+)g%d$") or "") or 285
end
function dbg.rim_glow(a, on, secs)
    local go = a.character:get_GameObject()
    local mgr = go:call("getComponent(System.Type)", sdk.typeof("app.MaterialInterpolationRequestManager"))
    if not mgr then return end
    if on then
        mgr:call(RIM_REQ, sm.RIM.mode, sm.RIM.cat, -1, -1)
        sm.rimOn, sm.rimOffAt = true, os.clock() + (secs or sm.RIM.secs)   -- (a pulse: off again by itself)
        -- its colour slots in my meshes (looked up anew each time: equipment changes)
        sm.rimEntries = {}
        for _, mesh in ipairs(dbg.ai.meshes(go)) do
            pcall(function()
                for m = 0, mesh:call("get_MaterialNum") - 1 do
                    for _, nm in ipairs({ "RimLight_Emissive_Color_A", "RimLight_Emissive_Color_B" }) do
                        pcall(function()
                            local v = mesh:call("getMaterialVariableIndex", m, nameHash:call(nil, nm))
                            if v == nil or v >= 65535 then return end
                            mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", m, v)   -- (3.07: only slots that read)
                            sm.rimEntries[#sm.rimEntries + 1] = { mesh = mesh:add_ref(), m = m, v = v }
                        end)
                    end
                end
            end)
        end
    elseif sm.rimOn then
        mgr:call(RIM_FIN, sm.RIM.mode, sm.RIM.cat, -1, -1)
        sm.rimOn = false
    end
end
-- my rim-light colour slots (equipment changes: looked up anew each time) and their colour turned to a hue
function dbg.rim_entries(go)
    local out = {}
    for _, mesh in ipairs(dbg.ai.meshes(go)) do
        pcall(function()
            for m = 0, mesh:call("get_MaterialNum") - 1 do
                for _, nm in ipairs({ "RimLight_Emissive_Color_A", "RimLight_Emissive_Color_B" }) do
                    pcall(function()
                        local v = mesh:call("getMaterialVariableIndex", m, nameHash:call(nil, nm))
                        if v == nil or v >= 65535 then return end
                        mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", m, v)   -- (3.07: only slots that read)
                        out[#out + 1] = { mesh = mesh:add_ref(), m = m, v = v }
                    end)
                end
            end
        end)
    end
    return out
end
function dbg.rim_paint(entries, hue)
    for i = #entries, 1, -1 do   -- (a slot that fails is dropped, never read again)
        local e = entries[i]
        local ok = pcall(function()
            local f = e.mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", e.m, e.v)
            local h, s0, v = dbg.ai.hsv(f.x, f.y, f.z)
            if v <= 0.001 or s0 < 0.2 or (h > 250 and h < 330) then return end   -- (dark / white / already ours)
            local r, g, b = dbg.ai.rgb(hue, s0, v)
            e.mesh:call("setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)", e.m, e.v, Vector4f.new(r, g, b, f.w))
        end)
        if not ok then table.remove(entries, i) end
    end
end
re.on_pre_application_entry("BeginRendering", function()
    if sm.rimOffAt and os.clock() >= sm.rimOffAt then
        sm.rimOffAt = nil
        local a = runtime.player()
        if a then pcall(dbg.rim_glow, a, false) end
    end
    if not sm.rimOn or not sm.rimEntries then return end
    local hue = (PB.activeVocation == "stormblade") and 205 or pick_hue()
    for i = #sm.rimEntries, 1, -1 do   -- the game's teal, turned to our hue (its own strength kept)
        local e = sm.rimEntries[i]
        local ok = pcall(function()
            local f = e.mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", e.m, e.v)
            local h, s0, v = dbg.ai.hsv(f.x, f.y, f.z)
            if v <= 0.001 then return end
            local r, g, b = dbg.ai.rgb(hue, s0, v)
            e.mesh:call("setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)", e.m, e.v, Vector4f.new(r, g, b, f.w))
        end)
        if not ok then table.remove(sm.rimEntries, i) end
    end
end)
-- our own sounds (x0005-PactbladeSounds.pak): loaded into my sound container once per character
-- (2.66 diagnosis: our banks load fine; through a container list nothing joins my container, but our trigger list loaded
-- DIRECTLY does: lists 40 -> 41 - and the sounds played. So both lists are loaded directly.)
sm.SND = { lists = { { "soundlib.SoundBankListData", "Sound/Resource/pactblade/pactblade_fx_BankListData.user", load = true },
                     { "soundlib.SoundTriggerInfoListData", "Sound/Resource/pactblade/pactblade_fx_TriggerInfoListData.user", load = true } },
           charge = 199459528, hit = 3434957627 }
local function my_container(a)
    for _, c in ipairs(a.character:get_GameObject():call("get_Components"):get_elements()) do
        if c:get_type_definition():get_full_name() == "app.WwiseContainerApp" then return c end
    end
end
sm.my_container = my_container   -- (the menu's diagnosis uses it)
function sm.load_sounds(a)
    local go = a.character:get_GameObject()
    local c = my_container(a)
    -- loaded = our charge trigger really is in my container (the game rebuilds it, e.g. when a save loads - 2.70)
    if c and dbg.snd_find_info and dbg.snd_find_info(c, sm.SND.charge) then sm.soundsFor = go:get_address(); return end
    if not c then sm.sndInfo = "no sound container (?)"; return end
    sm.sets = sm.sets or {}
    local got = {}
    for _, l in ipairs(sm.SND.lists) do
        if not sm.sets[l[2]] then
            local ud = sdk.create_userdata(l[1], l[2])
            if ud then sm.sets[l[2]] = ud:add_ref() end
        end
        if sm.sets[l[2]] then
            if l.load then
                -- (still in its list of sets after the game rebuilt the container -> the load would be skipped)
                pcall(function() c._UserDataList:call("Remove", sm.sets[l[2]]) end)
                c:call("loadContainableUserData", sm.sets[l[2]])
            end
            got[#got + 1] = l[2]:match("([^/]+)$")
        end
    end
    local inIt = dbg.snd_find_info and dbg.snd_find_info(c, sm.SND.charge) ~= nil
    if inIt then sm.soundsFor = go:get_address() end
    sm.loadInfo = #got < #sm.SND.lists and "our sound files were NOT found"
        or (inIt and "our sounds are in my sound container" or "loaded, but our sounds did not join my container (retried every 5 s)")
end
-- loaded early (once Pactblade is on), so the first smite already has them (the first play after loading can be silent)
re.on_frame(function()   -- (checked every 5 s: back in if the game threw them out)
    if not live.on or os.clock() < (sm.nextLoadTry or 0) then return end
    sm.nextLoadTry = os.clock() + 5
    local a = runtime.player()
    if a then pcall(sm.load_sounds, a) end
end)
function sm.sound(a, id, what)
    pcall(sm.load_sounds, a)
    local c = my_container(a)
    local info = c and dbg.snd_find_info and dbg.snd_find_info(c, id)
    if not info then
        local lists, ours = -1, false
        pcall(function()
            local L = c["<AllTriggerInfoListData>k__BackingField"]
            lists = L._size
        end)
        sm.sndInfo = ("%s sound: not in my container yet (%s; %d trigger lists in it)"):format(what, tostring(sm.loadInfo), lists)
        return
    end
    local ok, r = pcall(dbg.snd_request, c, info, a.character:get_GameObject())
    sm.sndInfo = what .. " sound: " .. tostring(ok and r or r)
end
-- the blade's light: our point light on the held sword (switched on / off, never destroyed while the script runs)
function sm.light(on)
    if not on then
        if sm.L then pcall(function() sm.L.comp:call("set_Enabled", false) end) end
        return
    end
    if not sm.L then
        local go = make_anchor()
        go:set_Name("Pactblade_smite_light")
        local comp = go:call("createComponent(System.Type)", sdk.typeof("via.render.PointLight"))
        if not comp then return end
        sm.L = { go = go, comp = comp:add_ref() }
        pcall(function() sm.L.comp:call("set_ShadowEnable", false) end)
    end
    pcall(function()
        local _, sgo = held_sword()
        if sgo then sm.L.go:get_Transform():set_Position(sgo:get_Transform():get_Position()) end
        local r, g, b = dbg.nox_look()
        local mx = math.max(r, g, b, 1)
        sm.L.comp:call("set_Color", Vector3f.new(r / mx, g / mx, b / mx))
        sm.L.comp:call("set_Intensity", sm.lightLm + 0.0)
        sm.L.comp:call("set_Radius", sm.lightRadius + 0.0)
        sm.L.comp:call("set_Enabled", true)
    end)
end
re.on_script_reset(function() if sm.L then local o = sm.L.go; pcall(function() o:call("destroy(via.GameObject)", o) end) end end)
-- the saved settings (cfg.smite) <-> sm / NOX
sm.KEYS = { "fast", "blend", "boomScale", "boomFx", "lightOn", "lightUntil", "lightLm", "lightRadius", "chargeDelay" }
for _, k in ipairs(sm.KEYS) do if cfg.smite and cfg.smite[k] ~= nil then sm[k] = cfg.smite[k] end end
if cfg.smite and type(cfg.smite.boostGlow) == "number" then dbg.NOX.boostGlow = cfg.smite.boostGlow end
if cfg.smite and not cfg.smite.cdSooner then sm.chargeDelay = -0.2; cfg.smite.cdSooner = true end   -- (once: user, sooner)
if not (cfg.smite and cfg.smite.userSet) then   -- once: the user's screenshot values (2.59 may have saved the old defaults)
    sm.fast, sm.blend, sm.boomScale, sm.boomFx = 1.5, 12, 1.5, "-1/8/43"
    sm.lightOn, sm.lightUntil, sm.lightLm, sm.lightRadius = true, 132, 562, 3.0
    dbg.NOX.boostGlow = 2.5
    cfg.smite = cfg.smite or {}
    cfg.smite.userSet = true
    pcall(function() for _, k in ipairs(sm.KEYS) do cfg.smite[k] = sm[k] end; cfg.smite.boostGlow = 2.5; save_cfg() end)
end
function sm.save()
    cfg.smite = cfg.smite or {}
    for _, k in ipairs(sm.KEYS) do cfg.smite[k] = sm[k] end
    cfg.smite.boostGlow = dbg.NOX.boostGlow
    save_cfg()
end
-- Mystic Spearhand's charge-complete body effect (ch07 ns 25/50) on the player, its "Charge" colour in the picker's hue
local function pick_rgb()
    local gv = tostring(cfg.glowVariant or "")
    local hue = tonumber(gv:match("^ppb?(%d+)$") or gv:match("^h(%d+)g%d$") or "") or 285
    local h = (hue % 360) / 60
    local x = 1 - math.abs(h % 2 - 1)
    local t = ({ { 1, x, 0 }, { x, 1, 0 }, { 0, 1, x }, { 0, x, 1 }, { x, 0, 1 }, { 1, 0, x } })[math.floor(h) + 1]
    return t[1], t[2], t[3]
end
sm.chargeFx = {}   -- { c, untilT }
function dbg.charge_fx(a)
    local mgr = a.character:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    local conts, idx = mgr.ExternalDataContainers, nil
    for i = 0, conts:get_Count() - 1 do
        local ok, path = pcall(function() return tostring(conts[i].DataContainer:get_Path()) end)
        if ok and path:lower():find("ch07/13_ch07_ns", 1, true) then idx = i end
    end
    if not idx then sm.info = "Mystic Spearhand's effects are not on this character"; return end
    local id = sdk.create_instance("via.effect.script.EffectID")
    id.DataContainerIndex = idx; id.ContainerID = 25; id.ElementID = 50
    id.IsContainerIDOnly = false; id.IsElementIDOnly = false
    local c = mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
        id, a.character:get_GameObject(), -1, nil)
    if c then table.insert(sm.chargeFx, { c = c:add_ref(), untilT = os.clock() + 4 }) end
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if #sm.chargeFx == 0 then return end
    local r, g, b = pick_rgb()
    local col
    for k = #sm.chargeFx, 1, -1 do
        local e = sm.chargeFx[k]
        local done = os.clock() > e.untilT
        pcall(function() if e.c:call("get_isFinished") then done = true end end)
        if done then table.remove(sm.chargeFx, k)
        else
            pcall(function()
                col = col or via_colour({ r, g, b, 1 })
                local list = e.c:call("getAllPlayers")
                for q = 0, (list and list:call("get_Count") or 0) - 1 do
                    local pl = list:call("get_Item", q)
                    local ex = pl:getExternParameter("Charge")
                    if ex then ex:set_Color(col); sm.chargeColoured = true end
                end
            end)
        end
    end
end)
-- the big explosion where the strike landed (asked from the damage hook, made on the next late update)
function sm.on_hit(info)
    if sm.stage ~= 2 or sm.boomed then return end
    -- (any hit counts - an enemy, a crate, a barrel; the slam into bare ground is no hit, so nothing plays then: user)
    sm.boomed = true
    sm.hitFrame = sm.frame
    sm.refundAt = os.clock() + 0.3   -- (4.02 user: a hit gives 20 % of max stamina back - after the Arc's full drain)
    local v = info["<DamageGameObject>k__BackingField"]
    local p = v:get_Transform():get_Position()
    sm.boomAt = Vector3f.new(p.x, p.y + 1.0, p.z)
end
dbg.smite_hit = function(info) pcall(sm.on_hit, info) end
sm.refund = 0.20
re.on_pre_application_entry("LateUpdateBehavior", function()
    if not sm.refundAt or os.clock() < sm.refundAt then return end
    sm.refundAt = nil
    pcall(function()
        local smg = runtime.player().character:get_StaminaManager()
        local amt = smg:get_MaxValue() * sm.refund
        local before = smg:get_RemainingAmount()
        smg:add(amt, true)   -- (as DragonCore's consume_stamina, with + instead of -)
        note(("Eldritch Smite hit: +%.0f stamina (%.0f -> %.0f)"):format(amt, before, smg:get_RemainingAmount()))
    end)
end)
re.on_application_entry("LateUpdateBehavior", function()
    if not sm.boomAt then return end
    local at = sm.boomAt
    sm.boomAt = nil
    local ok, e = pcall(function()
        local a = runtime.player()
        local rot = a.character:get_GameObject():get_Transform():get_Rotation()
        pcall(sm.sound, a, sm.SND.hit, "hit")   -- (user's own explosion sound)
        if parts.play_ours(sm.boomFx, at, rot) then
            local o = parts.ours[#parts.ours]
            o.go:get_Transform():set_LocalScale(Vector3f.new(sm.boomScale, sm.boomScale, sm.boomScale))
        end
    end)
    sm.info = ok and "hit: explosion" or ("explosion failed: " .. tostring(e))
end)
local function finish(a, why)
    pcall(dbg.nox_boost, false)
    if a then pcall(dbg.rim_glow, a, false) end
    pcall(sm.light, false)
    if a then pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.0) end) end
    sm.stage, sm.fastOn = nil, false
    sm.info = why
    note("Eldritch Smite: " .. tostring(why))
end
local function stage(a, k)
    sm.stage, sm.asked, sm.started, sm.framed, sm.fastOn = k, os.clock(), nil, false, false
    if k == 1 then sm.boomed, sm.looked, sm.lookEndAt, sm.chargeAt, sm.chargeSet = false, false, nil, nil, false; pcall(sm.load_sounds, a) end
    if k == 2 then
        dbg.stamSwap = { mul = sm.drainMul or 0.5, untilT = os.clock() + 1.5, what = "Eldritch Smite (half the Arc's drain)" }   -- (1.1 user)
        if not dbg.NOX.boosted then pcall(dbg.nox_boost, true) end   -- (on since 0.3 s into part 1)
        pcall(dbg.rim_glow, a, true)   -- (user: Mystic Spearhand's whole-body charge look, our colour)
    end
    pcall(function() sm.prevMot = mkey(a.character.FullBodyLayer) end)
    pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.0) end)
    request(a, sm.PARTS[k].action)
end
local function update(a)
    local now = os.clock()
    if sm.bufferUntil then
        if now > sm.bufferUntil or a:is_staggered() then
            sm.bufferUntil = nil
        elseif a:weapon_drawn() then
            sm.bufferUntil = nil
            local can = false
            pcall(function()
                local track = a.character:get_Human().Track
                can = track.All or track.Skill
            end)
            if can and not sm.stage then
                sm.want = true
                note("Eldritch Smite: weapon drawn - executing buffered skill")
            end
        end
    end
    if sm.want then
        sm.want = false
        if not sm.stage then stage(a, 1); sm.info = "smiting" end
    end
    if not sm.stage then return end
    local part = sm.PARTS[sm.stage]
    local cur = a:current_action(0)
    if not sm.started then
        if cur == part.action then sm.started = now
        elseif now - sm.asked > 0.4 then return finish(a, part.action .. " did not start (now " .. tostring(cur) .. ")")
        else request(a, part.action); return end
    end
    if cur ~= part.action then return finish(a, "interrupted by " .. tostring(cur)) end
    if sm.stage == 1 and not sm.looked and now - sm.started >= sm.lookAfter then   -- the smite look from 0.3 s
        sm.looked = true
        pcall(dbg.nox_boost, true)
    end
    if sm.stage == 1 and not sm.chargeSet then   -- the charge sound: from the look's start, + / - the delay
        sm.chargeSet = true
        sm.chargeAt = sm.started + sm.lookAfter + math.max(-sm.lookAfter, sm.chargeDelay)
    end
    if sm.chargeAt and now >= sm.chargeAt then
        sm.chargeAt = nil
        pcall(sm.sound, a, sm.SND.charge, "charge")   -- (user's own charge sound)
    end
    pcall(sm.light, sm.lightOn and dbg.NOX.boosted)   -- the blade lights the area as long as the look is on
    local L = a.character.FullBodyLayer
    if mkey(L) == sm.prevMot and now - sm.started < 0.25 then return end   -- not on the new animation yet
    local fr = L:call("get_Frame")
    if not sm.framed then
        sm.framed = true
        if part.from > 0 and fr < part.from then   -- crossfade into the start frame (no jump)
            local ok = pcall(L.call, L, CHANGE, L:call("get_MotionBankID"), L:call("get_MotionID"), part.from, sm.blend, 1, 1)
            if not ok then L:call("set_Frame", part.from) end
            return
        end
    end
    if sm.stage == 2 then
        sm.frame = fr
        if fr >= sm.lookUntil and dbg.NOX.boosted and not sm.lookEndAt then sm.lookEndAt = now + sm.lookExtra end
        if sm.lookEndAt and now >= sm.lookEndAt and dbg.NOX.boosted then pcall(dbg.nox_boost, false); pcall(sm.light, false) end
    end
    if part.fastFrom and fr >= part.fastFrom and not sm.fastOn then   -- (user: only 270 - 347 faster)
        sm.fastOn = true
        L:call("set_Speed", sm.fast)
    end
    if fr >= part.to then
        if sm.PARTS[sm.stage + 1] then return stage(a, sm.stage + 1) end
        pcall(function() L:call("set_Speed", 1.0) end)
        request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion")
        return finish(a, "done")
    end
end
re.on_pre_application_entry("UpdateBehavior", function()
    if not sm.stage and not sm.want and not sm.bufferUntil then return end
    local a = runtime.player()
    if not a or not a:valid() or not live.on then sm.want = false; if sm.stage then finish(a, "Pactblade off") end; return end
    local ok, err = pcall(update, a)
    if not ok then finish(a, "error: " .. tostring(err)) end
end)
re.on_script_reset(function() if sm.stage then pcall(function() runtime.player().character.FullBodyLayer:call("set_Speed", 1.0) end) end end)
function sm.press()
    local now = os.clock()
    if sm.stage or sm.want or now - sm.lastPress < 0.6 or combo.stage ~= 0 or castT.t0 then return end
    local a = runtime.player()
    if not a or not a:valid() then return end
    if not a:weapon_drawn() then
        dbg.ensure_drawn(a)
        sm.bufferUntil = now + 1.2
        sm.lastPress = now
        note("Eldritch Smite: weapon sheathed - unsheathe triggered")
        return
    end
    local can = false
    pcall(function()
        local track = a.character:get_Human().Track
        can = track.All or track.Skill
    end)
    if not can then return end
    if dbg.slots and not dbg.slots.use() then dbg.slots.deny(); note("Eldritch Smite: no spell slot free"); return end   -- (1.1)
    sm.lastPress, sm.want = now, true
end
-- the press of the bound skill (or, while binding, whichever skill is pressed next becomes the slot)
pcall(function()
    local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
    sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
        if not live.on or not dbg.press_ok() then return end
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if sm.binding then
            sm.binding = false
            if NAMES[id] then cfg.smiteSkill = NAMES[id]; save_cfg(); sm.info = "now in " .. NAMES[id] .. "'s slot" end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        if id ~= IDS[cfg.smiteSkill] then return end
        sm.press()
        return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
    end, function(r) return r end)
end)
-- the vanilla skill started any other way (a queued press ...) becomes the smite too - not the combo's own requests
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if not live.on or sm.ourReq or combo.stage ~= 0 or not cfg.smiteSkill or dbg.INTEGRATED then return end
            local skip = false
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                if name:sub(1, #cfg.smiteSkill) ~= cfg.smiteSkill then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                skip = true
                sm.press()
            end)
            if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
end)
end)()

------------------------------------------------------------------------
-- MISTY DIVE (user's skill): warp above the enemy in front, fall into the air Empale (Job01_HeavyAttackAir)
------------------------------------------------------------------------
;(function()
local md = { info = "-", lastPress = -10, above = 1.8, back = 0.0, range = 15, cone = 90,   -- (3.79 user: 15 m)
             ACTION = "Job01_HeavyAttackAir",   -- (user: lower)
             -- (user: the same preparing jump as Mystic Spearhand's skill - recorded: Job07_SkyDive, motions 170/1100 prepare
             -- (with its start effects + sound), 170/1101 = the teleport (sound 2823464530), 170/1102 the landing)
             PREP = "Job07_SkyDive", PREP_BANK = 170, WARP_MOTION = 1101, prepMax = 0.6, warpSound = 2823464530,
             -- (user: use the WHOLE SkyDive - its own targeting + teleport - and only swap the strike after the teleport)
             mode = "ours", afterTeleport = 0.05, lockWarp = true,
             fallSpeed = 7, strikeDepth = 0.3, ownStrike = true, dmg = 1500, react = 300, landGap = 0.5, aimBack = 0.4, headHold = 0.25 }   -- (user: from scratch - SkyDive's targeting finds nothing for a Fighter)
dbg.misty = md
local IDS, NAMES = {}, {}
pcall(function()
    for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            if ok and type(v) == "number" then IDS[f:get_name()] = v & 0xFFFFFFFF; NAMES[v & 0xFFFFFFFF] = f:get_name() end
        end
    end
end)
local function request(a, name)
    md.ourReq = true
    local ok = a:request_action(name, 0)
    md.ourReq = false
    return ok
end
-- alive = HP above 0 (is_alive() turned every enemy down here); unreadable HP counts as alive
function md.alive(ch)
    if not ch then return false end
    local hp
    pcall(function() hp = ch["<Hit>k__BackingField"]:get_Hp() end)
    if type(hp) ~= "number" then pcall(function() hp = ch:get_Hit():get_Hp() end) end
    return type(hp) ~= "number" or hp > 0
end
-- (3.78) on my screen: in front of the camera and inside its view (its vertical field of view, 16:9 width), body height
md.nearAny = 5
function md.on_screen(q)
    local yes = true
    pcall(function()
        local cam = sdk.get_primary_camera()
        local ct = cam:get_GameObject():get_Transform()
        local c, rot = ct:get_Position(), ct:get_Rotation()
        local v = Vector3f.new(q.x - c.x, q.y + 1.0 - c.y, q.z - c.z)
        local fw, rt, up = rot * Vector3f.new(0, 0, -1), rot * Vector3f.new(1, 0, 0), rot * Vector3f.new(0, 1, 0)
        local depth = v.x * fw.x + v.y * fw.y + v.z * fw.z   -- (camera space: forward, right, up)
        local l = { x = v.x * rt.x + v.y * rt.y + v.z * rt.z, y = v.x * up.x + v.y * up.y + v.z * up.z, z = -depth }
        if depth <= 0.1 then yes = false; return end
        local fov = 50
        pcall(function() fov = cam:call("get_FOV") end)
        local tv = math.tan(math.rad(fov) / 2)
        local th = tv * 16 / 9
        yes = math.abs(l.x / -l.z) <= th * 1.05 and math.abs(l.y / -l.z) <= tv * 1.1
    end)
    return yes
end
-- Misty Dive's own pick (camera or facing - user aims with the camera)
function md.pick(a)
    local best, bestD, bestS, why
    pcall(function()
        local tr = a.character:get_GameObject():get_Transform()
        local p = tr:get_Position()
        local dirs = {}
        pcall(function()
            local c = sdk.get_primary_camera():get_GameObject():get_Transform():get_Position()
            local x, z = p.x - c.x, p.z - c.z
            local l = math.sqrt(x * x + z * z)
            if l > 0.05 then dirs[#dirs + 1] = { x / l, z / l } end
        end)
        local f = tr:get_Rotation() * Vector3f.new(0, 0, 1)
        local fl = math.sqrt(f.x * f.x + f.z * f.z)
        if fl > 0.001 then dirs[#dirs + 1] = { f.x / fl, f.z / fl } end
        local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
        local n, nAlive = 0, 0
        for k = 0, list._size - 1 do
            pcall(function()
                local ch = list._items[k]._Chara
                n = n + 1
                if not md.alive(ch) then return end
                nAlive = nAlive + 1
                local q = ch:get_GameObject():get_Transform():get_Position()
                local dx, dz = q.x - p.x, q.z - p.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d > md.range or math.abs(q.y - p.y) > 15 then return end   -- (standing on a Cyclops)
                if d > md.nearAny and not md.on_screen(q) then return end     -- (3.78 user: further than 5 m = on my screen only)
                local ang = 0
                if d > 3 then   -- (close by / on top of it: any direction)
                    ang = 180
                    for _, v in ipairs(dirs) do
                        ang = math.min(ang, math.deg(math.acos(math.max(-1, math.min(1, (dx * v[1] + dz * v[2]) / d)))))
                    end
                end
                if ang > md.cone then return end
                local sc = d * (1 + ang / 90)
                if not bestS or sc < bestS then best, bestD, bestS = ch, d, sc end
            end)
        end
        why = ("%d enemies listed, %d alive"):format(n, nAlive)
    end)
    return best, bestD, why
end
-- why nobody was picked: the nearest enemy and what ruled it out (user: dummies sometimes not targeted)
function md.why(a)
    local out = "no enemies listed"
    pcall(function()
        local tr = a.character:get_GameObject():get_Transform()
        local p = tr:get_Position()
        local f = tr:get_Rotation() * Vector3f.new(0, 0, 1)
        local fl = math.sqrt(f.x * f.x + f.z * f.z)
        local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
        local bestD
        for k = 0, list._size - 1 do
            pcall(function()
                local ch = list._items[k]._Chara
                local q = ch:get_GameObject():get_Transform():get_Position()
                local dx, dz = q.x - p.x, q.z - p.z
                local d = math.sqrt(dx * dx + dz * dz)
                if bestD and d >= bestD then return end
                bestD = d
                local ang = d > 0.01 and fl > 0.001 and math.deg(math.acos(math.max(-1, math.min(1, (dx * f.x + dz * f.z) / (d * fl))))) or 0
                local alive = true
                pcall(function() alive = ch["<Hit>k__BackingField"]:get_Hp() > 0 end)
                out = ("nearest enemy %.1f m, %.0f deg to the side, %.1f m height gap, %s"):format(d, ang, q.y - p.y, alive and "alive" or "not alive")
            end)
        end
    end)
    return out
end
-- the dive itself: where to, the warp (+ SkyDive's teleport sound), the air Empale
-- (3.50) our descent: above the enemy (it may move), never up, down at md.fallSpeed to its head; there the strike
function md.strike(a, F, why)
    md.follow = nil
    local t = F.t
    if not md.hitLanded and md.alive(t) then   -- the Empale's blade didn't hit: our hit
        pcall(function()
            local hm = sdk.get_managed_singleton("app.HitManager")
            local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()
            info.Damage = md.dmg
            info.DamageType, info.DamageActType, info.IsDirectDamageEnableAllDamageType = 7, 7, true   -- Hitback_L
            pcall(function() info.DamageReaction = md.react end)
            local ok = pcall(hm.call, hm, "directDamage", info, t["<Hit>k__BackingField"], a.character:get_GameObject(), false, a.character["<Hit>k__BackingField"])
            if not ok then hm:call("directDamage", info, t["<Hit>k__BackingField"], nil, false, nil) end
        end)
        note(("Misty Dive: strike (%s) - the blade hadn't hit: our hit %.0f"):format(why, md.dmg))
    else note(("Misty Dive: strike (%s) - the Empale's blade hit"):format(why)) end
    pcall(function()   -- down on the ground beside it (never on top of it)
        local tq = t:get_GameObject():get_Transform():get_Position()
        local r = 0.5
        pcall(function() r = t["<CharaController>k__BackingField"]:call("get_Radius") or r end)
        if r >= (md.bigRadius or 1.0) then   -- (1.0 user: like Skydragon - on a big monster you land on its body and stay)
            md.landedAt = nil
            note(("Misty Dive: a big one (radius %.1f m) - left to fall onto its body"):format(r))
            return
        end
        local gap = r + md.landGap
        local tr = a.character:get_GameObject():get_Transform()
        local p = tr:get_Position()
        local ox, oz = p.x - tq.x, p.z - tq.z   -- (where I am, seen from its middle)
        local d = math.sqrt(ox * ox + oz * oz)
        if d < 0.01 then ox, oz, d = F.bx, F.bz, 1 end
        local k = math.max(d, gap) / d        -- (straight down; out of its body only as far as needed)
        local land = Vector3f.new(tq.x + ox * k, tq.y + 0.05, tq.z + oz * k)
        pcall(function()   -- (3.97) the real ground there (stairs / slopes higher than its feet)
            if not combo.nearest_hit then return end
            local g = combo.nearest_hit(Vector3f.new(land.x, land.y + 2.5, land.z), Vector3f.new(land.x, land.y - 3.0, land.z), 0.05)
            if g and (g.y > land.y or land.y - g.y < 1.0) then land = Vector3f.new(land.x, g.y + 0.05, land.z) end
        end)
        tr:set_Position(land)
        a.character["<CharaController>k__BackingField"]:call("warp")
        md.landedAt = { land, os.clock() }
        note(("Misty Dive: landed %.1f m from its middle (moved %.1f m sideways)"):format(math.max(d, gap), math.max(0, gap - d)))
    end)
end
function md.follow_step(a, now)
    local F = md.follow
    if not F then return end
    local tr = a.character:get_GameObject():get_Transform()
    local p = tr:get_Position()
    local tq = F.t:get_GameObject():get_Transform():get_Position()
    local x, z = tq.x + F.ox + F.bx * md.aimBack, tq.z + F.oz + F.bz * md.aimBack   -- (my body a little on my side: the blade is in front of me)
    local dt = math.min(0.1, math.max(0, now - F.tl))
    F.tl = now
    local y = math.min(p.y, F.lastY)                                -- never up
    y = math.max(F.low, math.min(y, F.lastY - md.fallSpeed * dt))   -- and always coming down
    F.lastY = y
    tr:set_Position(Vector3f.new(x, y, z))
    pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
    if md.hitLanded then return md.strike(a, F, "blade hit on the way") end
    if y <= F.low + 0.02 then   -- (3.69: at its head: held there until the blade hits, at most headHold s)
        F.atHead = F.atHead or now
        if now - F.atHead >= md.headHold then return md.strike(a, F, "at its head") end
        return
    end
    if now - F.t0 > 1.5 or not md.alive(F.t) then return md.strike(a, F, "time / target gone") end
end
local function dive(a)
    local tr = a.character:get_GameObject():get_Transform()
    local t, d
    if md.target and md.alive(md.target) then   -- the one picked at the press (on the ground)
        t = md.target
        pcall(function()
            local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
            d = math.sqrt((q.x - p.x) ^ 2 + (q.z - p.z) ^ 2)
        end)
    else
        pcall(function() t, d = md.pick(a) end)
    end
    local dest, rot, dx, dz
    if t then
        dest, rot, dx, dz = combo.dive_spot(a, t, md.above, md.back)
        md.info = ("diving onto an enemy %.1f m away"):format(d or 0)
    else   -- nobody in front: 3 m ahead, up in the air
        local p = tr:get_Position()
        local f = tr:get_Rotation() * Vector3f.new(0, 0, 1)
        local len = math.sqrt(f.x * f.x + f.z * f.z)
        local fx, fz = len > 0.001 and f.x / len or 0, len > 0.001 and f.z / len or 1
        dest, rot, dx, dz = Vector3f.new(p.x + fx * 3, p.y + md.above + 1.5, p.z + fz * 3), tr:get_Rotation(), fx, fz
        md.info = "no enemy in front: dove ahead (" .. md.why(a) .. ")"
    end
    combo.warp_to(a, dest, rot, dx, dz)   -- (its CharaController warp also clears SkyDive's jump speed)
    if combo.cue_sound then pcall(combo.cue_sound, a, md.warpSound) end
    md.stage, md.asked, md.started, md.hold = "dive", os.clock(), nil, { dest = dest, rot = rot, dx = dx, dz = dz, n = 3, always = true }
    md.steppedOff = nil
    md.lockXZ = { dest.x, dest.z, warp = md.lockWarp, top = dest.y + 2, head = t and dest.y - md.above or nil }   -- straight down from there, never up
    md.push = 0
    md.hitLanded, md.follow, md.lastCur = false, nil, nil
    if t and md.ownStrike then   -- (3.50) our own descent onto it
        md.lockXZ = nil
        local tq = t:get_GameObject():get_Transform():get_Position()
        md.follow = { t = t, ox = dest.x - tq.x, oz = dest.z - tq.z, bx = -(dx or 0), bz = -(dz or 1), lastY = dest.y,
                      low = dest.y - md.above - md.strikeDepth, t0 = os.clock(), tl = os.clock(), feet = tq.y }
        local l = math.sqrt(md.follow.bx ^ 2 + md.follow.bz ^ 2)
        if l > 0.001 then md.follow.bx, md.follow.bz = md.follow.bx / l, md.follow.bz / l end
    end
    note("Misty Dive: " .. md.info)
    request(a, md.ACTION)
end
-- first Mystic Spearhand's preparing jump (its own action: its start effects + sound come with it)
local function start(a)
    if not a:weapon_drawn() then
        dbg.ensure_drawn(a)
        md.bufferUntil = os.clock() + 1.2
        return
    end
    if md.fromAir then   -- (already in the air: no preparing jump)
        md.fromAir = false
        md.seenDive = {}
        md.stage, md.prepT, md.prepStarted, md.teleportAt, md.lockXZ = "prep", os.clock(), nil, nil, nil
        md.target = nil
        local t = md.pick(a)
        if t then md.target = t:add_ref() end
        pcall(function()
            local tr = a.character:get_GameObject():get_Transform()
            local f = tr:get_Rotation() * Vector3f.new(0, 0, 1)
            local len = math.sqrt(f.x * f.x + f.z * f.z)
            md.face = len > 0.001 and { f.x / len, f.z / len, tr:get_Rotation() } or nil
        end)
        note("Misty Dive from the air: " .. (t and "straight to the enemy" or "no enemy - straight ahead"))
        dive(a)
        return
    end
    md.seenDive = {}
    md.stage, md.prepT, md.prepStarted, md.teleportAt, md.lockXZ = "prep", os.clock(), nil, nil, nil
    md.target = nil   -- (SkyDive's own targeting finds nothing for a Fighter: our pick, used at its teleport)
    local t, d, why = md.pick(a)
    if t then
        md.target = t:add_ref()
        note(("Misty Dive press: enemy %.1f m away picked"):format(d or 0))
    else
        note("Misty Dive press: nobody picked (" .. tostring(why) .. "; " .. md.why(a) .. ")")
    end
    pcall(function()   -- the way I face at the press: the dive goes that way (user: sometimes it fell backwards)
        local tr = a.character:get_GameObject():get_Transform()
        local f = tr:get_Rotation() * Vector3f.new(0, 0, 1)
        local len = math.sqrt(f.x * f.x + f.z * f.z)
        md.face = len > 0.001 and { f.x / len, f.z / len, tr:get_Rotation() } or nil
    end)
    request(a, md.PREP)
end
local function update(a)
    local now = os.clock()
    if md.bufferUntil then
        if now > md.bufferUntil or a:is_staggered() then
            md.bufferUntil = nil
        elseif a:weapon_drawn() then
            md.bufferUntil = nil
            local can, air = false, false
            pcall(function()
                local track = a.character:get_Human().Track
                can = track.All or track.Skill
            end)
            pcall(function() air = a.character:get_IsGround() == false end)
            if can and not md.stage then
                dbg.stam_cost(a, "Misty Dive", md.stamina or 110)
                md.lastPress, md.want, md.fromAir = now, true, air
                note("Misty Dive: weapon drawn - executing buffered skill")
            end
        end
    end
    if md.want then
        md.want = false
        if not md.stage then local ok, e = pcall(start, a); if not ok then md.info = "failed: " .. tostring(e); md.stage = nil end end
    end
    if not md.stage then return end
    if md.stage == "prep" then   -- until SkyDive reaches its teleport (motion 1101), then our warp + dive
        local cur = tostring(a:current_action(0) or "")
        if cur == md.PREP then md.prepStarted = md.prepStarted or now end
        local teleport = false
        pcall(function()
            local L = a.character.FullBodyLayer
            teleport = L:call("get_MotionBankID") == md.PREP_BANK and L:call("get_MotionID") == md.WARP_MOTION
        end)
        if md.mode == "msp" and md.prepStarted then
            -- SkyDive teleports by itself; a moment after its teleport its strike becomes the air Empale
            if teleport and not md.teleportAt then md.teleportAt = now end
            if md.teleportAt and now - md.teleportAt >= md.afterTeleport then
                -- no leftover speed from SkyDive's jump, and facing the way I faced at the press (held a few frames)
                local tr = a.character:get_GameObject():get_Transform()
                local onTarget = false
                if md.target then   -- above the enemy in front, facing it (SkyDive put us above ourselves)
                    pcall(function()
                        local dest, rot, dx, dz = combo.dive_spot(a, md.target, md.above, md.back)
                        tr:set_Position(dest)
                        tr:set_Rotation(rot)
                        md.face = { dx / math.max(0.001, math.sqrt(dx * dx + dz * dz)), dz / math.max(0.001, math.sqrt(dx * dx + dz * dz)), rot }
                        md.hold = { dest = dest, rot = rot, dx = dx, dz = dz, n = 3, always = true }
                        onTarget = true
                    end)
                end
                pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
                if md.face and not onTarget then
                    tr:set_Rotation(md.face[3])
                    pcall(combo.face, a, md.face[1], md.face[2])
                    md.hold = { dest = tr:get_Position(), rot = md.face[3], dx = md.face[1], dz = md.face[2], n = 4, keepPos = true }
                end
                md.stage, md.asked, md.started, md.teleportAt = "dive", now, nil, nil
                local p0 = tr:get_Position()
                md.lockXZ = { p0.x, p0.z }   -- (user: straight down - no sideways drift with the stick / momentum)
                md.info = onTarget and "SkyDive's teleport, moved above the enemy, the air Empale" or "SkyDive's teleport (no enemy), the air Empale"
                note("Misty Dive: " .. md.info)
                request(a, md.ACTION)
            elseif now - md.prepStarted > 2.0 then md.stage = nil; md.info = "SkyDive never teleported" end
            return
        end
        -- (user: 200 m up - SkyDive's upward push comes in its teleport's first frame, after a warp in that frame:
        -- our warp waits md.afterTeleport too, and the speed is cleared on every hold frame)
        if teleport and not md.teleportAt then md.teleportAt = now end
        local due = md.teleportAt and now - md.teleportAt >= md.afterTeleport
        if due or (md.prepStarted and now - md.prepStarted > md.prepMax) or (not md.prepStarted and now - md.prepT > 0.4) then
            md.teleportAt = nil
            local ok, e = pcall(dive, a)
            if not ok then md.info = "failed: " .. tostring(e); md.stage = nil end
        elseif not md.prepStarted then request(a, md.PREP) end
        return
    end
    if md.follow then pcall(md.follow_step, a, now) end
    if md.lockXZ then   -- straight down: only the height changes until the dive is over
        pcall(function()
            local tr = a.character:get_GameObject():get_Transform()
            local p = tr:get_Position()
            local L = md.lockXZ
            local push = math.sqrt((p.x - L[1]) ^ 2 + (p.z - L[2]) ^ 2)
            md.push = math.max(md.push or 0, push)
            if not L.y0 then L.y0, L.t0 = p.y, now end
            if L.warp and not L.checked and now - L.t0 >= 0.3 then   -- the fall goes on with the controller warp?
                L.checked = true
                if p.y > L.y0 - 0.05 then L.warp = false; note("Misty Dive: the controller lock stopped the fall - dropped") end
            end
            local y = p.y
            if L.top and y > L.top then   -- (user: from under the ground it threw me ~2 km up)
                y = L.top
                if not L.capped then L.capped = true; note("Misty Dive: pushed upward - held at the dive spot's height") end
            end
            if push > 0.001 or y ~= p.y then
                tr:set_Position(Vector3f.new(L[1], y, L[2]))
                if y ~= p.y then pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end) end
                if L.warp then pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end) end
            end
            if now - L.t0 > 3 then md.lockXZ = nil end   -- (never held for long)
            if L.head and y <= L.head + 0.3 then md.lockXZ = nil end   -- at its head: free (no standing on it)
        end)
    end
    local h = md.hold   -- the character controller can put us back for a frame or two after a warp
    if h and h.n > 0 then
        h.n = h.n - 1
        local tr = a.character:get_GameObject():get_Transform()
        if (h.always or not md.started) and not h.keepPos then
            tr:set_Position(h.dest)
            pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)   -- (no speed kept)
        end
        tr:set_Rotation(h.rot)
        pcall(combo.face, a, h.dx, h.dz)
    end
    local cur = tostring(a:current_action(0) or "")
    if not md.started then
        if cur == md.ACTION then md.started = now
        elseif now - md.asked > 0.5 then   -- (never left hanging in the air: the game's fall)
            md.stage, md.lockXZ = nil, nil
            md.info = md.ACTION .. " did not start (now " .. cur .. ") - falling"
            pcall(function() a.character["<CharaController>k__BackingField"]:call("warp") end)
            request(a, "WaitToFall")
        else request(a, md.ACTION) end
        return
    end
    if md.started and not md.steppedOff and now - md.started > 2.5 and cur == md.ACTION then
        md.steppedOff = true   -- (still falling after 2.5 s = standing on something, e.g. the enemy's head)
        pcall(function()
            local tr = a.character:get_GameObject():get_Transform()
            local p = tr:get_Position()
            local bx, bz = -(md.hold and md.hold.dx or 0), -(md.hold and md.hold.dz or 1)
            local l = math.max(0.001, math.sqrt(bx * bx + bz * bz))
            md.lockXZ = nil
            tr:set_Position(Vector3f.new(p.x + bx / l * 1.5, p.y, p.z + bz / l * 1.5))
            a.character["<CharaController>k__BackingField"]:call("warp")
        end)
        note("Misty Dive: still in the air after 2.5 s - stepped off (1.5 m back)")
    end
    if cur ~= md.lastCur then md.lastCur = cur; note("Misty Dive: action " .. cur) end
    if not cur:find("^Job01_HeavyAttackAir") then   -- (its landing is part of it; then it is over)
        md.stage, md.lockXZ, md.follow = nil, nil, nil
        note(("Misty Dive: over (the game pushed me sideways up to %.2f m a frame)"):format(md.push or 0))
    end
end
re.on_pre_application_entry("UpdateBehavior", function()
    if md.stage and not md.armor then   -- (3.75 user: super armour while diving)
        pcall(function() runtime.player():set_super_armor(true) end); md.armor = true
    elseif not md.stage and md.armor then
        pcall(function() runtime.player():set_super_armor(false) end); md.armor = false
    end
    if not md.stage and not md.want and not md.bufferUntil then return end
    local a = runtime.player()
    if not a or not a:valid() or not live.on then md.want, md.stage = false, nil; return end
    local ok, err = pcall(update, a)
    if not ok then md.stage = nil; md.info = "error: " .. tostring(err) end
end)
re.on_pre_application_entry("LateUpdateBehavior", function()   -- (3.51) moved far right after the landing? noted
    local L = md.landedAt
    if not L then return end
    if os.clock() - L[2] > 1.2 then md.landedAt = nil; return end
    pcall(function()
        local a = runtime.player()
        local p = a.character:get_GameObject():get_Transform():get_Position()
        local d = math.sqrt((p.x - L[1].x) ^ 2 + (p.z - L[1].z) ^ 2)
        if d > 1.0 and not L.noted then
            L.noted = true
            note(("Misty Dive: %.1f m away from the landing spot %.2f s later (action %s)"):format(d, os.clock() - L[2], tostring(a:current_action(0))))
        end
    end)
end)
re.on_application_entry("LateUpdateBehavior", function()   -- (the lock again after the game moved us this frame)
    if md.follow then
        pcall(function()
            local F = md.follow
            local tr = runtime.player().character:get_GameObject():get_Transform()
            local p = tr:get_Position()
            local tq = F.t:get_GameObject():get_Transform():get_Position()
            tr:set_Position(Vector3f.new(tq.x + F.ox + F.bx * md.aimBack, math.min(p.y, F.lastY), tq.z + F.oz + F.bz * md.aimBack))
        end)
        return
    end
    if not md.lockXZ then return end
    pcall(function()
        local tr = runtime.player().character:get_GameObject():get_Transform()
        local p = tr:get_Position()
        tr:set_Position(Vector3f.new(md.lockXZ[1], md.lockXZ.top and math.min(p.y, md.lockXZ.top) or p.y, md.lockXZ[2]))
        if md.lockXZ.warp then pcall(function() runtime.player().character["<CharaController>k__BackingField"]:call("warp") end) end
    end)
end)
md.FX = { ["14/7/10"] = "sd10", ["14/7/11"] = "sd11", ["14/7/20"] = "sd20", ["14/7/21"] = "sd21", ["13/0/10"] = "sdns10", ["0/15/0"] = "sdex" }   -- (2.95: as a Fighter SkyDive plays 14/7/10 + 14/7/11)   -- SkyDive's teal on me (0/15/0 = the skill-start flash ch00/atk/13_ch00_EX_000_00, inverted layers: baked with the opposite hue)
md.fxOn, md.fxs, md.res = true, {}, {}
function md.hue()   -- the colour picked under Look (285 / 300 / 315); nil = the game's colours
    local p40 = part_cfg("-1/8/40")
    local h = p40.mode == "ours" and tonumber(tostring(p40.variant or ""):match("^e(%d+)$") or "")
    return (h == 285 or h == 300 or h == 315) and h or nil
end
function md.busy() return md.stage ~= nil or md.want or (dbg.blink and dbg.blink.stage == "prep") or os.clock() - (md.lastBusy or -10) < 1.5 end   -- (3.86: Blink Strike's preparing jump is recoloured too)
function dbg.md_seen(args, how)   -- (diagnosis 2.94; off unless md.logFx)
    if not md.logFx or not md.busy() then return end
    local go = sdk.to_managed_object(args[2]):call("get_GameObject")
    if go:get_address() ~= live.go then return end
    local idd = effect_id_of(args, how)
    md.seenDive = md.seenDive or {}
    local key = tostring(idd) .. " " .. how
    if md.seenDive[key] then return end
    md.seenDive[key] = true
    note(("Misty Dive fx: %s via %s%s"):format(tostring(idd), how, md.FX[idd] and " (ours replaces it)" or ""))
end
-- the teal material colours on these meshes: { "<object> / <material> / <variable> hue h" ... }
function md.teal_of(go, label, out, dump)
    for _, mesh in ipairs(dbg.ai.meshes(go)) do
        pcall(function()
            local gname = tostring(mesh:get_GameObject():get_Name())
            for i = 0, mesh:call("get_MaterialNum") - 1 do
                local mname = tostring(mesh:call("getMaterialName", i))
                for v = 0, mesh:call("getMaterialVariableNum", i) - 1 do
                    pcall(function()
                        local name = tostring(mesh:call("getMaterialVariableName", i, v))
                        local f = mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", i, v)
                        local h, s0, mx = dbg.ai.hsv(f.x, f.y, f.z)
                        if s0 > 0.35 and mx > 0.02 and h >= 150 and h <= 230 then
                            out[name] = (out[name] or 0) + 1
                            dump[#dump + 1] = { who = label, go = gname, material = mname, var = name, value = { f.x, f.y, f.z, f.w } }
                        end
                    end)
                end
            end
        end)
    end
end
function md.teal_dump()
    local dump = {}
    for _, who in ipairs({ "me", "clone" }) do
        local out = {}
        pcall(function()
            local go
            if who == "me" then go = runtime.player().character:get_GameObject()
            else
                local inst = dbg.ai.handler(runtime.player()):call("get_Instance")
                go = inst and inst:get_GameObject()
            end
            if go then md.teal_of(go, who, out, dump) end
        end)
        local names = {}
        for k, n in pairs(out) do names[#names + 1] = k .. " x" .. n end
        table.sort(names)
        note(("Misty Dive teal on %s: %s"):format(who, #names > 0 and table.concat(names, ", ") or "none"))
    end
    pcall(json.dump_file, "Pactblade_misty_teal.json", dump)
end
function dbg.md_fx(args, idd)
    if not md.fxOn or not md.FX[idd] or not md.busy() then return false end
    local hue = md.hue()
    if not hue then return false end
    local go = sdk.to_managed_object(args[2]):call("get_GameObject")
    if go:get_address() ~= live.go then return false end
    return ("vfx/effects/pactblade/pb_%s_h%d.efx"):format(md.FX[idd], hue)
end
function dbg.md_fx_play(rv, path)
    local c = sdk.to_managed_object(rv)
    if not c then return end
    if not md.res[path] then
        local r = sdk.create_resource("via.effect.EffectResource", path)
        if not r then
            c = nil
            if not md.fxMissing then md.fxMissing = true; note("Misty Dive: our effect copy not found (" .. path .. ") - restart the game for the pak") end
            return
        end
        md.res[path] = r:add_ref()
    end
    local ptr = runtime.player().character:get_GameObject():get_Transform()
    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_md_fx", 0)
    go = go:add_ref()
    go:call(".ctor")
    go:set_Name("Pactblade_md_fx")
    local tr = go:get_Transform()
    tr:set_Position(ptr:get_Position())
    tr:set_Rotation(ptr:get_Rotation())
    local holder = md.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref()
    local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
    ep:call("set_Resource", holder)
    pcall(function() ep:call("set_AutoStart", true) end)
    pcall(function()   -- which parts the game switches on (emitters / groups) - NOT its colour / group parameters:
        -- those carry the game's teal, copied only when its player was ready that frame (user: randomly teal again)
        local list = c:call("getAllPlayers")
        local src = list and list:call("get_Count") > 0 and list:call("get_Item", 0)
        if not src then return end
        pcall(function() ep:call("set_EmitMaskBit", src:call("get_EmitMaskBit")) end)
        pcall(function() local m = src:call("get_MaskName"); if m and tostring(m) ~= "" then ep:call("set_MaskName", m) end end)
        pcall(function() ep:call("set_GroupEnabled", src:call("get_GroupEnabled")) end)
        pcall(function()
            local n = src:call("getGroupNamesCount")
            if not n or n == 0 then return end
            ep:call("setGroupNamesCount", n)
            for q = 0, n - 1 do ep:call("setGroupNames", q, src:call("getGroupNames", q)) end
        end)
    end)
    c:call("killAll")
    note("Misty Dive: our copy plays (" .. path:match("([^/]+)$") .. ")")
    md.fxs[#md.fxs + 1] = { go = go, ep = ep, untilT = os.clock() + 4 }
    md.fxN = (md.fxN or 0) + 1
end
re.on_pre_application_entry("LateUpdateBehavior", function()
    if md.stage then md.lastBusy = os.clock() end
    if #md.fxs > 0 then   -- our copies go with me; gone after 4 s
        local now = os.clock()
        local ptr
        pcall(function() ptr = runtime.player().character:get_GameObject():get_Transform() end)
        for i = #md.fxs, 1, -1 do
            local o = md.fxs[i]
            if now > o.untilT or not ptr then
                pcall(function() o.go:call("destroy(via.GameObject)", o.go) end)
                table.remove(md.fxs, i)
            else
                pcall(function()
                    local tr = o.go:get_Transform()
                    tr:set_Position(ptr:get_Position())
                    tr:set_Rotation(ptr:get_Rotation())
                end)
            end
        end
    end
end)
re.on_pre_application_entry("BeginRendering", function()   -- my body glow (SkyDive's rim light) in our colour
    if md.tealAt and os.clock() >= md.tealAt then md.tealAt = nil; pcall(md.teal_dump) end
    if not md.fxOn or not md.busy() or not dbg.rim_paint then md.rim = nil; return end
    local hue = md.hue()
    if not hue then return end
    if not md.rim then
        pcall(function() md.rim = dbg.rim_entries(runtime.player().character:get_GameObject()) end)
        md.rim = md.rim or {}
    end
    dbg.rim_paint(md.rim, hue)
end)
md.finish = "always"   -- (user: blocking it didn't work - left to the game) the air Empale's execution: "staggered" (staggered + standing only), "always", "never"
md.STAG = { "damage", "stagger", "flinch", "knockback", "stun", "hitback", "shock", "stumble" }
md.DOWN = { "down", "blown", "lie", "lying", "slam", "fall", "crawl", "getup", "standup", "rise", "air", "dead", "die" }
function md.target_state(ch)
    local nm = "?"
    pcall(function() local e = ch:get_ActionManager().CurrentActionList[0]; nm = tostring(e and e.Name or "?") end)
    local l = nm:lower()
    local function any(words) for _, w in ipairs(words) do if l:find(w, 1, true) then return true end end return false end
    return any(md.STAG) and not any(md.DOWN), nm
end
pcall(function()
    sdk.hook(sdk.find_type_definition("app.HumanCatchProcessor"):get_method("processFinishingMove(app.HitController.DamageInfo, app.Character)"),
        function(args)
            local st = thread.get_hook_storage()
            st.mdBlock = nil
            if md.stage ~= "dive" or md.finish == "always" then return end
            local block
            pcall(function()
                local info = sdk.to_managed_object(args[3])
                local hc = info:get_AttackHitController()
                local me = runtime.player().character:get_GameObject()
                if not hc or hc:get_GameObject():get_address() ~= me:get_address() then return end
                local ch = sdk.to_managed_object(args[4])
                local ok, nm = true, "-"
                if md.finish == "never" then ok = false elseif ch then ok, nm = md.target_state(ch) end
                block = not ok
                note(("Misty Dive: execution check - enemy action %s -> %s"):format(nm, ok and "allowed" or "blocked"))
            end)
            if block then st.mdBlock = true; return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r)
            local st = thread.get_hook_storage()
            if st.mdBlock then st.mdBlock = nil; return sdk.to_ptr(0) end   -- (null: no finishing move)
            return r
        end)
    md.finishHook = true
end)
function md.press()
    local now = os.clock()
    if md.stage or md.want or now - md.lastPress < 0.6 or combo.stage ~= 0 or castT.t0 then return end
    local a = runtime.player()
    if not a or not a:valid() then return end
    if not a:weapon_drawn() then
        dbg.ensure_drawn(a)
        md.bufferUntil = now + 1.2
        md.lastPress = now
        note("Misty Dive: weapon sheathed - unsheathe triggered")
        return
    end
    local can, air = false, false
    pcall(function()
        local track = a.character:get_Human().Track
        can = track.All or track.Skill
    end)
    pcall(function() air = a.character:get_IsGround() == false end)
    if air then   -- (user: usable while jumping; 3.65: only from a real jump / fall, never on a rope / hurt)
        local okA, cur = dbg.air_ok(a)
        can = okA
        if not okA then note("Misty Dive: not now (" .. tostring(cur) .. ")") end
    end
    note(("Misty Dive press%s%s"):format(air and " (in the air)" or "", can and "" or " - refused: the game's skill track is closed"))
    if can then dbg.stam_cost(a, "Misty Dive", md.stamina or 110) end
    if can then md.lastPress, md.want, md.fromAir = now, true, air end
end
-- (user: the slot is a shield skill and there is no shield) - the game asks HumanSkillAvailability whether a skill can be
-- used (a shield skill needs a shield); for MY character and Misty Dive's slot the answer is yes while Pactblade is on
for _, mname in ipairs({ "isCustomSkillAvailable(app.HumanCustomSkillID)", "isCustomSkillAvailableWithoutItemCondition(app.HumanCustomSkillID)" }) do
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HumanSkillAvailability"):get_method(mname), function(args)
            local st = thread.get_hook_storage()
            st.mdYes = nil
            if not live.on or not cfg.mistySkill or not dbg.press_ok() then return end
            -- (while binding any skill may come through, so a shield skill can be picked without a shield)
            local sid = sdk.to_int64(args[3]) & 0xFFFFFFFF
            local beamBind = dbg.beam and dbg.beam.binding
            local blinkBind = dbg.blink and dbg.blink.binding
            if not md.binding and not beamBind and not blinkBind and sid ~= IDS[cfg.mistySkill] and sid ~= IDS[cfg.beamSkill or ""]
               and sid ~= IDS[cfg.blinkSkill or ""] then return end
            pcall(function()
                local ch = sdk.to_managed_object(args[2]).Chara
                if ch and ch:get_GameObject():get_address() == live.go then st.mdYes = true end
            end)
        end, function(r)
            local st = thread.get_hook_storage()
            if st.mdYes then st.mdYes = nil; md.allowed = (md.allowed or 0) + 1; return sdk.to_ptr(1) end
            return r
        end)
    end)
end
pcall(function()
    local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
    sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
        if not live.on or not dbg.press_ok() then return end
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if md.binding then
            md.binding = false
            if NAMES[id] then cfg.mistySkill = NAMES[id]; save_cfg(); md.info = "now in " .. NAMES[id] .. "'s slot" end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        if id ~= IDS[cfg.mistySkill] then return end
        md.press()
        return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
    end, function(r) return r end)
end)
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
            if not live.on or md.ourReq or combo.stage ~= 0 or not cfg.mistySkill or dbg.INTEGRATED then return end
            local skip = false
            pcall(function()
                local name = sdk.to_managed_object(args[4]):ToString()
                if name:sub(1, #cfg.mistySkill) ~= cfg.mistySkill then return end
                if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                skip = true
                md.press()
            end)
            if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
end)
end)()

-- the colour of everything recoloured in files (blast launch + explosion, Eldritch Slash wave, warp wisps, arm effect)
local COLOURS = { { 285, "purple" }, { 300, "pink-purple" }, { 315, "pink" }, { false, "the game's colours (no recolour)" } }
local function current_hue()
    local p40 = part_cfg("-1/8/40")
    return p40.mode == "ours" and tonumber(tostring(p40.variant or ""):match("^e(%d+)$") or "") or false
end
local function set_colour(hue)
    for _, id in ipairs({ "-1/8/40", "-1/8/43", "-1/10/1", "-1/10/3", "-1/10/6" }) do
        local pc = part_cfg(id)
        local v = hue and ((id:find("^%-1/10/") and "h" or "e") .. hue) or nil
        pc.mode, pc.variant, pc.follow = hue and "ours" or "whole", v, id == "-1/10/1"
    end
    local lv = tonumber(tostring(cfg.glowVariant or ""):match("g(%d)$") or "") or 2
    cfg.glowVariant = hue and ("h%dg%d"):format(hue, lv) or "dis"   -- the arm without its cloud, game colour
    cfg.blastTint, cfg.armTint = hue and true or false, hue and true or false
    glowState.res = nil; glow_clear(); sleeve_restore(); save_cfg()
end
-- purple look (user): dropdowns, buttons, sliders, section headers
local THEME = { { 7, 0xFF4A1E5C }, { 8, 0xFF6A2C84 }, { 9, 0xFF8A3AAA }, { 21, 0xFF6A2C84 }, { 22, 0xFF8A3AAA },
                { 23, 0xFFA048C8 }, { 24, 0xFF5A2470 }, { 25, 0xFF7A3296 }, { 26, 0xFF9A40BE }, { 19, 0xFFE07AFF },
                { 20, 0xFFF0A0FF }, { 18, 0xFFE07AFF } }   -- FrameBg x3, Button x3, Header x3, SliderGrab x2, CheckMark
local TITLE = 0xFFFFB4F0   -- light purple (ABGR)
local function title(t) imgui.text_colored(t, TITLE) end
-- HEX (user): Examine (Circle) puts Hex on the enemy in front for 15 s: an X of Frost Boon shimmer (Dimension Door's
-- frame effect, in the Nox mist colour) on it, -10 % defence (every hit on it x 1/0.9), killing it gives 15 % HP back.
-- One target: a new Hex takes it off the old one. Also here: the Burst bind's far-side step (dbg.burst_step).
;(function()
    local hex = { secs = 15, defence = 0.10, heal = 0.15, over = 0.6, scale = 1.0, roll = 45, freezeAt = 0.8,
                  copies = 2, col = { 255, 255, 255 }, bright = 2, half = 0.6, side = 0.0, dots = false,   -- (half: 3.12 dots - each line runs ~1.1 m from its anchor along its own up)
                  info = "-", anchors = {},
                  res = nil, behind = 1.8, pts = nil }
    dbg.hex = hex
    local SHIMMER = "vfx/effects/weapon/wp00/009/13_wp00_009_enchant_25.efx"   -- (Dimension Door's door frame)
    local OURS = "vfx/effects/pactblade/pb_hexx_b%d.efx"   -- (our solid pink copies, brightness 1-3)
    local function clear()
        for _, an in ipairs(hex.anchors) do pcall(function() an.go:call("destroy(via.GameObject)", an.go) end) end
        hex.anchors = {}
        hex.target, hex.go = nil, nil
    end
    re.on_script_reset(clear)
    local function anchor()
        local want = OURS:format(hex.bright)
        if hex.resPath ~= want then hex.res, hex.resPath = nil, want end
        if not hex.res then
            local r = sdk.create_resource("via.effect.EffectResource", want)
            if not r then
                if not hex.noOurs then hex.noOurs = true; note("Hex: our pink X file not loaded (restart the game for the pak) - the game's shimmer") end
                r = sdk.create_resource("via.effect.EffectResource", SHIMMER)
            end
            if not r then return nil end
            hex.res = r:add_ref()
        end
        local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_hex", 0)
        go = go:add_ref()
        go:call(".ctor")
        go:set_Name("Pactblade_hex")
        local holder = hex.res:create_holder("via.effect.EffectResourceHolder"):add_ref()
        local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
        ep:call("set_Resource", holder)
        pcall(function() ep:call("set_AutoStart", true) end)
        return { go = go, ep = ep }
    end
    local function hp_of(ch)
        local hp
        pcall(function() hp = ch["<Hit>k__BackingField"]:get_Hp() end)
        return hp
    end
    hex.staminaPct = 0.10   -- (4.07 user)
    function hex.put(a, t)
        if hex.target and t and hex.target:get_address() == t:get_address() and dbg.gclock() < (hex.untilT or 0) then
            if os.clock() - (hex.againNoted or 0) > 1 then hex.againNoted = os.clock(); note("Hex: already hexed - nothing, no cost") end
            return   -- (4.08: no second Hex on the same enemy, no second cost)
        end
        pcall(function()   -- (4.07) the cost: 10 % of my max stamina
            local smg = a.character:get_StaminaManager()
            local b0, cost = smg:get_RemainingAmount(), smg:get_MaxValue() * hex.staminaPct
            smg:call("setRemainingAmount(System.Single)", math.max(0, b0 - cost))
            note(("stamina: Hex paid %.0f (%.0f -> %.0f)"):format(cost, b0, smg:get_RemainingAmount()))
        end)
        if hex.target and hex.target:get_address() ~= t:get_address() then clear() end
        hex.target, hex.go = t:add_ref(), t:get_GameObject():add_ref()
        hex.untilT = dbg.gclock() + hex.secs
        hex.build()
        hex.headAt, hex.placedNote = nil, nil
        hex.info = ("on %s for %.0f s"):format(tostring(t:get_GameObject():get_Name()), hex.secs)
        note("Hex: " .. hex.info .. " (" .. #hex.anchors .. " shimmer points)")
    end
    dbg.hex_put = hex.put
    function hex.build()   -- the two lines (x copies), playing from 0 until hex.freezeAt, then frozen
        for _, an in ipairs(hex.anchors) do pcall(function() an.go:call("destroy(via.GameObject)", an.go) end) end
        hex.anchors = {}
        for i = 1, 2 * hex.copies do
            local an = anchor()
            if an then an.line = i % 2 == 1 and 1 or -1; hex.anchors[#hex.anchors + 1] = an end
        end
        hex.born, hex.frozen = os.clock(), false
    end
    -- the top of the creature: its highest "head" joint (as Misty Dive's spot), every 0.3 s; else feet + 1.7
    local function head_y(q)
        local now = os.clock()
        if hex.headAt and now - hex.headAt < 0.3 and hex.headY then return hex.headY end
        hex.headAt = now
        local y
        pcall(function()
            local joints = hex.go:get_Transform():call("get_Joints")
            for k = 0, joints:call("get_Length") - 1 do
                local j = joints:call("Get", k)
                if tostring(j:call("get_Name")):lower():find("head") then
                    local jp = j:get_Position()
                    if math.abs(jp.x - q.x) < 6 and math.abs(jp.z - q.z) < 6 and jp.y > q.y and jp.y < q.y + 15 and (not y or jp.y > y) then y = jp.y end
                end
            end
        end)
        hex.headY, hex.headFound = y or q.y + 1.7, y ~= nil
        return hex.headY
    end
    -- the X: two diagonals through the enemy's chest, turned to the camera, following it
    re.on_pre_application_entry("LateUpdateBehavior", function()
        if not hex.target then return end
        local now = os.clock()
        local hp = hp_of(hex.target)
        if hp and hp <= 0 then   -- killed while hexed: 15 % HP back
            pcall(function()
                local hc = runtime.player().character["<Hit>k__BackingField"]
                local before = hc:get_Hp()
                local amount = hc:get_OriginalMaxHp() * hex.heal
                hc:call("recoverHp(System.Single, System.Boolean, System.Int32, System.Boolean)", amount, false, 0, false)
                note(("Hex: the target died - HP %.0f -> %.0f (+%.0f)"):format(before, hc:get_Hp(), amount))
            end)
            hex.info = "target killed: HP restored"
            clear()
            return
        end
        if dbg.gclock() > (hex.untilT or 0) or not live.on then hex.info = "ended"; clear(); return end
        pcall(function()
            local tr = hex.go:get_Transform()
            local q = tr:get_Position()
            local hy = head_y(q)
            -- big creatures get a bigger X (user: tiny on the Cyclops): x1 up to 1.8 m tall, at most x4
            local big = math.max(1, math.min(4, (hy - q.y) / 1.8))
            local sc = hex.scale * big
            local c = Vector3f.new(q.x, hy + hex.over * big, q.z)   -- above the head
            if not hex.placedNote then
                hex.placedNote = true
                note(("Hex X: feet %.1f, head %.1f (%s), size x%.1f, centre %.1f m up"):format(q.y, hy, hex.headFound and "head joint" or "no head joint: feet + 1.7", big, c.y - q.y))
            end
            local cam = sdk.get_primary_camera():get_GameObject():get_Transform():get_Position()
            local fx, fz = c.x - cam.x, c.z - cam.z
            local l = math.max(0.001, math.sqrt(fx * fx + fz * fz))
            fx, fz = fx / l, fz / l
            -- facing the camera (yaw), each line rolled +-roll about the view axis
            local yaw = math.atan(-fx, -fz)
            local qy = Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
            local col = via_colour({ hex.col[1] / 255, hex.col[2] / 255, hex.col[3] / 255, 1 })
            if not hex.frozen and now - (hex.born or now) >= hex.freezeAt then   -- the chosen frame: stop there
                hex.frozen = true
                for _, an in ipairs(hex.anchors) do pcall(function() an.ep:call("set_PlaySpeed", 0.0) end) end
            end
            local pts = {}
            hex.pts = { c = c, lines = pts }
            local rx, rz = -fz, fx   -- (right, seen from the camera)
            for _, an in ipairs(hex.anchors) do
                local r = math.rad(hex.roll) * an.line
                local qr = Quaternion.new(math.cos(r / 2), 0, 0, math.sin(r / 2))
                local atr = an.go:get_Transform()
                local q = qy * qr
                local dir = q * Vector3f.new(0, 1, 0)   -- the line's own up
                local off = hex.half * sc
                local sd = hex.side * an.line            -- (the two lines pushed apart / together sideways)
                local at = Vector3f.new(c.x - dir.x * off + rx * sd, c.y - dir.y * off, c.z - dir.z * off + rz * sd)
                atr:set_Position(at)
                atr:set_Rotation(q)
                pts[#pts + 1] = { at, Vector3f.new(at.x + dir.x, at.y + dir.y, at.z + dir.z) }
                atr:set_LocalScale(Vector3f.new(sc, sc, sc))
                pcall(function() an.ep:set_Color(col) end)
            end
        end)
    end)
    -- -10 % defence: every hit on the hexed enemy (mine go through the damage hook above; others here)
    function dbg.hex_mul(info)
        if not hex.go then return 1 end
        local v = info["<DamageGameObject>k__BackingField"]
        if v and v:get_address() == hex.go:get_address() then return 1 / (1 - hex.defence) end
        return 1
    end
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageValue(app.HitController.DamageInfo)"),
            function(args)
                local st = thread.get_hook_storage()
                st.hexInfo = nil
                if not hex.go then return end
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    local owner = info["<AttackOwnerObject>k__BackingField"]
                    if owner and owner:get_address() == live.go then return end   -- (mine: the hook above)
                    local v = info["<DamageGameObject>k__BackingField"]
                    if v and v:get_address() == hex.go:get_address() then st.hexInfo = info end
                end)
            end, function(r)
                local st = thread.get_hook_storage()
                local info = st.hexInfo
                st.hexInfo = nil
                if info then pcall(function() info.Damage = info.Damage / (1 - hex.defence) end) end
                return r
            end)
    end)
    re.on_frame(function()   -- debug dots for placing the X
        if not hex.dots or not hex.target or not hex.pts then return end
        pcall(function()
            local function dot(v, col, r)
                local sp = draw.world_to_screen(v)
                if sp then draw.filled_circle(sp.x, sp.y, r, col, 12) end
            end
            dot(hex.pts.c, 0xFF00FF00, 7)
            for _, l in ipairs(hex.pts.lines) do dot(l[1], 0xFF0000FF, 6); dot(l[2], 0xFFFF8000, 5) end
        end)
    end)
    pcall(function()   -- no jump right after the Burst step (the same Jump press)
        sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
            function(args)
                if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
                if os.clock() > (dbg.noJumpUntil or 0) then return end
                local skip = false
                pcall(function()
                    local name = sdk.to_managed_object(args[4]):ToString()
                    if not name:find("Jump") then return end
                    if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                    skip = true
                    note("Burst step: jump refused (" .. name .. ")")
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
    end)
    re.on_pre_application_entry("UpdateBehavior", function()   -- the Burst step, at the same point as the combo's warps
        local w = dbg.burstWant
        if not w then return end
        dbg.burstWant = nil
        if os.clock() - w.t > 0.5 then return end
        local a = runtime.player()
        if not a or not a:valid() then return end
        dbg.noJumpUntil = os.clock() + 0.4
        local ok, e = pcall(dbg.burst_step, a, w.target, w.mb)
        note(ok and "Misty Step (Burst): to the far side of the enemy" or ("Burst step failed: " .. tostring(e)))
        pcall(function()   -- the same Jump press may have started a jump: no jump after the step
            local cur = tostring(a:current_action(0) or "")
            if cur:find("Jump") then a:request_action("NormalLocomotion", 0); note("Burst step: jump " .. cur .. " stopped") end
        end)
    end)
    -- the Burst bind's step: to the far side of the bound enemy, facing it (combo's warp: wisps, afterimage, sounds)
    function dbg.burst_step(a, target, mb)
        local tr = a.character:get_GameObject():get_Transform()
        local p = tr:get_Position()
        local q = target:get_GameObject():get_Transform():get_Position()
        local dx, dz = q.x - p.x, q.z - p.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.01 then dx, dz, l = 0, 1, 1 end
        dx, dz = dx / l, dz / l
        local back = hex.behind
        pcall(function() local r = target["<CharaController>k__BackingField"]:call("get_Radius"); if r and r + 1.0 > back then back = r + 1.0 end end)
        local dest = Vector3f.new(q.x + dx * back, q.y, q.z + dz * back)
        combo.warp_to(a, dest, combo.yaw(-dx, -dz), -dx, -dz)
        unbind(target, mb)
    end
end)()

-- ELDRITCH BLAST (user, 3.21): a beam from the left hand. Riotous Fury's opening (the shield bash: without a shield
-- the left hand is thrust forward); at bm.fireFrame the Golem's laser (our purple copy pb_beam_h<hue>, a 15 m mesh along
-- its own +Z, -5..+10, 3 m wide) grows from the palm to the target in bm.grow s - our own anchor, rotated onto the
-- target and stretched along Z every frame - then the hit (damage + the Golem's hit flash), a short hold and it thins out.
;(function()
    local bm = { info = "-", lastPress = -10, ACTION = "Job01_BravesRaidStart",
                 AIR_ACTION = "Job07_MagicBindComplete", airKill = { ["13/20/56"] = true }, airFire = 0.30, airEnd = 0.9, air = true, airFollow = true, sound = true, soundLead = 0.2, airAnimFx = true, airLaunch = true, airLaunchScale = 0.3,   -- (1.0.1 user: the launch flash at 30 %, like the Bolt)
                 fireFrame = 57, endFrame = 75, grow = 0.10, hold = 0.45, fade = 0.15,
                 width = 0.25, from = 0, to = -5, range = 20,
                 chain = true, mesh = false, spacing = 0.5, chainScale = 0.35, maxCopies = 50,
                 rowLook = 7, followHand = false, launchLen = 1.5, launchSecs = 0.15, launchFade = 0.10, handClean = true, hitDelay = 0.15, freeze = true, freezeAt = 0.10, frozenSpeed = 0.0, boom = true, animFx = true, animFxSeen = {}, boomScale = 1.0, pickRange = 20,   -- (3.37 user: 20 m, aim window 40 deg)
                 lineRadius = 1.2, animSpeed = 1.5,
                 dmg = 2800, magRate = 3.5, stamina = 200, react = 300, aimCone = 40, maxUp = 20, airRange = 35, airUp = 4, stagger = true, hue = 300, tint = false,   -- (3.39 user: 1.4x the 3.34 damage, not 1.6x)
                 hand = true, handScale = 0.35, hitFx = false, hitScale = 0.6, dots = false,   -- (3.24 user: wisps to remove - the Golem hit flash, off)
                 res = {}, fx = {}, frame = nil, endF = nil }
    dbg.beam = bm
    local GAME = { beam2 = "vfx/effects/character/ch52/000/13_ch52_000_generalshell_030_02.efx",
                   beamhand = "vfx/effects/character/ch52/000/13_ch52_000_generalshell_030_01.efx",
                   beamhit2 = "vfx/effects/character/ch52/000/13_ch52_000_generalshell_030_03.efx",
                   beamrow = "vfx/effects/character/ch52/000/13_ch52_000_generalshell_030_01.efx",
                   beamrowb = "vfx/effects/character/ch52/000/13_ch52_000_generalshell_030_01.efx" }
    for _, k in ipairs({ "beamrowc", "beamrowd", "beamrowe", "beamrowf", "beamrowg" }) do GAME[k] = GAME.beamrow end
    local ROW = { "beamhand", "beamrow", "beamrowb", "beamrowc", "beamrowd", "beamrowe", "beamrowf", "beamrowg" }
    local IDS, NAMES = {}, {}
    pcall(function()
        for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
            if f:is_static() then
                local ok, v = pcall(f.get_data, f, nil)
                if ok and type(v) == "number" then IDS[f:get_name()] = v & 0xFFFFFFFF; NAMES[v & 0xFFFFFFFF] = f:get_name() end
            end
        end
    end)
    local function mkey(L) return L:call("get_MotionBankID") * 100000 + L:call("get_MotionID") end
    local function hue_rgb(hue)
        local h = (hue % 360) / 60
        local x = 1 - math.abs(h % 2 - 1)
        local t = ({ { 1, x, 0 }, { x, 1, 0 }, { 0, 1, x }, { 0, x, 1 }, { x, 0, 1 }, { 1, 0, x } })[math.floor(h) + 1]
        return t[1], t[2], t[3]
    end
    -- one of our anchors playing <kind> (our baked copy in the chosen hue; the game's own file if ours is missing)
    local function anchor(kind)
        local want = ("vfx/effects/pactblade/pb_%s_h%d.efx"):format(kind, bm.hue)   -- (beam2 / beamhit2: x0006, own gradients)
        local res = bm.res[want]
        if not res then
            local r = sdk.create_resource("via.effect.EffectResource", want)
            if not r then
                if not bm.noOurs then bm.noOurs = true; note("Eldritch Blast: our purple beam files not loaded (restart the game for the pak) - the Golem's own") end
                r = sdk.create_resource("via.effect.EffectResource", GAME[kind])
            end
            if not r then return nil end
            res = r:add_ref()
            bm.res[want] = res
        end
        local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_beam", 0)
        go = go:add_ref()
        go:call(".ctor")
        go:set_Name("Pactblade_beam")
        local holder = res:create_holder("via.effect.EffectResourceHolder"):add_ref()
        local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
        ep:call("set_Resource", holder)
        pcall(function() ep:call("set_AutoStart", true) end)
        if bm.tint then pcall(function() local r, g, b = hue_rgb(bm.hue); ep:set_Color(via_colour({ r, g, b, 1 })) end) end
        return { go = go, ep = ep }
    end
    local function drop(an) if an then pcall(function() an.go:call("destroy(via.GameObject)", an.go) end) end end
    local function clear_shot()
        local sh = bm.shot
        bm.shot = nil
        if sh then drop(sh.beam); drop(sh.hand); for _, an in pairs(sh.chain or {}) do drop(an) end end
    end
    re.on_script_reset(function()
        clear_shot()
        for _, f in ipairs(bm.fx) do drop(f) end
        bm.fx = {}
    end)
    -- the rotation that turns +Z onto (dx, dy, dz) (unit): pitch about X, then yaw about Y
    local function look_rot(dx, dy, dz)
        local yaw = math.atan(dx, dz)
        local pitch = math.asin(math.max(-1, math.min(1, -dy)))
        local qy = Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
        local qx = Quaternion.new(math.cos(pitch / 2), math.sin(pitch / 2), 0, 0)
        return qy * qx
    end
    local function palm_of(a)
        local p
        pcall(function() p = a.game_object:get_Transform():getJointByName(PB.PALM):get_Position() end)
        if not p then
            local q = a.character:get_GameObject():get_Transform():get_Position()
            p = Vector3f.new(q.x, q.y + 1.3, q.z)
        end
        return p
    end
    local function aim_of(t)   -- the target's middle (hip joint; else its feet + 1.2)
        local v
        pcall(function() v = t.Hip:get_Position() end)
        if not v then pcall(function() local q = t:get_GameObject():get_Transform():get_Position(); v = Vector3f.new(q.x, q.y + 1.2, q.z) end) end
        return v
    end
    local function alive(t) return t and dbg.misty and dbg.misty.alive(t) end
    local function request(a, name)
        bm.ourReq = true
        local ok = a:request_action(name, 0)
        bm.ourReq = false
        return ok
    end
    function bm.play_sound(a)   -- (3.44: the Smite's own hit sound; 3.45: bm.soundLead s before the beam)
        bm.sounded = true
        if bm.sound and dbg.smite and dbg.smite.sound then pcall(dbg.smite.sound, a, dbg.smite.SND.hit, "Eldritch Blast") end
    end
    local function finish(a, why)
        if bm.stage and a then pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.0) end) end
        bm.stage = nil
        bm.info = why
        note("Eldritch Blast: " .. tostring(why))
    end
    local function face(a, t)
        if not t then return end
        pcall(function()
            local tr = a.character:get_GameObject():get_Transform()
            local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
            local dx, dz = q.x - p.x, q.z - p.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 0.05 then tr:set_Rotation(combo.yaw(dx / l, dz / l)) end
        end)
    end
    -- the beam leaves the palm
    local function fire(a)
        clear_shot()
        local palm = palm_of(a)
        local t = alive(bm.target) and bm.target or nil
        local aim = t and aim_of(t)
        if not aim then   -- nothing picked: along the camera (RE cameras look down -Z), the first enemy near that line
            local f
            pcall(function() f = sdk.get_primary_camera():get_GameObject():get_Transform():get_Rotation() * Vector3f.new(0, 0, -1) end)
            pcall(function()   -- (the stick pushed: that way, level)
                local sy
                pcall(function()
                    if not a.input:call("isLeverInputL") then return end
                    sy = a.character["<TargetAngleCtrl>k__BackingField"].Move["<AngleDeg>k__BackingField"]
                end)
                if sy == nil then sy = stick_yaw(a) end
                if sy then f = Vector3f.new(math.sin(math.rad(sy)), 0, math.cos(math.rad(sy))) end
            end)
            if not f then f = a.character:get_GameObject():get_Transform():get_Rotation() * Vector3f.new(0, 0, 1); f = Vector3f.new(f.x, 0, f.z) end
            local l = math.max(0.001, math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z))
            local fx, fy, fz = f.x / l, f.y / l, f.z / l
            aim = Vector3f.new(palm.x + fx * bm.range, palm.y + fy * bm.range, palm.z + fz * bm.range)
            local bestT
            pcall(function()
                local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
                for k = 0, list._size - 1 do
                    pcall(function()
                        local ch = list._items[k]._Chara
                        if not alive(ch) then return end
                        local v = aim_of(ch)
                        local vx, vy, vz = v.x - palm.x, v.y - palm.y, v.z - palm.z
                        local along = vx * fx + vy * fy + vz * fz
                        if along < 0.3 or along > ((vy > bm.airUp) and math.max(bm.range, bm.airRange) or bm.range) then return end
                        local px, py, pz = vx - fx * along, vy - fy * along, vz - fz * along
                        local rad = bm.lineRadius
                        pcall(function() rad = rad + ch["<CharaController>k__BackingField"]:call("get_Radius") end)
                        if math.sqrt(px * px + py * py + pz * pz) > rad then return end
                        if not bestT or along < bestT then bestT, t = along, ch end
                    end)
                end
            end)
            if t then t = t:add_ref(); aim = aim_of(t) or aim end
        end
        local d = math.sqrt((aim.x - palm.x) ^ 2 + (aim.y - palm.y) ^ 2 + (aim.z - palm.z) ^ 2)
        if not bm.sounded then bm.play_sound(a) end   -- (not played early: now)
        if bm.stage == "air" and bm.airLaunch then   -- (3.43: the air Burst's launch flash at the hand)
            pcall(function()
                local l = math.max(0.001, d)
                if parts.play_ours("-1/8/40", palm, look_rot((aim.x - palm.x) / l, (aim.y - palm.y) / l, (aim.z - palm.z) / l)) then
                    parts.ours[#parts.ours].go:get_Transform():set_LocalScale(Vector3f.new(bm.airLaunchScale, bm.airLaunchScale, bm.airLaunchScale))
                end
            end)
        end
        local n = math.max(1, math.min(bm.maxCopies, math.floor(d / math.max(0.05, bm.spacing) + 0.5)))
        bm.shot = { t0 = os.clock(), target = t, aim = aim, beam = bm.mesh and anchor("beam2") or nil,
                    hand = bm.hand and anchor(bm.handClean and "beamrowd" or "beamhand") or nil, inAir = bm.stage == "air", chain = {}, n = bm.chain and n or 0 }
        note(("Eldritch Blast: fired at frame %.1f (motion end %s), %s, %.1f m"):format(bm.frame or -1, tostring(bm.endF),
            t and tostring(t:get_GameObject():get_Name()) or "nothing on the line - along the camera", d))
    end
    -- the hit: damage (+ a flinch) and the Golem's hit flash where the beam ends
    local function hit(a, sh, at, dir)
        if sh.target and alive(sh.target) then
            pcall(function()
                local hm = sdk.get_managed_singleton("app.HitManager")
                local me, myHit = a.character:get_GameObject(), a.character["<Hit>k__BackingField"]
                local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()
                local dmg, src = bm.dmg, "fixed (no Eldritch Bolt hit yet)"
                if dbg.boltMag then dmg, src = dbg.boltMag * bm.magRate, ("magick %.0f x%.2f"):format(dbg.boltMag, bm.magRate) end
                pcall(function()   -- (Hex: -10 % defence)
                    local hx = dbg.hex
                    if hx and hx.go and hx.go:get_address() == sh.target:get_GameObject():get_address() then dmg = dmg / (1 - hx.defence) end
                end)
                info.Damage = dmg
                pcall(function() info.IsMagicAttack = true end)   -- (magick only)
                pcall(function() info.MagicDamage = dmg end)
                pcall(function() info.SlashDamage, info.StrikeDamage, info.ShootDamage = 0, 0, 0 end)
                if bm.stagger then   -- a flinch: Hitback_M with enough reaction power to pass the enemy's threshold
                    info.DamageType, info.DamageActType, info.IsDirectDamageEnableAllDamageType = 6, 6, true
                    pcall(function() info.DamageReaction = bm.react end)
                    pcall(function() info.OverwriteBlownType = 6 end)
                end
                local th = sh.target["<Hit>k__BackingField"]
                local hp0 = th:get_Hp()
                bm.ourInfo, bm.ourInfoUntil, bm.reacts = info:get_address(), os.clock() + 1.0, 0
                local ok, e1 = pcall(hm.call, hm, "directDamage", info, th, me, false, myHit)
                local how = "with owner"
                if not ok then how = "without owner (" .. tostring(e1) .. ")"; hm:call("directDamage", info, th, nil, false, nil) end
                bm.info = ("hit %s for %.0f (%s)"):format(tostring(sh.target:get_GameObject():get_Name()), dmg, src)
                local after = "?"
                pcall(function() after = ("type %s, reaction %.0f"):format(tostring(info.DamageType), info.DamageReaction) end)
                note(("Eldritch Blast hit %s: %.0f damage (%s), HP %.0f -> %.0f (%s; after the call: %s; reaction hooks %d)"):format(
                    tostring(sh.target:get_GameObject():get_Name()), dmg, src, hp0, th:get_Hp(), how, after, bm.reacts or 0))
            end)
        else bm.info = "fired (nothing hit)"; note("Eldritch Blast: beam arrived, no living target") end
        if bm.boom then
            pcall(function()
                local rot = look_rot(dir.x, dir.y, dir.z)   -- (as the bolt's: the way it flew)
                for _, id in ipairs({ "-1/8/40", "-1/8/43" }) do   -- Eldritch Bolt's hit: starburst + explosion
                    if parts.play_ours(id, at, rot) then
                        parts.ours[#parts.ours].go:get_Transform():set_LocalScale(Vector3f.new(bm.boomScale, bm.boomScale, bm.boomScale))
                    end
                end
            end)
        end
        if bm.hitFx then
            local an = anchor("beamhit2")
            if an then
                local tr = an.go:get_Transform()
                tr:set_Position(at)
                tr:set_Rotation(look_rot(-dir.x, -dir.y, -dir.z))
                tr:set_LocalScale(Vector3f.new(bm.hitScale, bm.hitScale, bm.hitScale))
                an.untilT = os.clock() + 2.5
                bm.fx[#bm.fx + 1] = an
            end
        end
    end
    -- the animation: Riotous Fury's opening, the beam at bm.fireFrame, back to standing at bm.endFrame
    local function update(a)
        local now = os.clock()
        if bm.want then
            bm.want = false
            if bm.stage then return end
            bm.target = nil
            pcall(function()
                local md = dbg.misty
                bm.aimBy = nil
                local at = bm.aim_pick and bm.aim_pick(a)
                if at then bm.target = at:add_ref(); note("Eldritch Blast: aimed (" .. tostring(bm.aimBy) .. ") at " .. tostring(at:get_GameObject():get_Name())); return end
                if bm.aimBy == "stick" then note("Eldritch Blast: nothing where the stick points"); return end   -- (no nearest-enemy fallback then)
                local old = md.range
                md.range = bm.pickRange
                local ok, t, _, why = pcall(md.pick, a)
                md.range = old
                if ok and t then bm.target = t:add_ref()
                else note("Eldritch Blast: nothing picked (" .. tostring(ok and why or t) .. "; " .. tostring(md.why(a)) .. ")") end
            end)
            face(a, bm.target)
            local inAir = false
            pcall(function() inAir = a.character:get_IsGround() == false end)
            bm.stage, bm.asked, bm.started, bm.fired, bm.frame, bm.endF = (inAir and bm.air) and "air" or "anim", now, nil, false, nil, nil
            bm.act = bm.stage == "air" and bm.AIR_ACTION or bm.ACTION
            bm.sounded, bm.lastFr, bm.lastFrT, bm.frRate = false, nil, nil, nil
            pcall(function() bm.prevMot = mkey(a.character.FullBodyLayer) end)
            request(a, bm.act)
            dbg.stamTraceUntil = os.clock() + 1.0   -- (4.02: what makes the bar flash full)
            if bm.stamina > 0 then   -- (4.04: Riotous Fury's 480 swapped for this before it lands; the check after as a backup)
                dbg.stamSwap = { cost = bm.stamina, untilT = os.clock() + 0.6, what = "Eldritch Blast" }
                dbg.stam_cost(a, "Eldritch Blast", bm.stamina)
            end
            bm.info = "casting"
        end
        if not bm.stage then return end
        local cur = a:current_action(0)
        local act = bm.act or bm.ACTION
        if not bm.started then
            if cur == act then bm.started = now
            elseif now - bm.asked > 0.4 then return finish(a, act .. " did not start (now " .. tostring(cur) .. ")")
            else request(a, act); return end
        end
        if cur ~= act then
            if not bm.fired then return finish(a, "interrupted by " .. tostring(cur) .. " before the beam") end
            return finish(a, "done (" .. tostring(cur) .. " took over)")
        end
        if bm.stage == "air" then   -- the air bolt's animation: fire after bm.airFire s, let go after bm.airEnd s
            if not bm.fired then
                face(a, alive(bm.target) and bm.target or nil)
                if not bm.sounded and now - bm.started >= bm.airFire - bm.soundLead then bm.play_sound(a) end
                if now - bm.started >= bm.airFire then bm.fired = true; fire(a) end
            end
            if now - bm.started >= bm.airEnd then
                request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion")
                return finish(a, "done (air)")
            end
            return
        end
        local L = a.character.FullBodyLayer
        if mkey(L) == bm.prevMot and now - bm.started < 0.25 then return end   -- not on the new animation yet
        local fr = L:call("get_Frame")
        bm.frame = fr
        if not bm.endF then
            pcall(function() bm.endF = L:call("get_EndFrame") end)
            pcall(function() note(("Eldritch Blast: opening plays at layer speed %.2f"):format(L:call("get_Speed"))) end)
        end
        if not bm.fired then pcall(L.call, L, "set_Speed", bm.animSpeed) else pcall(L.call, L, "set_Speed", 1.0) end
        if not bm.fired then
            face(a, alive(bm.target) and bm.target or nil)
            if bm.lastFr and now > bm.lastFrT and fr > bm.lastFr then bm.frRate = (fr - bm.lastFr) / (now - bm.lastFrT) end   -- (frames a second)
            bm.lastFr, bm.lastFrT = fr, now
            if not bm.sounded and bm.frRate and (bm.fireFrame - fr) / bm.frRate <= bm.soundLead then bm.play_sound(a) end
            if fr >= bm.fireFrame then bm.fired = true; fire(a) end
        end
        if fr >= bm.endFrame then
            request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion")
            return finish(a, "done")
        end
    end
    re.on_pre_application_entry("UpdateBehavior", function()
        if not bm.stage and not bm.want then return end
        local a = runtime.player()
        if not a or not a:valid() or not live.on then bm.want = false; if bm.stage then finish(a, "Pactblade off") end; return end
        local ok, err = pcall(update, a)
        if not ok then finish(a, "error: " .. tostring(err)) end
    end)
    -- the beam itself, every frame: from the palm to the target, growing, then thinning out
    re.on_pre_application_entry("LateUpdateBehavior", function()
        local now = os.clock()
        for i = #bm.fx, 1, -1 do
            if now > bm.fx[i].untilT then drop(bm.fx[i]); table.remove(bm.fx, i) end
        end
        local sh = bm.shot
        if not sh then return end
        local ok, err = pcall(function()
            local a = runtime.player()
            if not a or not a:valid() then clear_shot(); return end
            sh.palm0 = sh.palm0 or palm_of(a)   -- (user: the beam's start stays where the hand fired it)
            local palm = (bm.followHand or (sh.inAir and bm.airFollow)) and palm_of(a) or sh.palm0
            if sh.target and alive(sh.target) then sh.aim = aim_of(sh.target) or sh.aim end
            local aim = sh.aim
            local dx, dy, dz = aim.x - palm.x, aim.y - palm.y, aim.z - palm.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist < 0.3 then return end
            dx, dy, dz = dx / dist, dy / dist, dz / dist
            local t = now - sh.t0
            local frac = math.min(1, t / math.max(0.001, bm.grow))
            local len = math.max(0.01, dist * frac)
            local w = bm.width
            if t > bm.grow + bm.hold then w = w * (1 - (t - bm.grow - bm.hold) / math.max(0.001, bm.fade)) end
            if w <= 0 then clear_shot(); return end
            if frac >= 1 and not sh.arrived then sh.arrived = now end
            if sh.arrived and not sh.hit and now - sh.arrived >= bm.hitDelay then sh.hit = true; hit(a, sh, aim, { x = dx, y = dy, z = dz }) end
            local span = bm.to - bm.from
            if math.abs(span) < 0.1 then span = span < 0 and -0.1 or 0.1 end
            local sg = span < 0 and -1 or 1
            local k = len / math.abs(span)
            local q = look_rot(dx, dy, dz)
            if sg < 0 then q = q * Quaternion.new(0, 0, 1, 0) end   -- (its -Z toward the target)
            local o = sg * bm.from * k   -- (mesh point 'from' lands on the palm)
            local at = Vector3f.new(palm.x - dx * o, palm.y - dy * o, palm.z - dz * o)
            if sh.beam then
                local tr = sh.beam.go:get_Transform()
                tr:set_Position(at)
                tr:set_Rotation(q)
                tr:set_LocalScale(Vector3f.new(w, w, k))
            end
            local q0 = look_rot(dx, dy, dz)
            for i = 1, sh.n do   -- the chain: copy i at i/n of the way, there once the beam has grown past it
                local f = i / sh.n
                if f <= frac + 1e-6 then
                    if sh.chain[i] == nil then   -- (false = gone / failed: never made again)
                        sh.chain[i] = anchor(ROW[bm.rowLook] or "beamrow") or false
                        if sh.chain[i] then sh.chain[i].born = now end
                    end
                    local an = sh.chain[i]
                    local early = 1   -- (the launch cloud: copies near the hand go first)
                    if dist * f <= bm.launchLen and t > bm.launchSecs then
                        early = math.max(0, 1 - (t - bm.launchSecs) / math.max(0.001, bm.launchFade))
                    end
                    if an and early <= 0 then drop(an); sh.chain[i] = false; an = nil end
                    if an then
                        local tr = an.go:get_Transform()
                        local cs = bm.chainScale * (w / math.max(0.001, bm.width)) * early
                        tr:set_Position(Vector3f.new(palm.x + dx * dist * f, palm.y + dy * dist * f, palm.z + dz * dist * f))
                        tr:set_Rotation(q0)
                        tr:set_LocalScale(Vector3f.new(cs, cs, cs))
                    end
                end
            end
            if bm.freeze then
                local function fz(an)
                    if an and not an.frozen and now - (an.born or sh.t0) >= bm.freezeAt then
                        an.frozen = true
                        pcall(function() an.ep:call("set_PlaySpeed", bm.frozenSpeed) end)
                    end
                end
                for i = 1, sh.n do fz(sh.chain[i]) end
                fz(sh.hand)
            end
            if sh.hand and t > bm.launchSecs + bm.launchFade then drop(sh.hand); sh.hand = nil end
            if sh.hand then
                local tr = sh.hand.go:get_Transform()
                local hs = bm.handScale * (w / math.max(0.001, bm.width))
                if t > bm.launchSecs then hs = hs * math.max(0, 1 - (t - bm.launchSecs) / math.max(0.001, bm.launchFade)) end
                tr:set_Position(palm)
                tr:set_Rotation(q)
                tr:set_LocalScale(Vector3f.new(hs, hs, hs))
            end
            sh.pts = { palm = palm, tip = Vector3f.new(palm.x + dx * len, palm.y + dy * len, palm.z + dz * len), at = at }
        end)
        if not ok then bm.info = "beam error: " .. tostring(err); clear_shot() end
    end)
    re.on_frame(function()   -- placement dots: green = palm, red = beam tip, yellow = the mesh beam's anchor
        if not bm.dots or not bm.shot or not bm.shot.pts then return end
        pcall(function()
            local function dot(v, col, r)
                local sp = draw.world_to_screen(v)
                if sp then draw.filled_circle(sp.x, sp.y, r, col, 12) end
            end
            dot(bm.shot.pts.palm, 0xFF00FF00, 7); dot(bm.shot.pts.tip, 0xFF0000FF, 7); dot(bm.shot.pts.at, 0xFF00FFFF, 5)
        end)
    end)
    -- Riotous Fury's own effects (the pink whirlwind): switched off while the beam's animation plays
    pcall(function()
        local td = sdk.find_type_definition("via.effect.script.ObjectEffectManager2")
        for _, m in ipairs(td:get_methods()) do
            local okP, pt = pcall(function() return m:get_param_types() end)
            local okR, rt = pcall(function() return m:get_return_type():get_full_name() end)
            local fsm = ({ requestEffectInternal = true, requestEffectFromFsmOrSequence = true, requestEffectFromFsm = true,
                           requestEffectParamFromFsm = true, requestEffectParamAllElementsFromFsm = true })[m:get_name()]
                        and okR and rt == "via.effect.script.CreatedEffectContainer"
            if fsm or (m:get_name() == "requestEffect" and okP and pt[1] and pt[1]:get_full_name() == "via.effect.script.EffectID") then
                local mname = m:get_name()
                sdk.hook(m, function(args)
                    local st = thread.get_hook_storage()
                    st.bmKill = nil
                    if not bm.stage or not bm.animFx or not live.on then return end
                    if bm.stage == "air" and bm.airAnimFx then   -- (3.43: the air animation keeps its look; 1.0.1: but not the big swirl)
                        local ok, idd = pcall(effect_id_of, args, mname)
                        if not (ok and bm.airKill[idd]) then return end
                    end
                    pcall(function()
                        local mgr = sdk.to_managed_object(args[2])
                        if mgr:call("get_GameObject"):get_address() ~= live.go then return end
                        local k = mname
                        pcall(function()
                            local id = sdk.to_managed_object(args[3])
                            k = ("%s %d/%d/%d"):format(mname, id.DataContainerIndex, id.ContainerID, id.ElementID)
                        end)
                        st.bmKill = k
                    end)
                end, function(rv)
                    local st = thread.get_hook_storage()
                    local k = st.bmKill
                    st.bmKill = nil
                    if k then
                        pcall(function() local c = sdk.to_managed_object(rv); if c then c:call("killAll") end end)
                        if not bm.animFxSeen[k] then bm.animFxSeen[k] = true; note("Eldritch Blast: animation effect " .. k .. " switched off") end
                    end
                    return rv
                end)
            end
        end
    end)
    local function our_info(args)
        if not bm.ourInfo or os.clock() > (bm.ourInfoUntil or 0) then return nil end
        local info = sdk.to_managed_object(args[3])
        if info and info:get_address() == bm.ourInfo then return info end
    end
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method("getReactionDamageType(app.HitController.DamageInfo)"),
            function(args)
                local st = thread.get_hook_storage()
                st.bmR = nil
                if not bm.stagger then return end
                pcall(function() st.bmR = our_info(args) end)
            end, function(r)
                local st = thread.get_hook_storage()
                local info = st.bmR
                st.bmR = nil
                if not info then return r end
                bm.reacts = (bm.reacts or 0) + 1
                pcall(function() info.DamageType, info.DamageActType, info.OverwriteBlownType = 6, 6, 6 end)
                return sdk.to_ptr(6)
            end)
    end)
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageReaction(app.HitController.DamageInfo)"),
            function(args)
                local st = thread.get_hook_storage()
                st.bmP = nil
                if not bm.stagger then return end
                pcall(function() st.bmP = our_info(args) end)
            end, function(r)
                local st = thread.get_hook_storage()
                local info = st.bmP
                st.bmP = nil
                if info then
                    bm.reacts = (bm.reacts or 0) + 1
                    pcall(function() if info.DamageReaction < bm.react then info.DamageReaction = bm.react end end)
                end
                return r
            end)
    end)
    -- the target: the enemy nearest to where the camera points (within bm.aimCone, bm.pickRange m); else Misty Dive's pick
    local function aim_pick(a, rangeMul)
        rangeMul = rangeMul or 1
        local best, bestA
        bm.seenList, bm.listNote = {}, true
        pcall(function()
            local p = a.character:get_GameObject():get_Transform():get_Position()
            local fx, fz
            local sy
            pcall(function()   -- (3.48: the game's move direction from the stick - no left/right guess)
                if not a.input:call("isLeverInputL") then return end
                sy = a.character["<TargetAngleCtrl>k__BackingField"].Move["<AngleDeg>k__BackingField"]
            end)
            if sy == nil then sy = stick_yaw(a) end   -- (user aims with the left stick; else the camera)
            if sy then fx, fz = math.sin(math.rad(sy)), math.cos(math.rad(sy)); bm.aimBy = "stick"
            else
                local f = sdk.get_primary_camera():get_GameObject():get_Transform():get_Rotation() * Vector3f.new(0, 0, -1)
                local fl = math.sqrt(f.x * f.x + f.z * f.z)
                if fl < 0.05 then return end
                fx, fz = f.x / fl, f.z / fl
                bm.aimBy = "camera"
            end
            local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
            for k = 0, list._size - 1 do
                pcall(function()
                    local ch = list._items[k]._Chara
                    if not alive(ch) then return end
                    local g = ch:get_GameObject():get_Transform():get_Position()
                    local q = aim_of(ch) or g   -- (3.46: the body, not the object - flying harpies)
                    local dx, dz = q.x - p.x, q.z - p.z
                    local d = math.sqrt(dx * dx + dz * dz)
                    if bm.listNote then
                        local gd = math.sqrt((g.x - p.x) ^ 2 + (g.z - p.z) ^ 2)
                        bm.seenList[#bm.seenList + 1] = ("%s body %.1f m / %.1f up, object %.1f m / %.1f up"):format(
                            tostring(ch:get_GameObject():get_Name()), d, q.y - p.y, gd, g.y - p.y)
                    end
                    local reach = ((q.y - p.y > bm.airUp) and math.max(bm.pickRange, bm.airRange) or bm.pickRange) * rangeMul   -- (fliers: further)
                    if d > reach or d < 0.05 or math.abs(q.y - p.y) > bm.maxUp then return end
                    local ang = math.deg(math.acos(math.max(-1, math.min(1, (dx * fx + dz * fz) / d))))
                    if d < 2.5 then ang = math.min(ang, bm.aimCone) end   -- (right next to me: counts)
                    if ang > bm.aimCone and not (bm.aimBy == "camera" and dbg.misty and dbg.misty.on_screen(q)) then return end   -- (3.84)
                    local sc = ang + d * 0.1   -- (the angle; the distance only breaks ties)
                    if not bestA or sc < bestA then best, bestA = ch, sc end
                end)
            end
        end)
        bm.listNote = false
        if not best and #bm.seenList > 0 then note("Eldritch Blast: enemies: " .. table.concat(bm.seenList, "; ", 1, math.min(6, #bm.seenList))) end
        return best
    end
    bm.aim_pick = aim_pick
    dbg.beam_fire = fire
    function bm.press()
        local now = os.clock()
        if bm.stage or bm.want or now - bm.lastPress < 0.6 or combo.stage ~= 0 then return end
        local can = false
        pcall(function()
            local track = runtime.player().character:get_Human().Track
            can = track.All or track.Skill
        end)
        local air = false
        pcall(function() air = runtime.player().character:get_IsGround() == false end)
        if air and bm.air then   -- (user: usable in the air; 3.65: only from a real jump / fall, never on a rope / hurt)
            local okA, cur = dbg.air_ok(runtime.player())
            can = okA
            if not okA then note("Eldritch Blast: not now (" .. tostring(cur) .. ")") end
        end
        note("Eldritch Blast press" .. (air and " (in the air)" or "") .. (can and "" or " - refused: the game's skill track is closed"))
        if can then bm.lastPress, bm.want = now, true end
    end
    pcall(function()
        local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
        sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
            if not live.on or not dbg.press_ok() then return end
            local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
            if bm.binding then   -- 'put it in the next skill I press'
                bm.binding = false
                if NAMES[id] then cfg.beamSkill = NAMES[id]; save_cfg(); bm.slotInfo = "now in " .. NAMES[id] .. "'s slot" end
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            if id ~= IDS[cfg.beamSkill or ""] then return end
            bm.press()
            return sdk.PreHookResult.SKIP_ORIGINAL   -- the vanilla skill never plays
        end, function(r) return r end)
    end)
    pcall(function()
        local SIG2 = "processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean)"
        sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG2), function(args)
            if not live.on or not bm.air or not dbg.press_ok() then return end
            local id = sdk.to_int64(args[4]) & 0xFFFFFFFF
            if id ~= IDS[cfg.beamSkill or ""] then return end
            local air = false
            pcall(function() air = runtime.player().character:get_IsGround() == false end)
            if not bm.seenEntry then bm.seenEntry = true; note("Eldritch Blast: the button's entry is called" .. (air and " (in the air)" or "")) end
            if not air then return end   -- (on the ground the usual hook below takes it)
            bm.press()
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(r) return r end)
    end)
    -- the vanilla skill started any other way becomes the beam too; while the beam plays, the game's follow-up of
    -- Riotous Fury's opening (the rest of Riotous Fury) is refused
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
            function(args)
                if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
                if not live.on or bm.ourReq then return end
                local skip = false
                pcall(function()
                    local name = sdk.to_managed_object(args[4]):ToString()
                    local bs = cfg.beamSkill or "?"
                    local mine = (not dbg.INTEGRATED) and name:sub(1, #bs) == bs
                    local follow = bm.stage and name:find("^Job01_BravesRaid") ~= nil
                    if not mine and not follow then return end
                    if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                    skip = true
                    if mine then bm.press() elseif bm.refused ~= name then bm.refused = name; note("Eldritch Blast: follow-up refused: " .. name) end
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
    end)
end)()

-- BLINK STRIKE (user, 3.85): Blink Behind (our first mod) as a Pactblade skill - warp behind the enemy (the Archfey
-- Combo's warp look), then Riotous Fury's last hit (Job01_BravesRaid from bs.from to bs.to - picked in game from the
-- frame readout).
;(function()
    local bs = { info = "-", lastPress = -10, ACTION = "Job01_BravesRaid", from = 106, to = 235,   -- (3.90 user: the last hit from 119, AnimPlayer; 3.93: 106; i-0.4: cut at 235)
                 fastFrom = 150, fastSpeed = 1.7, cancelFrom = 170, endBlend = 8,   -- (i-0.4 user: faster recovery after the hit; i-0.6: cancel 170, blended end)
                 blend = 6, behind = 1.2,
                 rangeMul = 0.75, speed = 1.0, frame = nil, endF = nil, motion = "-", air = true,   -- (3.86 user: 10 m; 3.94: 15 m)
                 prep = true, PREP = "Job07_SkyDive", PREP_BANK = 170, WARP_MOTION = 1101, prepMax = 0.6, afterTeleport = 0.05,
                 prepWarp = 0.25, groundLock = true, warpSound = 2823464530,   -- (3.91; 3.92: 0.25 s)
                 airHold = 0.2, airSounds = { 3610636506, 1717783091 }, airFx = { "sdex", "sd10", "sd11", "sdns10" }, fxs = {}, res = {} }
    dbg.blink = bs
    local CHANGE = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"
    local IDS, NAMES = {}, {}
    pcall(function()
        for _, f in ipairs(sdk.find_type_definition("app.HumanCustomSkillID"):get_fields()) do
            if f:is_static() then
                local ok, v = pcall(f.get_data, f, nil)
                if ok and type(v) == "number" then IDS[f:get_name()] = v & 0xFFFFFFFF; NAMES[v & 0xFFFFFFFF] = f:get_name() end
            end
        end
    end)
    local function mkey(L) return L:call("get_MotionBankID") * 100000 + L:call("get_MotionID") end
    local function request(a, name)
        bs.ourReq = true
        local ok = a:request_action(name, 0)
        bs.ourReq = false
        return ok
    end
    local function finish(a, why)
        pcall(function() for _, go in ipairs(bs.fxs or {}) do go:call("destroy(via.GameObject)", go) end; bs.fxs = {} end)
        if a then pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.0) end) end
        bs.stage = nil
        bs.info = why
        note("Misty Strike: " .. tostring(why))
    end
    local function fx_on_me(a)   -- (3.95) SkyDive's launch effects (our purple copies) on me, for the air hold
        local hue = (dbg.misty and dbg.misty.hue and dbg.misty.hue()) or 285
        local p = a.character:get_GameObject():get_Transform()
        for _, nm in ipairs(bs.airFx) do
            pcall(function()
                local path = ("vfx/effects/pactblade/pb_%s_h%d.efx"):format(nm, hue)
                if not bs.res[path] then
                    local r = sdk.create_resource("via.effect.EffectResource", path)
                    if not r then return end
                    bs.res[path] = r:add_ref()
                end
                local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_ms_fx", 0)
                go = go:add_ref(); go:call(".ctor"); go:set_Name("Pactblade_ms_fx")
                go:get_Transform():set_Position(p:get_Position())
                go:get_Transform():set_Rotation(p:get_Rotation())
                local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
                ep:call("set_Resource", bs.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref())
                pcall(function() ep:call("set_AutoStart", true) end)
                bs.fxs[#bs.fxs + 1] = go
            end)
        end
    end
    local function fx_off()
        for _, go in ipairs(bs.fxs) do pcall(function() go:call("destroy(via.GameObject)", go) end) end
        bs.fxs = {}
    end
    re.on_script_reset(fx_off)
    local function blink(a, t)   -- behind it (seen from me), facing it
        local p = a.character:get_GameObject():get_Transform():get_Position()
        local q = t:get_GameObject():get_Transform():get_Position()
        local dx, dz = q.x - p.x, q.z - p.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 0.01 then dx, dz, l = 0, 1, 1 end
        dx, dz = dx / l, dz / l
        local back = bs.behind
        pcall(function() local r = t["<CharaController>k__BackingField"]:call("get_Radius"); if r then back = back + r end end)
        local dest = Vector3f.new(q.x + dx * back, q.y, q.z + dz * back)
        pcall(function()   -- (3.96) the ground there: stairs / slopes higher than its feet; a flier's ground far below stays
            if not combo.nearest_hit then return end
            local g = combo.nearest_hit(Vector3f.new(dest.x, dest.y + 2.5, dest.z), Vector3f.new(dest.x, dest.y - 3.0, dest.z), 0.05)
            if not g then bs.groundInfo = "no ground found"; return end
            if g.y > dest.y or dest.y - g.y < 1.0 then
                bs.groundInfo = ("ground %.2f m %s"):format(math.abs(g.y - dest.y), g.y > dest.y and "higher" or "lower")
                dest = Vector3f.new(dest.x, g.y + 0.05, dest.z)
            else bs.groundInfo = ("ground %.1f m below - stays in the air"):format(dest.y - g.y) end
        end)
        combo.warp_to(a, dest, combo.yaw(-dx, -dz), -dx, -dz)
        bs.face = { -dx, -dz }
        if bs.groundInfo then note("Misty Strike landing: " .. bs.groundInfo); bs.groundInfo = nil end
    end
    local function update(a)
        local now = os.clock()
        if bs.want then
            bs.want = false
            if bs.stage then return end
            local t = dbg.beam and dbg.beam.aim_pick and dbg.beam.aim_pick(a, bs.rangeMul)
            if not t then bs.info = "no enemy where I aim"; note("Misty Strike: no enemy where I aim"); return end
            local inAir = false
            pcall(function() inAir = a.character:get_IsGround() == false end)
            if inAir and bs.airHold > 0 then   -- (3.95) from a jump: frozen in the air, the launch effects + sounds, then the warp
                bs.target = t:add_ref()
                bs.stage, bs.prepT = "airprep", now
                pcall(function() bs.ground = a.character:get_GameObject():get_Transform():get_Position() end)
                pcall(function() a.character.FullBodyLayer:call("set_Speed", 0.0) end)
                pcall(fx_on_me, a)
                if combo.cue_sound then for _, sid in ipairs(bs.airSounds) do pcall(combo.cue_sound, a, sid) end end
                return
            end
            if bs.prep and not inAir then   -- (3.86) Misty Dive's getting-ready: SkyDive's preparing jump first, the warp at its teleport
                bs.target = t:add_ref()
                bs.stage, bs.prepT, bs.prepStarted, bs.teleportAt = "prep", now, nil, nil
                pcall(function() bs.ground = a.character:get_GameObject():get_Transform():get_Position() end)
                request(a, bs.PREP)
                return
            end
            local ok, e = pcall(blink, a, t)
            if not ok then bs.info = "warp failed: " .. tostring(e); note(bs.info); return end
            note("Misty Strike: behind " .. tostring(t:get_GameObject():get_Name()))
            bs.stage, bs.asked, bs.started, bs.framed, bs.endF = "strike", now, nil, false, nil
            pcall(function() bs.prevMot = mkey(a.character.FullBodyLayer) end)
            request(a, bs.ACTION)
        end
        if not bs.stage then return end
        if bs.stage == "airprep" then
            pcall(function()   -- held where I was
                local tr = a.character:get_GameObject():get_Transform()
                tr:set_Position(bs.ground)
                a.character["<CharaController>k__BackingField"]:call("warp")
                a.character.FullBodyLayer:call("set_Speed", 0.0)
            end)
            if now - bs.prepT < bs.airHold then return end
            fx_off()
            pcall(function() a.character.FullBodyLayer:call("set_Speed", 1.0) end)
            local t = bs.target
            bs.target = nil
            if not t or not (dbg.misty and dbg.misty.alive(t)) then return finish(a, "the enemy is gone") end
            local ok, e = pcall(blink, a, t)
            if not ok then return finish(a, "warp failed: " .. tostring(e)) end
            if combo.cue_sound then pcall(combo.cue_sound, a, bs.warpSound) end
            bs.hold = { n = 3 }
            pcall(function() bs.hold.dest = a.character:get_GameObject():get_Transform():get_Position() end)
            note("Misty Strike (from the air): behind " .. tostring(t:get_GameObject():get_Name()))
            bs.stage, bs.asked, bs.started, bs.framed, bs.endF, bs.retries = "strike", now, nil, false, nil, 0
            pcall(function() bs.prevMot = mkey(a.character.FullBodyLayer) end)
            request(a, bs.ACTION)
            return
        end
        if bs.stage == "prep" then
            local curP = tostring(a:current_action(0) or "")
            if curP == bs.PREP then bs.prepStarted = bs.prepStarted or now end
            local teleport = false
            pcall(function()
                local L = a.character.FullBodyLayer
                teleport = L:call("get_MotionBankID") == bs.PREP_BANK and L:call("get_MotionID") == bs.WARP_MOTION
            end)
            if teleport and not bs.teleportAt then bs.teleportAt = now end
            if bs.groundLock and bs.ground then   -- (3.91: no lift - the crouch and its effects stay on the ground)
                pcall(function()
                    local tr = a.character:get_GameObject():get_Transform()
                    local p = tr:get_Position()
                    if p.y > bs.ground.y + 0.02 then
                        tr:set_Position(Vector3f.new(bs.ground.x, bs.ground.y, bs.ground.z))
                        a.character["<CharaController>k__BackingField"]:call("warp")
                    end
                end)
            end
            local due = (bs.teleportAt and now - bs.teleportAt >= bs.afterTeleport) or (bs.prepStarted and now - bs.prepStarted >= bs.prepWarp)
            if due or (bs.prepStarted and now - bs.prepStarted > bs.prepMax) or (not bs.prepStarted and now - bs.prepT > 0.4) then
                local t = bs.target
                bs.target = nil
                if not t or not (dbg.misty and dbg.misty.alive(t)) then return finish(a, "the enemy is gone") end
                local ok, e = pcall(blink, a, t)
                if not ok then return finish(a, "warp failed: " .. tostring(e)) end
                if combo.cue_sound then pcall(combo.cue_sound, a, bs.warpSound) end   -- (3.91: SkyDive's teleport sound)
                bs.hold = { n = 3 }
                pcall(function()   -- (3.89: the preparing jump's effect copies end at the teleport)
                    local md = dbg.misty
                    for _, o in ipairs(md.fxs or {}) do pcall(function() o.go:call("destroy(via.GameObject)", o.go) end) end
                    md.fxs = {}
                    md.lastBusy = -10
                end)
                pcall(function() bs.hold.dest = a.character:get_GameObject():get_Transform():get_Position() end)
                note("Misty Strike: behind " .. tostring(t:get_GameObject():get_Name()) .. (teleport and " (at SkyDive's teleport)" or ""))
                bs.stage, bs.asked, bs.started, bs.framed, bs.endF, bs.retries = "strike", now, nil, false, nil, 0
                pcall(function() bs.prevMot = mkey(a.character.FullBodyLayer) end)
                request(a, bs.ACTION)
            elseif not bs.prepStarted then request(a, bs.PREP) end
            return
        end
        if bs.hold and bs.hold.n > 0 and bs.hold.dest then   -- (SkyDive's upward push after a warp: held a few frames)
            bs.hold.n = bs.hold.n - 1
            pcall(function()
                a.character:get_GameObject():get_Transform():set_Position(bs.hold.dest)
                a.character["<CharaController>k__BackingField"]:call("warp")
            end)
        end
        local cur = a:current_action(0)
        if not bs.started then
            if cur == bs.ACTION then bs.started = now
            elseif now - bs.asked > 0.4 then return finish(a, bs.ACTION .. " did not start (now " .. tostring(cur) .. ")")
            else request(a, bs.ACTION); return end
        end
        if cur ~= bs.ACTION then
            local c = tostring(cur)
            if (c:find("Landing") or c:find("Fall") or c:find("Jump")) and now - bs.started < 0.6 and (bs.retries or 0) < 5 then   -- (3.89)
                bs.retries = (bs.retries or 0) + 1
                bs.framed = false
                request(a, bs.ACTION)
                note("Misty Strike: " .. c .. " took over - the strike again")
                return
            end
            return finish(a, "done (" .. c .. " took over)")
        end
        local L = a.character.FullBodyLayer
        if mkey(L) == bs.prevMot and now - bs.started < 0.25 then return end   -- not on the new animation yet
        local fr = L:call("get_Frame")
        bs.frame = fr
        pcall(function() bs.motion = ("%d/%d"):format(L:call("get_MotionBankID"), L:call("get_MotionID")) end)
        if not bs.endF then pcall(function() bs.endF = L:call("get_EndFrame"); note(("Misty Strike: Riotous Fury's animation %s, %.0f frames"):format(bs.motion, bs.endF)) end) end
        if not bs.framed then
            bs.framed = true
            if bs.from > 0 and fr < bs.from then   -- (straight to the last hit, crossfaded)
                local ok = pcall(L.call, L, CHANGE, L:call("get_MotionBankID"), L:call("get_MotionID"), bs.from + 0.0, bs.blend + 0.0, 1, 1)
                if not ok then L:call("set_Frame", bs.from + 0.0) end
                return
            end
        end
        pcall(function() L:call("set_Speed", bs.speed + 0.0) end)
        local dtS = math.min(0.1, now - (bs.lastStepT or now))
        bs.lastStepT = now
        if fr >= bs.fastFrom and bs.fastSpeed > 1 then   -- (i-0.5) faster: the frame moved on by us
            pcall(function() L:call("set_Frame", fr + dtS * 60 * (bs.fastSpeed - 1)) end)
        end
        local function to_end()   -- (i-0.5) the animation to its last frame (i-0.6: crossfaded, no snap)
            local last = math.max(fr, (bs.endF or 282) - 1) + 0.0
            local ok = pcall(L.call, L, CHANGE, L:call("get_MotionBankID"), L:call("get_MotionID"), last, (bs.endBlend or 8) + 0.0, 1, 1)
            if not ok then pcall(function() L:call("set_Frame", last) end) end
        end
        if fr >= bs.cancelFrom then   -- (i-0.4) after the hit: the next input ends it at once
            local pressed
            for _, b in ipairs({ "AttackL", "AttackS", "Jump", "JobSpecialAction", "Skill1", "Skill2", "Skill3", "Skill4", "Skill5", "Skill6", "Dash", "SkillAdditional" }) do
                local ok, v = pcall(a.button_pressed, a, b)
                if ok and v then pressed = b; break end
            end
            if pressed then
                pcall(function() L:call("set_Speed", 1.0) end)
                to_end()
                request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion")
                return finish(a, ("done (cancelled by %s at frame %.0f)"):format(pressed, fr))
            end
        end
        if fr >= bs.to then
            to_end()
            request(a, a:is_grounded() == false and "WaitToFall" or "NormalLocomotion")
            return finish(a, ("done (cut at frame %.0f)"):format(fr))
        end
    end
    local function lock_ground()   -- (3.92) while getting ready: never above the ground I pressed on
        if bs.stage ~= "prep" or not bs.groundLock or not bs.ground then return end
        pcall(function()
            local a = runtime.player()
            local tr = a.character:get_GameObject():get_Transform()
            local p = tr:get_Position()
            if p.y > bs.ground.y + 0.01 then
                tr:set_Position(Vector3f.new(p.x, bs.ground.y, p.z))
                a.character["<CharaController>k__BackingField"]:call("warp")
            end
        end)
    end
    re.on_pre_application_entry("UpdateMotion", lock_ground)
    re.on_application_entry("UpdateMotion", lock_ground)
    re.on_pre_application_entry("LateUpdateBehavior", lock_ground)
    re.on_application_entry("LateUpdateBehavior", lock_ground)
    re.on_pre_application_entry("BeginRendering", lock_ground)
    re.on_pre_application_entry("UpdateBehavior", function()
        if not bs.stage and not bs.want then return end
        local a = runtime.player()
        if not a or not a:valid() or not live.on then bs.want = false; if bs.stage then finish(a, "Pactblade off") end; return end
        local ok, err = pcall(update, a)
        if not ok then finish(a, "error: " .. tostring(err)) end
    end)
    function bs.press()
        local now = os.clock()
        if bs.stage or bs.want or now - bs.lastPress < 0.6 or combo.stage ~= 0 then return end
        local a = runtime.player()
        local busy, cur = dbg.busy_action(a)
        if busy then note("Misty Strike: not now (" .. tostring(cur) .. ")"); return end
        local can = false
        pcall(function()
            local track = a.character:get_Human().Track
            can = track.All or track.Skill
        end)
        local air = false
        pcall(function() air = a.character:get_IsGround() == false end)
        if air and bs.air then can = dbg.air_ok(a) end   -- (3.94 user: from a jump too)
        note("Misty Strike press" .. (air and " (in the air)" or "") .. (can and "" or " - refused"))
        if can then bs.lastPress, bs.want = now, true; dbg.stam_cost(a, "Misty Strike", bs.stamina or 110) end
    end
    pcall(function()
        local SIG = "processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"
        sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG), function(args)
            if not live.on or not dbg.press_ok() then return end
            local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
            if bs.binding then
                bs.binding = false
                if NAMES[id] then cfg.blinkSkill = NAMES[id]; save_cfg(); bs.slotInfo = "now in " .. NAMES[id] .. "'s slot" end
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
            if id ~= IDS[cfg.blinkSkill or ""] then return end
            bs.press()
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(r) return r end)
    end)
    pcall(function()   -- (3.94) in the air the game never gets that far: the button's own entry first (as the beam's)
        local SIG2 = "processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean)"
        sdk.hook(sdk.find_type_definition("app.PlayerInputProcessorDetail"):get_method(SIG2), function(args)
            if not live.on or not bs.air or not dbg.press_ok() then return end
            local id = sdk.to_int64(args[4]) & 0xFFFFFFFF
            if id ~= IDS[cfg.blinkSkill or ""] then return end
            local air = false
            pcall(function() air = runtime.player().character:get_IsGround() == false end)
            if not air then return end
            bs.press()
            return sdk.PreHookResult.SKIP_ORIGINAL
        end, function(r) return r end)
    end)
    pcall(function()   -- the vanilla skill started any other way = Blink Strike; while it plays, Riotous Fury's own follow-ups refused
        sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
            function(args)
                if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- (1.0) the player only
                if not live.on or bs.ourReq then return end
                local skip = false
                pcall(function()
                    local name = sdk.to_managed_object(args[4]):ToString()
                    local ks = cfg.blinkSkill or "?"
                    local mine = (not dbg.INTEGRATED) and name:sub(1, #ks) == ks
                    local follow = bs.stage and name:find("^Job01_BravesRaid") ~= nil
                    local land = bs.stage == "strike" and (name:find("Landing") or name:find("Fall") or name:find("Jump")) ~= nil   -- (3.89)
                    if not mine and not follow and not land then return end
                    if sdk.to_managed_object(args[2]):get_GameObject():get_address() ~= live.go then return end
                    skip = true
                    if mine then bs.press() elseif land and bs.refused ~= name then bs.refused = name; note("Misty Strike: " .. name .. " refused (the strike plays)") end
                end)
                if skip then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
    end)
end)()

-- HELLISH REBUKE (user, 4.09): hit by an enemy (no reaction or a flinch - not staggered / knocked down / grabbed): for
-- hr.window s, Interact = the rebuke - motion 9112/750 (45 frames) at 1.2x, the attacker set on fire (FireSpread),
-- 30 % of max stamina. (Green hellfire = the next step.)
;(function()
    local hr = { info = "-", window = 0.5, speed = 1.2, bank = 9112, motion = 750, frames = 45, fps = 50, burnAt = 20,
                 staminaPct = 0.30, BURN = 5, on = true, flinch = true, react = 10000, cooldown = 6, lastCast = -100,
                 greenFire = true, fireConts = {}, fireRes = {}, fireSwapped = {},
                 spark = true, sparkHue = 120, sparkScale = 0.3, sparkSecs = 1.5, res = {}, sparks = {},
                 boom = true, boomScale = 1.0, boomSound = true, SOUND = 1047135920,   -- (4.11; 4.19: our own sound)
                 flinchDmg = 30, holdEnd = 0.5, flash = true, flashMode = 3460334268, flashCat = 8, flashSecs = 0.6, flashFx = { 20, 10 }, flashSound = 4127918784 }   -- (4.14)
    dbg.rebuke = hr
    local BIG = { "down", "blown", "slam", "ragdoll", "catch", "caught", "grab", "shrinkl", "shrinkll", "large", "dead", "die", "stun", "faint" }
    local function big_reaction(cur)
        local l = tostring(cur or ""):lower()
        for _, w in ipairs(BIG) do if l:find(w, 1, true) then return true end end
        return false
    end
    -- an enemy hits me: the window opens (the attacker kept)
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageValue(app.HitController.DamageInfo)"),
            function(args)
                if not hr.on or not live.on or not live.go then return end
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    local v = info["<DamageGameObject>k__BackingField"]
                    if not v or v:get_address() ~= live.go then return end
                    local owner = info["<AttackOwnerObject>k__BackingField"]
                    if not owner or owner:get_address() == live.go then return end
                    local ch = owner:call("getComponent(System.Type)", sdk.typeof("app.Character"))
                    if not ch then return end
                    local direct = false   -- (4.35) status ticks (fire, poison...) come as direct damage: not a real hit
                    pcall(function() direct = info.IsDirectDamage == true end)
                    if not direct then pcall(function() direct = info["<IsDirectDamage>k__BackingField"] == true end) end
                    if direct then
                        if os.clock() > (hr.tickNoteT or 0) then hr.tickNoteT = os.clock() + 3; note("Hellish Rebuke: a tick / direct damage - no window") end
                        return
                    end
                    hr.open = { untilT = os.clock() + hr.window, who = ch:add_ref(), at = os.clock(), noted = false }
                    pcall(function()   -- (4.38) what opened it
                        hr.open.kind = ("dmg %.0f type %s act %s weak %s shoot %s magic %s react %.0f"):format(info.Damage or -1, tostring(info.DamageType),
                            tostring(info.DamageActType), tostring(info.IsWeakDamage), tostring(info.IsShootAttack), tostring(info.IsMagicAttack), info.DamageReaction or -1)
                    end)
                end)
            end, function(r) return r end)
    end)
    local function cast(a, t)
        hr.open = nil
        pcall(function()   -- 30 % of max stamina (set directly)
            local smg = a.character:get_StaminaManager()
            local b0, cost = smg:get_RemainingAmount(), smg:get_MaxValue() * hr.staminaPct
            smg:call("setRemainingAmount(System.Single)", math.max(0, b0 - cost))
            note(("stamina: Hellish Rebuke paid %.0f (%.0f -> %.0f)"):format(cost, b0, smg:get_RemainingAmount()))
        end)
        pcall(function()   -- face the attacker
            local tr = a.character:get_GameObject():get_Transform()
            local p, q = tr:get_Position(), t:get_GameObject():get_Transform():get_Position()
            local dx, dz = q.x - p.x, q.z - p.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 0.05 and combo.yaw then tr:set_Rotation(combo.yaw(dx / l, dz / l)); pcall(dbg.set_facing_deg, a.character["<TargetAngleCtrl>k__BackingField"], math.deg(math.atan(dx / l, dz / l))) end
        end)
        pcall(function() a:request_action("NormalLocomotion", 0) end)   -- (out of a flinch)
        if hr.flash then pcall(function()   -- (4.14) the 'charge finished' whole-body flash (Tusk Toss / Warrior skills)
            local go = a.character:get_GameObject()
            local mgr = go:call("getComponent(System.Type)", sdk.typeof("app.MaterialInterpolationRequestManager"))
            if mgr then
                mgr:call("requestMaterialMode(System.UInt32, app.MaterialInterpolationRequestManager.RequestListCategory, System.Int32, System.Int32)", hr.flashMode, hr.flashCat, -1, -1)
                hr.flashOff = { mgr = mgr:add_ref(), at = os.clock() + hr.flashSecs }
            end
            local emgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
            local conts, idx = emgr.ExternalDataContainers, nil
            for i = 0, conts:get_Count() - 1 do
                local ok, path = pcall(function() return tostring(conts[i].DataContainer:get_Path()) end)
                if ok and path:lower():find("ch00/13_ch00_ref", 1, true) then idx = i end
            end
            if idx then
                local id = sdk.create_instance("via.effect.script.EffectID")
                id.DataContainerIndex = idx; id.ContainerID = hr.flashFx[1]; id.ElementID = hr.flashFx[2]
                id.IsContainerIDOnly = false; id.IsElementIDOnly = false
                emgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)", id, go, -1, nil)
            end
            if combo.cue_sound then pcall(combo.cue_sound, a, hr.flashSound) end
        end) end
        hr.play = { t = 0, last = os.clock(), target = t, burned = false }
        pcall(function() a:set_super_armor(true) end)   -- (4.16: until the end hold is over)
        hr.info = "rebuke on " .. tostring(t:get_GameObject():get_Name())
        note("Hellish Rebuke: " .. hr.info)
    end
    local function burn(t, now)
        if not now then   -- (4.15) the flinch first, the fire 0.1 s later
            hr.burnLater = { t = t, at = os.clock() + 0.1 }
        end
        if not now then
            if hr.flinch then pcall(function()
                local a = runtime.player()
                local hm = sdk.get_managed_singleton("app.HitManager")
                local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()
                info.Damage = hr.flinchDmg or 30
                info.DamageType, info.DamageActType, info.IsDirectDamageEnableAllDamageType = 6, 6, true   -- Hitback_M
                pcall(function() info.DamageReaction = hr.react end)
                pcall(function() info.OverwriteBlownType = 6 end)
                pcall(function() info.IsMagicAttack = true end)
                pcall(function() info.IsForceReceived = true end)            -- (4.16: through its attack's armour)
                pcall(function() info.IgnoreBalanceReactionCalc = true end)
                local ok = pcall(hm.call, hm, "directDamage", info, t["<Hit>k__BackingField"], a.character:get_GameObject(), false, a.character["<Hit>k__BackingField"])
                if not ok then hm:call("directDamage", info, t["<Hit>k__BackingField"], nil, false, nil) end
                note("Hellish Rebuke: flinch hit")
            end) end
            return
        end
        pcall(function() hr.watch = { addr = t:get_GameObject():get_address(), untilT = dbg.gclock() + 12.0, seen = {} } end)
        if hr.greenFire and hr.resSwaps[1] then pcall(hr.swap_flames, nil, false) end   -- (4.38) the last one's back first
        if hr.greenFire then local okS, errS = pcall(function()   -- (4.29) its flame files -> ours BEFORE it catches fire
            local n = hr.swap_flames(t:get_GameObject(), true)
            note(("Hellish Rebuke: %d flame file(s) of it -> hellfire"):format(n))
            if n == 0 then pcall(hr.dump_fx_data, t:get_GameObject(), "Pactblade_fx_data_enemy.json", tostring(t:get_GameObject():get_Name())) end
        end)
            if not okS then note("Hellish Rebuke: flame swap failed: " .. tostring(errS)) end
        end
        if hr.greenFire then pcall(function()   -- (4.20) the body glow: found 0.8 s later (and again at 2 s), green for 12 s
            hr.mat.go = t:get_GameObject():add_ref()
            hr.mat.scanAt, hr.mat.untilT, hr.mat.entries = dbg.gclock() + 0.05, dbg.gclock() + 12, nil
            hr.mat.rescanAt = dbg.gclock() + 2.0
            hr.fxScanAt, hr.fxScanT = dbg.gclock() + 1.0, t
        end) end   -- (4.15: its fire effects noted)
        pcall(function()
            if t:get_IsDead() then return end
            local req = sdk.create_instance("app.StatusConditionDef.RequestInfo"):add_ref()
            t["<StatusConditionCtrl>k__BackingField"]:call(
                "reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean)",
                hr.BURN, nil, req, false)
            note("Hellish Rebuke: the attacker burns")
        end)
    end
    function hr.fx_scan(t)   -- (4.21) every effect player near the burning target: object / parent / file
        local q = t:get_GameObject():get_Transform():get_Position()
        local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local list = scene:call("findComponents(System.Type)", sdk.typeof("via.effect.EffectPlayer"))
        local n = list and list:call("get_Length") or 0
        local seen, out = {}, {}
        for k = 0, n - 1 do
            pcall(function()
                local ep = list:call("get_Item", k)
                local go = ep:call("get_GameObject")
                local p = go:get_Transform():get_Position()
                if (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2 > 9 then return end
                local path = tostring(ep:call("get_ResourcePath") or "?")
                local par = "-"
                pcall(function() local pt = go:get_Transform():get_Parent(); par = pt and tostring(pt:get_GameObject():get_Name()) or "-" end)
                local key = tostring(go:get_Name()) .. "|" .. path
                if seen[key] then return end
                seen[key] = true
                out[#out + 1] = ("%s (parent %s): %s"):format(tostring(go:get_Name()), par, path)
            end)
        end
        note(("Hellish Rebuke: %d effect(s) within 3 m of the burning one:"):format(#out))
        for i = 1, math.min(#out, 14) do note("  " .. out[i]) end
        dbg.save("Pactblade_burn_fx.json", out)
    end
    function hr.burn_me()   -- (4.22, user's idea) me on fire; 1.2 s later my heat colours + effects are noted
        local a = runtime.player()
        local ch = a.character
        if hr.greenFire then pcall(function()   -- (4.29) my flame files -> ours first
            if hr.resSwaps[1] then hr.swap_flames(hr.mat.go, false) end
            note(("Hellish Rebuke test: %d flame file(s) of mine -> hellfire"):format(hr.swap_flames(ch:get_GameObject(), true)))
        end) end
        local req = sdk.create_instance("app.StatusConditionDef.RequestInfo"):add_ref()
        ch["<StatusConditionCtrl>k__BackingField"]:call(
            "reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean)",
            hr.BURN, nil, req, false)
        hr.watch = { addr = ch:get_GameObject():get_address(), untilT = dbg.gclock() + 6.0, seen = {} }
        hr.meAt = os.clock() + 1.2
        if hr.greenFire then   -- (4.24) my own burning in the hellfire colours too (to see the look on me)
            hr.mat.go = ch:get_GameObject():add_ref()
            hr.mat.scanAt, hr.mat.untilT, hr.mat.entries = dbg.gclock() + 0.05, dbg.gclock() + 12, nil
        end
        note("Hellish Rebuke test: I'm on fire")
    end
    function hr.me_report()
        local a = runtime.player()
        local go = a.character:get_GameObject()
        local ents, names = hr.mat_scan(go)
        local list = {}
        for k, n in pairs(names) do list[#list + 1] = k .. " x" .. n end
        note(("ME burning: %d heat colour slot(s): %s (e.g. %s)"):format(#ents, table.concat(list, ", "), tostring(hr.mat.sample)))
        hr.mat.sample = nil
        local out = {}
        local function ep_path(ep)   -- (4.25) its file, whichever way answers
            local p
            for _, how in ipairs({
                function() return ep:call("get_ResourcePath") end,
                function() return ep:call("get_Resource"):call("get_ResourcePath") end,
                function() return ep:call("get_Resource"):call("get_Resource"):call("get_ResourcePath") end,
                function() return ep:get_field("Resource"):call("get_ResourcePath") end }) do
                local ok, v = pcall(how)
                if ok and v ~= nil and tostring(v) ~= "" then p = tostring(v); break end
            end
            return p or "?"
        end
        hr.ep_path = ep_path
        local function walk(tr, depth)   -- my child objects with effect players (ALL of them)
            if depth > 8 then return end
            pcall(function()
                local cgo = tr:get_GameObject()
                local comps = cgo:call("get_Components")
                for _, c in ipairs(comps and comps:get_elements() or {}) do
                    pcall(function()
                        if c:get_type_definition():get_full_name() ~= "via.effect.EffectPlayer" then return end
                        local st = "?"
                        pcall(function() st = tostring(c:call("get_Action")) end)
                        out[#out + 1] = ("%s: %s (state %s)"):format(tostring(cgo:get_Name()), ep_path(c), st)
                    end)
                end
            end)
            local c = tr:get_Child()
            while c do walk(c, depth + 1); c = c:get_Next() end
        end
        pcall(walk, go:get_Transform(), 0)
        note(("ME burning: %d effect player(s) on my objects"):format(#out))
        for i = 1, math.min(#out, 24) do note("  " .. out[i]) end
        dbg.save("Pactblade_burn_me.json", { colours = list, effects = out })
        pcall(function()   -- (4.32) the effect data WHILE burning + what the manager has on top
            local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
            local conts = mgr.ExternalDataContainers
            local paths = {}
            for ci = 0, conts:get_Count() - 1 do pcall(function() paths[#paths + 1] = ci .. "=" .. tostring(conts[ci].DataContainerPath) end) end
            note(("ME burning: %d data containers: %s"):format(conts:get_Count(), table.concat(paths, ", "):sub(1, 900)))
            pcall(function() note("ME burning: own DataContainer " .. tostring(mgr.DataContainerPath) .. " / request " .. tostring(mgr.RequestDataContainer)) end)
            pcall(function()
                local cl = mgr._ExtenralDataContainerCommandList
                note(("ME burning: %d pending container command(s)"):format(cl and cl:get_Count() or -1))
            end)
        end)
        pcall(hr.dump_fx_data)
    end
    re.on_frame(function()
        if hr.meAt and os.clock() >= hr.meAt then hr.meAt = nil; local ok, e = pcall(hr.me_report); if not ok then note("ME burning report failed: " .. tostring(e)) end end
    end)
    hr.mat = { hue = 120, hot = 62 }   -- (4.20) the burning glow on its body, green; 4.23: yellow where it was hottest
    hr.fireTone = "gy2"   -- (4.34) the flame files: gy2 = inverted layers like the rest, gy = inverted layers flipped
    hr.flamePlayers, hr.flameTint, hr.useTint = {}, { 0.45, 1.0, 0.25 }, false   -- (4.28) the game's flame players, multiplied by this
    hr.resSwaps = {}   -- (4.29) { el, i, orig } per swapped flame file
    function hr.each_fx_data(go, fn)   -- (4.30/4.33) every effect data element of this character: fn(contIndex, key, id, element, holder)
        local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
        if not mgr then return end
        local function walk_holder(ci, ed)   -- a manager or an external data container: its standard + expert data
            pcall(function()
                local map = ed.StandardDataMap
                local entries = map and map._entries
                local cnt = 0
                pcall(function() cnt = entries:call("get_Length") end)
                if cnt == 0 then pcall(function() cnt = #entries:get_elements() end) end
                for k = 0, cnt - 1 do
                    pcall(function()
                        local e = entries[k]
                        local key, sd = e.key, e.value
                        if not sd then return end
                        local ids = sd:call("getElementIDList")
                        for q = 0, (ids and ids:get_Count() or 0) - 1 do
                            local id = ids:get_Item(q)
                            local el = sd:call("getElementFromID", id)
                            if el then fn(ci, key, id, el, ed) end
                        end
                    end)
                end
            end)
            pcall(function()
                local list = ed.ExpertProviderInfoList
                for k = 0, (list and list:get_Count() or 0) - 1 do
                    pcall(function()
                        local data = list[k]._Data
                        local tn = data and data:get_type_definition():get_name() or "?"
                        local els = data and data.Elements
                        for q = 0, (els and els:get_Count() or 0) - 1 do
                            pcall(function()
                                local el = els[q]
                                local id = "?"
                                pcall(function() id = el.ID end)
                                fn(ci, "expert " .. tn, id, el, ed)
                            end)
                        end
                    end)
                end
            end)
        end
        walk_holder(-1, mgr)   -- (4.33) the manager's own set (13_chcm_pl_Ref.pfb)
        local conts = mgr.ExternalDataContainers
        for ci = 0, conts:get_Count() - 1 do pcall(function() walk_holder(ci, conts[ci]) end) end
    end
    function hr.dump_fx_data(go, file, who)   -- (4.35) any character (default: me)
        go = go or runtime.player().character:get_GameObject()
        file, who = file or "Pactblade_fx_data.json", who or "me"
        local out, n = {}, 0
        pcall(function()
            local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
            note(("fx data (%s): manager %s, own set %s, %d external set(s)"):format(who, tostring(mgr ~= nil),
                mgr and tostring(mgr.DataContainerPath) or "-", mgr and mgr.ExternalDataContainers:get_Count() or 0))
        end)
        local shown = 0
        hr.each_fx_data(go, function(ci, key, id, el, ed)
            n = n + 1
            local files = {}
            pcall(function()
                for i = 0, el:call("getResourcesCount") - 1 do
                    local h = el:call("getResources", i)
                    files[#files + 1] = h and tostring(h:call("get_ResourcePath")) or "nil"
                end
            end)
            local line = ("%d %s | key %s | element %s | %s"):format(ci, tostring(ed.DataContainerPath or "?"), tostring(key), tostring(id), table.concat(files, ", "))
            out[#out + 1] = line
            if table.concat(files, ","):lower():find("badstatus", 1, true) and shown < 40 then shown = shown + 1; note("fx data: " .. line) end
        end)
        dbg.save(file, out)
        note(("fx data: %d element(s) on %s (data/%s)"):format(n, who, file))
    end
    function hr.swap_flames(go, on)   -- the bad-status flame files of THIS character -> ours (on) / back (off)
        local n = 0
        if not on then   -- (4.38) back: no GameObject needed (the old target may be dead / gone)
            for _, sw in ipairs(hr.resSwaps) do pcall(function() sw.el:call("setResources", sw.i, sw.orig); n = n + 1 end) end
            hr.resSwaps = {}
            return n
        end
        local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
        if not mgr then return 0 end
        hr.resUntil = dbg.gclock() + 14
        hr.each_fx_data(go, function(ci, key, id, el)
                    pcall(function()
                        for i = 0, el:call("getResourcesCount") - 1 do
                            local h = el:call("getResources", i)
                            local path = h and tostring(h:call("get_ResourcePath") or "") or ""
                            local lp = path:lower()
                            local num, pre = lp:match("ch00_badstatus_000_(%d+)"), "bs"
                            if num and not ({ ["10"] = 1, ["11"] = 1, ["12"] = 1, ["15"] = 1, ["16"] = 1, ["17"] = 1 })[num] then num = nil end   -- (4.34: fire only)
                            if not num then   -- (4.36) enemy humans (13_chcm_em_pl_Ref): Common/BadStatus 100_10-12
                                num, pre = lp:match("cm_badstatus_100_(%d+)"), "bc"
                                if num and not ({ ["10"] = 1, ["11"] = 1, ["12"] = 1 })[num] then num = nil end
                            end
                            if not num then   -- (4.37) large monsters (13_chcm_em_L_*_Ref): Common/BadStatus 101_10-14
                                num, pre = lp:match("cm_badstatus_101_(%d+)"), "bl"
                                if num and not ({ ["10"] = 1, ["11"] = 1, ["12"] = 1, ["13"] = 1, ["14"] = 1 })[num] then num = nil end
                            end
                            if num then
                                local ours = ("vfx/effects/pactblade/pb_%s%s_%s.efx"):format(pre, num, pre ~= "bs" and "gy2" or (hr.fireTone or "gy2"))
                                if hr.fireRes[ours] == nil then
                                    local r = sdk.create_resource("via.effect.EffectResource", ours)
                                    hr.fireRes[ours] = r and r:add_ref() or false
                                end
                                if hr.fireRes[ours] then
                                    note("Hellish Rebuke: flame file " .. path:match("[^/]+$") .. " -> " .. ours:match("[^/]+$"))
                                    hr.resSwaps[#hr.resSwaps + 1] = { el = el:add_ref(), i = i, orig = h:add_ref() }
                                    el:call("setResources", i, hr.fireRes[ours]:create_holder("via.effect.EffectResourceHolder"):add_ref())
                                    n = n + 1
                                end
                            end
                        end
                    end)
        end)
        return n
    end
    re.on_pre_application_entry("BeginRendering", function()
        if hr.resSwaps[1] and dbg.gclock() > (hr.resUntil or 0) then   -- (4.29/4.38) the burn is over: the files back
            local n = hr.swap_flames(nil, false)
            note(("Hellish Rebuke: %d flame file(s) back to the game's"):format(n))
        end
        if not hr.useTint then hr.flamePlayers = {}; return end
        if not next(hr.flamePlayers) then return end
        if dbg.gclock() > (hr.mat.untilT or 0) then hr.flamePlayers = {}; return end
        local col = via_colour({ hr.flameTint[1], hr.flameTint[2], hr.flameTint[3], 1 })
        for addr, ep in pairs(hr.flamePlayers) do
            local ok = pcall(function() ep:set_Color(col) end)
            if not ok then hr.flamePlayers[addr] = nil end
        end
    end)
    function hr.mat_scan(go)
        local out, names = {}, {}
        for _, mesh in ipairs(dbg.ai.meshes(go)) do
            pcall(function()
                for m = 0, mesh:call("get_MaterialNum") - 1 do
                    for v = 0, mesh:call("getMaterialVariableNum", m) - 1 do
                        pcall(function()
                            local nm = tostring(mesh:call("getMaterialVariableName", m, v))
                            if not nm:find("^Heat_") or not nm:find("Color") then return end   -- (4.22: the burning set only)
                            local f = mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", m, v)
                            out[#out + 1] = { mesh = mesh:add_ref(), m = m, v = v }
                            names[nm] = (names[nm] or 0) + 1
                            if not hr.mat.sample then hr.mat.sample = ("%s = %.2f %.2f %.2f %.2f"):format(nm, f.x, f.y, f.z, f.w) end
                        end)
                    end
                end
            end)
        end
        return out, names
    end
    re.on_pre_application_entry("BeginRendering", function()
        if hr.fxScanAt and dbg.gclock() >= hr.fxScanAt then
            hr.fxScanAt = nil
            local ok, e = pcall(hr.fx_scan, hr.fxScanT)
            if not ok then note("Hellish Rebuke: effect scan failed: " .. tostring(e)) end
        end
        local M = hr.mat
        if M.scanAt and dbg.gclock() >= M.scanAt and M.go then
            M.scanAt = nil
            pcall(function()
                local names
                M.entries, names = hr.mat_scan(M.go)
                local list = {}
                for k, n in pairs(names) do list[#list + 1] = k .. " x" .. n end
                table.sort(list)
                note(("Hellish Rebuke: heat colours on its body: %d slot(s): %s (e.g. %s)"):format(#M.entries, table.concat(list, ", "), tostring(M.sample)))
                M.sample = nil
            end)
        end
        if not M.entries or dbg.gclock() > (M.untilT or 0) then return end
        for i = #M.entries, 1, -1 do
            local e = M.entries[i]
            local ok = pcall(function()
                local f = e.mesh:call("getMaterialFloat4(System.UInt32, System.UInt32)", e.m, e.v)
                local h, s0, v = dbg.ai.hsv(f.x, f.y, f.z)
                if v <= 0.001 or s0 < 0.2 or (h > 50 and h < 150) then return end   -- (dark / white / already ours)
                local L = (0.299 * f.x + 0.587 * f.y + 0.114 * f.z) / v   -- (4.23) how yellow the original fire colour is
                local w = math.max(0, math.min(1, (L - 0.40) / 0.40))
                local r, g, b = dbg.ai.rgb(M.hue + (M.hot - M.hue) * w, s0, v)
                e.mesh:call("setMaterialFloat4(System.UInt32, System.UInt32, via.Float4)", e.m, e.v, Vector4f.new(r, g, b, f.w))
            end)
            if not ok then table.remove(M.entries, i) end
        end
    end)
    re.on_pre_application_entry("LateUpdateBehavior", function()   -- (4.26) its flames: the burning one's own effect players
        local M = hr.mat
        if dbg.gclock() > (M.untilT or 0) and next(hr.fireSwapped) then   -- (the window is over: ours go)
            for addr, f in pairs(hr.fireSwapped) do if type(f) == "table" then pcall(function() f.go:call("destroy(via.GameObject)", f.go) end) end end
            hr.fireSwapped = {}
        end
        if not hr.greenFire or not M.go or dbg.gclock() > (M.untilT or 0) or dbg.gclock() < (M.fxNext or 0) then return end
        M.fxNext = dbg.gclock() + 0.1
        local seenNow = {}
        local function swap(ep)
            local addr = ep:get_address()
            local path
            for _, how in ipairs({
                function() return ep:call("get_ResourcePath") end,
                function() return ep:call("get_Resource"):call("get_ResourcePath") end,
                function() return ep:call("get_Resource"):call("get_Resource"):call("get_ResourcePath") end }) do
                local ok, v = pcall(how)
                if ok and v ~= nil and tostring(v) ~= "" then path = tostring(v); break end
            end
            local el = tostring(path):lower():match("badstatus_000_(%d+)")
            if not el then return end
            seenNow[addr] = true
            hr.flamePlayers[addr] = ep   -- (4.28: tinted every frame in BeginRendering)
            if true then return end   -- (4.28: no copy of ours - it can't emit from the body)
            if hr.fireSwapped[addr] then return end
            local ours = ("vfx/effects/pactblade/pb_bs%s_%s.efx"):format(el, hr.tone or "gy")
            if hr.fireRes[ours] == nil then
                local r = sdk.create_resource("via.effect.EffectResource", ours)
                hr.fireRes[ours] = r and r:add_ref() or false
            end
            if not hr.fireRes[ours] then return end
            local ogo = ep:call("get_GameObject")
            local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_hellfire", 0)
            go = go:add_ref(); go:call(".ctor"); go:set_Name("Pactblade_hellfire")
            local tr, otr = go:get_Transform(), ogo:get_Transform()
            pcall(function()   -- (beside the game's flame object: the same parent and place)
                local par = otr:get_Parent()
                if par then
                    local ok = pcall(tr.call, tr, "setParent(via.Transform, System.Boolean)", par, false)
                    if not ok then pcall(tr.call, tr, "set_Parent", par) end
                end
                tr:set_Position(otr:get_Position())
                tr:set_Rotation(otr:get_Rotation())
            end)
            local mine = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
            mine:call("set_Resource", hr.fireRes[ours]:create_holder("via.effect.EffectResourceHolder"):add_ref())
            pcall(function() mine:call("set_AutoStart", true) end)
            hr.fireSwapped[addr] = { go = go, otr = otr:add_ref() }
            note("Hellish Rebuke: hellfire flames on it (" .. el .. ")")
        end
        local function walk(tr, depth)
            if depth > 8 then return end
            pcall(function()
                local comps = tr:get_GameObject():call("get_Components")
                for _, c in ipairs(comps and comps:get_elements() or {}) do
                    pcall(function() if c:get_type_definition():get_full_name() == "via.effect.EffectPlayer" then swap(c) end end)
                end
            end)
            local c = tr:get_Child()
            while c do walk(c, depth + 1); c = c:get_Next() end
        end
        pcall(walk, M.go:get_Transform(), 0)
        for addr, f in pairs(hr.fireSwapped) do   -- ours follow the game's flame object; gone with it
            if type(f) == "table" then
                if not seenNow[addr] then
                    pcall(function() f.go:call("destroy(via.GameObject)", f.go) end)
                    hr.fireSwapped[addr] = nil
                else
                    pcall(function() local t2 = f.go:get_Transform(); t2:set_Position(f.otr:get_Position()); t2:set_Rotation(f.otr:get_Rotation()) end)
                end
            end
        end
    end)
    re.on_pre_application_entry("LateUpdateBehavior", function()   -- (4.18) its burning effects get our green files
        if #hr.fireConts == 0 then return end
        local now = os.clock()
        for i = #hr.fireConts, 1, -1 do
            local fc = hr.fireConts[i]
            if dbg.gclock() > fc.untilT then table.remove(hr.fireConts, i)
            else pcall(function()
                local list = fc.c:call("getAllPlayers")
                for q = 0, (list and list:call("get_Count") or 0) - 1 do
                    pcall(function()
                        local pl = list:call("get_Item", q)
                        local addr = pl:get_address()
                        if hr.fireSwapped[addr] then return end
                        local path = tostring(pl:call("get_ResourcePath") or "")
                        local el = path:lower():match("badstatus_000_(%d+)")
                        if not el then return end
                        local ours = ("vfx/effects/pactblade/pb_bs%s_g120.efx"):format(el)
                        if not hr.fireRes[ours] then
                            local r = sdk.create_resource("via.effect.EffectResource", ours)
                            if not r then hr.fireRes[ours] = false; return end
                            hr.fireRes[ours] = r:add_ref()
                        end
                        if not hr.fireRes[ours] then return end
                        hr.fireSwapped[addr] = true
                        pl:call("set_Resource", hr.fireRes[ours]:create_holder("via.effect.EffectResourceHolder"):add_ref())
                        pcall(function() pl:call("set_AutoStart", true) end)
                        note("Hellish Rebuke: the fire made green (" .. el .. ")")
                    end)
                end
            end) end
        end
    end)
    re.on_pre_application_entry("LateUpdateBehavior", function()   -- (4.15) the fire after the flinch
        local b = hr.burnLater
        if not b or os.clock() < b.at then return end
        hr.burnLater = nil
        burn(b.t, true)
    end)
    for _, spec in ipairs({ { "app.StatusConditionActionEffectCall", "setEffect" }, { "app.StatusConditionActionEffectCallEndurance", "callEffect" } }) do
        pcall(function()   -- (4.17) the status effect call itself: which set / provider / element
            local td = sdk.find_type_definition(spec[1])
            for _, m in ipairs(td:get_methods()) do
                if m:get_name() == spec[2] then
                    sdk.hook(m, function(args)
                        local w = hr.watch
                        if not w or dbg.gclock() > w.untilT + 1.0 then return end
                        pcall(function()
                            local this = sdk.to_managed_object(args[2])
                            local ap = this.ActionParam
                            local vals = {}
                            for _, f in ipairs({ "DataContainerIndex", "ProviderID", "ElementID", "OnceProviderID", "OnceElementID", "_DataContainerIndex", "_ProviderID", "_ElementID" }) do
                                pcall(function() local v = ap[f]; if v ~= nil then vals[#vals + 1] = f .. " " .. tostring(v) end end)
                            end
                            local key = spec[2] .. table.concat(vals, ",")
                            if w.seen[key] then return end
                            w.seen[key] = true
                            note(("Hellish Rebuke status fx: %s.%s %s"):format(spec[1]:match("%.(%w+)$"), spec[2], table.concat(vals, ", ")))
                        end)
                    end, function(r) return r end)
                end
            end
        end)
    end
    pcall(function()   -- (4.15) which effects the burning target starts (to make its fire green)
        local td = sdk.find_type_definition("via.effect.script.ObjectEffectManager2")
        for _, m in ipairs(td:get_methods()) do
            local nm = m:get_name()
            local okR, rt = pcall(function() return m:get_return_type():get_full_name() end)
            if (nm == "requestEffect" or nm == "requestEffectInternal") and okR and rt == "via.effect.script.CreatedEffectContainer" then
                sdk.hook(m, function(args)
                    local st = thread.get_hook_storage()
                    st.hrW = nil
                    local w = hr.watch
                    if not w or dbg.gclock() > w.untilT then return end
                    pcall(function()
                        local go = sdk.to_managed_object(args[2]):call("get_GameObject")
                        if go:get_address() ~= w.addr then return end
                        local id = "?"
                        pcall(function() local e = sdk.to_managed_object(args[3]); id = ("%d/%d/%d"):format(e.DataContainerIndex, e.ContainerID, e.ElementID) end)
                        local set = "?"
                        pcall(function()
                            local e = sdk.to_managed_object(args[3])
                            set = tostring(sdk.to_managed_object(args[2]).ExternalDataContainers[e.DataContainerIndex].DataContainer:get_Path())
                        end)
                        st.hrW = { id = id, set = set }
                    end)
                end, function(rv)
                    local st = thread.get_hook_storage()
                    local r = st.hrW
                    st.hrW = nil
                    if r and hr.greenFire and r.id:match("^%d+/10/") then   -- (4.18) a bad-status effect on it: made green
                        pcall(function() hr.fireConts[#hr.fireConts + 1] = { c = sdk.to_managed_object(rv):add_ref(), untilT = dbg.gclock() + 15 } end)
                    end
                    if r and hr.watch and not hr.watch.seen[r.id] then
                        hr.watch.seen[r.id] = true
                        local files = {}
                        pcall(function()
                            local c = sdk.to_managed_object(rv)
                            local list = c:call("getAllPlayers")
                            for q = 0, (list and list:call("get_Count") or 0) - 1 do
                                pcall(function() files[#files + 1] = tostring(list:call("get_Item", q):call("get_ResourcePath")) end)
                            end
                        end)
                        note(("Hellish Rebuke burn fx: %s from %s -> %s"):format(r.id, r.set, table.concat(files, ", ")))
                    end
                    return rv
                end)
            end
        end
    end)
    local function spark(a, at, scale, secs, kind)   -- (4.10) green fire popping off my left palm; 4.11: or a burst at 'at'
        pcall(function()
            local path = ("vfx/effects/pactblade/pb_%s_%s.efx"):format(kind or "torch", hr.tone or "gy")   -- (4.23: green with a yellow core)   -- (4.14: the bolt's own effects, green; 4.15: the palm = a torch's flame)
            if not hr.res[path] then
                local r = sdk.create_resource("via.effect.EffectResource", path)
                if not r then if not hr.noFile then hr.noFile = true; note("Hellish Rebuke: the green spark file is not loaded (restart the game for the pak)") end; return end
                hr.res[path] = r:add_ref()
            end
            local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_rebuke", 0)
            go = go:add_ref(); go:call(".ctor"); go:set_Name("Pactblade_rebuke")
            local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
            ep:call("set_Resource", hr.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref())
            pcall(function() ep:call("set_AutoStart", true) end)
            local sc = scale or hr.sparkScale
            go:get_Transform():set_LocalScale(Vector3f.new(sc, sc, sc))
            if at then go:get_Transform():set_Position(at) end
            hr.sparks[#hr.sparks + 1] = { go = go, untilT = os.clock() + (secs or hr.sparkSecs), fixed = at ~= nil }
        end)
    end
    re.on_pre_application_entry("LateUpdateBehavior", function()   -- (4.14) the flash's material mode ends
        local f = hr.flashOff
        if not f or os.clock() < f.at then return end
        hr.flashOff = nil
        pcall(function() f.mgr:call("finishMaterialMode(System.UInt32, app.MaterialInterpolationRequestManager.RequestListCategory, System.Int32, System.Int32)", hr.flashMode, hr.flashCat, -1, -1) end)
    end)
    re.on_pre_application_entry("LateUpdateBehavior", function()   -- the sparks follow the palm, then go
        if #hr.sparks == 0 then return end
        local palm
        pcall(function() palm = runtime.player().game_object:get_Transform():getJointByName(PB.PALM):get_Position() end)
        for i = #hr.sparks, 1, -1 do
            local sp = hr.sparks[i]
            if os.clock() > sp.untilT or not palm then pcall(function() sp.go:call("destroy(via.GameObject)", sp.go) end); table.remove(hr.sparks, i)
            elseif not sp.fixed then pcall(function() sp.go:get_Transform():set_Position(palm) end) end
        end
    end)
    re.on_pre_application_entry("UpdateBehavior", function()
        local o = hr.open
        if not o then return end
        local a = runtime.player()
        if not a or not live.on then hr.open = nil; return end
        if os.clock() > o.untilT then hr.open = nil; return end
        local cur = a:current_action(0)
        if not o.noted then o.noted = true; note("Hellish Rebuke window: hit by " .. tostring(o.who:get_GameObject():get_Name()) .. " (my action " .. tostring(cur) .. ") " .. tostring(o.kind or "")) end
        if not a:button_pressed("Interact") then return end
        if dbg.leapOpen and dbg.hex_put then   -- (1.0 user: both fired on one press) the Hex window is open: Interact = Hex
            if not o.hexNoted then o.hexNoted = true; note("Hellish Rebuke: the press goes to Hex (its window is open)") end
            return
        end
        if big_reaction(cur) then hr.open = nil; note("Hellish Rebuke: not now (" .. tostring(cur) .. " - more than a flinch)"); return end
        local busy, bc = dbg.busy_action(a)
        if busy and not tostring(bc):find("dmg", 1, true) then hr.open = nil; note("Hellish Rebuke: not now (" .. tostring(bc) .. ")"); return end
        if not (dbg.misty and dbg.misty.alive(o.who)) then hr.open = nil; return end
        if dbg.gclock() - hr.lastCast < hr.cooldown then   -- (4.18 user: once every 6 s)
            hr.open = nil
            note(("Hellish Rebuke: not ready (%.1f s left)"):format(hr.cooldown - (dbg.gclock() - hr.lastCast)))
            return
        end
        hr.lastCast = dbg.gclock()
        cast(a, o.who)
    end)
    re.on_frame(function()   -- (4.13) the Mage cast bank (9112) kept on me while Pactblade is on
        if not live.on or os.clock() < (hr.nextBank or 0) or not dbg.castT then return end
        hr.nextBank = os.clock() + 5
        pcall(function() dbg.castT.bank(runtime.player()) end)
    end)
    local function motion_ready(a)
        local ok, yes = pcall(function()
            local info = sdk.create_instance("via.motion.MotionInfo", true)
            return a.character:get_Motion():call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", hr.bank, hr.motion, info)
        end)
        return ok and yes
    end
    re.on_pre_application_entry("UpdateMotion", function()   -- the clip on the layer, at our time (AnimPlayer's way)
        local pl = hr.play
        if not pl then return end
        if not pl.ready then   -- (4.13: its bank loaded and the motion there - at most 0.4 s)
            local a = runtime.player()
            pcall(function() if dbg.castT then dbg.castT.bank(a) end end)
            if motion_ready(a) then pl.ready = true; pl.last = os.clock()
            elseif os.clock() - (pl.born or os.clock()) < 0.4 then pl.born = pl.born or os.clock(); return end
            pl.ready = true
        end
        pcall(function()
            local a = runtime.player()
            local L = a.character.FullBodyLayer
            local now = os.clock()
            pl.t = pl.t + (now - pl.last) * hr.fps * hr.speed
            pl.last = now
            pl.started = pl.started or now
            local cap = hr.frames / (hr.fps * hr.speed) + hr.holdEnd + 0.6   -- (4.38) never longer than this
            if now - pl.started > cap then pl.t = hr.frames; pl.holdUntil = now; note(("Hellish Rebuke: the clip cut at %.2f s (cap)"):format(now - pl.started)) end
            if pl.t >= hr.frames then
                pl.holdUntil = pl.holdUntil or (now + hr.holdEnd)   -- (4.16: held on the last frame, the flame in my hand)
                for _, sp in ipairs(hr.sparks) do if not sp.fixed then sp.untilT = math.max(sp.untilT, pl.holdUntil) end end
                if now < pl.holdUntil then
                    pcall(L.call, L, "set_Speed", 0.0)
                    pcall(L.call, L, "set_Frame", hr.frames - 0.5)
                    return
                end
                hr.play = nil
                pcall(L.call, L, "set_Speed", 1.0)
                pcall(function() a:set_super_armor(false) end)
                pcall(function() a:request_action("NormalLocomotion", 0) end)
                note(("Hellish Rebuke: the clip ended after %.2f s (action now %s)"):format(now - pl.started, tostring(a:current_action(0))))
                return
            end
            if L:call("get_MotionBankID") ~= hr.bank or L:call("get_MotionID") ~= hr.motion then
                L:call("changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)",
                    hr.bank, hr.motion, pl.t + 0.0, pl.t < 1 and 6.0 or 0.0, 0, 0)
                local okE, ef = pcall(L.call, L, "get_EndFrame")
                if L:call("get_MotionBankID") ~= hr.bank or not okE or not ef or ef <= 0 then   -- (4.12: its bank isn't loaded)
                    hr.play = nil
                    pcall(L.call, L, "set_Speed", 1.0)
                    pcall(function() a:set_super_armor(false) end)
                    pcall(function() a:request_action("NormalLocomotion", 0) end)
                    note(("Hellish Rebuke: animation %d/%d isn't loaded on me - played without it"):format(hr.bank, hr.motion))
                    if not pl.burned then pl.burned = true; burn(pl.target); if hr.spark then spark(a) end end
                    return
                end
            end
            L:call("set_Speed", 0.0)
            L:call("set_Frame", pl.t + 0.0)
            if not pl.burned and pl.t >= hr.burnAt then
                pl.burned = true
                burn(pl.target)
                if hr.spark then spark(a) end
                if hr.boom then pcall(function()   -- (4.11) the fire explosion on it (look + sound)
                    local t = pl.target
                    local at
                    pcall(function() at = t.Hip:get_Position() end)
                    if not at then local q = t:get_GameObject():get_Transform():get_Position(); at = Vector3f.new(q.x, q.y + 1.0, q.z) end
                    spark(a, at, hr.boomScale, 3.0, "43")
                    spark(a, at, hr.boomScale, 2.0, "40")
                    if hr.boomSound and dbg.smite and dbg.smite.sound then pcall(dbg.smite.sound, a, hr.SOUND, "Hellish Rebuke") end
                end) end
            end
        end)
    end)
end)()


------------------------------------------------------------------------
-- (4.98) SAVE + ONLINE GUARD (the Dragonforge mod's, MODLOG 2026-10-16): the save file and the online pawn / owner data
-- are built from plain items - the sword's magick / element and the guise chest's bonus come off while they are built.
------------------------------------------------------------------------
;(function()
    local G = { saveDepth = 0, onlineDepth = 0, saving = false, builds = 0, saves = 0, last = "-" }
    dbg.guard = G
    local function strip(why)
        dbg.guardHold = true
        G.stripAt = os.clock()
        pcall(sword_restore)
        G.chestWas = false
        pcall(function()
            local gu = dbg.guise
            if gu and gu.bonus and gu.bonus.itemMod then G.chestWas = true; gu.armour_bonus(false) end
        end)
        G.last = os.date("%H:%M:%S") .. " " .. why
        note(("guard: %s - sword plain, guise chest %s (saves %d, online builds %d)"):format(why, G.chestWas and "plain" or "untouched", G.saves, G.builds))
    end
    local function apply()
        dbg.guardHold = false   -- the sword re-applies itself (sword_update, within 0.5 s)
        if G.chestWas then
            G.chestWas = false
            pcall(function() local gu = dbg.guise; if gu and gu.on and gu.bonus.on then gu.armour_bonus(true) end end)
        end
    end
    local function save_pre()
        if G.saveDepth == 0 then G.saving = true; G.saves = G.saves + 1; if G.onlineDepth == 0 then strip("save") end end
        G.saveDepth = G.saveDepth + 1
    end
    local function save_post()
        G.saveDepth = math.max(0, G.saveDepth - 1)
        if G.saveDepth > 0 then return end
        G.saving = false
        if G.onlineDepth == 0 then apply() end
    end
    local function online_pre(name)
        if G.onlineDepth == 0 and G.saveDepth == 0 then strip("online " .. name) end
        G.onlineDepth = G.onlineDepth + 1
        G.builds = G.builds + 1
    end
    local function online_post()
        G.onlineDepth = math.max(0, G.onlineDepth - 1)
        if G.onlineDepth == 0 and not G.saving then apply() end   -- (saving triggers the builders too)
    end
    pcall(function()
        local sm_t = sdk.find_type_definition("app.SaveDataManager")
        for _, m in ipairs({ "save", "saveGameSaveData" }) do
            pcall(sdk.hook, sm_t:get_method(m), function() pcall(save_pre) end, function(r) pcall(save_post); return r end)
        end
        local im_t = sdk.find_type_definition("app.ItemManager")
        for _, m in ipairs({ "saveGameSaveData", "saveGameSaveDataTarget", "fillStorageSaveData", "makeLoopSaveData" }) do
            pcall(sdk.hook, im_t:get_method(m), function() pcall(save_pre) end, function(r) pcall(save_post); return r end)
        end
    end)
    local function hook_online(tdname, match)
        local td = sdk.find_type_definition(tdname)
        if not td then return end
        for _, m in ipairs(td:get_methods()) do
            local name = m:get_name()
            if match(name) then
                pcall(sdk.hook, m, function() pcall(online_pre, name) end, function(r) pcall(online_post); return r end)
            end
        end
    end
    pcall(hook_online, "app.OnlinePawnDataFormatter", function(n)
        return n:find("^updatePlaydataFrom") or n:find("^getEquipSnapshot") or n == "makeToUploadValidationWork"
    end)
    pcall(hook_online, "app.PawnServerController", function(n)
        return n == "registerSupportPawnUploadData" or n == "registerSupportPawnDismissal" or n == "registerSupportPawnLeaveParty"
            or n == "registerSupportPawnLost"
    end)
    re.on_script_reset(function() dbg.guardHold = false end)
    -- (1.0.2 user: Bolt / Blast / Slash wave did ~no damage = the sword stayed plain: a save's end never came) the guard
    -- lets go by itself after 5 s - a save / an upload build takes far less
    re.on_frame(function()
        if not dbg.guardHold or os.clock() - (G.stripAt or 0) < 5 then return end
        note(("guard: no end seen after 5 s (save depth %d, online %d) - the sword gets its magick back"):format(G.saveDepth, G.onlineDepth))
        G.saveDepth, G.onlineDepth, G.saving = 0, 0, false
        apply()
    end)
end)()
;(function()   -- (4.100) a rest (inn / camp) ends the Otherworldly Guise
    local function rested(where)
        local gu = dbg.guise
        if gu and gu.on and not gu.ending then pcall(gu.stop, "rested (" .. where .. ")") end
    end
    for _, t in ipairs({ { "app.BarRoomTimeSkipStateBase", { "onBarRoomTimeSkipBeforeRestart", "onBeforeRestart" }, "inn" },
                         { "app.CampStateBase", { "onCampBeforeRestart", "onBeforeRestart" }, "camp" } }) do
        pcall(function()
            local td = sdk.find_type_definition(t[1])
            for _, m in ipairs(td:get_methods()) do
                for _, want in ipairs(t[2]) do
                    if m:get_name() == want then pcall(sdk.hook, m, function() pcall(rested, t[3]) end, function(r) return r end) end
                end
            end
        end)
    end
end)()


------------------------------------------------------------------------
-- (4.99) SKILL NAMES + DESCRIPTIONS in the game's menus (VSB's text.lua way): the Fighter skills Pactblade takes over
-- show Pactblade's text - only while Pactblade is active, only in the player's own menus.
------------------------------------------------------------------------
;(function()
    local guid = require("DragonCore.game.guid")
    local T = { on = not dbg.INTEGRATED, playerMenu = false, next = {} }   -- (i-0.1: off - VSB names its own skills)
    dbg.skilltext = T
    -- the name message GUIDs of every Fighter skill (base / upgraded / DLC level), from the game's message files
    local NAME_GUIDS = {
        Job01_BlinkStrike = { "8869c5e3-d7eb-49a3-9ba2-8f8057de0074", "cc879334-7c4b-4e3b-8fd7-c55f682a543f" },
        Job01_HindsightSlash = { "24ac6b02-f368-471b-bd8a-228b125eaaab", "b2ee6bd9-58e4-4b8a-96b1-ee3324a56ea8" },
        Job01_RisingLunge = { "62f7b035-6012-4529-ae36-ed713d7eadd8", "8d1d2cf7-cf93-4e63-8324-f4e6adac467c", "d5089a6d-23f0-44fb-9e66-ffd6a1b2661f" },
        Job01_FullMoonSlash = { "6b7e7c13-e4a0-409b-975d-e1daf34c509a", "8c02bf26-ac21-46e6-b689-bc5368e59527", "ce599592-463a-441a-b61d-f1fffdd64d23" },
        Job01_ViolentStab = { "2291852f-7d5f-4e96-9ec3-6710aeff7400", "56cc8a41-02b3-494b-91d8-2143190db018", "9b1d0d10-bed3-48ab-8c8a-5540b91b4cc2" },
        Job01_BravesRaid = { "ff2a95de-97df-42b9-989a-2ebe94420850" },
        Job01_ShieldSummons = { "31a8f6fd-149f-4144-843c-8efd511780bb", "76008f0a-2aab-4343-9e96-ceff23a16c1c" },
        Job01_Springboard = { "cc0be63a-9679-42e1-a2be-19a1f919c7e5", "cadebbae-12a3-4edc-a19d-22d6ff52eb46" },
        Job01_CymbalAttack = { "24a7e7fb-1b9d-4589-abf2-a1e17ac5361e", "ba457603-e590-447d-918b-f3100f696a90" },
        Job01_ShieldCounter = { "ca63840d-64be-48ee-a8b9-dfe836620fbe", "1214e931-0c8e-461f-aca4-e8234a62589d", "116cf151-1b06-47ca-a47a-beb90830012b" },
        Job01_FullMoonGuard = { "301c7d27-545a-45ac-8e3a-4a3e37b6d20e", "1090741b-82f3-4a78-b47e-bf12088cd5e4" },
        Job01_DivineDefense = { "43f96b14-db97-48ae-b6bb-2133bb5382e0", "a9ac7e70-cd80-43c5-8f8e-8bfeb3a56d35" },
    }
    local TEXT = {
        smite = { "Eldritch Smite", "Channel your patron's power into a crushing overhead blow that hurls even great foes to the ground." },
        slash = { "Eldritch Slash", "Unleash a sweeping arc of eldritch force that cleaves foes from afar." },
        blast = { "Eldritch Blast", "Thrust out your off hand and loose a searing beam of eldritch energy. Can be used mid-air." },
        brew = { "Tasha's Caustic Brew", "Conjure a torrent of acid that washes over the foes before you, poisoning them." },
        guise = { "Tasha's Otherworldly Guise", "Cloak yourself in a spectral armour from beyond. Bolsters defence, wards off flame and poison, and lets you levitate." },
        combo = { "Archfey Combo", "A fey-born flurry: vanish and strike from every side in quick succession." },
        dive = { "Misty Dive", "Vanish into mist and plunge down upon a foe from above." },
        strike = { "Misty Strike", "Step through the mist behind a foe and strike before they can turn." },
    }
    -- (4.103) the English vanilla names of every level (for texts that carry no message id)
    local VANILLA = {
        Job01_BlinkStrike = { "Blink Strike", "Burst Strike" }, Job01_HindsightSlash = { "Hindsight Slash", "Hindsight Sweep" },
        Job01_RisingLunge = { "Airward Slash", "Cloudward Slash", "Cloudfall Strike" },
        Job01_FullMoonSlash = { "Compass Slash", "Full Moon Slash", "Plenilune Slash" },
        Job01_ViolentStab = { "Gouging Skewer", "Gutting Skewer", "Eviscerating Skewer" }, Job01_BravesRaid = { "Riotous Fury" },
        Job01_ShieldSummons = { "Shield Summons", "Shield Drum" }, Job01_Springboard = { "Springboard", "Launchboard" },
        Job01_CymbalAttack = { "Shield Bash", "Shield Pummel" }, Job01_ShieldCounter = { "Counter Slash", "Vengeful Slash", "Punishing Counter" },
        Job01_FullMoonGuard = { "Impeccable Guard", "Flawless Guard" }, Job01_DivineDefense = { "Perfect Defense", "Divine Defense" },
    }
    -- guid -> { name, desc } from the current slot bindings (rebuilt when they change)
    local cacheKey, cache = nil, {}
    local function map()
        local binds = {
            [cfg.smiteSkill or "Job01_BlinkStrike"] = "smite", Job01_HindsightSlash = "slash", [cfg.beamSkill or "Job01_ShieldSummons"] = "blast",
            Job01_FullMoonSlash = "brew", Job01_DivineDefense = "guise", [cfg.comboSkill or "Job01_BravesRaid"] = "combo",
            [cfg.mistySkill or "Job01_RisingLunge"] = "dive", [cfg.blinkSkill or "Job01_CymbalAttack"] = "strike",
        }
        local key = ""
        for id, k in pairs(binds) do key = key .. id .. "=" .. k .. ";" end
        if key == cacheKey and T.dictDone then return cache end
        cacheKey, cache, T.byId = key, {}, {}
        local dict
        pcall(function() dict = sdk.get_managed_singleton("app.GuiManager").CustomSkillDefineDictionary end)
        local idsTd = sdk.find_type_definition("app.HumanCustomSkillID")
        T.dictDone = false
        T.byName = {}
        for id, k in pairs(binds) do
            for _, nm in ipairs(VANILLA[id] or {}) do T.byName[nm] = TEXT[k] end
            for _, g in ipairs(NAME_GUIDS[id] or {}) do cache[g] = TEXT[k] end
            pcall(function()   -- (4.101) the game's own name GUID of every level
                local v = idsTd:get_field(id):get_data(nil) & 0xFFFFFFFF
                T.byId[v] = TEXT[k]
                local levels = dict and dict[v]
                if not levels then return end
                T.dictDone = true
                for lv = 0, 6 do
                    pcall(function()
                        local def = levels[lv]
                        local g = def and guid.to_string(def._SkillName)
                        if g then cache[g] = TEXT[k] end
                    end)
                end
            end)
        end
        return cache
    end

    local function active() return T.on and live.on end
    local function info_of(g) if not active() or not g then return nil end; return map()[g] end
    local function info_by_id(id) if not active() then return nil end; map(); return T.byId and T.byId[id & 0xFFFFFFFF] end
    local function gid(ctrl) local ok, g = pcall(function() return guid.to_string(ctrl:get_MessageId()) end); return ok and g or nil end
    local function store_this(args) thread.get_hook_storage().this = sdk.to_managed_object(args[2]) end
    local function hook(tn, sig, pre, post)
        local td = sdk.find_type_definition(tn)
        local m = td and td:get_method(sig)
        if not m then return end
        pcall(sdk.hook, m, function(args) if pre then pcall(pre, args) end end,
            function(r) if post then local ok, out = pcall(post, r); if ok and out ~= nil then return out end end; return r end)
    end
    local PLAYER_CHARA = 2891076981
    local function chara_is_player(this)
        local raw = this:getCharaId()
        local id = type(raw) == "number" and math.tointeger(raw) or sdk.to_int64(raw)
        return id ~= nil and (id & 0xFFFFFFFF) == PLAYER_CHARA
    end
    -- Vocation Guild: the custom-skill list + its info window
    local function guild_list(this)
        local sl = this._Main_ContentsListCtrl
        local items, infos = sl.ItemList, sl.InfoList
        for i = 0, infos:get_Count() - 1 do
            local inf = infos[i]
            local item = items[inf.ItemIndex]
            local t
            pcall(function() t = info_by_id(inf.Id) end)   -- (4.101) by skill id (VSB's way)
            if not t and item then t = info_of(gid(item._TxtName)) end
            if t then inf.Name = t[1]; if item then item._TxtName:set_Message(t[1]) end end
        end
    end
    local function guild_window(this)
        if not T.playerMenu then return end
        local t = info_of(gid(this._TxtCustomInfoName))
        if t then
            this._TxtCustomInfoName:set_Message(t[1])
            pcall(function()
                local w = this._TxtCustomInfoName:get_DisplaySize().w
                this._PnlCustomJobIcon:set_Position(Vector3f.new(-w / 2 - 23, 22, 0))
            end)
            this._TxtCustomInfo:set_Message(t[2])
        end
        pcall(guild_list, this)
    end
    function T.retext(root)   -- (4.103) every text under a screen: ours by message id or by the vanilla English name
        if not active() or not T.playerMenu or not root then return 0 end
        map()
        local n = 0
        local function walk(c, depth)
            if not c or depth > 14 then return end
            pcall(function()
                if c:get_type_definition():is_a("via.gui.Text") then
                    local t = info_of(gid(c))
                    if not t then
                        local msg = c:call("get_Message")
                        if msg then
                            msg = tostring(msg):gsub("<[^>]*>", "")
                            t = T.byName[msg]
                        end
                    end
                    if t then
                        local cur = tostring(c:call("get_Message") or "")
                        if not cur:find(t[1], 1, true) then c:call("set_Message", t[1]); n = n + 1 end
                    end
                end
            end)
            local ch
            pcall(function() ch = c:call("get_Child") end)
            while ch do
                walk(ch, depth + 1)
                local nx
                pcall(function() nx = ch:call("get_Next") end)
                ch = nx
            end
        end
        walk(root, 0)
        return n
    end
    local function retext_this(this) pcall(function() T.retext(this:get_field("Root") or this.Root) end) end
    local G = "app.ui040101_00"
    for _, sig in ipairs({ "setupEqSkills(System.Int32)", "setupEqSkills()", "updateDispSkillEqList()" }) do
        hook(G, sig, store_this, function() local this = thread.get_hook_storage().this; if this then T.playerMenu = chara_is_player(this); retext_this(this) end end)
    end
    hook(G, "getCharaId()", function(args) local this = sdk.to_managed_object(args[2]); pcall(guild_window, this) end)
    hook(G, "setupCustomSkillInfoWindow", store_this, function() local this = thread.get_hook_storage().this; T.playerMenu = chara_is_player(this); pcall(guild_window, this); retext_this(this) end)
    hook(G, "setupContents(System.Int32)", store_this, function() local this = thread.get_hook_storage().this; if this then T.playerMenu = chara_is_player(this); pcall(guild_list, this) end end)
    -- status page: the skill list + the skill video panel
    local function list_names(items)
        if not T.playerMenu then return end
        for i = 0, items:get_Count() - 1 do
            pcall(function()
                local it = items[i]
                local ctrl = it.TxtSkill or it.Name
                local t = info_of(gid(ctrl))
                if t then ctrl:set_Message(t[1]) end
            end)
        end
    end
    local S = "app.ui060601_01"
    hook(S, "setupKeyGuide", function(args) local this = sdk.to_managed_object(args[2]); T.playerMenu = not this.IsPawn; thread.get_hook_storage().this = this end,
        function()
            local this = thread.get_hook_storage().this
            local mv = this and this.Movie
            local t = mv and T.playerMenu and info_of(gid(mv.TxtTitle))
            if t then mv.TxtTitle:set_Message(t[1]); mv.TxtDetail:set_Message(t[2]) end
        end)
    hook(S, "mouseSkillCtrlSelectionChanged", function(args) local this = sdk.to_managed_object(args[2]); T.playerMenu = not this.IsPawn; thread.get_hook_storage().this = this end,
        function() local this = thread.get_hook_storage().this; if this then list_names(this.SkillCtrl.ItemList) end end)
    -- the Dragonforged screen's skill list
    hook("app.ui041503", "setFlowId", store_this, function() local this = thread.get_hook_storage().this; if this then list_names(this.SkillListCtrl.ItemList) end end)
    -- the name when equipping it (and wherever the game asks for a custom skill's name)
    hook("app.GUIBase", "getCustomSkillName(app.HumanCustomSkillID, app.HumanCustomSkillLevelNo)", function(args)
        local st = thread.get_hook_storage()
        st.name = nil
        if not active() or not T.playerMenu then return end
        local id = sdk.to_int64(args[2]) & 0xFFFFFFFF
        local lv = sdk.to_int64(args[3]) & 0xFFFFFFFF
        local t = info_by_id(id)   -- (4.101) by skill id: every level
        if t then st.name = sdk.to_ptr(sdk.create_managed_string(t[1])) end
    end, function(r) return thread.get_hook_storage().name end)
    hook("app.GUIBase", "getCustomSkillName(app.Character.JobEnum, app.HumanCustomSkillID, app.HumanCustomSkillLevelNo)", function(args)
        local st = thread.get_hook_storage()
        st.name2 = nil
        if not active() or not T.playerMenu then return end
        local t = info_by_id(sdk.to_int64(args[3]) & 0xFFFFFFFF)
        if t then st.name2 = sdk.to_ptr(sdk.create_managed_string(t[1])) end
    end, function(r) return thread.get_hook_storage().name2 end)
    hook("app.GuiManager", "getExCustomSkillName(app.HumanCustomSkillID)", function(args)
        if not active() then return end
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if info_by_id(id) and not T.exNoted then T.exNoted = true; note("skill text: the game asked an EX (DLC level) name for skill " .. id) end
    end)
    -- the HUD skill palette (written on the next frame, like VSB)
    hook("app.ui010201", "setCustomSkill(System.Boolean)", function(args)
        if not active() then return end
        local this = sdk.to_managed_object(args[2])
        if not this:get_DrawSelf() then return end
        local ids, nos, btns = this.CustomSkillMsgId, this.SkillBtnNo, this.BtnList
        for i = 0, ids:get_Count() - 1 do
            local t = info_of(guid.to_string(ids[i]))
            if t then
                local btn = btns[nos[i].m_value]
                if btn then local nm = t[1]; T.next[#T.next + 1] = function() btn.Txt:set_Message('<COLOR preset="arrow"></COLOR>' .. nm) end end
            end
        end
    end)
    re.on_application_entry("LateUpdateBehavior", function()
        if #T.next == 0 then return end
        local run = T.next
        T.next = {}
        for _, fn in ipairs(run) do pcall(fn) end
    end)
end)()




------------------------------------------------------------------------
-- (1.0 user: the guise gave nothing against fire - a Gagana set him on fire) while the guise is on: burning and poison
-- are refused for me, fire hits on me do gu.fireTaken (0.5) of their damage. Statuses asked for me are noted once.
------------------------------------------------------------------------
;(function()
    local SC = sdk.find_type_definition("app.StatusConditionDef.StatusConditionEnum")
    local function enum(n) local ok, v = pcall(function() return SC:get_field(n):get_data(nil) end); return ok and v or nil end
    local REFUSE = {}
    -- (Caught Fire, Torched = tar on fire, Blighted, Fulminant Poison)
    for _, n in ipairs({ "FireSpread", "OilSpread", "Poison", "VirulentPoison" }) do local v = enum(n); if v then REFUSE[v & 0xFFFFFFFF] = n end end
    local NAMES = {}
    pcall(function() for _, f in ipairs(SC:get_fields()) do if f:is_static() then local v = f:get_data(nil); if type(v) == "number" then NAMES[v & 0xFFFFFFFF] = f:get_name() end end end end)
    local function guise_on() local g = dbg.guise; return g ~= nil and g.on == true and live.on end
    local seen = {}
    -- (1.0.1 user: Blighted -> Fulminant Poison still came) statuses also arrive by flag lists that skip the hook below:
    -- every frame while the guise is on, the active ones on me (flag bit = 1 << enum) - refused ones cured at once,
    -- every new one noted by name
    local lastFlags = 0
    re.on_frame(function()
        if not guise_on() then lastFlags = 0; return end
        local a = runtime.player()
        if not a then return end
        pcall(function()
            local sc = a.character["<StatusConditionCtrl>k__BackingField"]
            local flags = sdk.to_int64(sc:call("get_ActiveStatusConditionFlagProp")) or 0
            if flags == lastFlags then return end
            local new = flags & ~lastFlags
            lastFlags = flags
            for id, name in pairs(NAMES) do
                if id < 63 and (new & (1 << id)) ~= 0 then note(("Guise: status on me: %s%s"):format(name, REFUSE[id] and " - cured" or "")) end
            end
            for id, name in pairs(REFUSE) do
                if id < 63 and (flags & (1 << id)) ~= 0 then
                    pcall(sc.call, sc, "reqStatusConditionCure(app.StatusConditionDef.StatusConditionEnum, System.Boolean)", id, false)
                end
            end
        end)
    end)
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.StatusConditionCtrl"):get_method(
            "reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean)"),
            function(args)
                if not guise_on() or not live.sc or sdk.to_int64(args[2]) ~= live.sc then return end
                local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
                local name = REFUSE[id]
                if not seen[id] then seen[id] = true; note(("Guise: status asked for me: %s%s"):format(tostring(NAMES[id] or id), name and " - refused" or "")) end
                if name then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
    end)
    pcall(function()
        sdk.hook(sdk.find_type_definition("app.HitController"):get_method("calcDamageValue(app.HitController.DamageInfo)"),
            function(args)
                local st = thread.get_hook_storage()
                st.pbFire = nil
                if not guise_on() then return end
                pcall(function()
                    local info = sdk.to_managed_object(args[3])
                    local v = info["<DamageGameObject>k__BackingField"]
                    if not v or v:get_address() ~= live.go then return end
                    local el = -1
                    pcall(function() el = tonumber(info["<AttackUserData>k__BackingField"]:get_field("_ElementType")) or -1 end)
                    if el ~= 1 then pcall(function() el = tonumber(info:call("get_ElementType")) or el end) end
                    if el == 1 then st.pbFire = info end   -- 1 = Fire
                end)
            end, function(r)
                local st = thread.get_hook_storage()
                local info = st.pbFire
                st.pbFire = nil
                if info then
                    pcall(function()
                        local k = (dbg.guise and dbg.guise.fireTaken) or 0.5
                        local before = info.Damage
                        info.Damage = before * k
                        note(("Guise: fire hit on me %.0f -> %.0f"):format(before, info.Damage))
                    end)
                end
                return r
            end)
    end)
end)()


------------------------------------------------------------------------
-- (1.1) SPELL SLOTS (user): 1 at level 1, +1 every 15 levels, max 5; Eldritch Smite and Otherworldly Guise use one;
-- they come back one after another, 20 s each (game clock: not in menus). HUD: a row of circles - thick gold ring,
-- black core, purple when full; the recharging one fills up from the middle. (The skills' use of slots comes next.)
------------------------------------------------------------------------
;(function()
    local SL = { used = 0, max = 1, level = 1, rechargeAt = nil, RECHARGE = 20, nextLevel = 0,
                 x = 0.497, y = 0.976, size = 1.0, gap = 2.6, show = true }   -- (1.1 user: 3 areas to try; x/y = the row's centre)
    SL.SPOTS = { { "under the stamina bar (blue)", 0.497, 0.976 }, { "under the pawn commands (red)", 0.201, 0.973 },
                 { "bottom-left corner (green)", 0.054, 0.967 } }
    dbg.slots = SL
    local SAVE = "Pactblade_slots.json"   -- (1.1) the display settings (on / position / size), the player's own
    pcall(function()
        local t = json.load_file(SAVE)
        if type(t) ~= "table" then return end
        for _, k in ipairs({ "x", "y", "size", "gap" }) do if type(t[k]) == "number" then SL[k] = t[k] end end
        if type(t.show) == "boolean" then SL.show = t.show end
    end)
    function SL.save() pcall(json.dump_file, SAVE, { x = SL.x, y = SL.y, size = SL.size, gap = SL.gap, show = SL.show }) end
    function SL.menu()   -- the player's options (release + test menu)
        local c, any = nil, false
        c, SL.show = imgui.checkbox("Spell slots on the HUD", SL.show); any = any or c
        for k, sp in ipairs(SL.SPOTS) do
            if imgui.button(sp[1]:gsub(" %(%a+%)$", "") .. "##slspot" .. k) then SL.x, SL.y, any = sp[2], sp[3], true end
            if k < #SL.SPOTS then imgui.same_line() end
        end
        c, SL.size = imgui.slider_float("size##slsize", SL.size, 0.5, 2.5, "%.2f"); any = any or c
        if any then SL.save() end
    end
    local function clock() return dbg.gclock and dbg.gclock() or os.clock() end
    function SL.refresh()
        if os.clock() < SL.nextLevel then return end
        SL.nextLevel = os.clock() + 1.0
        pcall(function()
            local a = runtime.player()
            local sc = a.character:get_Human()["<StatusContext>k__BackingField"]
            SL.level = tonumber(sc:call("get_Level")) or SL.level
        end)
        SL.max = math.max(1, math.min(5, 1 + math.floor((SL.level or 1) / 15)))
        if SL.used > SL.max then SL.used = SL.max end
    end
    function SL.free() return SL.max - SL.used end
    function SL.use()   -- true = one was free and is now used
        SL.refresh()
        if SL.used >= SL.max then return false end
        SL.fade = { idx = SL.max - SL.used, t0 = os.clock() }   -- (the rightmost full one fades away)
        SL.used = SL.used + 1
        if not SL.rechargeAt then SL.rechargeAt = clock() + SL.RECHARGE end
        return true
    end
    function SL.fill() SL.used, SL.rechargeAt = 0, nil end
    function SL.deny() SL.deniedAt = os.clock() end   -- a press with no slot free: the row flashes red
    -- (1.1) none free: the game is told Smite / Guise aren't available (greyed out like with too little stamina)
    for _, mname in ipairs({ "isCustomSkillAvailable(app.HumanCustomSkillID)", "isCustomSkillAvailableWithoutItemCondition(app.HumanCustomSkillID)" }) do
        pcall(function()
            sdk.hook(sdk.find_type_definition("app.HumanSkillAvailability"):get_method(mname), function(args)
                local st = thread.get_hook_storage()
                st.pbNoSlot = nil
                if not live.on or not live.avail or sdk.to_int64(args[2]) ~= live.avail then return end
                if SL.used < SL.max then return end
                local A = dbg.adapter
                local e = A and A.map and A.map[sdk.to_int64(args[3]) & 0xFFFFFFFF]
                if e and (e.kind == "smite" or e.kind == "guise") then st.pbNoSlot = true end
            end, function(r)
                local st = thread.get_hook_storage()
                if st.pbNoSlot then st.pbNoSlot = nil; return sdk.to_ptr(0) end
                return r
            end)
        end)
    end
    local function tick()
        if SL.rechargeAt and clock() >= SL.rechargeAt then
            SL.used = math.max(0, SL.used - 1)
            SL.rechargeAt = SL.used > 0 and clock() + SL.RECHARGE or nil
            SL.flash = { idx = SL.max - SL.used, t0 = os.clock() }   -- (1.1 user: the refilled one glows up for a second)
        end
    end
    -- colours are ABGR (0xAABBGGRR) - the game's HUD style: engraved bronze rims, dark see-through cores, muted violet
    local SHADOW, GLOW = 0x90000000, 0x2EC9559A
    local RIM_DARK, RIM_LIGHT, RIM_INNER, CORE = 0xFF30556B, 0xFF6AA9C9, 0xFF26455A, 0xE60A0D12
    local GEM = { { 0.66, 0xFF6B1D4B }, { 0.55, 0xFF9C2C6D }, { 0.38, 0xFFC9559A } }
    local SHINE = 0xE6F2B3D9
    local ORBIT = 0xFFE08AF0
    local function alpha(col, a) return (math.floor(math.max(0, math.min(1, a)) * ((col >> 24) & 0xFF)) << 24) | (col & 0xFFFFFF) end
    -- the moon phase: the lit part of a disk of radius g, p 0 (new) .. 1 (full), waxing from the LEFT (user); 1 px strips
    local function moon(cx, cy, g, p, col)
        local n = math.max(2, math.floor(g))
        for k = -n, n do
            local y = k / n * g
            local half = math.sqrt(math.max(0, g * g - y * y))
            local xt = half * (1 - 2 * p)   -- the terminator (an ellipse across the disk)
            if half - xt > 0.05 then draw.filled_rect(cx - half, cy + y - g / n * 0.5, half - xt, g / n + 0.6, col) end
        end
    end
    local function screen_size()
        local w, h = 1920, 1080
        pcall(function() local v = imgui.get_display_size(); if v and v.x > 0 then w, h = v.x, v.y end end)
        return w, h
    end
    local function paused()
        local p = false
        pcall(function() local gm = sdk.get_managed_singleton("app.GuiManager"); if gm and gm:call("isPausedGUI") then p = true end end)
        return p
    end
    re.on_frame(function()
        if not live.on then return end
        SL.refresh()
        tick()
        if not SL.show or paused() then return end
        pcall(function()
            local w, h = screen_size()
            local r = h * 0.0095 * SL.size
            local free = SL.free()
            local x0 = w * SL.x - (SL.max - 1) * r * SL.gap / 2   -- the row centred on the spot
            local y0 = h * SL.y
            local prog = 0
            if SL.rechargeAt then prog = math.max(0, math.min(1, 1 - (SL.rechargeAt - clock()) / SL.RECHARGE)) end
            local deny = SL.deniedAt and (os.clock() - SL.deniedAt) / 0.5 or 1
            for i = 1, SL.max do
                local cx, cy = x0 + (i - 1) * r * SL.gap, y0
                if deny < 1 then draw.filled_circle(cx, cy, r * 1.45, alpha(0xC02020E0, 1 - deny), 40) end   -- no slot free: red
                local full = i <= free
                local k = full and 1 or ((i == free + 1 and SL.rechargeAt) and prog or 0)
                local now = os.clock()
                local breathe = 0.65 + 0.35 * math.sin(now * 2.2 + i * 1.3)
                if full then draw.filled_circle(cx, cy, r * (1.38 + 0.10 * breathe), alpha(GLOW, breathe), 40) end   -- breathing halo
                draw.filled_circle(cx, cy, r * 1.14, SHADOW, 40)
                draw.filled_circle(cx, cy, r, RIM_DARK, 40)              -- the engraved rim: dark - light - dark
                draw.filled_circle(cx, cy, r * 0.88, RIM_LIGHT, 40)
                draw.filled_circle(cx, cy, r * 0.78, RIM_INNER, 40)
                draw.filled_circle(cx, cy, r * 0.71, CORE, 40)           -- the dark core
                if full then
                    for _, g in ipairs(GEM) do draw.filled_circle(cx, cy, r * g[1], g[2], 40) end
                    draw.filled_circle(cx - r * 0.20, cy - r * 0.22, r * 0.13, SHINE, 20)
                    local ang = now * 2.4 + i * 1.9                      -- a light running round the rim, with a tail
                    for t = 0, 4 do
                        local a2 = ang - t * 0.22
                        draw.filled_circle(cx + math.cos(a2) * r * 0.86, cy + math.sin(a2) * r * 0.86, r * (0.16 - t * 0.025), alpha(ORBIT, 1 - t * 0.2), 16)
                    end
                elseif k > 0 then                                        -- recharging: the moon's phases
                    for _, g in ipairs(GEM) do moon(cx, cy, r * g[1], k, g[2]) end
                end
                local fl = SL.flash
                if fl and fl.idx == i then                               -- just refilled: a glow that blooms out and fades
                    local t = (now - fl.t0) / 1.0
                    if t >= 1 then SL.flash = nil
                    else
                        draw.filled_circle(cx, cy, r * (1.2 + 1.0 * t), alpha(0x66E08AF0, 1 - t), 40)
                        draw.filled_circle(cx, cy, r * (1.1 + 0.5 * t), alpha(0x88F2B3D9, 1 - t), 40)
                        draw.filled_circle(cx, cy, r * 0.62, alpha(0xFFF2C8F5, (1 - t) * 0.8), 40)   -- the gem shining bright
                    end
                end
                local f = SL.fade
                if f and f.idx == i then                                 -- just used: the gem swells and fades away
                    local t = (now - f.t0) / 0.6
                    if t >= 1 then SL.fade = nil
                    else
                        for _, g in ipairs(GEM) do draw.filled_circle(cx, cy, r * g[1] * (1 + 0.45 * t), alpha(g[2], 1 - t), 40) end
                    end
                end
            end
        end)
    end)
end)()

re.on_draw_ui(function()
    if not imgui.tree_node(PB.NAME .. " " .. PB.VERSION) then return end
    for _, c in ipairs(THEME) do imgui.push_style_color(c[1], c[2]) end
    local ok, err = pcall(function()
    local ch
    if live.vsb == "missing" then
        imgui.text_colored("VocationAndSkillBuilder (VSB) is not loaded: Pactblade is picked in VSB's menu.", 0xFF40C0FF)
    elseif live.vsb ~= "picked" then
        imgui.text("Pactblade is not picked: VocationAndSkillBuilder -> Vocations -> Fighter: pick Pactblade.")
    else
        imgui.text(live.on and "Pactblade is ACTIVE (sword in hand)." or "Pactblade is picked - active with a sword in hand.")
        pcall(function()   -- (i-0.1) the VSB skill adapter
            local A = dbg.adapter
            if A then
                pcall(A.refresh)
                imgui.text(("VSB skills: %s | presses %d (last: %s)"):format(A.info, A.presses, tostring(A.last or "-")))
            end
        end)
    end
    if live.on and live.shieldWorn then
        imgui.text_colored("Pactblade can't use a shield: take yours off (it can't be equipped while active).", 0xFF40C0FF)
    end
    if json.RELEASE then   -- (1.0) the release menu
        ch, cfg.nox = imgui.checkbox("Nox sword look (purple mist + blade glow)", cfg.nox)
        if ch then save_cfg() end
        ch, cfg.glow = imgui.checkbox("Arm effect", cfg.glow)
        if ch then save_cfg() end
        if dbg.slots then pcall(dbg.slots.menu) end   -- (1.1)
        if imgui.tree_node("Dimension Door") then
            if dbg.dd then pcall(dbg.dd.draw) else imgui.text("Dimension Door not loaded: " .. tostring(dbg.ddErr)) end
            imgui.tree_pop()
        end
        return
    end

    title("Look")
    local hue = current_hue()
    local ci = #COLOURS
    for k, c in ipairs(COLOURS) do if c[1] == hue then ci = k end end
    local cl = {}
    for k, c in ipairs(COLOURS) do cl[k] = c[2] end
    local chc, cn = imgui.combo("Colour (blasts, Eldritch Slash, warps, arm)", ci, cl)
    if chc then set_colour(COLOURS[cn][1]); hue = COLOURS[cn][1] end
    ch, cfg.glow = imgui.checkbox("Arm effect", cfg.glow)
    if ch then save_cfg() end
    if cfg.glow then
        local v = tostring(cfg.glowVariant or "")
        local ahue, lv = tonumber(v:match("^h(%d+)g") or ""), tonumber(v:match("g(%d)$") or "") or 2
        if ahue then
            local c1, c2
            c1, lv = imgui.slider_int("   glow strength", lv, 1, 4)
            if c1 then cfg.glowVariant = ("h%dg%d"):format(ahue, lv); glowState.res = nil; glow_clear(); save_cfg() end
            c2, cfg.glowLvCharge = imgui.slider_int("   glow strength while charging", math.floor(cfg.glowLvCharge or 4), 1, 4)
            if c2 then glow_clear(); save_cfg() end
        end
        ch, cfg.glowSheathed = imgui.checkbox("   also while the sword is sheathed (always when charging)", cfg.glowSheathed)
        if ch then save_cfg() end
    end
    ch, cfg.nox = imgui.checkbox("Nox sword look", cfg.nox)
    local chg
    chg, dbg.noxGlowMode = imgui.checkbox("  blade glow mode (3.03 crash test: off)", dbg.noxGlowMode)
    if ch then save_cfg() end
    if cfg.nox and imgui.tree_node("Nox look settings (blade glow + mist)") then
        local SL = { { "blade glow: red", "R", 255 }, { "blade glow: green", "G", 255 }, { "blade glow: blue", "B", 255 },
                     { "blade glow: brightness", "Bright", 8 } }
        local any = false
        local function block(title, get, set, tag)
            imgui.text(title)
            for _, part in ipairs({ "blade", "mist" }) do
                for _, sl in ipairs(SL) do
                    local label = sl[1]:gsub("^blade glow", part == "blade" and "blade glow" or "mist")
                    local maxv = (part == "mist" and sl[2] == "Bright") and 4 or sl[3]
                    local v = get(part, sl[2])
                    local chn, nv = imgui.slider_float(label .. "##" .. tag, v, 0, maxv, sl[2] == "Bright" and "%.2f" or "%.0f")
                    if chn then set(part, sl[2], nv); any = true end
                end
            end
        end
        block("everyday look:", function(part, k) return cfg["nox" .. (part == "blade" and "Blade" or "Mist") .. k] end,
              function(part, k, v) cfg["nox" .. (part == "blade" and "Blade" or "Mist") .. k] = v end, "day")
        if imgui.button("everyday look: back to the defaults") then
            cfg.noxBladeR, cfg.noxBladeG, cfg.noxBladeB, cfg.noxBladeBright = 91, 26, 142, 1.0
            cfg.noxMistR, cfg.noxMistG, cfg.noxMistB, cfg.noxMistBright = 126, 0, 54, 1.3
            any = true
        end
        block("during Eldritch Smite (part 2):", function(part, k) return cfg.noxSmite[part .. k] end,
              function(part, k, v) cfg.noxSmite[part .. k] = v end, "smite")
        if any then save_cfg() end
        imgui.tree_pop()
    end

    title("Skills")
    imgui.text("   Vocation button: tap = dodge, hold = Eldritch Bolt, right after Onslaught / Empale = Eldritch Burst")
    ch, cfg.bind = imgui.checkbox("Eldritch Bolt binds - Misty Step (Quik Fot) with Jump", cfg.bind)
    if ch then save_cfg() end
    local WARP_LOOKS = { "wisps", "quikfot", "blink" }
    local wfi = 1
    for k, v in ipairs(WARP_LOOKS) do if v == cfg.warpFx then wfi = k end end
    imgui.text(("Archfey Combo slot: %s%s"):format(tostring(cfg.comboSkill), combo.slotInfo and ("  (" .. combo.slotInfo .. ")") or ""))
    imgui.same_line()
    if imgui.button(combo.binding and "press the skill now...##cb" or "put it in the next skill I press##cb") then combo.binding = true end
    local chw, wfn = imgui.combo("Warp look (Archfey Combo / Misty Step)", wfi, { "Wisps", "Quik Fot", "Blink Behind (Skydragon's Fangtooth)" })
    if chw then cfg.warpFx = WARP_LOOKS[wfn]; save_cfg() end
    if cfg.warpFx == "wisps" then
        ch, cfg.warpWispSecs = imgui.slider_float("   wisps last (s)", cfg.warpWispSecs, 0.2, 3.0, "%.2f")
        if ch then save_cfg() end
    end
    ch, cfg.afterimage = imgui.checkbox("Afterimage where a warp starts (Mystic Spearhand's ghost, our colour)", cfg.afterimage)
    if ch then save_cfg() end
    if cfg.afterimage then
        ch, cfg.afterimageSecs = imgui.slider_float("   afterimage lasts (s)", cfg.afterimageSecs, 0.1, 2.0, "%.2f")
        if ch then save_cfg() end
    end

    if imgui.tree_node("Dimension Door") then   -- (i-0.7)
        if dbg.dd then pcall(dbg.dd.draw) else imgui.text("Dimension Door not loaded: " .. tostring(dbg.ddErr)) end
        imgui.tree_pop()
    end
    if imgui.tree_node("Advanced") then
        title("Arm effect")
        ch, cfg.freezeAt = imgui.slider_float("   frozen at (s)", cfg.freezeAt, 0.05, 3.0, "%.2f")
        if ch then glow_clear(); save_cfg() end
        ch, cfg.chargeFull = imgui.checkbox("   while charging: the whole effect from the start (looped)", cfg.chargeFull)
        if ch then glow_clear(); save_cfg() end
        if cfg.chargeFull then
            local c1, c2
            c1, cfg.chargeSpeed = imgui.slider_float("      charging play speed", cfg.chargeSpeed, 0.1, 2.0, "%.2f")
            c2, cfg.chargeEnd = imgui.slider_float("      loop back after (s of the effect)", cfg.chargeEnd, 0.5, 6.0, "%.2f")
            if c1 or c2 then save_cfg() end
        end
        title("Runtime colour (the effects not recoloured in files)")
        ch, cfg.armTint = imgui.checkbox("   arm", cfg.armTint)
        if ch then sleeve_restore(); save_cfg() end
        imgui.same_line()
        ch, cfg.blastTint = imgui.checkbox("   blasts", cfg.blastTint)
        if ch then save_cfg() end
        if cfg.armTint or cfg.blastTint then
            local cr, cg, cb, cbr
            cr, cfg.armR = imgui.slider_int("      red", cfg.armR, 0, 255)
            cg, cfg.armG = imgui.slider_int("      green", cfg.armG, 0, 255)
            cb, cfg.armB = imgui.slider_int("      blue", cfg.armB, 0, 255)
            cbr, cfg.armBright = imgui.slider_float("      brightness", cfg.armBright, 1.0, 8.0, "%.1f")
            if cr or cg or cb or cbr then sleeve_restore(); save_cfg() end
        end
        ch, cfg.boom = imgui.slider_float("   blast cloud size (0 = none)", cfg.boom, 0.0, 1.0, "%.2f")
        if ch then save_cfg() end
        ch, cfg.comboNoDust = imgui.checkbox("   no dust from the Archfey Combo's Rush parts", cfg.comboNoDust)
        if ch then save_cfg() end
        title("Archfey Combo")
        ch, cfg.comboDynamic = imgui.checkbox("   warps go around the enemy (opposite, then the free sides; off = fixed spots)", cfg.comboDynamic)
        if ch then save_cfg() end
        ch, cfg.finisherHeight = imgui.slider_float("   air finisher height (m above / below its head)", cfg.finisherHeight, -1.5, 1.5, "%.2f")
        if ch then save_cfg() end
        ch, cfg.comboTurn = imgui.checkbox("   opening: turn toward a nearby enemy", cfg.comboTurn)
        if ch then save_cfg() end
        if cfg.comboTurn then
            local c1, c2
            c1, cfg.comboTurnSpeed = imgui.slider_float("      turn speed (degrees a second)", cfg.comboTurnSpeed, 30, 1440, "%.0f")
            c2, cfg.comboTurnRange = imgui.slider_float("      enemy within (m)", cfg.comboTurnRange, 2, 30, "%.1f")
            if c1 or c2 then save_cfg() end
        end
        title("Eldritch Burst window (vocation button during each swing)")
        local w1, w2, w3
        w1, cfg.burstWindow = imgui.slider_float("   Onslaught: s from the start", cfg.burstWindow, 0.05, 1.5, "%.2f")
        local w2a, w2b
        w2a, cfg.empaleFrom = imgui.slider_float("   Empale (ground): from frame", cfg.empaleFrom, 0, 200, "%.1f")
        w2b, cfg.empaleTo = imgui.slider_float("   Empale (ground): to frame (dodge after it)", cfg.empaleTo, 0, 250, "%.1f")
        if w2a or w2b then w2 = true end
        local t1, t2
        t1, cfg.tuskFrom = imgui.slider_float("   Tusk Toss: from frame", cfg.tuskFrom, 0, 200, "%.1f")
        t2, cfg.tuskTo = imgui.slider_float("   Tusk Toss: to frame", cfg.tuskTo, 0, 250, "%.1f")
        if t1 or t2 then w2 = true end
        w3, cfg.burstWindowEmpaleAir = imgui.slider_float("   Empale (in the air): s from the start", cfg.burstWindowEmpaleAir, 0.05, 1.5, "%.2f")
        if w1 or w2 or w3 then save_cfg() end
        title("Eldritch Slash")
        ch, cfg.slashFrame = imgui.slider_float("   wave fires at frame", cfg.slashFrame, 0, 97, "%.1f")
        if ch then save_cfg() end
        ch, cfg.slashRange = imgui.slider_float("   wave range (x Magike Cut's)", cfg.slashRange, 1, 20, "%.1f")
        if ch then save_cfg() end
        ch, cfg.slashHitRange = imgui.slider_float("   wave ends after (m) - set it to where the wave fades", cfg.slashHitRange or 28, 5, 70, "%.0f")
        if ch then save_cfg() end
        ch, cfg.slashFastFrom = imgui.slider_float("   1.2x speed from frame (the recovery)", cfg.slashFastFrom, 0, 350, "%.1f")
        if ch then save_cfg() end
        ch, cfg.slashTurn = imgui.checkbox("   turn toward a nearby enemy before the wave", cfg.slashTurn)
        if ch then save_cfg() end
        if cfg.slashTurn then
            local c1, c2, c3
            c1, cfg.slashTurnRange = imgui.slider_float("      enemy within (m)", cfg.slashTurnRange, 2, 30, "%.1f")
            c2, cfg.slashTurnCone = imgui.slider_float("      and within (degrees of where you face)", cfg.slashTurnCone, 10, 180, "%.0f")
            c3, cfg.slashTurnSpeed = imgui.slider_float("      turn speed (degrees a second)", cfg.slashTurnSpeed, 30, 1440, "%.0f")
            if c1 or c2 or c3 then save_cfg() end
        end
        imgui.tree_pop()
    end

    local chf
    chf, dbg.fogCut = imgui.slider_float("fog test: cut the Eldritch Bolt explosion after (s, 0 = off)", dbg.fogCut or 0.0, 0, 3, "%.1f")
    if imgui.tree_node("Skill settings") then
        if imgui.tree_node("Eldritch Smite") then
            local sm, chm = dbg.smite, nil
            imgui.text(("slot: %s   |   %s"):format(tostring(cfg.smiteSkill), sm.info))
            if imgui.button(sm.binding and "press the skill now...##sm" or "put it in the next skill I press##sm") then sm.binding = true end
            chm, sm.fast = imgui.slider_float("speed from frame 150", sm.fast, 1, 3, "%.2f")
            chm, sm.blend = imgui.slider_float("blend into Arc of Obliteration (frames)", sm.blend, 0, 30, "%.0f")
            chm, dbg.NOX.boostGlow = imgui.slider_float("blade glow while smiting (x)", dbg.NOX.boostGlow, 1, 6, "%.1f")
            chm, sm.boomScale = imgui.slider_float("hit explosion size (x)", sm.boomScale, 0.5, 6, "%.1f")
            local downs = { 15, 12 }
            local dpick = sm.downType == 12 and 2 or 1
            chm, dpick = imgui.combo("knocks enemies", dpick, { "slammed to the ground (Slam_L)", "knocked down (Hitdown_L)" })
            if chm then sm.downType = downs[dpick] end
            chm, sm.downPower = imgui.slider_float("stagger power x (big enemies go down past their limit)", sm.downPower, 1, 2000, "%.0f")
            chm, sm.dmgMul = imgui.slider_float("damage x", sm.dmgMul, 0, 2, "%.2f")
            chm, sm.lethalSkip = imgui.checkbox("a killing blow: the game's own death (no flying body)", sm.lethalSkip)
            chm, sm.push = imgui.slider_float("push back x (0 = they drop where they stand)", sm.push, 0, 1, "%.2f")
            chm, sm.noBlown = imgui.checkbox("never turned into a blown-away reaction", sm.noBlown)
            chm, sm.lightOn = imgui.checkbox("the blade lights the area during the smite", sm.lightOn)
            chm, sm.lightLm = imgui.slider_float("blade light strength", sm.lightLm, 100, 10000, "%.0f")
            chm, sm.lightRadius = imgui.slider_float("blade light reach (m)", sm.lightRadius, 1, 15, "%.1f")
            chm, sm.chargeDelay = imgui.slider_float("charge sound vs the sword lighting up (s, minus = sooner)", sm.chargeDelay, -0.3, 1.5, "%.2f")
            local sig = ("%s|%s|%s|%s|%s|%s|%s|%s|%s"):format(sm.fast, sm.blend, sm.boomScale, tostring(sm.lightOn), sm.lightUntil, sm.lightLm, sm.lightRadius, dbg.NOX.boostGlow, sm.chargeDelay)
            if sig ~= sm.lastSig then sm.lastSig, sm.dirtyAt = sig, os.clock() end
            if sm.dirtyAt and os.clock() - sm.dirtyAt > 1.5 then sm.dirtyAt = nil; sm.save() end   -- (saved by itself)
            imgui.tree_pop()
        end
        if imgui.tree_node("Tasha's Caustic Brew") then
            local sk, chb = dbg.brew, nil
            imgui.text(sk.info)
            chb, sk.tickSecs = imgui.slider_float("acid hits every (s)", sk.tickSecs, 0.1, 1.0, "%.2f")
            chb, sk.tickDmg = imgui.slider_float("damage per acid hit", sk.tickDmg, 0, 2000, "%.0f")
            chb, sk.poisonPts = imgui.slider_float("poison build-up per acid hit (100 = poisoned)", sk.poisonPts, 0, 100, "%.0f")
            chb, sk.poisonMul = imgui.slider_float("poison damage x (our poison only)", sk.poisonMul, 1, 5, "%.1f")
            chb, sk.lingerSecs = imgui.slider_float("acid lasts (s)", sk.lingerSecs, 1, 10, "%.1f")
            chb, sk.halfWidth = imgui.slider_float("acid strip: half width (m)", sk.halfWidth, 0.5, 4, "%.2f")
            imgui.tree_pop()
        end
        if imgui.tree_node("Otherworldly Guise") then
            local gu, chh = dbg.guise, nil
            imgui.text("Perfect Defense / Divine Defense's slot: Caustic Brew's chant -> the guise | " .. tostring(gu.skill.info))
            chh, gu.skill.on = imgui.checkbox("the skill on##gu", gu.skill.on)
            chh, gu.skill.secs = imgui.slider_float("the skill lasts (s)##gu", gu.skill.secs, 10, 120, "%.0f")
            if gu.on and gu.t0 then imgui.text(("left: %.0f s (paused time not counted: %.0f s)"):format(math.max(0, gu.secs - (os.clock() - gu.t0)), gu.pausedSecs or 0)) end
            chh, gu.skill.staminaPct = imgui.slider_float("stamina cost (of max)##gu", gu.skill.staminaPct, 0, 1, "%.2f")
            chh, gu.bonus.on = imgui.checkbox("bonuses (defence, fire + poison resist)##gu", gu.bonus.on)
            imgui.same_line()
            imgui.text(("recalculated %d x"):format(gu.bonus.calls))
            chh, gu.bonus.def = imgui.slider_float("defence bonus##gu", gu.bonus.def, 0, 1, "%.2f")
            chh, gu.lev.on = imgui.checkbox("Levitate (in the air: hold jump)##gu", gu.lev.on)
            imgui.same_line()
            imgui.text(tostring(gu.lev.info))
            chh, gu.lev.hold = imgui.slider_float("hold jump for (s)##gu", gu.lev.hold, 0.05, 1, "%.2f")
            chh, gu.lev.rise = imgui.slider_float("levitate rise speed (m/s)##gu", gu.lev.rise, 0, 5, "%.1f")
            chh, gu.lev.maxRise = imgui.slider_float("levitate max height (m)##gu", gu.lev.maxRise, 0, 10, "%.1f")
            chh, gu.lev.maxKeep = imgui.slider_float("levitate lasts at most (s)##gu", gu.lev.maxKeep, 0.5, 15, "%.1f")
            chh, gu.lev.staminaPerSec = imgui.slider_float("levitate stamina per s##gu", gu.lev.staminaPerSec, 0, 300, "%.0f")
            chh, gu.lev.hSpeed = imgui.slider_float("levitate steering speed (m/s)##gu", gu.lev.hSpeed, 0, 12, "%.1f")
            chh, gu.lev.anim.on = imgui.checkbox("levitate animation (Mage's)##gu", gu.lev.anim.on)
            imgui.same_line()
            imgui.text("bank " .. tostring(gu.lev.anim.bank or "?"))
            chh, gu.lev.anim.speed = imgui.slider_float("levitate animation speed##gu", gu.lev.anim.speed, 0.2, 3, "%.2f")
            imgui.text("state: " .. tostring(gu.info))
            local names = {}
            for i, c in ipairs(gu.CHESTS) do names[i] = c[1] end
            chh, gu.chest = imgui.combo("chest##gu", gu.chest, names)
            names = {}
            for i, c in ipairs(gu.LEGS) do names[i] = c[1] end
            chh, gu.legs = imgui.combo("legs##gu", gu.legs, names)
            if imgui.button((gu.on and "end the guise" or "show the guise") .. "##gu") then pcall(gu.show, runtime.player()) end
            imgui.same_line()
            if imgui.button("probe (armour parts -> log)##gu") then pcall(gu.probe, runtime.player()) end
            if gu.parked then imgui.same_line(); if imgui.button("release the clone##gu") then pcall(gu.release_clone) end end
            local fxNames = { "Mirage Dance element 0", "element 20", "both", "none" }
            chh, gu.fxSel = imgui.combo("ghost effects##gu", gu.fxSel, fxNames)
            chh, gu.cloudSpeed = imgui.slider_float("purple cloud speed##gu", gu.cloudSpeed, 0.1, 2, "%.2f")
            chh, gu.cloudAlpha = imgui.slider_float("purple cloud see-through (1 = full)##gu", gu.cloudAlpha, 0, 1, "%.2f")
            chh, gu.cloudBright = imgui.slider_float("purple cloud brightness##gu", gu.cloudBright, 0, 2, "%.2f")
            chh, gu.cloudTint[1] = imgui.slider_float("purple cloud tint red##gu", gu.cloudTint[1], 0, 4, "%.2f")
            chh, gu.cloudTint[2] = imgui.slider_float("purple cloud tint green##gu", gu.cloudTint[2], 0, 4, "%.2f")
            chh, gu.cloudTint[3] = imgui.slider_float("purple cloud tint blue##gu", gu.cloudTint[3], 0, 4, "%.2f")
            chh, gu.bodyFx = imgui.checkbox("the clone's body effect##gu", gu.bodyFx)
            imgui.same_line()
            chh, gu.startFx = imgui.checkbox("its start effect##gu", gu.startFx)
            if gu.on and gu.inst then if imgui.button("list the armour's material variables (log)##gu") then pcall(gu.matvars, gu.inst) end end
            if not gu.on and not gu.parked then
                chh, gu.src = imgui.combo("clone source##gu", gu.src, { "shared afterimage (works; warp ghosts paused)", "Trickster decoy (test)" })
            else
                imgui.text("clone source: " .. (gu.src == 2 and "Trickster decoy" or "shared afterimage") .. " (end + release to change)")
            end
            chh, gu.sideTest = imgui.checkbox("test: the ghost 3 m to my side (do enemies go after it?)##gu", gu.sideTest)
            chh, gu.parkDecoy = imgui.checkbox("park the decoy at the end (off = released, test 4.95)##gu", gu.parkDecoy == true)
            chh, gu.ill.on = imgui.checkbox("illusion look (the game's ghost material values)##gu", gu.ill.on)
            chh, gu.ill.enable = imgui.slider_float("Illusion_Enable##gu", gu.ill.enable, 0, 1, "%.2f")
            chh, gu.ill.front = imgui.slider_float("Illusion_AlphaRate_Front (see-through front)##gu", gu.ill.front, 0, 1, "%.2f")
            chh, gu.ill.rim = imgui.slider_float("Illusion_AlphaRate_Rim (edges)##gu", gu.ill.rim, 0, 1, "%.2f")
            chh, gu.ill.fade = imgui.slider_float("Illusion_FadeRate (chest)##gu", gu.ill.fade, 0, 1, "%.2f")
            chh, gu.ill.fadeLegs = imgui.slider_float("Illusion_FadeRate (legs)##gu", gu.ill.fadeLegs, 0, 1, "%.2f")
            chh, gu.ill.grad = imgui.slider_float("Illusion_RimAlphaGrad##gu", gu.ill.grad, 0, 4, "%.2f")
            chh, gu.ill.noise = imgui.slider_float("Illusion_NoiseBlend##gu", gu.ill.noise, 0, 1, "%.2f")
            chh, gu.ill.dither = imgui.slider_float("DitherFadeRate (1 = solid)##gu", gu.ill.dither, 0, 1, "%.2f")
            chh, gu.ill.dissolve = imgui.slider_float("DissolveRate (0 = all there)##gu", gu.ill.dissolve, 0, 1, "%.2f")
            if gu.on and gu.inst then if imgui.button("redo the ghost look##gu") then local okG, eG = pcall(gu.ghost, gu.inst); note("Guise: ghost look again: " .. tostring(eG)) end end
            chh, gu.secs = imgui.slider_float("lasts (s)##gu", gu.secs, 5, 60, "%.0f")
            chh, gu.scale[1] = imgui.slider_float("width (x)##gu", gu.scale[1], 0.9, 1.4, "%.2f")
            chh, gu.scale[2] = imgui.slider_float("height (y)##gu", gu.scale[2], 0.9, 1.4, "%.2f")
            chh, gu.scale[3] = imgui.slider_float("depth (z)##gu", gu.scale[3], 0.9, 1.4, "%.2f")
            chh, gu.yOff = imgui.slider_float("up / down (m)##gu", gu.yOff, -0.3, 0.3, "%.2f")
            chh, gu.hue = imgui.slider_float("glow hue##gu", gu.hue, 0, 360, "%.0f")
            chh, gu.sat = imgui.slider_float("glow saturation##gu", gu.sat, 0, 1, "%.2f")
            chh, gu.glow = imgui.slider_float("glow strength##gu", gu.glow, 0, 4, "%.2f")
            imgui.tree_pop()
        end
        if imgui.tree_node("Hellish Rebuke") then
            local hr, chh = dbg.rebuke, nil
            imgui.text("Hit (no reaction / a flinch): Interact within the window | " .. tostring(hr.info))
            chh, hr.on = imgui.checkbox("on##hr", hr.on)
            chh, hr.window = imgui.slider_float("window after the hit (s)##hr", hr.window, 0.1, 2, "%.2f")
            chh, hr.speed = imgui.slider_float("animation speed##hr", hr.speed, 0.5, 3, "%.2f")
            chh, hr.burnAt = imgui.slider_float("the attacker catches fire at frame##hr", hr.burnAt, 0, 45, "%.0f")
            chh, hr.staminaPct = imgui.slider_float("stamina cost (of max)##hr", hr.staminaPct, 0, 1, "%.2f")
            chh, hr.flinch = imgui.checkbox("the attacker flinches##hr", hr.flinch)
            chh, hr.cooldown = imgui.slider_float("once every (s)##hr", hr.cooldown, 0, 30, "%.0f")
            chh, hr.greenFire = imgui.checkbox("its burning is green##hr", hr.greenFire)
            if imgui.button("test: dump my effect data (where the flame files are)##hr") then pcall(hr.dump_fx_data) end
            local tp = hr.fireTone == "gy" and 2 or 1
            chh, tp = imgui.combo("flame file look##hr", tp, { "gy2 (inverted layers like the rest)", "gy (inverted layers flipped)" })
            if chh then hr.fireTone = tp == 2 and "gy" or "gy2" end
            chh, hr.useTint = imgui.checkbox("(old) tint the game's flames instead##hr", hr.useTint)
            chh, hr.flameTint[1] = imgui.slider_float("flames tint red##hr", hr.flameTint[1], 0, 1, "%.2f")
            chh, hr.flameTint[2] = imgui.slider_float("flames tint green##hr", hr.flameTint[2], 0, 1, "%.2f")
            chh, hr.flameTint[3] = imgui.slider_float("flames tint blue##hr", hr.flameTint[3], 0, 1, "%.2f")
            if imgui.button("test: set ME on fire (in the hellfire colours), note my burning look##hr") then require("DragonCore.game.actor_fx").defer(function() local ok, e = pcall(hr.burn_me); if not ok then note("burn me failed: " .. tostring(e)) end end) end
            chh, hr.react = imgui.slider_float("flinch power##hr", hr.react, 0, 10000, "%.0f")
            chh, hr.holdEnd = imgui.slider_float("hold the last frame (s)##hr", hr.holdEnd, 0, 2, "%.2f")
            chh, hr.spark = imgui.checkbox("green fire spark at my left hand##hr", hr.spark)
            chh, hr.boom = imgui.checkbox("green fire explosion on the attacker##hr", hr.boom)
            chh, hr.boomScale = imgui.slider_float("explosion size##hr", hr.boomScale, 0.2, 4, "%.2f")
            chh, hr.boomSound = imgui.checkbox("its sound (hellishrebukesfx 6-8 s)##hr", hr.boomSound)
            chh, hr.sparkScale = imgui.slider_float("spark size##hr", hr.sparkScale, 0.05, 1.5, "%.2f")
            chh, hr.flash = imgui.checkbox("'charge finished' body flash + sound at the cast##hr", hr.flash)
            imgui.tree_pop()
        end
        if imgui.tree_node("Spell slots (HUD test)") then   -- (1.1)
            pcall(function()
                local SL, c = dbg.slots, nil
                SL.refresh()
                imgui.text(("level %d -> %d slot(s), %d used, next back in %s"):format(SL.level or 0, SL.max, SL.used,
                    SL.rechargeAt and ("%.1f s"):format(SL.rechargeAt - dbg.gclock()) or "-"))
                if imgui.button("use a slot##sl") then SL.use() end
                imgui.same_line()
                if imgui.button("refill##sl") then SL.fill() end
                SL.menu()
                c, SL.x = imgui.slider_float("centre x (of the screen width)##sl", SL.x, 0, 1, "%.3f")
                c, SL.y = imgui.slider_float("centre y (of the screen height)##sl", SL.y, 0, 1, "%.3f")
                c, SL.gap = imgui.slider_float("spacing##sl", SL.gap, 2.0, 5.0, "%.2f")
                if imgui.button("save position##sl") then SL.save() end
            end)
            imgui.tree_pop()
        end
        if imgui.tree_node("Misty Strike") then
            pcall(function()
                local b, c = dbg.blink, nil
                c, b.fastFrom = imgui.slider_float("faster from frame##bsr", b.fastFrom, 106, 282, "%.0f")
                c, b.fastSpeed = imgui.slider_float("recovery speed##bsr", b.fastSpeed, 1, 3, "%.2f")
                c, b.cancelFrom = imgui.slider_float("input cancels from frame##bsr", b.cancelFrom, 106, 282, "%.0f")
                c, b.to = imgui.slider_float("ends at frame##bsr", b.to, 120, 282, "%.0f")
                c, b.endBlend = imgui.slider_float("end blend (frames)##bsr", b.endBlend, 0, 30, "%.0f")
            end)
            local bs, chk = dbg.blink, nil
            imgui.text(("slot: %s%s   |   %s"):format(tostring(cfg.blinkSkill), bs.slotInfo and ("  (" .. bs.slotInfo .. ")") or "", bs.info))
            imgui.text(("Riotous Fury animation %s: frame %s of %s"):format(tostring(bs.motion), bs.frame and ("%.1f"):format(bs.frame) or "-", tostring(bs.endF or "-")))
            if imgui.button(bs.binding and "press the skill now...##bs" or "put it in the next skill I press##bs") then bs.binding = true end
            chk, bs.from = imgui.slider_float("starts at frame (the last hit)##bs", bs.from, 0, 400, "%.0f")
            chk, bs.to = imgui.slider_float("ends at frame (9999 = its end)##bs", bs.to, 1, 9999, "%.0f")
            chk, bs.speed = imgui.slider_float("animation speed##bs", bs.speed, 0.2, 3, "%.2f")
            chk, bs.air = imgui.checkbox("usable from a jump##bs", bs.air)
            chk, bs.airHold = imgui.slider_float("from a jump: held in the air with the launch effects for (s)##bs", bs.airHold, 0, 1, "%.2f")
            chk, bs.prep = imgui.checkbox("getting ready first (Misty Dive's preparing jump)##bs", bs.prep)
            chk, bs.prepWarp = imgui.slider_float("teleport after getting ready for (s)##bs", bs.prepWarp, 0.05, 0.8, "%.2f")
            chk, bs.groundLock = imgui.checkbox("stay on the ground while getting ready##bs", bs.groundLock)
            chk, bs.behind = imgui.slider_float("lands this far behind it (m, + its size)##bs", bs.behind, 0, 4, "%.1f")
            imgui.tree_pop()
        end
        if imgui.tree_node("Eldritch Blast (beam)") then
            local bm, chb = dbg.beam, nil
            imgui.text(("slot: %s%s   |   %s   |   frame %s of %s"):format(tostring(cfg.beamSkill), bm.slotInfo and ("  (" .. bm.slotInfo .. ")") or "",
                bm.info, bm.frame and ("%.1f"):format(bm.frame) or "-", tostring(bm.endF or "-")))
            if imgui.button(bm.binding and "press the skill now...##bm" or "put it in the next skill I press##bm") then bm.binding = true end
            chb, bm.fireFrame = imgui.slider_float("beam fires at frame##bm", bm.fireFrame, 0, 80, "%.0f")
            chb, bm.endFrame = imgui.slider_float("animation ends at frame##bm", bm.endFrame, 5, 120, "%.0f")
            chb, bm.grow = imgui.slider_float("beam grows to the target in (s)##bm", bm.grow, 0.02, 0.6, "%.2f")
            chb, bm.hold = imgui.slider_float("beam stays (s)##bm", bm.hold, 0, 2, "%.2f")
            chb, bm.fade = imgui.slider_float("beam thins out in (s)##bm", bm.fade, 0.02, 1, "%.2f")
            chb, bm.width = imgui.slider_float("beam thickness (1 = the Golem's 3 m)##bm", bm.width, 0.02, 1, "%.2f")
            imgui.text(("damage = your magick (%s, from the last Eldritch Bolt hit) x the slider = %s; before any bolt hit: the fixed value"):format(
                dbg.boltMag and ("%.0f"):format(dbg.boltMag) or "not known yet", dbg.boltMag and ("%.0f"):format(dbg.boltMag * bm.magRate) or ("%.0f"):format(bm.dmg)))
            chb, bm.magRate = imgui.slider_float("damage x magick##bm", bm.magRate, 0.5, 6, "%.2f")
            chb, bm.dmg = imgui.slider_float("fixed damage (no bolt hit yet)##bm", bm.dmg, 0, 5000, "%.0f")
            chb, bm.stamina = imgui.slider_float("stamina cost##bm", bm.stamina, 0, 600, "%.0f")
            chb, bm.react = imgui.slider_float("flinch power##bm", bm.react, 0, 2000, "%.0f")
            chb, bm.aimCone = imgui.slider_float("aims at the enemy nearest the camera's aim, within (deg)##bm", bm.aimCone, 5, 60, "%.0f")
            chb, bm.stagger = imgui.checkbox("hit makes it flinch##bm", bm.stagger)
            local hues = { 285, 300, 315 }
            local hi = bm.hue == 285 and 1 or bm.hue == 315 and 3 or 2
            chb, hi = imgui.combo("colour##bm", hi, { "purple (285)", "pink-purple (300)", "pink (315)" })
            if chb then bm.hue = hues[hi] end
            chb, bm.tint = imgui.checkbox("extra colour tint on top (new beams)##bm", bm.tint)
            chb, bm.hand = imgui.checkbox("flash at the hand##bm", bm.hand)
            chb, bm.handScale = imgui.slider_float("hand flash size##bm", bm.handScale, 0.05, 2, "%.2f")
            chb, bm.hitFx = imgui.checkbox("flash at the target##bm", bm.hitFx)
            chb, bm.hitScale = imgui.slider_float("target flash size##bm", bm.hitScale, 0.05, 3, "%.2f")
            chb, bm.sound = imgui.checkbox("Eldritch Smite's hit sound when it fires##bm", bm.sound)
            chb, bm.soundLead = imgui.slider_float("sound comes this early (s)##bm", bm.soundLead, 0, 0.6, "%.2f")
            chb, bm.air = imgui.checkbox("usable in the air (the air Eldritch Bolt animation)##bm", bm.air)
            chb, bm.airAnimFx = imgui.checkbox("in the air: keep the animation's own effects##bm", bm.airAnimFx)
            chb, bm.airLaunch = imgui.checkbox("in the air: launch flash at the hand (Eldritch Burst's)##bm", bm.airLaunch)
            chb, bm.airLaunchScale = imgui.slider_float("in the air: launch flash size##bm", bm.airLaunchScale, 0.1, 3, "%.2f")
            chb, bm.airFollow = imgui.checkbox("in the air: beam start follows the hand##bm", bm.airFollow)
            chb, bm.airFire = imgui.slider_float("in the air: beam after (s)##bm", bm.airFire, 0.05, 1.0, "%.2f")
            chb, bm.airEnd = imgui.slider_float("in the air: animation ends after (s)##bm", bm.airEnd, 0.2, 2.0, "%.2f")
            chb, bm.animSpeed = imgui.slider_float("opening speed (until the beam)##bm", bm.animSpeed, 0.5, 3, "%.2f")
            chb, bm.pickRange = imgui.slider_float("aims at enemies up to (m)##bm", bm.pickRange, 5, 50, "%.0f")
            chb, bm.airRange = imgui.slider_float("enemies above me (flying): aims up to (m)##bm", bm.airRange, 10, 60, "%.0f")
            chb, bm.airUp = imgui.slider_float("'above me' = more than (m) higher##bm", bm.airUp, 1, 10, "%.1f")
            chb, bm.lineRadius = imgui.slider_float("nothing aimed at: hits enemies this close to the line (m)##bm", bm.lineRadius, 0.3, 4, "%.1f")
            chb, bm.boom = imgui.checkbox("Eldritch Bolt's explosion on the hit##bm", bm.boom)
            chb, bm.hitDelay = imgui.slider_float("hit / explosion after the beam arrives (s)##bm", bm.hitDelay, 0, 0.6, "%.2f")
            chb, bm.animFx = imgui.checkbox("switch off the animation's own effects (the whirlwind)##bm", bm.animFx)
            chb, bm.boomScale = imgui.slider_float("explosion size##bm", bm.boomScale, 0.1, 3, "%.2f")
            chb, bm.rowLook = imgui.combo("row flashes##bm", bm.rowLook, { "full (with drifting smoke)", "no drifting smoke", "no smoke at all", "no shock ring (3.27: no beam)", "full, no blur / camera shake (3.28)", "full, no lights (3.29)", "F: no lights, no blur, no still smoke (3.31)", "G: no lights, no blur, no drifting smoke (3.31)" })
            chb, bm.handClean = imgui.checkbox("hand flash without blur / camera shake##bm", bm.handClean)
            chb, bm.freeze = imgui.checkbox("hold each flash at its bright moment (the beam stays bright)##bm", bm.freeze)
            chb, bm.freezeAt = imgui.slider_float("bright moment: s into each flash##bm", bm.freezeAt, 0, 0.6, "%.2f")
            chb, bm.frozenSpeed = imgui.slider_float("held flash still plays at (0 = still)##bm", bm.frozenSpeed, 0, 0.5, "%.2f")
            chb, bm.launchLen = imgui.slider_float("launch cloud: the first (m) of the beam##bm", bm.launchLen, 0, 6, "%.1f")
            chb, bm.launchSecs = imgui.slider_float("launch cloud goes after (s)##bm", bm.launchSecs, 0, 0.6, "%.2f")
            chb, bm.launchFade = imgui.slider_float("launch cloud shrinks away in (s)##bm", bm.launchFade, 0.02, 0.4, "%.2f")
            chb, bm.followHand = imgui.checkbox("beam start follows the hand after firing##bm", bm.followHand)
            chb, bm.chain = imgui.checkbox("beam = a row of hand flashes##bm", bm.chain)
            chb, bm.spacing = imgui.slider_float("one flash every (m)##bm", bm.spacing, 0.15, 3, "%.2f")
            chb, bm.chainScale = imgui.slider_float("flash size in the row##bm", bm.chainScale, 0.05, 2, "%.2f")
            chb, bm.maxCopies = imgui.slider_int("at most (flashes)##bm", bm.maxCopies, 5, 80)
            chb, bm.mesh = imgui.checkbox("also the Golem's beam mesh (didn't show in 3.22)##bm", bm.mesh)
            imgui.text("placement (the Golem's beam mesh runs -5 .. +10 along its own forward):")
            chb, bm.from = imgui.slider_float("mesh point at the hand##bm", bm.from, -5, 10, "%.1f")
            chb, bm.to = imgui.slider_float("mesh point at the target##bm", bm.to, -10, 15, "%.1f")
            chb, bm.dots = imgui.checkbox("show dots (green = hand, red = beam tip, yellow = mesh beam anchor)##bm", bm.dots)
            if imgui.button("fire a beam now (test, no animation)##bm") then
                pcall(function() local a = runtime.player(); bm.target = dbg.misty.pick(a); dbg.beam_fire(a) end)
            end
            imgui.tree_pop()
        end
        if imgui.tree_node("Hex") then
            local hx, chx = dbg.hex, nil
            imgui.text("Examine (Circle) in the bind window (after Eldritch Bolt / Burst): Hex on the bound enemy | " .. hx.info)
            chx, hx.secs = imgui.slider_float("lasts (s)##hex", hx.secs, 3, 60, "%.0f")
            chx, hx.defence = imgui.slider_float("defence lowered by##hex", hx.defence, 0, 0.5, "%.2f")
            chx, hx.heal = imgui.slider_float("HP back on a kill (of max)##hex", hx.heal, 0, 0.5, "%.2f")
            if imgui.button("Hex the enemy in front (test)##hex") then
                pcall(function() local a = runtime.player(); dbg.hex_put(a, dbg.misty.pick(a)) end)
            end
            local rebuild = false
            chx, hx.freezeAt = imgui.slider_float("freeze at (s) - the X is replayed to this frame##hex", hx.freezeAt, 0, 4, "%.2f")
            rebuild = rebuild or chx
            chx, hx.copies = imgui.slider_int("copies per line (more = more solid)##hex", hx.copies, 1, 4)
            rebuild = rebuild or chx
            if rebuild and hx.target then hx.build() end
            chx, hx.roll = imgui.slider_float("line angle (deg)##hex", hx.roll, 0, 90, "%.0f")
            chx, hx.scale = imgui.slider_float("X size##hex", hx.scale, 0.2, 4, "%.2f")
            chx, hx.over = imgui.slider_float("X above the head (m)##hex", hx.over, -2, 4, "%.2f")
            chx, hx.dots = imgui.checkbox("show placement dots (green = X centre, red = line anchor, blue = 1 m along the line)##hex", hx.dots)
            chx, hx.half = imgui.slider_float("move each line along itself##hex", hx.half, -4, 4, "%.2f")
            chx, hx.side = imgui.slider_float("move the lines apart / together##hex", hx.side, -3, 3, "%.2f")
            chx, hx.bright = imgui.slider_int("X brightness (our pink file 1-3)##hex", hx.bright, 1, 3)
            if chx and hx.target then hx.build() end
            imgui.text("colour tint (255/255/255 = the file's own pink):")
            chx, hx.col[1] = imgui.slider_int("X red##hex", hx.col[1], 0, 255)
            chx, hx.col[2] = imgui.slider_int("X green##hex", hx.col[2], 0, 255)
            chx, hx.col[3] = imgui.slider_int("X blue##hex", hx.col[3], 0, 255)
            chx, hx.behind = imgui.slider_float("Burst step: behind the enemy (m)##hex", hx.behind, 0.8, 5, "%.1f")
            imgui.tree_pop()
        end
        if imgui.tree_node("Misty Dive") then
            local md, chd = dbg.misty, nil
            imgui.text(("slot: %s   |   %s   |   no-shield checks answered: %d"):format(tostring(cfg.mistySkill), md.info, md.allowed or 0))
            if imgui.button(md.binding and "press the skill now...##md" or "put it in the next skill I press##md") then md.binding = true end
            chd, md.ownStrike = imgui.checkbox("straight down onto the enemy, sure hit, land beside it (3.50)##md", md.ownStrike)
            chd, md.fallSpeed = imgui.slider_float("fall speed (m/s)##md", md.fallSpeed, 2, 40, "%.0f")
            chd, md.headHold = imgui.slider_float("at its head: wait for the blade at most (s)##md", md.headHold, 0, 1, "%.2f")
            chd, md.dmg = imgui.slider_float("damage when the blade misses##md", md.dmg, 0, 5000, "%.0f")
            chd, md.aimBack = imgui.slider_float("body this far on my side of it (the blade is in front) (m)##md", md.aimBack, 0, 1.5, "%.2f")
            chd, md.landGap = imgui.slider_float("landing: keep this far off its body (m)##md", md.landGap, 0, 3, "%.1f")
            local mpick = md.mode == "ours" and 2 or 1
            chd, mpick = imgui.combo("teleport", mpick, { "SkyDive's teleport, then moved above the enemy", "ours (above the enemy in front)" })
            if chd then md.mode = mpick == 2 and "ours" or "msp" end
            chd, md.afterTeleport = imgui.slider_float("air Empale after SkyDive's teleport (s)", md.afterTeleport, 0, 0.5, "%.2f")
            chd, md.above = imgui.slider_float("height above the enemy's head (m)", md.above, 0.5, 6, "%.1f")
            chd, md.back = imgui.slider_float("toward me from the enemy (m)", md.back, 0, 4, "%.1f")
            chd, md.lockWarp = imgui.checkbox("straight down: hold the character controller too", md.lockWarp)
            chd, md.fxOn = imgui.checkbox(("our colour on its effects + body glow (%d copies played)"):format(md.fxN or 0), md.fxOn)
            local FIN = { "staggered", "always", "never" }
            local fpick = md.finish == "always" and 2 or md.finish == "never" and 3 or 1
            chd, fpick = imgui.combo("execution animation" .. (md.finishHook and "" or " (hook failed)"), fpick,
                { "only on a staggered, standing enemy", "whenever the game does it", "never" })
            if chd then md.finish = FIN[fpick] end
            chd, md.range = imgui.slider_float("finds enemies up to (m)", md.range, 3, 40, "%.0f")
            imgui.tree_pop()
        end
        imgui.tree_pop()
    end
    if imgui.tree_node("Debug") then
        imgui.text(("%s | button: %s | action: %s"):format(live.on and "ACTIVE" or "off", st.phase, tostring(dbg.action)))
        imgui.text(("Archfey Combo: part %d%s | %s | Forbeding Bolts: %d"):format(combo.stage,
            combo.target and " (target set)" or "", tostring(dbg.leap or "Quik Fot: -"), dbg.bindShots or 0))
        if combo.slash then imgui.text("Eldritch Slash: " .. (combo.slash.on and "playing" or "-")) end
        if combo.result then
            imgui.text_colored("Last " .. combo.result.text, combo.result.ok and 0xFF40FF40 or 0xFF4040FF)
        end
        imgui.text(tostring(dbg.thief or "Footpad / Controlled Fall: -"))
        imgui.text(("Test dummies: %d | %s"):format(dummy.count, dummy.status))
        for _, d in ipairs(DUMMIES) do
            if imgui.button("Spawn " .. d.name) then require("DragonCore.game.actor_fx").defer(function() dummy_spawn(d) end) end
            imgui.same_line()
        end
        imgui.new_line()
        for _, d in ipairs(DUMMIES) do
            if d.tag == "ch250000" or d.tag == "ch254000" or d.tag == "ch253000" or d.tag == "ch253012" or d.tag == "ch230004" then
                if imgui.button("Spawn a NORMAL " .. d.name .. " (fights)##real") then require("DragonCore.game.actor_fx").defer(function() dummy.real(d) end) end
                imgui.same_line()
            end
        end
        imgui.new_line()
        dbg.vf = dbg.vf or { density = 5, size = 8, height = 5, col = 0, emis = false, kind = 2 }
        local vf = dbg.vf
        if imgui.button(vf.go and "remove the fog box##vf" or "Darkness test: a black FOG BOX 10 m ahead (engine volumetric fog)##vf") then
            if vf.go then pcall(function() vf.go:call("destroy(via.GameObject)", vf.go) end); vf.go, vf.fog = nil, nil
            else
                local ok, e = pcall(function()
                    local a = runtime.player()
                    local tr = a.character:get_GameObject():get_Transform()
                    local p, f = tr:get_Position(), tr:get_Rotation() * Vector3f.new(0, 0, 1)
                    local l = math.max(0.001, math.sqrt(f.x * f.x + f.z * f.z))
                    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_fog", 0)
                    go = go:add_ref(); go:call(".ctor"); go:set_Name("Pactblade_fog")
                    go:get_Transform():set_Position(Vector3f.new(p.x + f.x / l * 10, p.y, p.z + f.z / l * 10))
                    local fog = go:call("createComponent(System.Type)", sdk.typeof("via.render.VolumetricFog"))
                    if not fog then error("no VolumetricFog component") end
                    vf.go, vf.fog = go, fog:add_ref()
                end)
                vf.info = ok and "fog box made" or ("fog failed: " .. tostring(e))
                note("Darkness test: " .. vf.info)
            end
        end
        if imgui.button("list the game's fog volumes here (to the trace)##vf") then
            pcall(function()
                local function desc(f)
                    local out = {}
                    for _, g in ipairs({ "get_Enabled", "get_VolumeType", "get_Density", "get_Radius", "get_OBBEnabled", "get_EmissionEnabled" }) do
                        local ok, v = pcall(f.call, f, g)
                        out[#out + 1] = g:sub(5) .. " " .. (ok and tostring(v) or "?")
                    end
                    pcall(function() local c = f:call("get_Color"); out[#out + 1] = ("col %d/%d/%d/%d"):format(c.r, c.g, c.b, c.a) end)
                    pcall(function()
                        local go = f:call("get_GameObject")
                        local sc = go:get_Transform():get_LocalScale()
                        out[#out + 1] = ("%s scale %.1f/%.1f/%.1f"):format(tostring(go:get_Name()), sc.x, sc.y, sc.z)
                    end)
                    return table.concat(out, ", ")
                end
                local list = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
                    :call("findComponents(System.Type)", sdk.typeof("via.render.VolumetricFog"))
                local n = list and list:call("get_Length") or 0
                note(("fog volumes in the scene: %d"):format(n))
                for k = 0, math.min(n, 6) - 1 do note("  fog " .. k .. ": " .. desc(list:call("get_Item", k))) end
                if vf.fog then note("  OURS: " .. desc(vf.fog)) end
                local ctl = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
                    :call("findComponents(System.Type)", sdk.typeof("via.render.VolumetricFogControl"))
                note(("fog controls: %d"):format(ctl and ctl:call("get_Length") or 0))
            end)
        end
        if vf.fog then
            local chv
            chv, vf.density = imgui.slider_float("fog density##vf", vf.density, 0, 100, "%.1f")
            chv, vf.size = imgui.slider_float("fog box width (m)##vf", vf.size, 1, 30, "%.1f")
            chv, vf.height = imgui.slider_float("fog box height (m)##vf", vf.height, 1, 20, "%.1f")
            chv, vf.col = imgui.slider_float("fog brightness (0 = black)##vf", vf.col, 0, 1, "%.2f")
            chv, vf.kind = imgui.slider_int("fog type (2 box, 3 box world, 1 height fog, 0 global)##vf", vf.kind, 0, 4)
            pcall(function()
                local fog = vf.fog
                pcall(function() fog:call("set_VolumeType", vf.kind) end)
                pcall(function() fog:call("set_Density", vf.density + 0.0) end)
                pcall(function() fog:call("set_Radius", vf.size / 2) end)
                pcall(function() fog:call("set_Color", via_colour({ vf.col, vf.col, vf.col, 1 })) end)
                pcall(function() fog:call("set_Enabled", true) end)
                vf.go:get_Transform():set_LocalScale(Vector3f.new(vf.size, vf.height, vf.size))
            end)
            imgui.text("  " .. tostring(vf.info))
        end
        imgui.text("Darkness test (3.72): the game's dark-area shells, 10 m ahead, 15 s, harmless (Skill Maker's file no longer exists):")
        for _, dk in ipairs({ { "Chimera variant ch254001_60", "AppSystem/ch/ch254/001/60/userdata/ch254001_60darkareashellparamdata.user", 0 },
                              { "ch223004", "AppSystem/ch/ch223/004/userdata/ch223004darkareashellparamdata.user", 0 },
                              { "ch227001 #0", "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user", 0 },
                              { "ch227001 #1", "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user", 1 },
                              { "ch227001 #2", "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user", 2 },
                              { "ch227001 #3", "AppSystem/ch/ch227/001/userdata/ch227001darkareashellparamdata.user", 3 } }) do
            if imgui.button("dark area: " .. dk[1] .. "##dk" .. dk[1]) then
                require("DragonCore.game.actor_fx").defer(function()
                    local a = runtime.player()
                    local res, err = spawn(a, { type = "shell", id = "pb_darkness_test", shell = dk[2], shell_id = dk[3],
                                                cast = { mode = "owner", offset = { 0, 0, 10 } }, lifetime = 15, cosmetic = true })
                    dummy.status = res and ("dark area spawned: " .. dk[1]) or ("dark area failed: " .. tostring(err))
                    note(dummy.status)
                end)
            end
            imgui.same_line()
        end
        imgui.new_line()
        if imgui.button("Remove all dummies (and the normal ones)") then
            require("DragonCore.game.summons").request_remove_all()
            dummy.set, dummy.hits, dummy.count, dummy.wanted, dummy.status = {}, {}, 0, {}, "removed"
        end
        local okH, hr = pcall(function() return sdk.get_managed_singleton("app.TimeManager"):get_InGameHour() end)
        imgui.text(("Time of day: %s:00"):format(okH and tostring(hr) or "?"))
        if imgui.button("Skip to daytime (10:00)") then
            local okS, e2 = pcall(dbg.day_skip, 10)
            if not okS then note("time skip failed: " .. tostring(e2)) end
        end
        imgui.same_line()
        ch, cfg.keepDay = imgui.checkbox("keep it daytime", cfg.keepDay == true)
        if ch then save_cfg() end
        -- the Recorder: my effects / sounds / animations (+ nearby objects' sounds) -> Caustic Brew's sound picks
        if imgui.tree_node("Recorder (my effects + sounds + animations, works with any weapon)") then
            local chr
            chr, dbg.rec.secs = imgui.slider_float("seconds", dbg.rec.secs, 2, 30, "%.0f")
            if imgui.button(dbg.rec.on and "recording..." or "record now") and not dbg.rec.on then
                dbg.rec.list, dbg.rec.t0, dbg.rec.lastMotion, dbg.rec.on, dbg.rec.scs = {}, os.clock(), nil, true, {}
            end
            local chn
            chn, dbg.rec.near = imgui.checkbox("also sounds of objects within 10 m (barrels, vases, water ...)", dbg.rec.near)
            imgui.text(dbg.rec.info)
            imgui.tree_pop()
        end
        imgui.text("Last hits (before -> after | physical, magick):")
        for i = #dbg.hits, 1, -1 do
            local h = dbg.hits[i]
            imgui.text(("  %-8s %.0f -> %.0f | physical %.0f, magick %.0f, elemental %.0f | x%.2f"):format(
                h.kind, h.before or 0, h.after or 0, h.phys, h.mag, h.elemental or 0, h.rate or 0))
        end
        for i = #dbg.log, 1, -1 do imgui.text(dbg.log[i]) end
        imgui.tree_pop()
    end
    end)
    imgui.pop_style_color(#THEME)
    if not ok then imgui.text_colored("menu error: " .. tostring(err), 0xFF4040FF) end
    imgui.tree_pop()
end)
