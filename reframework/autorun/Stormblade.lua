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
            pcall(function()
                local vp = require("VSB.game.vocprogress")
                local prog = require("VSB.core.progression")
                local pts = vp and vp.points_of and vp.points_of("stormblade") or 0
                local r = prog and prog.rank_from_points and prog.rank_from_points({ progression = { difficulty = 2.2 } }, pts) or 1
                imgui.text(string.format("Rank: %d  |  DCP Points: %d", r, pts))
                if imgui.button("Reset Stormblade to Rank 1 (0 Points)") then
                    local s = vp.snapshot and vp.snapshot() or { points = {} }
                    if s and s.points then
                        s.points.stormblade = 0
                        vp.set(s)
                    end
                    pcall(function()
                        for _, slot in ipairs({ 0, 1, 4 }) do
                            local p = string.format("VSB/state/saves/slot_%d.json", slot)
                            local d = json.load_file(p)
                            if d then
                                if d.vocation_progress and d.vocation_progress.points then
                                    d.vocation_progress.points.stormblade = 0
                                end
                                d.custom = {}
                                d.equipped = nil
                                json.dump_file(p, d)
                            end
                        end
                        json.dump_file("VSB/state/handover.json", {})
                    end)
                end
            end)
        else
            imgui.text("Equip a sword and pick Stormblade in VSB to activate.")
        end
        imgui.tree_pop()
    end
end)
