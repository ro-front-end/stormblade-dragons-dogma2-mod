# ⚡ Stormblade Vocation — Dragon's Dogma 2

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: REFramework](https://img.shields.io/badge/Engine-REFramework-orange)](https://github.com/praydog/REFramework)
[![Framework: VSB](https://img.shields.io/badge/Framework-VSB%201.5%2B-green)](https://www.nexusmods.com/dragonsdogma2/mods/1917)
[![Core: DragonCore](https://img.shields.io/badge/Dependency-_DragonCore-red)](https://www.nexusmods.com/dragonsdogma2/mods/1916)

**Stormblade** is a custom hybrid vocation for *Dragon's Dogma 2*, engineered with modularity, balance, and software design best practices. It reimagines the sword archetype into a high-speed, lightning-infused **Storm Mage-Knight**: wielding a single-handed blade without a shield, casting lightning spells and bolts from the off-hand, and donning agile light armor.

---

## 🗡️ Core Concept & Gameplay Pillars

1. **Bare-Handed Spellcasting (No Shield):**
   * Prescinds entirely from heavy shields. The left hand remains free to channel agile evasions, palm strikes, and lightning magic.
   * `RB` (*JobSpecialAction*) executes **`Lightning Step`**: a pure, ultra-fast directional quickstep/dodge with electric sparks (costs 100 stamina, 90 with *Eye of Hurricane*; blocked while exhausted), replacing vanilla blocking with zero animation lock or stance freezes.
   * `Triangle` / `Y` / `R-Click` (*Heavy Attack*) executes a **Dual Off-Hand Magic System**:
     * **Tap (< 350ms) — Vanilla Heavy Stab & Downed Finisher:** 100% native Fighter heavy stab (`Job01_HeavyAttack`) and grounded finisher (`FinishingMove` / `DownAttack`) with zero animation stutter, no stamina drain, and zero unwanted projectile release.
     * **Hold (>= 350ms, or >= 180ms with *Tempest Overcharge*) — Close-Range Levin Strike:** Channels crackling electricity and calls down a localized Levin lightning bolt (`shell_id = 8`, `1.40x` Strength, `Hitback_M`) with zero cheesy stun lock and 100% EXP/loot retention.
2. **Native Light Armor Wardrobe (`PB.update_stormblade_armor`):**
   * Dynamically enables **500 Light & Medium armors** (*Archer*, *Mage*, *Thief*, *Mystic Spearhand*, *Magick Archer*, and universal cloaks) while blocking **169 Heavy Plate & Chain Mail armors** (*Fighter*, *Warrior*) across all shops and equipment menus, with full Save & Online Guard restoration.
3. **Curated Spellsword Repertoire & Clean Vocation Guild:**
   * All 6 vanilla Fighter shield weapon skills and 4 shield core skills are automatically hidden in the Vocation Guild (`Weapon Skills` and `Core Skills` tabs) while Stormblade is active.
   * Features **8 Progressive Weapon & Maister Skills**, **3 Progressive Core Skills**, and **5 Progressive Rank-Scaled Augmentations**, all unlocking by Stormblade's custom Vocation Rank and requiring vanilla-balanced **Discipline Points (DCP)** in the Vocation Guild.

---

## ⚡ Complete Skill Loadout & DCP Progression

### Weapon Skills & Maister Arts (`unlock_by: "custom"`)
| Rank (Lv1 / Lv2) | DCP Cost (Lv1 / Lv2) | Skill Name | Base Animation / Shell | Key Mechanics & Synergy |
| :--- | :--- | :--- | :--- | :--- |
| **Rank 1 / Rank 4** | **200 / 1000 Dcp** | **Lightning Thrust / High Lightning Thrust** (`sb_thrust`) | `Job01_BlinkStrike` | **High-speed gap closer.** Blinding dash forward at ground level with crackling lightning on the blade tip. |
| **Rank 2 / Rank 5** | **500 / 1400 Dcp** | **Storm Ascender / High Storm Ascender** (`sb_ascender`) | `Job01_RisingLunge` | **Vertical leap slash.** Soaring upward cut enveloped in thunder sparks for aerial foes and monster weakpoints. |
| **Rank 3 / Rank 6** | **700 / 1800 Dcp** | **Arc Slash / High Arc Slash** (`sb_slash`) | `Job01_HindsightSlash` + Wave | **2.0x Strength (100% Thunder).** Horizontal blade slash (`1.0x`) + long-range electric crescent wave (`1.0x`). |
| **Rank 4 / Rank 7** | **1000 / 2400 Dcp** | **Tempest Flurry / High Tempest Flurry** (`sb_combo`) | `Job07_DanceOfDeath` | **Continuous blade flurry.** Unstoppable terrestrial flurry with lightning-enchanted slashes and super armor. |
| **Rank 5 / Rank 8** | **1300 / 2800 Dcp** | **Thunder Stun / High Thunder Stun** (`sb_levin`) | `Job07_MagicBindComplete` + Shell 8 | **Focused lightning bolt.** Calls down a targeted celestial lightning bolt (`3.6x` + `0.7x` flash) to stagger enemies. |
| **Rank 6 / Rank 9** | **1600 / 3400 Dcp** | **Thunder Fall / High Thunder Fall** (`sb_fall`) | `Job01_ViolentStabStart` + Shell 8 | **Catastrophic dive finisher.** Leap forward and impale the earth, summoning a Levin thunderbolt and radial shockwave. |
| **Rank 8 (Maister 1)** | **5000 Dcp** | **Judgement of the Storm** (`sb_judgement`) | `Job07_MagicBindComplete` + 5x Shell 8 | **AoE Thunderstorm Matrix.** Summons 5 staggered celestial Levin thunderbolts across the battlefield with super armor. |
| **Rank 9 (Maister 2)** | **6000 Dcp** | **Omnislash: Raijin** (`sb_omnislash`) | 4-Stage Blink Combo + Shell 7/8 | **High-Speed Blink Flurry.** Teleports around the target from every side with electric bursts before an overhead Levin finisher. |

### Core Skills (Progressive by Rank & DCP in Vocation Guild)
| Unlock Rank | DCP Cost | Core Skill | Effect |
| :--- | :--- | :--- | :--- |
| **Rank 1** | **Innate** | **Lightning Step & Levin Heavy Combo** | Directional electric quickstep on `RB` and hold-release close-range Levin strike on `Y` / `Triangle`. |
| **Rank 2** | **400 Dcp** | **Static Counter** (`sb_core_counter`) | Executing `Lightning Step` (`RB`) within `0.35s` of an enemy blow or in close combat unleashes a `1.25x` Strength electric shockwave (`shell_id = 7`), halves incoming hit damage, and refreshes `Thunder Boon`. |
| **Rank 4** | **900 Dcp** | **Tempest Overcharge** (`sb_core_overcharge`) | Light sword slashes supercharge your off-hand for `2.5s`, halving the charge time required for the Heavy Levin strike (`0.35s` $\rightarrow$ `0.18s`). |
| **Rank 6** | **1500 Dcp** | **Storm Carve** (`sb_core_carve`) | While clinging to or pinning a monster, every **2nd sword strike** discharges a `0.85x` Strength lightning jolt (`shell_id = 7`) directly into the creature's hide. |

### Progressive Rank-Scaled Augmentations (Vocation Guild `Augments` Tab)
| Unlock Rank | DCP Cost | Augmentation | Passive Bonus |
| :--- | :--- | :--- | :--- |
| **Rank 2** | **300 Dcp** | **Fulmination** | `+30` Strength (applied to equipped sword & Status screen, boosting both physical slashes and lightning scaling). |
| **Rank 4** | **900 Dcp** | **Conductivity** | `+150` Max Stamina (`app.StaminaManager:get_MaxValue()`). |
| **Rank 6** | **1800 Dcp** | **Aegis of the Storm** | `+45` Magick Defense (applied to equipped light armor & Status screen). |
| **Rank 8** | **3000 Dcp** | **Overload** | `+20%` Thunder damage against monster weakpoints (`IsWeakDamage`) or Drenched/Tarred/Shocked targets. |
| **Rank 9** | **5000 Dcp** | **Eye of the Hurricane** | `-10%` Stamina cost on all skills (`app.HumanStaminaController`). |
