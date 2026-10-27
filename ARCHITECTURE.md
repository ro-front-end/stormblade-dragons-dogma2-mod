# 🏛️ Architecture & Engineering Guidelines — Stormblade

This document outlines the software design principles, conventions, and architectural patterns adopted in the **Stormblade** project. As a modular game modification running within Capcom's RE Engine via REFramework, following these guidelines ensures code maintainability, memory safety, and complete decoupling.

---

## 1. Core Design Principles

### 1.1 Separation of Concerns (SoC)
* **Declarative Data (JSON):** Vocation definitions, attribute growth, discipline points (DCP), unlock ranks, and skill timelines reside strictly in JSON manifests under `reframework/data/VSB/packs/stormblade/`.
* **Runtime Logic (Lua):** Engine hooks, memory address tracking, and input processing reside in `reframework/autorun/Stormblade/`.
* **Thin Entry-Point:** `Stormblade.lua` serves exclusively as a composition root (bootstrapper). It does not contain game logic; it only initializes services and binds lifecycle events.

### 1.2 DRY (Don't Repeat Yourself)
* Common RE Engine operations (retrieving the player instance, accessing `app.ItemManager`, memory pointer casting) are encapsulated into dedicated service helpers.
* Constants (Element IDs, Slot Enums, Job IDs) are centralized to avoid magic numbers.

### 1.3 Fault Tolerance & Crash Guarding
* Every invocation into native engine objects via REFramework SDK is protected using `pcall` (protected call) to prevent runtime script crashes from bubbling up to the game engine.
* Pointers and managed objects are validated for null/freed memory before dereferencing:
  ```lua
  local actor = runtime.player()
  if not actor or not actor:valid() then return end
  ```

---

## 2. Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       Stormblade.lua                        │
│             (Thin Bootstrapper / Lifecycle Hub)             │
└──────────────┬──────────────┬──────────────┬────────────────┘
               │              │              │
      ┌────────▼────────┐     │     ┌────────▼────────┐
      │    core.lua     │     │     │   weapons.lua   │
      │  State Manager  │     │     │ Duospear Scaling│
      │  & VSB Binding  │     │     │ & Thunder Boon  │
      └─────────────────┘     │     └─────────────────┘
                              │
               ┌──────────────┴──────────────┐
               │                             │
      ┌────────▼────────┐           ┌────────▼────────┐
      │   skills.lua    │           │ locomotion.lua  │
      │  RB Storm Bolt  │           │ Speed Multiplier│
      │ & Action Hooks  │           │(1.0 walk/1.04 run)
      └─────────────────┘           └─────────────────┘
```

### Module Responsibilities:
1. **`Stormblade/core.lua`:**
   * Interfaces with `_G.VSB_API` to check if `app.picks.Job01 == "stormblade"`.
   * Manages active lifecycle states (`is_active()`, `on_enter()`, `on_exit()`).
2. **`Stormblade/weapons.lua`:**
   * Reads player's equipped sword in slot `Main`.
   * Sets `_MagicAttack = _PhysicalAttack` and `_Element = 3` (Thunder) in `app.ItemWeaponParam`.
   * Restores original parameters cleanly when unequipping or deactivating.
3. **`Stormblade/skills.lua`:**
   * Intercepts `JobSpecialAction` (`RB` / Defend) while no shield is worn.
   * Spawns lightning projectile (`Magike Sperepelote` shell) scaled directly from Strength (2.2x charged, 1.5x burst, 1.0x tap) with 450 stagger.
   * Accelerates basic sword attack chain by 1.25x (+25%).
   * Includes smart draw buffering when executing skills from a sheathed stance.
4. **`Stormblade/locomotion.lua`:**
   * Applies dynamic locomotion scaling: normal walking (1.00x) and +4% running/sprinting (1.04x).

---

## 3. REFramework Lifecycle Integration

* `re.on_frame(fn)`: Executes periodic checks (polling intervals throttled to 15 frames for low CPU overhead).
* `re.on_script_reset(fn)`: Ensures all weapon parameters, boons, and hooks are restored to vanilla state immediately upon script reload, preventing game state corruption.

