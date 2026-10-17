# Shaped Haven — Game Design Document

Minimal bullet-heaven (survivors-like) game. Server-authoritative architecture:
a headless **Zig** simulation server owns all game state; a **C++17 / Ogre3D**
client is a thin view + input layer that talks to it over loopback TCP.

Produced with Gemini (High reasoning) after genre research; this document is the
shared contract both repos implement.

---

## 1. Core Loop and Pacing

- **Server tick rate:** 60 Hz (16.667 ms fixed step).
- **Arena:** 2000 × 2000 units (`[-1000, 1000]` on X and Y, hard boundary walls).
  Orthographic camera viewport covers 80 × 45 units.
- **Player base stats:** 1.0 × 1.0 unit square collider (0.5 unit half-extent),
  100 max HP, 12.0 units/sec movement (0.2 units/tick), 3.0 unit XP pickup radius.
- **Target run length:** 20:00 (1200 s / 72,000 ticks) standard survival
  benchmark; past 20:00 enters hyper-scaling endurance mode.
- **XP and level curve:** XP required for level `L → L+1`:
  `XP(L) = floor(10 + 5L + 1.5L²)`.
  Gem values: Small = 2 XP, Medium = 10 XP, Large = 50 XP, Boss Cache = 250 XP.
  Pacing milestones: level 10 at 3:00 (685 cumulative XP), level 25 at 10:00
  (8,225 cumulative XP), level 45 at 20:00 (40,725 cumulative XP).
- **Difficulty curve** by elapsed minutes `t`:
  - **Phase A (0:00–5:00, linear onboarding):** enemy HP multiplier
    `M_HP(t) = 1.0 + 0.20t`. Spawn density follows the §4 formula,
    `R(t) = 3.0 + 2.2t + 0.35t²` enemies/sec — 3.0/s at the start, 14.0/s at
    1:00, 22.75/s at 5:00.
  - **Phase B (5:00–15:00, quadratic mid-game):**
    `M_HP(t) = 2.0 + 0.25(t − 5)²`. Tier 2 enemies enter; the first weapon
    evolution is expected at 9:00–12:00.
  - **Phase C (15:00–20:00, exponential climax):**
    `M_HP(t) = 27.0 × 1.22^(t − 15)`. Tier 3 enemies and high elite density test
    full 4-evolution + synergy builds.
  - **Phase D (20:00+, endless escalation):**
    `M_HP(t) = 73.0 × 1.35^(t − 20)`. Enemy move speed +4% per minute past 20:00.
- **Score:** `(seconds survived × 10) + (level × 250) + (kills × 2)`.

## 2. Server State Model

### Entities and fields (SoA / flat pools)

- **Player (max 4):** `id: u8`, `state_flags: u8` (ALIVE, INVULNERABLE,
  AWAITING_LEVELUP), `pos: [2]f32`, `vel: [2]f32`, `aim_dir: [2]f32`,
  `hp: f32`, `max_hp: f32`, `shield: f32`, `xp: u32`, `level: u16`,
  `weapons: [4]WeaponSlot` (`id: u8`, `level: u8`, `cooldown_ticks: u16`,
  `evolved: bool`), `passives: [10]u8` (level 0..5 per passive index),
  `synergy_mask: u16`
- **Enemy (max 4096):** `id: u32`, `archetype: u8` (Circle T1–T3, Triangle
  T1–T3, Boss), `elite_mask: u8`, `pos: [2]f32`, `vel: [2]f32`, `hp: f32`,
  `max_hp: f32`, `radius: f32`, `contact_dmg: f32`, `move_speed: f32`,
  `ai_timer: u16`
- **Projectile (max 2048):** `id: u32`, `owner_id: u8`, `weapon_id: u8`,
  `shape: u8` (ARC, CIRCLE, RAY), `pos: [2]f32`, `vel: [2]f32`, `radius: f32`,
  `arc_rad: f32`, `damage: f32`, `pierce_remaining: u8`, `ttl_ticks: u16`
- **XP gem (max 4096):** `id: u32`, `pos: [2]f32`, `xp_value: u16`,
  `magnet_target_id: u8` (0xFF if stationary)

### Snapshot contents and rate

- **Rate:** 20 Hz (sent every 3 server ticks / 50 ms).
- **Header (24 bytes):** `server_tick: u32`, `baseline_tick: u32`,
  `run_time_ms: u32`, `acked_input_seq: [4]u32`, `game_state: u8`,
  `counts: [4]u16` (players, enemies, projectiles, gem events).
- **Quantized entity records:** positions encoded as i16 in 0.05 unit steps
  (`[-1000, 1000]` maps to `[-20000, 20000]`); velocity/orientation as u8 angle
  (0..255 mapping 0..2π); HP as u16 (0..65535, or normalized u8 percentage for
  non-bosses).
- **Transient events array:** `DamageEvent` (`target_id: u32`, `amount: u16`,
  `is_crit: u8`), `DeathEvent` (`entity_id: u32`).

### Client interpolation and prediction

- **Interpolation buffer:** client renders remote entities at
  `t_render = t_latest_server − 100 ms` (2 snapshot intervals).
- **State blending:** given snapshots `A` and `B` bracketing `t_render`,
  position is interpolated via `P(t) = P_A + α(P_B − P_A)` where
  `α = (t_render − t_A) / 50 ms`.
- **Local player prediction:** client simulates its own movement at 60 Hz
  immediately from WASD input and stores a ring buffer of 128
  `(input_seq, move_vec, predicted_pos)` entries. Upon receiving
  `acked_input_seq`, the client re-simulates unacknowledged inputs from the
  authoritative server position. Errors below 2.0 units blend out at 15% per
  frame; errors at or above 2.0 units snap immediately.

## 3. Upgrade System

### 10 passives

| ID | Passive name | Stat modified | Effect per level | Max level | Total at max |
|----|--------------|---------------|------------------|-----------|--------------|
| P0 | Spinach Core | Damage | +10% base weapon damage | 5 | +50% |
| P1 | Amplifier Lens | Area | +12% hitbox/arc radius | 5 | +60% |
| P2 | Clockwork Gear | Cooldown | −8% weapon cooldown ticks | 5 | −40% |
| P3 | Accelerator Coil | Projectile speed | +15% projectile velocity | 5 | +75% |
| P4 | Stasis Capacitor | Duration | +15% hitbox/projectile lifetime | 5 | +75% |
| P5 | Prism Splitter | Projectile count | +1 projectile / swing per cycle | 3 | +3 count |
| P6 | Magnet Array | Pickup radius | +35% XP gem attraction range | 5 | +175% |
| P7 | Thruster Boots | Move speed | +8% player movement speed | 5 | +40% |
| P8 | Titanium Plating | Armor | −3 flat damage taken (min 1) | 5 | −15 flat |
| P9 | Nano Repair | Regen | +0.8 HP restored per second | 5 | +4.0 HP/s |

**Unlimited limit-break:** once all held weapon and passive slots reach max
level, subsequent level-ups offer repeatable **Overclock** upgrades — +2% global
damage, +1.5% attack speed, or +25 max HP — with no cap. This is what makes the
upgrade system unlimited and endless.

### Weapon level curves (8 levels each)

| Weapon | L1 base stats | L2–L3 | L4 breakpoint | L5–L7 | L8 max breakpoint |
|--------|---------------|-------|---------------|-------|-------------------|
| Sword (melee arc) | 20 dmg, 0.75 s CD, 3.5 u reach, 90° arc, 0.15 s dur, 99 pierce | L2: 4.4 u reach; L3: 30 dmg, 0.70 s CD | +1 simultaneous rear slash; arc widens to 120° | L5: 45 dmg; L6: 0.60 s CD, 5.25 u reach; L7: 65 dmg, 150° arc | 90 dmg, 0.50 s CD, fires 2 sequential slashes per cycle |
| Axe (heavy sweep) | 45 dmg, 1.60 s CD, 5.0 u reach, 160° arc, 0.35 s dur, 99 pierce | L2: 60 dmg; L3: 6.0 u reach, 180° arc | 270° arc; adds 2.0 u knockback impulse | L5: 85 dmg, 1.45 s CD; L6: 110 dmg, 7.0 u reach; L7: 140 dmg, 1.25 s CD | 180 dmg, full 360° spin, hits twice per swing (0.20 s delay) |
| Bow (piercing arrow) | 30 dmg, 1.10 s CD, 18 u/s speed, 0.4 u radius, 1 count, 2.0 s dur, 2 pierce | L2: +1 arrow (15° spread); L3: 40 dmg, 3 pierce | Arrows ricochet 1 time off screen bounds; speed 22.5 u/s | L5: 55 dmg, +1 arrow; L6: 0.90 s CD, 5 pierce; L7: 75 dmg, +1 arrow (4 total) | 100 dmg, infinite pierce (99), 2 ricochets per arrow |
| Gun (rapid kinetic) | 12 dmg, 0.25 s CD, 28 u/s speed, 0.25 u radius, 1 count, 1.2 s dur, 1 pierce | L2: 15 dmg, 0.22 s CD; L3: +1 parallel bullet | Every 4th shot explodes (2.5 u radius, 150% AoE dmg) | L5: 20 dmg, 0.18 s CD; L6: 25 dmg, 2 pierce; L7: +1 bullet (3 total), 0.15 s CD | 35 dmg, 0.12 s CD (8.33 shots/s), explosive round every 2nd shot |

### 8 evolutions (weapon L8 + maxed passive)

- **Sword L8 + Clockwork Gear L5 → Vorpal Blender:** continuous 360° orbital
  blade ring (5.5 u radius) ticking every 0.15 s for 65 damage.
- **Sword L8 + Thruster Boots L5 → Phase Katana:** propels the player 4.0 u
  forward along the movement vector every 1.5 s with 0.3 s invulnerability,
  leaving a 150 damage slash wake.
- **Axe L8 + Amplifier Lens L5 → Gravity Cleaver:** 12.0 u radius sweep that
  pulls hit enemies 4.0 u inward and leaves a 3.0 s ground rift dealing
  40 damage/sec.
- **Axe L8 + Titanium Plating L5 → Juggernaut Halberd:** adds 300% of flat
  armor to base damage; each swing grants +2 temporary shield per enemy hit
  (caps at 50 shield).
- **Bow L8 + Accelerator Coil L5 → Railgun Longbow:** instant hitscan beam
  (45.0 u length, 1.2 u width), 220 damage, 0.70 s cooldown, infinite pierce.
- **Bow L8 + Prism Splitter L3 → Storm Volley:** fires 12 arrows in a 360°
  nova; each arrow splits into 2 half-damage sub-arrows on first enemy impact.
- **Gun L8 + Spinach Core L5 → Vulcan Minigun:** 0.05 s cooldown
  (20 rounds/sec), 50 damage; hits apply a stacking debuff increasing enemy
  damage taken by +5% (caps at +50%).
- **Gun L8 + Stasis Capacitor L5 → Cryo Flechette:** bullets slow targets by
  40% for 2.5 s; at 5 stacks the target freezes solid for 1.5 s and shatters on
  death for 120 AoE damage (3.0 u radius).

### 5 synergies (active when both items reach level 3+)

- **Magnet Array + Amplifier Lens → Singularity Field:** magnetized XP gems deal
  15 kinetic damage to enemies they pass through while flying toward the player.
- **Titanium Plating + Nano Repair → Reactive Carapace:** taking contact damage
  emits a 4.0 u radial shockwave dealing `12 × Regen` damage (1.0 s internal
  cooldown).
- **Sword + Axe → Cross-Slash Mastery:** every 3rd Axe sweep immediately resets
  Sword cooldown and grants +50% reach to the next Sword attack.
- **Bow + Gun → Target Painter:** Gun hits mark enemies for 3.0 s; Bow arrows
  curve toward marked targets within 6.0 u and deal +35% critical damage.
- **Thruster Boots + Accelerator Coil → Kinetic Charge:** moving accumulates
  10 charge per unit traveled; at 100 charge the next weapon activation gains
  +40% damage and +50% projectile speed.

## 4. Endless Escalation

### Spawn formula over time

Evaluated every 60 ticks (1.0 s). Let `t` be elapsed minutes and `P` the active
player count:

- Active cap: `E_max(t) = min(4096, floor(40 + 35t + 4t²))`
- Spawn rate: `R(t) = (3.0 + 2.2t + 0.35t²) × (1 + 0.5(P − 1))` enemies/sec
- **Spawn geometry:** enemies spawn at a random angle `θ ∈ [0, 2π)` at radial
  distance `d ∈ [48.0, 56.0]` units from the centroid of alive players (outside
  the 80 × 45 viewport).
- **Wave surges:** every 120 s (2:00, 4:00, …), for 15 s, `R(t)` is multiplied by
  2.5× and spawns cluster into two opposing 30° pincer arcs.

### 3 enemy tiers

| Tier & unlock | Archetype (shape) | Radius | Base HP | Speed | Contact dmg | Special behaviour & drop |
|---------------|-------------------|--------|---------|-------|-------------|--------------------------|
| T1 (0:00+) | Circle T1 (Swarmer) | 0.5 u | 15 | 4.5 u/s | 5 | Direct pursuit of nearest player. Drops Small Gem (2 XP). |
| T1 (1:30+) | Triangle T1 (Darter) | 0.5 u | 10 | 7.0 u/s | 8 | Pauses 0.4 s at 10 u range, then lunges at 15.0 u/s. Drops Small Gem (2 XP). |
| T2 (5:00+) | Circle T2 (Brute) | 0.9 u | 80 | 3.8 u/s | 12 | 50% knockback resistance. Drops Medium Gem (10 XP). |
| T2 (7:00+) | Triangle T2 (Spitter) | 0.7 u | 45 | 5.0 u/s | 10 | Halts at 18 u to fire a 9.0 u/s enemy projectile (10 dmg) every 2.5 s. Drops Medium Gem (10 XP). |
| T3 (12:00+) | Circle T3 (Goliath) | 1.4 u | 320 | 3.2 u/s | 22 | 85% knockback resistance; crushes T1 enemies out of its path. Drops Large Gem (50 XP). |
| T3 (14:00+) | Triangle T3 (Lancer) | 1.0 u | 180 | 8.5 u/s | 28 | Locks vector every 4.0 s and charges 24.0 u at 20.0 u/s (knockback immune). Drops Large Gem (50 XP). |

### Elite modifiers

Spawn chance `1% + 0.5% × t` (caps at 15%). Elites gain 3.0× HP, +25% radius,
and drop 5× XP:

- **Vampiric:** +20% move speed; restores 15% max HP upon damaging a player.
- **Splitter:** splits into 3 miniature copies (30% HP, +30% speed, 0.6× radius)
  on death.
- **Shielded:** spawns with a 50% max HP barrier that regenerates if undamaged
  for 3.0 s.
- **Haste Aura:** emits an 8.0 u aura granting +35% movement speed to nearby
  enemies.

### Boss cadence

- **Interval:** every 180 s (3:00, 6:00, 9:00, …).
- **Geometry & stats:** compound octagon (circle core + 2 counter-rotating
  triangles), 3.0 u radius, base HP
  `2500 × M_HP(t) × (1 + 0.75(P − 1))`, speed 5.5 u/s, contact dmg 35, 100%
  knockback/freeze immunity.
- **Attack cycle (6.0 s loop):** alternates a 12-projectile radial burst
  (14.0 u/s, 18 dmg) with a telegraphed 22.0 u/s dash (1.0 s red wireframe
  warning box).
- **Drop:** Boss Cache (250 XP + an immediate evolution/upgrade draft).

## 5. Protocol v1

- **Framing:** loopback TCP (`127.0.0.1:7777`), `TCP_NODELAY` enabled,
  little-endian packed structs. Every packet begins with a 7-byte header:
  `msg_type: u8`, `payload_len: u16`, `seq: u32`.

### Message list

| ID | Direction & name | Fields |
|----|------------------|--------|
| 0x01 | C2S_HELLO | `proto_ver: u8` (1), `requested_slot: u8` (0 = any), `session_token: u64`, `name: [16]u8` |
| 0x02 | C2S_INPUT | `input_seq: u32`, `client_tick: u32`, `move_x: i8` (−100..100), `move_y: i8`, `aim_angle: u16`, `buttons: u8` |
| 0x03 | C2S_LEVELUP_CHOICE | `event_id: u16`, `choice_idx: u8` (0..2) |
| 0x04 | C2S_ACK_SNAPSHOT | `last_recv_server_tick: u32` |
| 0x81 | S2C_WELCOME | `player_id: u8`, `session_token: u64`, `tick_hz: u8` (60), `snap_hz: u8` (20), `arena_half_size: u16` (1000), `server_tick: u32` |
| 0x82 | S2C_SNAPSHOT_FULL | `server_tick: u32`, `run_time_ms: u32`, `game_state: u8`, `acked_seq: [4]u32`, `players: [P]PlayerNet`, `enemies: [E]EnemyNet`, `projs: [K]ProjNet`, `gems: [G]GemNet` |
| 0x83 | S2C_SNAPSHOT_DELTA | `server_tick: u32`, `baseline_tick: u32`, `acked_seq: [4]u32`, `spawned: [S]EntityBlob`, `destroyed_ids: [D]u32`, `updated: [U]DeltaBlob` (`id: u32`, `dirty_mask: u8`, fields…) |
| 0x84 | S2C_LEVELUP_OFFER | `player_id: u8`, `event_id: u16`, `new_level: u16`, `options: [3]UpgradeOptionNet` (`item_id: u8`, `next_lvl: u8`, `is_evo: u8`) |
| 0x85 | S2C_GAME_OVER | `final_tick: u32`, `seconds_survived: u32`, `score: u32`, `kills: u32`, `summaries: [4]PlayerEndStats` |

### Full vs. delta snapshots

- Server retains a 32-snapshot ring buffer (1.6 s of history) and tracks
  `last_recv_server_tick` per connected client.
- If a client's `last_recv_server_tick` is 0 or falls outside the 32-snapshot
  window, the server sends `S2C_SNAPSHOT_FULL`.
- Otherwise the server diffs current entity state against
  `baseline_tick = last_recv_server_tick` and emits `S2C_SNAPSHOT_DELTA`.
- **Gem optimisation:** static XP gems never emit position deltas. The server
  sends a single spawn record (`id`, `pos_x`, `pos_y`, `xp_value`), a state
  change when magnetized (`id`, `target_player_id`), and a destroy id when
  collected.

### How player 2 joins later

- **Handshake:** player 2 connects via TCP and sends `C2S_HELLO`; the server
  assigns `player_id = 1` and replies `S2C_WELCOME`.
- **State sync:** the server sends `S2C_SNAPSHOT_FULL` to player 2; player 1
  receives player 2's spawn record inside their next `S2C_SNAPSHOT_DELTA`.
- **Catch-up initialisation:** player 2 spawns at player 1's coordinates +
  `(2.0, 0.0)` with 3.0 s invulnerability and level
  `max(1, floor(0.8 × party_level))`, queuing rapid `S2C_LEVELUP_OFFER` drafts.
- **Synchronised level-up:** XP is pooled across the party. When the bar fills,
  `game_state` transitions to `LevelUpPause`, the server pauses simulation
  ticks, dispatches `S2C_LEVELUP_OFFER` to all living players, and resumes once
  all players submit `C2S_LEVELUP_CHOICE` (or after a 15.0 s server timeout that
  auto-selects option 0).

## 6. Phase Plan

| Phase | Zig server (`shaped-haven-server`) | C++17 / Ogre3D client (`shaped-haven-client`) | Definition of done |
|-------|------------------------------------|-----------------------------------------------|--------------------|
| 1. Loopback skeleton & prediction | 60 Hz deterministic loop, non-blocking TCP listener, `C2S_HELLO` / `C2S_INPUT` parser, player kinematic integrator, 20 Hz `S2C_SNAPSHOT_FULL` broadcaster | Ogre3D window + orthographic camera, manual mesh builders (square, circle, triangle), async TCP socket thread, 60 Hz local input prediction + 100 ms interpolation buffer | A single square moves smoothly via WASD at 60 FPS over loopback TCP; artificial 50 ms delay produces zero visual jitter and reconciles within 1 tick |
| 2. Combat core & 4 weapons | Uniform spatial hash grid (4.0 u cell size) for broadphase collision; Circle/Triangle T1 spawning; Sword, Axe, Bow and Gun firing; arc/circle/ray hit detection; knockback | Procedural primitive batch renderer for enemies, weapon arcs and projectiles; floating damage numbers; HP bar billboards | 1,000 active enemies and 500 projectiles run under 4.0 ms/tick on the server and render at 60 FPS on the client; all 4 weapons fire and kill enemies accurately |
| 3. XP, level-up & upgrade engine | Gem drop/magnet logic, XP curve, simulation pause state, weighted 3-choice generator, 10 passives, 8-level weapon tables, 8 evolutions, 5 synergy flags | Level-up 3-card modal (ImGui or OgreOverlay), HUD XP bar, active weapon/passive icon tray, evolution visual swaps | Player can collect gems, pause on level-up, pick upgrades via `C2S_LEVELUP_CHOICE`, trigger all 8 evolutions and 5 synergies, and reach game over at 0 HP |
| 4. Escalation & delta protocol | 32-snapshot history ring, `S2C_SNAPSHOT_DELTA` encoder, 4-phase difficulty curve, T2/T3 enemies, 4 elite modifiers, 180 s boss state machine | Delta snapshot decompressor, colour/outline shaders for elite modifiers, boss telegraph warning geometry, run timer, `S2C_GAME_OVER` scoreboard screen | Bandwidth stays under 25 KB/s during a 2,500-enemy 20:00 stress test; bosses spawn every 3:00 and drop evolution chests; a full 20-minute run is playable start to finish |
| 5. Drop-in co-op & polish | Multi-client slot manager (4 players), dynamic mid-run join catch-up, synchronised party level-up pause with 15 s timeout, `session_token` reconnect handler | `--connect ip:port` flags, distinct player colour palettes, off-screen teammate indicator arrows, connection status overlay | A second client process connects mid-run at 10:00, receives full state, drafts catch-up upgrades, shares XP/level-up pauses with player 1, and survives a forced socket reconnect |
