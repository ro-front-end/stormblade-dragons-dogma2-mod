-- ==============================================================================
-- Stormblade / skills.lua
-- RB lightning projectile, 1.5x attack speed chain, and shieldless handling
-- ==============================================================================

local core = require("Stormblade.core")
local skills = {}

local FAST_ATTACK, FAST_OTHER = 1.5, 1.2
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

