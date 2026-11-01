# ⚡ Stormblade Vocation — Dragon's Dogma 2

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: REFramework](https://img.shields.io/badge/Engine-REFramework-orange)](https://github.com/praydog/REFramework)
[![Framework: VSB](https://img.shields.io/badge/Framework-VSB%201.5%2B-green)](https://www.nexusmods.com/dragonsdogma2/mods/1917)
[![Core: DragonCore](https://img.shields.io/badge/Dependency-_DragonCore-red)](https://www.nexusmods.com/dragonsdogma2/mods/1916)

**Stormblade** is a custom hybrid vocation for *Dragon's Dogma 2*, engineered with modularity, balance, and software design best practices. It reimagines the sword archetype into a high-speed, lightning-infused **Storm Mage-Knight**: wielding a single-handed blade without a shield, casting lightning spells and bolts from the off-hand, and donning agile armor.

---

## 🗡️ Core Concept & Gameplay Pillars

1. **Bare-Handed Spellcasting (No Shield):**
   * Prescinds entirely from heavy shields. The left hand remains free to channel agile evasions, palm strikes, and lightning magic.
   * `RB` (*JobSpecialAction*) executes **`Lightning Step`**: a pure, ultra-fast directional quickstep/dodge with electric sparks, replacing vanilla blocking with zero animation lock or stance freezes.
   * `Triangle` / `Y` / `R-Click` (*Heavy Attack*) executes a **Dual Off-Hand Magic System**:
     * **Tap (< 350ms) — `Thunderstrike`:** Replaces the vanilla sword heavy attack with a fast, off-hand palm thrust unleashing an electric shockwave with mild pushback (`Hitback_S`) and hybrid 2.2x Strength scaling.
     * **Hold (≥ 350ms) — `Lightning Javelin`:** Enters a charging stance channeling lightning in the palm and hurls a high-velocity piercing spear with heavy knockdown (`Hitback_L`), ~18m range, crosshair targeting, and hybrid 2.8x Strength scaling.
2. **Duospear Magic Scaling & Lightning Infusion:**
   * Automatically balances physical and magical power with 100% Thunder penetration (`_Element = 3`).
   * Scaled with VSB's calibrated Thunder multiplier (+1.5% electrical growth per rank) and balanced weapon split (70% physical / 45% magick).
3. **Agility & Balanced Flow:**
   * Light attack combo animation speed tuned to **1.30x (+30%)** (secondary finishers at 1.20x).
   * Balanced locomotion: **1.00x normal walking** (walk naturally alongside pawns and NPCs) and **1.04x (+4%) running / sprinting**.
   * **Smart Unsheathe Buffering:** Custom skills executed while sheathed automatically draw the blade smoothly before striking.
4. **Curated Spellsword Repertoire (Full 6-Skill Loadout):**
   * Vanilla shield skills (*Shield Bash*, *Shield Pummel*, *Launchboard*, *Shield Summons*) are cleanly removed/hidden from the Vocation Guild.
   * Features a cohesive 6-skill repertoire spanning from Rank 1 to Rank 6.
5. **Light Armor Wardrobe:**
   * Compatible with Archer, Thief, and Mage garb to preserve the agile visual fantasy.

---

## ⚡ Complete Skill Loadout (6 Official Skills + 2 Core Mechanics)

| Rank | Skill Name | Base Animation | Key Mechanics & Synergy |
| :--- | :--- | :--- | :--- |
| **Core** | **Lightning Step** | Evasive Quickstep | **Pure directional dodge on `RB`.** Instant repositioning with electric sparks, zero projectile delay, and no stance lock. |
| **Core** | **Thunderstrike / Lightning Javelin** | `Job07_MagicBindComplete` / `Job07_FarThrow` | **Dual off-hand heavy attack (`Triangle` / `Y` / `R-Click`).**<br>• **Tap:** Swift palm strike with an electric shockwave (`Hitback_S`, 2.2x Strength).<br>• **Hold (≥ 350ms):** Charged stance and lightning spear hurl with heavy knockdown (`Hitback_L`, 2.8x Strength, ~18m range). |
| **Rank 1** | **Lightning Thrust** | `Job01_BlinkStrike` | **High-speed gap closer.** Blinding dash forward at ground level with crackling lightning on the blade tip. Ideal combat opener. |
| **Rank 2** | **Storm Ascender** | `Job01_RisingLunge` | **Vertical leap slash.** Soaring upward cut enveloped in thunder sparks. Perfect for hunting flying harpies and striking giant monster weakpoints. |
| **Rank 3** | **Arc Slash** | `sb_slash.json` | **Sword wave slashes.** Horizontal blade slashes that release electric crescent shockwaves to cleave through foes at medium range. |
| **Rank 4** | **Tempest Flurry** | `Job07_DanceOfDeath` | **Continuous blade flurry.** Unstoppable terrestrial flurry (Wild Furie) with lightning-enchanted slashes and super armor. Tested and confirmed on bosses. |
| **Rank 5** | **Thunder Stun** | `Job07_MagicBindComplete` + Shell 8 | **Paralyzing palm discharge.** Extends the left palm and unleashes a concentrated lightning surge that halts and stuns enemies in their tracks. |
| **Rank 6** | **Thunder Fall** | `Job01_ViolentStabStart` + Shell 8/12 | **Catastrophic dive finisher.** Leap forward and impale the blade deep into the earth; on ground impact, summons a celestial Levin thunderbolt and radial shockwave. |

---

## ⚖️ Design Evolution & Decision Log

* **V2 Architecture Complete (6 Skills & Agility Polish):**
  * Configured `Lightning Step` on `RB` for fluid, non-blocking mobility.
  * Configured dual off-hand magic on `Triangle` / `Y`: tap for `Thunderstrike` palm shockwave, hold for `Lightning Javelin` charged throw.
  * Increased melee combat attack speed to **+30% (1.30x)**.
  * Rebalanced weapon scaling and stat compounding to maintain fair combat pacing.
  * Deployed `Thunder Fall` (Rank 6 finisher) and retired unstable radial Nova.
* **Phase 3 Complete — Levin Stun & Tempest Flurry Stabilization:**
  * Replaced book/shield animations with native Mystic Spearhand palm cast for `Thunder Stun`.
  * Transitioned `Tempest Flurry` to native VSB Wild Furie (`Job07_DanceOfDeath`), verified in active combat against bosses.
* **Locomotion Calibration (1.00x walk / 1.04x run):**
  * Preserved natural walking cadence alongside pawns while granting an agile sprinting boost.
* **Smart Unsheathe Buffering:**
  * Automated unsheathe state check with a 1.2s action buffer to prevent stance desynchronization.
