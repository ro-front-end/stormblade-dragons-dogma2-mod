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
     - `Arc Slash` (`sb_slash`, UUID `...002`): Horizontal shockwave slashes (`Job01_HindsightSlash`).
     - `Tempest Flurry` (`sb_combo`, UUID `...005`): High-speed blade chain (`Job01_BravesRaid`).
     - `Levin Storm` (`sb_levin`, UUID `...006`): Targeted vertical lightning strike from heavens (`Job01_RisingLunge` cast anchor, 2.8x Strength, 550 stagger).
     - `Nova Eléctrica` (`sb_nova`, UUID `...007`): 360° ground shockwave discharge (`Job01_FullMoonSlash` cast anchor, 2.0x Strength, 400 stagger).
   * **Runtime Shell & Scaling Engine (Phase 3):** Dedicated IIFE executor handling target raycasting (`aim_pick`), shell spawning (`HumanShellParamData_JobMagic.user` shells 8 & 36), electric blue tinting (`colour_shell`), and physical-to-magick damage injection in `calcDamageValue`.
   * **Declarative Schema Alignment (Phase 2):** VSB manifests deployed under `reframework/data/VSB/packs/stormblade/skills/` with unlock ranks (Levin: 3/7, Nova: 4/8) and mapped into `Pactblade.lua` routing.
   * **Phase 1 Routing Alignment:** Deprecated `sb_bolt` (`...001`), `sb_smite` (`...003`), and `sb_dive` (`...004`) were purged to eliminate duplicate entries and resolve mid-air state stalls (`Job07_SkyDive`).
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

---

## 5. Key Challenges & Iterative Solutions

Throughout development, technical constraints and gameplay edge-cases emerged that required iterative engineering. Rather than settling for fragile workarounds, we tested multiple alternatives to ensure maximum stability and polish:

| Challenge | Initial Symptom / Alternative Explored | Final Iterative Solution |
| :--- | :--- | :--- |
| **Lua 200-Locals Limit** | Script exceeded 200 file-scope locals (`LUAI_MAXVARS`), crashing REFramework on load (`too many local variables`). | **Namespace Table Packing (`PB.*`):** Packed constants, state flags, and helpers into a centralized table, dropping locals to 182 and establishing a safe 18-variable buffer. |
| **Storm Bolt 0-Damage** | Spearhand bolt has 0 base damage in DD2 (pure CC). Initial test scaled from base Magick, leaving Fighter stats doing 0 damage. | **Physical-to-Lightning Scaling:** Dynamically resolves `player_strength()` (sword + base attack), scaling bolt damage (2.2x charged, 1.5x burst) with full Thunder element penetration. |
| **Aerial Freezes & Target Desync** | "Thunder Smite" mapped to `Job07_SkyDive` locked character floating in mid-air when camera/lock-on desynced without a target. | **Pivoting to Grounded Spells:** Abandoned fragile aerial dive physics in favor of 100% reliable grounded spells: **Levin Storm** (celestial vertical strike) and **Nova Eléctrica** (radial ground discharge). |
| **Sheathed Input Drops** | Pressing weapon skills while sword was sheathed caused animation glitching or failed casts. | **Auto-Draw & Input Buffering:** Implemented `ensure_drawn()` with a 1.2s input action buffer, allowing smooth unsheathing straight into the skill execution. |
| **Laptop GPU TDR / Startup Deadlocks** | Multi-hour sessions on RTX 5050 Laptop GPU triggered Windows TDR resets (`DXGI_ERROR_DEVICE_REMOVED`) and startup thread hangs. | **Hook Optimization & Guardrails:** Disabled failing `FaultyFileDetector` hook in REFramework config, bounded active VFX lifetimes, and established recommended graphics profiles to eliminate VRAM exhaustion. |
