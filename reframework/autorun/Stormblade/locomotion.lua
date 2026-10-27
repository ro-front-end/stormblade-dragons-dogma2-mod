-- ==============================================================================
-- Stormblade / locomotion.lua
-- Agile movement speed: Normal walk (1.00x) and +4% run/sprint (1.04x)
-- ==============================================================================

local core = require("Stormblade.core")
local locomotion = {}

local RUN_SPEED_MULTIPLIER = 1.04  -- 4% boost: refined agile feel
local WALK_SPEED_MULTIPLIER = 1.00 -- 1.00x vanilla: walk naturally alongside pawns/NPCs
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
                local is_running = false
                if player:button_down("Dash") then
                    is_running = true
                else
                    local cc = chara["<CharaController>k__BackingField"]
                    if cc then
                        local v = cc:call("get_Velocity")
                        if v and (v.x * v.x + v.z * v.z) > 4.84 then -- > 2.2 m/s
                            is_running = true
                        end
                    end
                end
                local rate = is_running and RUN_SPEED_MULTIPLIER or WALK_SPEED_MULTIPLIER
                chara.Locomotion:call("set_SpeedRate", rate)
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

