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
        imgui.text_colored(active and "Status: ACTIVE" or "Status: INACTIVE", active and 0xFF00FF00 or 0xFF888888)
        if active then
            imgui.text("Weapon: Sword wielded (Job01)")
            imgui.text("Shield: Refused (Empty Off-Hand)")
            imgui.text("Attack Speed: +30% Chain")
            imgui.text("Dodge: Lightning Step (RB)")
            imgui.text("Heavy Attack: Thunderstrike (Off-Hand Palm)")
        else
            imgui.text("Equip a sword and pick Stormblade in VSB to activate.")
        end
        imgui.tree_pop()
    end
end)
