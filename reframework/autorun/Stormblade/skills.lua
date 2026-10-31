-- ==============================================================================
-- Stormblade / skills.lua
-- Lightning Step agile evasion on RB, 1.30x (+30%) attack speed chain, and shieldless handling
-- Thunderstrike: Empty off-hand heavy attack (palm thrust) replacing sword heavy attacks
-- ==============================================================================

local core = require("Stormblade.core")
local skills = {}

local FAST_ATTACK, FAST_OTHER = 1.30, 1.20
local BOLT_CHARGED_SCALING = 2.2 -- Charged Storm Bolt deals 2.2x Strength
local BOLT_BURST_SCALING = 1.5   -- Combo Burst deals 1.5x Strength
local BOLT_TAP_SCALING = 1.0     -- Quick Tap deals 1.0x Strength
local LEVIN_SCALING = 2.8        -- Levin Storm celestial strike deals 2.8x Strength
local NOVA_SCALING = 2.0         -- Nova Electrica 360 shockwave deals 2.0x Strength
local ONSLAUGHT_ACTIONS = {
    Job01_AttackLeft = true,
    Job01_AttackRight = true,
    Job01_AttackAir = true
}

-- Fighter Heavy Attack replacement: Thunderstrike (empty off-hand palm thrust)
local HEAVY_ATTACKS = {
    Job01_ShortRangeHeavyAttack = true,
    Job01_LongRangeHeavyAttack = true,
    Job01_DashHeavyAttack = true,
    Job01_HeavyAttackAir = true,
    Job01_StrikeShortRangeHeavyAttack = true,
    Job01_StrikeLongRangeHeavyAttack = true,
}

local heavy_hook_installed = false
local in_thunderstrike_request = false
local thunderstrike_state = { active = false, start_time = 0, spawned = false }

local function install_heavy_attack_hook()
    if heavy_hook_installed then return end
    heavy_hook_installed = true
    pcall(function()
        local am_type = sdk.find_type_definition("app.ActionManager")
        local method = am_type and am_type:get_method(
            "requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
        if method then
            sdk.hook(method, function(args)
                if not core.is_active() or in_thunderstrike_request then return end
                local player = core.get_player()
                if not player or not player:valid() or not player.action_manager then return end

                local am_addr = sdk.to_int64(args[2])
                if am_addr ~= player.action_manager:get_address() then return end

                local ok, name = pcall(function() return sdk.to_managed_object(args[4]):call("ToString()") end)
                if ok and name and (HEAVY_ATTACKS[name] or (name:find("^Job01_") and name:find("HeavyAttack"))) then
                    in_thunderstrike_request = true
                    player:request_action("Job07_MagicBindComplete", 0)
                    thunderstrike_state.active = true
                    thunderstrike_state.start_time = os.clock()
                    thunderstrike_state.spawned = false
                    in_thunderstrike_request = false
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(r) return r end)
        end
    end)
end

--- Updates Thunderstrike timing and spawns electric palm burst shell
function skills.update_thunderstrike()
    if not core.is_active() or not thunderstrike_state.active then return end
    local player = core.get_player()
    if not player or not player:valid() then
        thunderstrike_state.active = false
        return
    end

    local elapsed = os.clock() - thunderstrike_state.start_time

    if not thunderstrike_state.spawned and elapsed >= 0.20 then
        thunderstrike_state.spawned = true
        pcall(function()
            local PB = rawget(_G, "PB")
            if PB then PB.thunderstrikeT = os.clock() end

            local shell_node = {
                type = "shell",
                id = "sb_thunderstrike",
                shell = (PB and PB.JOB07_SHELLS) or "AppSystem/Shell/UserData/HumanShellParamData_Job07.user",
                shell_id = 12,
                cast = {
                    mode = "joint",
                    joint = "L_Hand_Palm",
                    face = "owner"
                },
                element = "Thunder",
                damage_type = "Hitback_S",
                attack_rate = 2.2,
                color = { 50, 180, 255, 255 },
                scale = 1.0
            }
            local res, err = player:spawn_shell(shell_node, nil)
            if res and res.record and PB and PB.colour_shell then
                PB.colour_shell(res.record, { 0.20, 0.70, 1.0, 1.0 }, 4.0, true)
            end
        end)
    end

    if elapsed >= 0.70 then
        thunderstrike_state.active = false
    end
end

-- Prevent equipping shields while active
local SLOT_SUB = 1
local hook_installed = false

local function install_shield_refusal_hook()
    if hook_installed then return end
    hook_installed = true
    pcall(function()
        local item_mgr = sdk.find_type_definition("app.ItemManager")
        local method = item_mgr and item_mgr:get_method(
            "setEquip(app.ItemDefine.StorageData, app.Character, app.EquipData.SlotEnum, System.Boolean, System.Boolean)")
        if method then
            sdk.hook(method, function(args)
                if not core.is_active() then return end
                local slot = (sdk.to_int64(args[5]) & 0xFFFFFFFF)
                if slot == SLOT_SUB then
                    local target_chara = sdk.to_managed_object(args[4])
                    local player = core.get_player()
                    if player and player.character and target_chara and
                       target_chara:get_address() == player.character:get_address() then
                        -- Refuse equipping a shield while Stormblade is active
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end
            end, function(r) return r end)
        end
    end)
end

--- Updates attack animation speed based on current action
function skills.update_attack_speed()
    if not core.is_active() then return end
    local player = core.get_player()
    if not player or not player:valid() then return end

    pcall(function()
        local cur = player:current_action(0)
        if not cur then return end

        local is_attack = (cur:find("Attack") ~= nil or cur:find("FinishingMove") ~= nil or cur == "Job07_MagicBindComplete")
        if is_attack then
            local sp = (ONSLAUGHT_ACTIONS[cur] or cur == "Job07_MagicBindComplete") and FAST_ATTACK or FAST_OTHER
            player:set_speed(sp)
        else
            player:set_speed(nil)
        end
    end)
end

--- Ensures weapon is drawn if attempting a skill while sheathed
function skills.ensure_drawn()
    local player = core.get_player()
    if not player or not player:valid() then return false end
    if player:weapon_drawn() then return true end
    pcall(function()
        local ok = player:draw_weapon()
        if not ok then player:request_action("DrawWeapon", 0) end
    end)
    return false
end

--- Ensures Stormblade core skills (Tusk Toss charged slash) are active from Rank 1
function skills.update_core_skills()
    if not core.is_active() then return end
    local player = core.get_player()
    if not player or not player:valid() or not player.character then return end
    pcall(function()
        local human = player.character:get_Human()
        local ctx = human and human["<SkillContext>k__BackingField"]
        if ctx then
            ctx:call("setNormalSkillEnable(app.HumanNormalSkillID)", 6)
        end
    end)
end

function skills.init()
    install_shield_refusal_hook()
    install_heavy_attack_hook()
end

function skills.restore()
    local player = core.get_player()
    if player and player:valid() then
        pcall(function() player:set_speed(nil) end)
    end
end

return skills
