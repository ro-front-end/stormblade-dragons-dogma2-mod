-- ==============================================================================
-- Stormblade / core.lua
-- State management and integration with VSB (Vocation and Skill Builder)
-- ==============================================================================

local core = {}

local PACK_ID = "stormblade"
local runtime = nil

-- Lazy loader for DragonCore runtime
local function get_runtime()
    if not runtime then
        pcall(function() runtime = require("DragonCore.game.runtime") end)
    end
    return runtime
end

local state = {
    active = false,
    player = nil,
    character = nil,
    game_object = nil,
    weapon_job = nil,
    shield_worn = false,
}

--- Checks whether Stormblade is currently selected in VSB picks for Job01 (Fighter)
function core.is_picked_in_vsb()
    local api = rawget(_G, "VSB_API")
    local app = api and api.app
    if not app or not app.picks then return false end
    return app.picks.Job01 == PACK_ID
end

--- Updates the core player and vocation state (called periodically)
function core.update()
    local rt = get_runtime()
    if not rt then
        state.active = false
        return false
    end

    local player = rt.player()
    if not player or not player:valid() then
        state.active = false
        state.player = nil
        return false
    end

    state.player = player
    state.character = player.character
    state.game_object = player.game_object and player.game_object:get_address()
    state.weapon_job = player:weapon_job()

    -- Check shield equipment status
    state.shield_worn = false
    pcall(function()
        local holder = player.character:get_WeaponAndItemHolder()
        local left = holder and holder:get_LeftWeapon()
        state.shield_worn = (left ~= nil and left:get_Weapon() ~= nil)
    end)

    -- Stormblade is active when picked in VSB and wielding a sword (Job01)
    local picked = core.is_picked_in_vsb()
    local sword_in_hand = (state.weapon_job == 1)
    state.active = (picked and sword_in_hand)

    return state.active
end

function core.is_active()
    return state.active
end

function core.has_shield()
    return state.shield_worn
end

function core.get_player()
    return state.player
end

function core.get_state()
    return state
end

return core

