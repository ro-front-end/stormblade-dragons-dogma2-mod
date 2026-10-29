# ⚡ Stormblade Vocation — Dragon's Dogma 2

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: REFramework](https://img.shields.io/badge/Engine-REFramework-orange)](https://github.com/praydog/REFramework)
[![Framework: VSB](https://img.shields.io/badge/Framework-VSB%201.5%2B-green)](https://www.nexusmods.com/dragonsdogma2/mods/1917)
[![Core: DragonCore](https://img.shields.io/badge/Dependency-_DragonCore-red)](https://www.nexusmods.com/dragonsdogma2/mods/1916)

**Stormblade** is a custom hybrid vocation for *Dragon's Dogma 2*, engineered with modularity, balance, and software design best practices. It reimagines the sword archetype into a high-speed, lightning-infused **Storm Mage-Knight**: wielding a single-handed blade without a shield, casting lightning spells and bolts from the off-hand, and donning agile armor.

---

## 🗡️ Core Concept & Gameplay Pillars

1. **Bare-Handed Spellcasting (No Shield):**
   * Prescinds entirely from heavy shields. The left palm remains free to channel raw elemental electricity.
   * `RB` (*JobSpecialAction*) replaces vanilla blocking with **Storm Bolt** / **Charged Lightning**, dealing elemental damage scaled directly from total **Strength** (2.2x charged, 1.5x burst, 1.0x tap) with Thunder penetration and high stagger (450 reaction).
2. **Duospear Magic Scaling & Lightning Infusion:**
   * Automatically balances physical and magical power ($\text{MagicAttack} = \text{PhysicalAttack}$) with 100% Thunder penetration (`_Element = 3`).
   * Scaled with VSB's native Thunder multipliers (+35% to +50% electrical damage).
3. **Agility & Balanced Flow:**
   * Light attack combo animation speed finely tuned to **1.25x (+25%)** (secondary finishers at 1.15x).
   * Balanced locomotion: **1.00x normal walking** (walk naturally alongside pawns and NPCs) and **1.04x (+4%) running / sprinting**.
   * **Smart Unsheathe Buffering:** Custom skills executed while sheathed automatically draw the blade smoothly before striking.
4. **Curated Spellsword Repertoire (No Dead Shield Skills):**
   * Vanilla shield skills (*Shield Bash*, *Shield Pummel*, *Launchboard*, *Shield Summons*) are cleanly removed from the Vocation Guild.
   * Replaced by 4 synergistic combat and storm magick skills.
5. **Light Armor Wardrobe:**
   * Compatible with Archer, Thief, and Mage garb to preserve the agile visual fantasy.

---

## ⚡ Complete Skill Loadout (4 Active Slots + 1 Core)

| Skill Name | Type | Key Mechanics & Synergy |
| :--- | :--- | :--- |
| **Storm Bolt** | **Core (`RB`)** | **Off-hand lightning bolt.** Free, permanent core mechanic (not occupying weapon slots). Tap for quick projectile; hold to charge a piercing thunderbolt with 450 stagger. Scales 2.2x with total Strength. |
| **Arc Slash** (*Eldritch Slash*) | **Weapon Slot 1** | **Sword wave slashes.** Triple horizontal blade slashes that release electric crescent waves to cleave through multiple foes at medium range. |
| **Tempest Flurry** (*Archfey Combo*) | **Weapon Slot 2** | **High-speed blade rush.** Continuous lightning-fast sword combo with blue afterimages, perfect for punishing staggered enemies. |
| **Levin Storm** (*Relámpago Celestial*) | **Weapon Slot 3** | **Vertical lightning strike.** Calls down an electric thunderbolt from the heavens onto the focused target with explosive impact and high knockdown. |
| **Nova Eléctrica** (*Radial Shockwave*) | **Weapon Slot 4** | **360° Ground discharge.** Expels a circular radial shockwave along the terrain, electrifying and throwing back surrounding smaller enemies. |

---

## ⚖️ Design Evolution & Decision Log

Every mechanic in Stormblade was refined iteratively based on extensive in-game testing to ensure maximum stability and balanced gameplay:

* **Phase 1 Complete — Surgical Cleanup & UUID Alignment:**
  * *Root Cause Solved:* "Thunder Smite" previously leaped and hung indefinitely in mid-air because `sb_smite.json` UUID was mapped to `"dive"` (`Job07_SkyDive`) without a valid target lock. Furthermore, "Storm Bolt" appeared as an unneeded purchasable slot skill in the Vocation Guild despite already being a permanent core mechanic on `RB`.
  * *Actions Executed:* 
    * Fully backed up and eliminated `sb_bolt.json`, `sb_smite.json`, and `sb_dive.json` from both project manifests and the game's active VSB directory.
    * Re-anchored `Pactblade.lua` routing: `sb_slash` (UUID `...002`) accurately triggers `Arc Slash` (Eldritch sword waves via `Job01_HindsightSlash`), and `sb_combo` (UUID `...005`) accurately triggers `Tempest Flurry` (high-speed blade rush via `Job01_BravesRaid`).
    * Validated Lua AST and local registers: 0 syntax errors, 182/200 locals (18 free slots).
* **Locomotion Calibration (1.12x ➔ 1.00x walk / 1.04x run):**
  * *Reasoning:* Initial +12% across all movement made walking noticeably desynced from pawns and NPCs. Walking was restored to 1.00x (vanilla) while sprinting received a subtle +4% boost for natural agility.
* **Attack Chain Speed (1.50x ➔ 1.25x):**
  * *Reasoning:* 1.50x felt overly rushed and disjointed. 1.25x (+25%) preserves satisfying visual clarity while maintaining a swift tempo.
* **Storm Bolt Damage Overhaul:**
  * *Reasoning:* Vanilla Mystic Spearhand bolt has 0 base damage in DD2 (pure CC). The initial mod scaled off character base magick, causing 0 damage for Fighter vocations. We engineered a dynamic `player_strength()` resolver (sword + base attack) converting full physical power into Thunder magick damage.
* **Smart Unsheathe Buffering:**
  * *Reasoning:* Executing skills from a sheathed stance previously caused unarmed animation desyncs. Added an automated unsheathe state check with a 1.2s action buffer.
* **Lua 200 Local Variable Constraint Fix:**
  * *Reasoning:* Sol3/Lua engine enforces a hard limit of 200 local variables per chunk. The base mod sat at 199 locals; adding new features pushed it to 201, crashing REFramework with `too many local variables in main function`. Solved by encapsulating globals and constants into a unified `PB.*` namespace, dropping active locals to 182 (18 free safety buffer).
* **Deprecating Aerial SkyDive (Smite):**
  * *Reasoning:* The airborne dive skill frequently stalled in mid-air when target tracking desynced. Replaced with grounded, 100% reliable skills: **Levin Storm** and **Nova Eléctrica**.
* **Eliminating Guild Duplicates & Shield Skills:**
  * *Reasoning:* Storm Bolt was duplicated in both `RB` and the Guild menu; shield skills were dead weight. Filtered the Guild manifest to expose only genuine sword and lightning skills.
* **Hardware & Thermal Stability (Laptop RTX 5050):**
  * *Reasoning:* Long multi-hour sessions caused GPU TDR driver crashes (`nvlddmkm.sys` / `DXGI_ERROR_DEVICE_REMOVED`). Disabled failing `FaultyFileDetector` hooks and tuned graphics recommendations (Effect Quality, Frame Gen, Mesh) to prevent VRAM overflow.

---

## 🛠️ Tech Stack & Architecture

* **Lua 5.4 / LuaJIT (REFramework runtime):** Game engine hooks, IL2CPP address resolution, FSM manipulation, and runtime stat patching.
* **JSON (VSB Schema v1):** Declarative vocation registration, stat tables, and skill progression.
* **Architecture Pattern:** Decoupled Modular Architecture (Thin entry-point, separated domain services for Weapons, Input, and Locomotion).

---

## 📂 Repository Structure

```text
stormblade/
├── .gitignore
├── README.md                 # Project vision, roadmap, and design decision log
├── ARCHITECTURE.md           # Engineering guidelines, DRY principles, and REFramework hooks
├── reframework/
│   ├── autorun/
│   │   ├── Stormblade.lua    # Thin entry point & lifecycle hooks
│   │   └── Stormblade/       # Modular domain services
│   │       ├── core.lua      # State manager & VSB detection
│   │       ├── weapons.lua   # ItemWeaponParam patcher & Thunder scaling
│   │       ├── locomotion.lua# Character speed multiplier (1.00x / 1.04x)
│   │       └── skills.lua    # RB storm bolt & skill adapter
│   └── data/
│       └── VSB/
│           └── packs/
│               └── stormblade/
│                   ├── pack.json    # VSB Vocation Schema
│                   └── skills/      # Custom skill declarations
│                       ├── sb_slash.json  # Arc Slash
│                       ├── sb_combo.json  # Tempest Flurry
│                       ├── sb_levin.json  # Levin Storm
│                       └── sb_nova.json   # Nova Eléctrica
```

---

## 📦 Requirements

* [Dragon's Dogma 2](https://store.steampowered.com/app/2054970/Dragons_Dogma_2/) (Latest Steam Version)
* [REFramework](https://github.com/praydog/REFramework) by praydog
* [_DragonCore](https://www.nexusmods.com/dragonsdogma2/mods/1916) (v1.2.6+) by Bloodragon
* [Vocation & Skill Builder (VSB)](https://www.nexusmods.com/dragonsdogma2/mods/1917) (v1.5.0+) by Bloodragon
* [Fluffy Mod Manager](https://www.nexusmods.com/dragonsdogma2/mods/1) (Recommended)
