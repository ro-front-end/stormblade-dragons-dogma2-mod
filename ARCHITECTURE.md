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
  This preserves register consumption well below 182, leaving an ample safety margin that prevents compilation halts (`too many local variables in main function`).

---

## 3. Skill & Progression Catalog (6 Skills + 2 Core Mechanics)

The complete skill catalog is architected for both standard 4-slot loadouts and expanded 6-slot environments:

```
Rank 1: sb_thrust.json   (Lightning Thrust — Blink Strike gap closer)
Rank 2: sb_ascender.json (Storm Ascender   — Cloudward Slash vertical anti-air)
Rank 3: sb_slash.json    (Arc Slash       — Eldritch crescent sword waves)
Rank 4: sb_combo.json    (Tempest Flurry  — Wild Furie terrestrial rush)
Rank 5: sb_levin.json    (Thunder Stun    — Off-hand palm paralyzing bolt)
Rank 6: sb_fall.json     (Thunder Fall    — High-impact ground impale with Levin pillar)
Core:   Lightning Step   (Pure directional quickstep dodge mapped to RB)
Core:   Heavy Stab / Lightning Javelin (Tap: native Fighter heavy stab & downed finisher; Hold: charged Lightning Javelin)
```

### 3.1 Dual Heavy Attack & Lightning Javelin Architecture
Stormblade implements a dual-mode heavy attack system with zero action interference:
* **Quick Tap (< 350ms) — Native Fighter Heavy Stab & Finisher:** All hooks (equestActionCore) bypass quick taps completely. Vanilla Job01_HeavyAttack and grounded finishers (FinishingMove / DownAttack) execute with 100% engine purity, zero animation stutter, no stamina drain, and zero projectile release.
* **Hold (>= 350ms) — Charged Lightning Javelin:** Holding AttackL enters a charging phase. On release, executes Job07_MagicBindComplete at 1.4x animation speed, launching a high-velocity piercing spear (speed = 5.5, scale_axes = {0.7, 0.7, 4.5}). Stun and MagicBind paralysis are dynamically purged to prevent cheesy freezes, applying a solid flinch impact (Hitback_M, 1.85x Strength scaling) and guaranteeing 100% EXP and drops. Crash-prone MaterialInterpolation hooks were eliminated for complete render-thread stability.
---

## 4. Git Branching Strategy & Release Discipline

* **`main`:** Production-grade, verified releases only. Never receives unverified skill experiments.
* **`sandbox`:** Active integration branch where new skills, animations, and parameter balances are committed iteratively.
* **Remote Push Restriction:** Pushes to remote repository (`origin`) require explicit user authorization.
