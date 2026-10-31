-- ==============================================================================
-- Stormblade / weapons.lua
-- Duospear formula: Scales sword MagicAttack = PhysicalAttack + Thunder infusion
-- ==============================================================================

local core = require("Stormblade.core")
local weapons = {}

local THUNDER_ELEMENT = 3
local FULL_STORE = 100

-- Active sword backup to guarantee clean restore
local backup = nil -- { param, id, itemId, original_mag, original_el, original_store, own }

local function get_item_manager()
    return sdk.get_managed_singleton("app.ItemManager")
end

local function get_held_weapon_id()
    local player = core.get_player()
    if not player or not player:valid() then return nil end
    local id = nil
    pcall(function()
        local holder = player.character:get_WeaponAndItemHolder()
        local right = holder and holder:get_RightWeapon()
        local w = right and right:get_Weapon()
        if w then id = w:get_WeaponID() end
    end)
    return id
end

local function refresh_character_equipment(itemId)
    local im = get_item_manager()
    local player = core.get_player()
    if not im or not player or not player.character then return end
    pcall(function()
        local ed = im:call("getEquipData(app.Character)", player.character)
        local data = ed and ed:get_field("Data")
        if data then
            pcall(data.call, data, "clearParam")
            pcall(data.call, data, "calc")
            pcall(im.call, im, "applyEquipDataForCharacter(app.Character)", player.character)
        end
    end)
end

local function ensure_thunder_boon()
    local player = core.get_player()
    if not player or not player:valid() or not player.character then return end
    pcall(function()
        local statuses = require("DragonCore.game.statuses")
        if not statuses.active(player.character, "thunder_boon") then
            statuses.apply(player.character, "thunder_boon")
        end
    end)
end

--- Restores any modified weapon stats back to vanilla
function weapons.restore()
    pcall(function()
        local player = core.get_player()
        if player and player:valid() and player.character then
            local statuses = require("DragonCore.game.statuses")
            statuses.cure(player.character, "thunder_boon")
        end
    end)
    if not backup then return end
    pcall(function()
        if backup.param then
            backup.param._MagicAttack = backup.original_mag
            backup.param._Element = backup.original_el
            backup.param._ElementStore = backup.original_store
        end
        if backup.own and backup.own.obj then
            backup.own.obj._MagicAttack = backup.own.mag
            backup.own.obj._Element = backup.own.el
            backup.own.obj._ElementStore = backup.own.store
        end
        refresh_character_equipment(backup.itemId)
    end)
    backup = nil
end

--- Applies Duospear Thunder scaling to the currently held sword
function weapons.update()
    if not core.is_active() then
        if backup then weapons.restore() end
        return
    end

    local weapon_id = get_held_weapon_id()
    if not weapon_id then
        if backup then weapons.restore() end
        return
    end

    -- If weapon is already modified and still matches, verify parameters haven't reset
    if backup and backup.id == weapon_id then
        ensure_thunder_boon()
        pcall(function()
            local p = backup.param
            if p._MagicAttack ~= p._PhysicalAttack or p._Element ~= THUNDER_ELEMENT then
                p._MagicAttack = p._PhysicalAttack
                p._Element = THUNDER_ELEMENT
                p._ElementStore = FULL_STORE
                refresh_character_equipment(backup.itemId)
            end
        end)
        return
    end

    -- Swapped to a new sword: restore old first
    if backup then weapons.restore() end

    local im = get_item_manager()
    if not im then return end

    local ok, param = pcall(function() return im:call("getItemData(app.WeaponID)", weapon_id) end)
    if not ok or not param then return end

    backup = {
        param = param:add_ref(),
        id = weapon_id,
        itemId = param._Id,
        original_mag = param._MagicAttack,
        original_el = param._Element,
        original_store = param._ElementStore,
    }

    -- Apply Duospear formula: Magic Attack = Physical Attack, Element = Thunder
    param._MagicAttack = param._PhysicalAttack
    param._Element = THUNDER_ELEMENT
    param._ElementStore = FULL_STORE

    refresh_character_equipment(backup.itemId)
    ensure_thunder_boon()
end

return weapons

