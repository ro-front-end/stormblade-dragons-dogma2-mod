-- ==============================================================================
-- Stormblade / skills.lua
-- Lightning Step agile evasion on RB, 1.30x (+30%) attack speed chain, and shieldless handling
-- ==============================================================================

local core = require("Stormblade.core")
local skills = {}

local FAST_ATTACK, FAST_OTHER = 1.30, 1.20
local BOLT_CHARGED_SCALING = 2.2 -- Charged Storm Bolt deals 2.2x Strength
local BOLT_BURST_SCALING = 1.5   -- Combo Burst deals 1.5x Strength
local BOLT_TAP_SCALING = 1.0     -- Quick Tap deals 1.0x Strength
local LEVIN_SCALING = 2.8        -- Levin Storm celestial strike deals 2.8x Strength
local NOVA_SCALING = 2.0         -- Nova Eléctrica 360 shockwave deals 2.0x Strength
local ONSLAUGHT_ACTIONS = {
    Job01_AttackLeft = true,
    Job01_AttackRight = true,
    Job01_AttackAir = true
}

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

        local is_attack = (cur:find("Attack") ~= nil or cur:find("FinishingMove") ~= nil)
        if is_attack then
            local sp = ONSLAUGHT_ACTIONS[cur] and FAST_ATTACK or FAST_OTHER
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
end

function skills.restore()
    local player = core.get_player()
    if player and player:valid() then
        pcall(function() player:set_speed(nil) end)
    end
end

return skills

