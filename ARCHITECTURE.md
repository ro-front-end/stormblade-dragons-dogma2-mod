# 🏛️ Architecture & Engineering Guidelines — Stormblade

This document outlines the software design principles, conventions, architectural patterns, runtime constraints, and subsystem implementations adopted in the **Stormblade** project. As a modular custom vocation running within Capcom's RE Engine via REFramework, DragonCore, and VSB, adhering to these guidelines ensures code maintainability, memory safety, and 100% crash resistance.

---

## 1. Core Design Principles

### 1.1 Separation of Concerns (SoC)
* **Declarative Data (JSON):** Vocation definitions, attribute growth, discipline points (DCP), unlock ranks, and skill catalogs reside strictly in JSON manifests under `reframework/data/VSB/packs/stormblade/`.
* **Runtime Logic (Lua):** Engine hooks, memory address tracking, and input processing reside in `reframework/autorun/Stormblade/` and `Pactblade.lua`.
* **Thin Entry-Point:** `Stormblade.lua` serves exclusively as a composition root (bootstrapper).

### 1.2 DRY (Don't Repeat Yourself) & Single Source of Truth
* Common RE Engine operations (retrieving player instance, accessing `app.ItemManager`, calculating total physical Strength, spawning managed shells) are encapsulated into single service functions (`PB.player_strength()`, `spawn()`).
* All Stormblade state and helpers live under the `PB` namespace table to stay well below Lua's 200-local-variable register limit (`LUAI_MAXVARS = 200`).

---

## 2. Subsystems Architecture (`Pactblade.lua`)

### 2.1 Native Light Armor Wardrobe (`PB.update_stormblade_armor`)
* Iterates `app.ItemManager._ItemDataDict` on `re.on_frame` when `PB.activeVocation == "stormblade"`.
* Uses `app.ItemArmorParam._Job` bitmasks (`Job01 = 2`, `Job02 = 4`, `Job03 = 8`, `Job04 = 16`, `Job05 = 32`, `Job07 = 128`, `Job08 = 256`) to classify all 669 armors in *Dragon's Dogma 2*:
  * **Allowed (500 Light/Medium pieces):** Any armor usable by *Archer*, *Mage*, *Thief*, *Mystic Spearhand*, or *Magick Archer* (plus universal clothes/cloaks shared with *Mage*) receives the `JOB_FIGHTER (2)` bit.
  * **Blocked (169 Heavy Plate/Mail pieces):** Any armor exclusive to *Fighter* and/or *Warrior* has the `JOB_FIGHTER (2)` bit stripped and is refused in `app.ItemManager:setEquip`.
* Original `_Job` bitmasks are cached in `armorOrigJobs` and restored immediately during Save/Online Guard (`dbg.guardHold`), vocation switches, and script resets.

### 2.2 Progressive Augmentations (`PB.update_stormblade_augments`)
* Evaluates current Stormblade Vocation Rank via `PB.stormblade_rank()` (`VSB.game.vocprogress.rank_of_pack("stormblade")` with fallback to `JobContext:calcJobRank`).
* Progressively unlocks 5 passives (**Rank 2** *Fulmination* `+30` Strength, **Rank 4** *Conductivity* `+150` Max Stamina, **Rank 6** *Aegis of the Storm* `+45` Magick Defense, **Rank 8** *Overload* `+20%` weakpoint/drenched Thunder damage, **Rank 9** *Eye of the Hurricane* `-10%` skill stamina cost).
* Integrates directly into the Vocation Guild's **Augments** tab (`app.ui040101_00`) with native DCP costs (`300 / 900 / 1800 / 3000 / 5000 Dcp`), dynamically mapped to `GuiManager.AbilityDefineDictionary["Job01"]` and unlocked progressively by rank.

### 2.3 Three-Layer Vocation Guild Shield & Foreign-Pack Filter
To keep the Vocation Guild (`app.ui040101_00`) completely free of Fighter shield skills and foreign VSB pack clutter while Stormblade is active:
1. **Dictionary Layer (`PB.update_stormblade_guild_defs`):** Sets `_UnlockRank = 99` on the 6 Fighter shield weapon skills (`Job01_ShieldSummons`, `Job01_Springboard`, `Job01_CymbalAttack`, `Job01_ShieldCounter`, `Job01_FullMoonGuard`, `Job01_DivineDefense`) and 4 Fighter shield core skills (`4, 5, 7, 8`) in `GuiManager.CustomSkillDefineDictionary`, `CustomSkillJobDefineDictionary[1]`, and `NormalSkillDefineDictionary["Job01"]`.
2. **Content Builder Layer (`addCustomSkillContentsList` & `addNormalContentsList`):** Filters the `List<MainContentsInfo>` post-build to strip even previously purchased Fighter shield skills and non-Stormblade VSB skills.
3. **Scroll Control Layer (`ScrollCtrlBase`2:makeList`):** Pre-filters `List<MainContentsInfo>` right before UI item instantiation (skipping `ContenstsType == 1` so the Vocations tab is untouched).
4. **Boot Guard Safe-Mode Protection:** Automatically verifies and resets `VSB/state/boot_guard.json` and `DragonCore/boot_guard.json` to `{"starting": false}` so menu integration never gets stuck in safe-mode after quick reloads.

### 2.4 Core Skills & Maister Skills Engine
* **Core Skills (`Static Counter`, `Tempest Overcharge`, `Storm Carve`):** Defined declaratively as `"kind": "core"` JSON manifests in `reframework/data/VSB/packs/stormblade/skills/` (Ranks 2, 4, 6 costing `400 / 900 / 1500 Dcp`) with `"unlock_by": "custom"` and `"trigger": {"type": "event", "event": "passive"}`. Runtime effects are enforced in `PB.has_core_skill` and `HitController:calcDamageValue`.
* **Maister Skills (`Judgement of the Storm` & `Omnislash: Raijin`):**
  * `sb_judgement.json` (Rank 8, `5000 Dcp`): Executes a 5-bolt staggered Levin thunderstorm matrix via VSB's timeline engine with super armor.
  * `sb_omnislash.json` (Rank 9, `6000 Dcp`): Bridges via UUID into the 4-stage directional blink-slash state machine (`combo_stage`) enhanced with `PB.fire_omnislash_stage` electric shockwaves (`shell_id = 7`) and an overhead Levin thunderbolt finisher (`shell_id = 8`).

### 2.5 Vocation Icon & Visual Identity
* Stormblade uses icon `35` (the golden Levin thunderbolt symbol from the game's native skill icon sheet), providing an unmistakable lightning-themed identity across all game screens and VSB manifests.
