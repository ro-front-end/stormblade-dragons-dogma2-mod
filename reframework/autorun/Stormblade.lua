-- ==============================================================================
-- Stormblade - Custom Hybrid Vocation for Dragon's Dogma 2
-- REFramework Script / Thin Composition Root
-- Requires: _DragonCore and VocationAndSkillBuilder (VSB)
-- ==============================================================================

local core = require("Stormblade.core")
local weapons = require("Stormblade.weapons")
local locomotion = require("Stormblade.locomotion")
local skills = require("Stormblade.skills")

-- Initialize hooks
skills.init()

-- Main update loop (throttled every few frames to conserve CPU cycles)
local frame_count = 0
local TICK_INTERVAL = 10

re.on_frame(function()
    frame_count = frame_count + 1
    if frame_count >= TICK_INTERVAL then
        frame_count = 0
        core.update()
        weapons.update()
        locomotion.update()
        skills.update_core_skills()
    end

    -- Attack speed must be evaluated on active frames
    if core.is_active() then
        skills.update_attack_speed()
    end
end)

-- Clean teardown on script reset
re.on_script_reset(function()
    weapons.restore()
    locomotion.restore()
    skills.restore()
end)

-- REFramework ImGui Panel
re.on_draw_ui(function()
    if imgui.tree_node("Stormblade Vocation") then
        local active = core.is_active()
        if active then
            imgui.text_colored("Status: ACTIVE (Lightning Infused)", 0xFF40C0FF)
        else
            imgui.text_colored("Status: INACTIVE (Pick 'Stormblade' in VSB)", 0xFF808080)
        end

        if active and core.has_shield() then
            imgui.text_colored("Warning: Prescinds from shields. Unequip your shield for full agility.", 0xFF5050FF)
        end
        imgui.tree_pop()
    end
end)

