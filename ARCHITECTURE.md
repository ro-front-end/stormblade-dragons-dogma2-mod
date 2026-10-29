# 🏛️ Architecture & Engineering Guidelines — Stormblade

This document outlines the software design principles, conventions, architectural patterns, and runtime constraints adopted in the **Stormblade** project. As a modular game modification running within Capcom's RE Engine via REFramework and DragonCore, adhering to these guidelines ensures code maintainability, memory safety, and 100% crash resistance.

---

## 1. Core Design Principles

### 1.1 Separation of Concerns (SoC)
* **Declarative Data (JSON):** Vocation definitions, attribute growth, discipline points (DCP), unlock ranks, and skill catalogs reside strictly in JSON manifests under `reframework/data/VSB/packs/stormblade/`.
* **Runtime Logic (Lua):** Engine hooks, memory address tracking, and input processing reside in `reframework/autorun/Stormblade/` and `Pactblade.lua`.
* **Thin Entry-Point:** `Stormblade.lua` serves exclusively as a composition root (bootstrapper). It does not contain complex game logic; it initializes services and binds lifecycle events.

### 1.2 DRY (Don't Repeat Yourself) & Single Source of Truth
* Common RE Engine operations (retrieving player instance, accessing `app.ItemManager`, calculating total physical Strength, spawning managed shells) are encapsulated into single service functions (`player_strength()`, `spawn()`).
* Skills are defined once and mapped cleanly: Core actions on `RB` (`JobSpecialAction`) are never duplicated into weapon slot manifests.

### 1.3 Memory Safety & Crash Guarding
* Every invocation into native engine objects via REFramework SDK is protected using `pcall` (protected call) to prevent runtime script crashes from bubbling up to the game engine.
* Pointers and managed objects are validated for null/freed memory before dereferencing:
  ```lua
  local actor = runtime.player()
  if not actor or not actor:valid() then return end
  ```

---

## 2. Lua Compiler Limits & Table Packing Pattern (`PB.*`)

### The 200 Local Variables Constraint
* Lua 5.1/5.4 and Sol3 enforce a strict compile-time limit of **at most 200 active local variables** in any single function/chunk (`LUAI_MAXVARS = 200`).
* Large single-file REFramework scripts frequently approach this limit when declaring file-scope variables.
* **Engineering Solution:**
  Instead of declaring discrete `local` variables at file scope, all module state, configuration flags, and static helpers are packed into a single namespace table `PB`:
  ```lua
  local PB = {}
  PB.activeVocation = nil
  PB.player_strength = function() ... end
  PB.HOLD_SEC = 0.35
  PB.COMBO_WINDOW = 0.35
  ```
  This reduces top-level register consumption from 201+ down to **182**, leaving an 18-variable safety margin that prevents compilation halts (`too many local variables in main function`).

---

## 3. Component Architecture & Data Flow

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
3. **`Stormblade/skills.lua` & `Pactblade.lua` Integration:**
   * **Core Action (`RB`):** Intercepts `JobSpecialAction` while no shield is worn. Casts Storm Bolt with instant tap and charged release, scaled dynamically from `player_strength()` with 450 stagger.
   * **Custom Weapon Slots:** Handled via `processCustomSkill` hook. Dispatches:
     - `Arc Slash` (`sb_slash`): Horizontal shockwave slashes.
     - `Tempest Flurry` (`sb_combo`): High-speed blade chain.
     - `Levin Storm` (`sb_levin`): Targeted vertical lightning strike from heavens.
     - `Nova Eléctrica` (`sb_nova`): 360° ground shockwave discharge.
   * **Sheathe Buffering:** Automatically buffers custom skills executed from a sheathed stance (`bufferUntil = os.clock() + 1.2`), drawing the blade before striking.
4. **`Stormblade/locomotion.lua`:**
   * Manages character speed rates: normal walking (`1.00x` vanilla parity) and running/sprinting (`1.04x` agile boost).

---

## 4. Hardware Stability & REFramework Integration

* **GPU Thermal & TDR Guarding:**
  On laptop hardware (such as RTX 5050 Laptop GPU), long sessions can trigger Windows TDR timeouts (`DXGI_ERROR_DEVICE_REMOVED` in `nvlddmkm.sys`).
  * `FaultyFileDetector_Enabled` is set to `false` in `re2_fw_config.txt` to eliminate resource parser hook failures that deadlock thread locks.
  * Particle and mesh memory footprints are kept bounded to prevent VRAM saturation over multi-hour sessions.
* **REFramework Lifecycle Hooks:**
  * `re.on_frame(fn)`: Executes state checks throttled to avoid per-frame CPU overhead.
  * `re.on_script_reset(fn)`: Ensures all weapon parameters, active buffs, and hooks restore cleanly to vanilla state upon script reset.
