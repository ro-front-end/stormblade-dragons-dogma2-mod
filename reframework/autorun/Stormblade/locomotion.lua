-- ==============================================================================
-- Stormblade / locomotion.lua
-- Agile movement speed multiplier (+12%) for character locomotion
-- ==============================================================================

local core = require("Stormblade.core")
local locomotion = {}

local MOVE_SPEED_MULTIPLIER = 1.05 -- 5% boost: subtle agile feel
local was_active = false

--- Updates character movement speed
function locomotion.update()
    local is_active = core.is_active()
    local player = core.get_player()
    if not player or not player:valid() then return end

    if is_active then
        was_active = true
        pcall(function()
            local chara = player.character
            if chara and chara.Locomotion then
                -- Apply controlled speed factor to locomotion controller
                chara.Locomotion:call("set_SpeedRate", MOVE_SPEED_MULTIPLIER)
            end
        end)
    elseif was_active then
        locomotion.restore()
    end
end

--- Restores character locomotion back to vanilla standard (1.0x)
function locomotion.restore()
    local player = core.get_player()
    if player and player:valid() and player.character then
        pcall(function()
            if player.character.Locomotion then
                player.character.Locomotion:call("set_SpeedRate", 1.0)
            end
        end)
    end
    was_active = false
end

return locomotion

