# shaped-haven-server

Headless, server-authoritative simulation core for **Shaped Haven**, a minimal
bullet-heaven (survivors-like) game.

The server owns *all* game state. It has no rendering code and no Ogre
dependency: it is a plain process that runs a fixed-timestep simulation and
speaks a compact snapshot protocol over TCP. Single player today is the same
code path as multiplayer later — the client just connects to `127.0.0.1`.

Companion repository: `shaped-haven-client` (C++17 / Ogre3D view + input layer).

## Architecture

- **Fixed timestep:** 60 Hz simulation tick (16.667 ms), deterministic order of
  system updates.
- **Transport:** TCP with `TCP_NODELAY`, little-endian packed structs, 7-byte
  packet header (`msg_type: u8`, `payload_len: u16`, `seq: u32`).
- **Snapshots:** 20 Hz, full snapshots first, then deltas against the last
  snapshot the client acknowledged.
- **State layout:** structure-of-arrays flat pools with hard caps
  (4 players, 4096 enemies, 2048 projectiles, 4096 XP gems).

Source layout:

| File | Contents |
| --- | --- |
| `root.zig` | Tick rate, entity caps and the other DESIGN.md constants. |
| `wire.zig` | Protocol v1: framing, payload layouts, quantization, and the byte values for the enums PROTOCOL.md leaves open. |
| `sim.zig` | The tick loop, the player pool, the integrator and the level-up pause. |
| `enemy.zig` | Enemy pool, Tier 1 archetypes, the spawn formula and the darter's AI. |
| `weapon.zig` | The weapon table: all four weapons across eight levels, plus the eight evolutions. |
| `upgrade.zig` | The item id space, the ten passives, the eight evolutions, the five synergies, the XP curve, stat resolution and the level-up choice generator. |
| `combat.zig` | Projectile pool, arc/circle/ray hit detection, damage, knockback and the projectile-level evolution effects. |
| `evolve.zig` | The evolved weapons' lingering effects: ground rifts and Cryo Flechette shatters. |
| `gem.zig` | The XP gem pool. |
| `spatial.zig` | Uniform spatial hash grid used as the combat broadphase. |
| `rng.zig` | Deterministic SplitMix64, so a run is reproducible from its seed. |
| `server.zig` | TCP listener, per-connection threads, the 60 Hz wall-clock loop. |
| `smoke.zig` | The phase-3 smoke test: one scripted run from gems to game over. |
| `bench.zig` | The phase-2 load measurement. |

The full design — entity fields, weapon/upgrade tables, escalation curves,
message list, phase plan — is in [DESIGN.md](DESIGN.md).

### Tick order

Determinism depends on this order, so it is part of the contract:

1. players integrate their input, and regen/timers tick;
2. enemies run their AI (slowed or frozen), integrate, and are clamped to the arena;
3. the broadphase grid is rebuilt from the enemies' new positions;
4. every ready weapon fires — resolved through the loadout, with the evolution and synergy effects;
5. projectiles travel and resolve what they overlap;
6. enemies touching a player deal contact damage, reduced by armor and absorbed by shield;
7. dead enemies drop a gem; dead enemies and spent projectiles are compacted;
8. gems magnetize, fly, and are collected, awarding XP;
9. ground rifts damage what stands in them and expire;
10. a filled XP bar pauses the run and offers three choices;
11. once a second, the spawn formula is evaluated.

Nothing moves between step 3 and step 7 except knockback *velocity*, so every
grid query in a tick sees a consistent set of indices and the pools are
compacted once, at the end. `reapDead` compacts the enemy pool, so the grid is
rebuilt again before the Cryo Flechette shatter query reads it.

### Protocol values this repository had to choose

`PROTOCOL.md` fixes the byte layout of `EnemyNet` and `ProjNet` but not the
meaning of their enum bytes. This repository chooses:

| Field | Values |
| --- | --- |
| `EnemyNet.archetype` | 0 Circle T1, 1 Circle T2, 2 Circle T3, 3 Triangle T1, 4 Triangle T2, 5 Triangle T3, 6 Boss — the order DESIGN.md §2 lists them in. Phase 2 emits only 0 and 3. |
| `ProjNet.shape` | 0 ARC, 1 CIRCLE, 2 RAY — the order DESIGN.md §2 lists them in. |
| `ProjNet.weapon_id` | 0 Sword, 1 Axe, 2 Bow, 3 Gun — the order DESIGN.md §3 lists them in. |

`shape = ARC` is the melee sweep: the sword and axe apply their damage
instantaneously through a sector test and then emit a short-lived, non-colliding
ARC record so the client can draw the swing. CIRCLE and RAY are travelling
projectiles that damage what they overlap as they move.

### Choices DESIGN.md and PROTOCOL.md left open

| Question | Choice |
| --- | --- |
| Does an evolution consume its passive? | No. The fusion replaces the weapon slot's item id with the evolution's and keeps the passive, so the passive can still arm a synergy. DESIGN.md §3 says nothing about consuming it, and consuming it would make the evolution a downgrade for synergy builds. |
| How are the three choices weighted? | Levelling a held weapon or passive 4, a new weapon or passive 3, an evolution 2, Overclock 1. Drawn three at a time, distinct, without replacement. |
| When is Overclock offered? | Only when all four weapon slots are filled *and* at level 8, and every held passive is at its max. An empty weapon slot is itself something left to fill, so it blocks the fallback. |
| How does a scripted client pick an option? | `C2S_LEVELUP_CHOICE` carries the `event_id` from the offer and a `choice_idx` of 0..2; the server ignores a stale or repeated event. |
| Is XP pooled across the party? | No — per player, in phase 3. DESIGN.md §5's party-pooled XP and the synchronised party pause are phase 5. |
| What does a restart reset? | The whole run: the world, the tick counter and every connected player. Phase 3 is single-player; a per-player restart is phase 5. |

## Requirements

- **Zig 0.18.0-dev.146** — the build installed on this machine at
  `D:\src\zig\zig.exe`. The code is written and verified against exactly this
  toolchain: its standard library differs substantially from earlier releases
  (`std.process.Init`, `std.Io`, the current `ArrayList` API), so read
  `D:\src\zig\lib\std` rather than older examples when extending it.
  Zig 0.17.0 is the current stable release, but fetching it from ziglang.org
  was not possible at a usable speed here; switching is a follow-up task once
  the download is practical.

## Build and test

```sh
zig build                          # build the server (Debug)
zig build -Doptimize=ReleaseFast   # the build to run when measuring
zig build test                     # run the headless simulation tests
zig build test -Doptimize=ReleaseFast   # the same tests, at shipping speed
zig build run                      # run the server (listens on 127.0.0.1:7777)
```

### Server flags

| Flag | Meaning |
| --- | --- |
| `--port <n>` | TCP port to listen on (default 7777). |
| `--stress-enemies <n>` | Hold `n` enemies live around the players. |
| `--stress-projectiles <n>` | Hold `n` gun projectiles live as well. |

The stress flags are a **measurement tool**, not part of the game. The natural
spawn curve of DESIGN.md §4 does not reach 1,000 live enemies until roughly
twelve minutes into a run, which is far too long to sit through while measuring
a frame rate; `--stress-enemies 1000 --stress-projectiles 500` puts the phase-2
load on the wire immediately so the client's side of the definition of done can
be measured against a real server. The load is placed around the players'
centroid, so it only starts once somebody has joined, and it is held at exactly
the requested counts — the top-up runs every tick, and also when a player
joins, so even the first snapshot a client receives carries the full load.

## Status

Phase 3 — XP, level-up and the upgrade engine. The server simulates the phase-2
combat core plus the whole upgrade system of DESIGN.md §3:

- **XP gems.** Every enemy drops a gem worth its tier's XP on death; a gem is
  magnetized when a player comes inside that player's pickup radius, flies in,
  and is collected for XP. The Magnet Array passive scales the radius.
- **The XP curve and the level-up.** `XP(L) = floor(10 + 5L + 1.5L²)`. A filled
  bar pauses the run (`game_state = 1`), offers three weighted choices and
  waits for `C2S_LEVELUP_CHOICE`, auto-selecting option 0 after 15 s.
- **A real stat-resolution layer.** All ten passives and all four weapons'
  eight-level tables change what the combat code does: damage, area, cooldown,
  projectile speed, lifetime, projectile count, pickup radius, move speed,
  armor, regen, and the per-level breakpoints (the sword's rear slash, the
  axe's knockback and double hit, the bow's ricochet, the gun's explosive
  rounds).
- **Eight evolutions**, each a level-8 weapon fused with its named passive, and
  **five synergies**, each active when both items reach level 3.
- **Unlimited progression.** Once every held weapon and passive is maxed, the
  three repeatable Overclock upgrades (global damage, attack speed, max HP)
  take over with no cap.
- **Death and restart.** HP reaching 0 ends the run (`game_state = 2` plus
  `S2C_GAME_OVER`); `C2S_RESTART` starts a fresh run.
- **`S2C_LOADOUT`** whenever level, XP or the item set changes.

Verified: `zig build test` — 169 tests pass. `zig build test
-Doptimize=ReleaseFast` — 169 pass.

### The phase-3 smoke test

`smoke.test.phase 3 smoke: a full run from gems to game over` drives the real
`Simulation` API through the whole definition of done in one scripted run:
enemies spawn and die, XP is collected, an upgrade is offered and applied, all
eight evolutions trigger, all five synergies arm and fire, the difficulty
escalates without bound, and the run ends at 0 HP and restarts. It lives in
`src/smoke.zig` and runs as part of `zig build test`.

### The phase-2 load measurement

DESIGN.md §6 sets the definition of done as *1,000 active enemies and 500
projectiles under 4.0 ms/tick*. The measurement is the `bench` test, and the
build mode is part of the result: a Debug build keeps bounds checks and panics
on every array access, which is a different order of cost from the release
build the server ships at. Both are quoted so the two are not confused:

| Build | Command | Mean | Worst |
| --- | --- | --- | --- |
| ReleaseFast | `zig build test -Doptimize=ReleaseFast` | 0.052 ms/tick | 0.17 ms/tick |
| Debug | `zig build test` | 0.585 ms/tick | 0.99 ms/tick |

Both over 240 ticks with 1,000 enemies and 500 projectiles live, measured on
this machine. The mean is stable; the worst tick is a single sample and moves
around between runs, so it is quoted as a range. The benchmark asserts that
the load it measured *was* that load — the mean live counts over the run must
equal the requested ones — so the number cannot come from a run that was
quietly serving less than the DoD names.

Phase 3 made the benchmark hold the player's level and HP: the load's own
weapons kill stressed enemies, so gems drop and the run would pause on a
level-up, and a thousand enemies swarming the player would kill it. A paused or
over tick measures nothing, so both are pinned out of the way and the number is
again the sustained cost of the load the DoD names.

### Against a real client

`zig build -Doptimize=ReleaseFast` then
`shaped-haven-server --stress-enemies 1000 --stress-projectiles 500`, with the
client's own `--frames 600 --verbose` run against it: a steady 138 fps, 20
snapshots/second, no dropped or malformed frames, and every snapshot carrying
exactly 1,000 enemies and 500 projectiles.

The client *draws* somewhat fewer than that — 845–950 enemies and 385–440
projectiles over the run. That is the client's interpolation, not the server's
load: it only draws an entity once two consecutive snapshots bracketing its
render time both carry it, so an entity younger than the 100 ms interpolation
delay is not drawn yet. The load churns — the player's weapons kill enemies
every tick and the top-up replaces them, and projectiles expire and are
replaced — so there is always a fraction too young to draw. The counts the
server puts on the wire are exact; the counts a client renders are a
consequence of its own delay.

Deliberately not in this phase (DESIGN.md §6 puts them later): the Tier 2 and
Tier 3 enemies, the elite modifiers and the boss of §4, and `S2C_SNAPSHOT_DELTA`
(phase 4). The upgrade system, the XP gems and player death are all in.

