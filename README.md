# ⚡ Stormblade Vocation — Dragon's Dogma 2

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: REFramework](https://img.shields.io/badge/Engine-REFramework-orange)](https://github.com/praydog/REFramework)
[![Framework: VSB](https://img.shields.io/badge/Framework-VSB%201.5%2B-green)](https://www.nexusmods.com/dragonsdogma2/mods/1917)
[![Core: DragonCore](https://img.shields.io/badge/Dependency-_DragonCore-red)](https://www.nexusmods.com/dragonsdogma2/mods/1916)

**Stormblade** is a custom hybrid vocation for *Dragon's Dogma 2*, engineered with modularity and software design best practices. It reimagines the sword archetype into a high-speed, lightning-infused **Mage-Knight**: wielding a single-handed blade without a shield, casting lightning bolts from the off-hand, and donning agile armor.

---

## 🗡️ Core Concept & Gameplay Pillars

1. **Bare-Handed Spellcasting (No Shield):**
   * Prescinds from heavy shields. The left palm remains free to channel raw elemental electricity.
   * `RB` (*JobSpecialAction*) replaces vanilla blocking with **Storm Bolt** / **Charged Lightning**, dealing elemental damage scaled directly from total **Strength** (2.2x charged, 1.5x burst, 1.0x tap) with Thunder penetration and high stagger.
2. **Duospear Magic Scaling & Lightning Infusion:**
   * Automatically balances physical and magical power ($\text{MagicAttack} = \text{PhysicalAttack}$) with 100% Thunder penetration.
   * Scaled with VSB's native Thunder multipliers (+35% to +50% electrical damage).
3. **Agility & Balanced Flow:**
   * Light attack combo animation speed finely tuned to **1.25x (+25%)**.
   * Balanced locomotion: **1.00x normal walking** (walk naturally alongside pawns/NPCs) and **1.04x (+4%) running / dashing**.
   * **Smart Unsheathe Buffering:** Custom skills executed while sheathed automatically draw the blade smoothly.
4. **Light Armor Wardrobe:**
   * Compatible with Archer, Thief, and Mage garb to preserve the agile visual fantasy.

---

## 🛠️ Tech Stack & Architecture

* **Lua 5.4 / LuaJIT (REFramework runtime):** Game engine hooks, IL2CPP address resolution, FSM manipulation, and runtime stat patching.
* **JSON (VSB Schema v1):** Declarative vocation registration, stat tables, and skill progression.
* **Architecture Pattern:** Decoupled Modular Architecture (Thin entry-point, separated domain services for Weapons, Input, and Locomotion).

---

## ⚡ Skill Architecture (3 Sections)

| Section | Role | Key Mechanics |
| :--- | :--- | :--- |
| **1. Core Skills (Núcleo)** | Foundational Mechanics | • **Storm Bolt (`RB`):** Instant discharge (tap) or high-impact bolt (hold).<br>• **Storm Step:** Agile dodge / evasion.<br>• **Bare-handed Stance:** Shieldless posture and 1.5x light attack chains. |
| **2. Weapon Skills (Ranura)** | Active Equippable Skills | • **Lightning Rush:** Instant forward dash with electrical trail.<br>• **Thunderfall Slash:** High-velocity airborne dive and shockwave.<br>• **Arc Slash:** Mid-range cleaving electrical projectile.<br>• **Storm Flurry:** Multi-hit electric combo. |
| **3. Infusions & Buffs (Parámetros)** | Passive Scaling & Boons | • **Thunder Boon:** Permanent native weapon enchantment with sparks and SFX.<br>• **Duospear Weapon Bridge:** Automatic $\text{Magic} = \text{Strength}$ parity. |

---

## 🗺️ Project Roadmap & Implementation Plan

- [x] **Phase 0:** Research & Architecture Design (VSB + REFramework lifecycle analysis).
- [x] **Phase 1:** Project foundation, folder layout, `.gitignore`, and Git documentation.
- [x] **Phase 2:** VSB Pack declaration (`pack.json`) and registration in REFramework picks.
- [x] **Phase 3:** Weapon service implementation (`weapons.lua` with Duospear Thunder scaling).
- [x] **Phase 4:** Input & Combat service (`skills.lua` with off-hand lightning on `RB`).
- [x] **Phase 5:** Locomotion & Agility module (`locomotion.lua` with +12% speed).
- [ ] **Phase 6:** In-game validation & refinement.

---

## 📂 Repository Structure

```text
stormblade/
├── .gitignore
├── README.md                 # Project vision, roadmap, and tech documentation
├── ARCHITECTURE.md           # Engineering guidelines, DRY principles, and REFramework hooks
├── reframework/
│   ├── autorun/
│   │   ├── Stormblade.lua    # Thin entry point & lifecycle hooks
│   │   └── Stormblade/       # Modular domain services
│   │       ├── core.lua      # State manager & VSB detection
│   │       ├── weapons.lua   # ItemWeaponParam patcher & Thunder scaling
│   │       ├── locomotion.lua# Character speed multiplier
│   │       └── skills.lua    # RB storm bolt & skill adapter
│   └── data/
│       └── VSB/
│           └── packs/
│               └── stormblade/
│                   ├── pack.json    # VSB Vocation Schema
│                   └── skills/      # Custom skill declarations
```

---

## 📦 Requirements

* [Dragon's Dogma 2](https://store.steampowered.com/app/2054970/Dragons_Dogma_2/) (Latest Steam Version)
* [REFramework](https://github.com/praydog/REFramework) by praydog
* [_DragonCore](https://www.nexusmods.com/dragonsdogma2/mods/1916) (v1.2.6+) by Bloodragon
* [Vocation & Skill Builder (VSB)](https://www.nexusmods.com/dragonsdogma2/mods/1917) (v1.5.0+) by Bloodragon
* [Fluffy Mod Manager](https://www.nexusmods.com/dragonsdogma2/mods/1) (Recommended)
