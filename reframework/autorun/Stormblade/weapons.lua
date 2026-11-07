-- ==============================================================================
-- Stormblade / weapons.lua
-- Spellsword Hybrid Scaling: 70% Physical + 65% Magick + Unsheathed Thunder Boon
-- Balanced for +30% agile attack speed without double weapon-element dipping
-- ==============================================================================

local core = require("Stormblade.core")
local weapons = {}

-- Balanced Ratios: 70% physical (agile 1H fast-cadence weight) + 65% magick (scales shells & boon natively)
-- Weapon _Element is preserved (not forced to 3) so unsheathed Thunder Boon doesn't double-dip on light slashes
local PHYS_RATIO = 0.70
local MAG_RATIO = 0.65

-- Active sword backup to guarantee clean restore
local backup = nil -- { param, id, itemId, original_phys, original_mag, original_el, original_store, own }

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
        if player:weapon_drawn() then
            if not statuses.active(player.character, "thunder_boon") then
                statuses.apply(player.character, "thunder_boon")
            end
        else
            if statuses.active(player.character, "thunder_boon") then
                statuses.cure(player.character, "thunder_boon")
            end
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
            backup.param._PhysicalAttack = backup.original_phys
            backup.param._MagicAttack = backup.original_mag
            backup.param._Element = backup.original_el
            backup.param._ElementStore = backup.original_store
        end
        if backup.own and backup.own.obj then
            backup.own.obj._PhysicalAttack = backup.own.phys
            backup.own.obj._MagicAttack = backup.own.mag
            backup.own.obj._Element = backup.own.el
            backup.own.obj._ElementStore = backup.own.store
        end
        refresh_character_equipment(backup.itemId)
    end)
    backup = nil
end

--- Applies Spellblade Thunder scaling to the currently held sword
function weapons.update()
    if not core.is_active() or _G.SB_SAVE_GUARD then
        if backup then weapons.restore() end
        return
    end

    local weapon_id = get_held_weapon_id()
    if not weapon_id then
        if backup then weapons.restore() end
        return
    end

    local fulm = tonumber(_G.SB_FULMINATION_BONUS) or 0

    -- If weapon is already modified and still matches, verify parameters haven't reset
    if backup and backup.id == weapon_id then
        local target_phys = math.max(1, math.floor(backup.original_phys * PHYS_RATIO)) + fulm
        local target_mag = math.max(backup.original_mag or 0, math.floor(backup.original_phys * MAG_RATIO)) + fulm
        ensure_thunder_boon()
        pcall(function()
            local p = backup.param
            local o = backup.own and backup.own.obj
            local need = (p._PhysicalAttack ~= target_phys or p._MagicAttack ~= target_mag)
            if o then
                local o_phys = math.max(1, math.floor(backup.own.phys * PHYS_RATIO)) + fulm
                local o_mag = math.max(backup.own.mag or 0, math.floor(backup.own.phys * MAG_RATIO)) + fulm
                if o._PhysicalAttack ~= o_phys or o._MagicAttack ~= o_mag then
                    o._PhysicalAttack = o_phys
                    o._MagicAttack = o_mag
                    need = true
                end
            end
            if need then
                p._PhysicalAttack = target_phys
                p._MagicAttack = target_mag
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
        original_phys = param._PhysicalAttack,
        original_mag = param._MagicAttack,
        original_el = param._Element,
        original_store = param._ElementStore,
    }

    pcall(function()
        local player = core.get_player()
        local ed = player and player.character and im:call("getEquipData(app.Character)", player.character)
        local data = ed and ed:get_field("Data")
        local main_slot = sdk.find_type_definition("app.EquipData.SlotEnum"):get_field("Main"):get_data(nil)
        local sd = data and data:call("get(app.EquipData.SlotEnum)", main_slot)
        local own = sd and sd:get_field("_ItemData")
        if own and own:get_address() ~= param:get_address() and own:get_field("_PhysicalAttack") ~= nil then
            backup.own = {
                obj = own:add_ref(),
                phys = own._PhysicalAttack,
                mag = own._MagicAttack,
                el = own._Element,
                store = own._ElementStore,
            }
            own._PhysicalAttack = math.max(1, math.floor(backup.own.phys * PHYS_RATIO)) + fulm
            own._MagicAttack = math.max(backup.own.mag or 0, math.floor(backup.own.phys * MAG_RATIO)) + fulm
        end
    end)

    -- Apply balanced Spellblade formula: 70% Physical, 65% Magick (no forced _Element to avoid double-dipping with Thunder Boon)
    param._PhysicalAttack = math.max(1, math.floor(backup.original_phys * PHYS_RATIO)) + fulm
    param._MagicAttack = math.max(backup.original_mag or 0, math.floor(backup.original_phys * MAG_RATIO)) + fulm

    refresh_character_equipment(backup.itemId)
    ensure_thunder_boon()
end

return weapons
