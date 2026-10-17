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
- **Snapshots:** 20 Hz. A full snapshot first, then deltas against the server's
  model of the state the client holds, with interest management keeping every
  snapshot to the receiver's own neighbourhood.
- **State layout:** structure-of-arrays flat pools with hard caps
  (4 players, 4096 enemies, 2048 projectiles, 4096 XP gems).

Source layout:

| File | Contents |
| --- | --- |
| `root.zig` | Tick rate, entity caps and the other DESIGN.md constants. |
| `wire.zig` | Protocol v2: framing, payload layouts, quantization, and the byte values for the enums PROTOCOL.md leaves open. |
| `races.zig` | The ten playable races: their stat rows, dash behaviour, and the names and lore the character select shows. |
| `sim.zig` | The tick loop, the player pool, the integrator, the dash state and the level-up pause. |
| `enemy.zig` | Enemy pool, all six archetypes plus the boss, the difficulty and spawn curves, the four elite modifiers and the archetype AI. |
| `weapon.zig` | The weapon table: all four weapons across eight levels, plus the eight evolutions. |
| `upgrade.zig` | The item id space, the ten passives, the eight evolutions, the five synergies, the XP curve, stat resolution, the level-up choice generator and the per-option stat deltas. |
| `combat.zig` | Projectile pool, arc/circle/ray hit detection, damage, knockback and the projectile-level evolution effects. |
| `evolve.zig` | The evolved weapons' lingering effects: ground rifts and Cryo Flechette shatters. |
| `loadout.zig` | The `--debug-loadout` **test affordance**: parse a starting loadout and apply it to a run. Not part of the game. |
| `gem.zig` | The XP gem pool. |
| `spatial.zig` | Uniform spatial hash grid used as the combat broadphase. |
| `rng.zig` | Deterministic SplitMix64, so a run is reproducible from its seed. |
| `delta.zig` | The 32-snapshot history ring, the per-connection model of what the client holds, the per-snapshot byte budget and the diff itself. |
| `server.zig` | TCP listener, per-connection threads, the 60 Hz wall-clock loop, snapshot encoding and interest management. |
| `smoke.zig` | The phase-3 smoke test: one scripted run from gems to game over. |
| `bench.zig` | The phase-2 load measurement. |
| `bandwidth.zig` | The phase-4 bandwidth measurement. |

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

`PROTOCOL.md` fixes the byte layout of the entity records but not the meaning of
their enum bytes. This repository chooses:

| Field | Values |
| --- | --- |
| `EnemyNet.archetype` | 0 Circle T1, 1 Circle T2, 2 Circle T3, 3 Triangle T1, 4 Triangle T2, 5 Triangle T3, 6 Boss — the order DESIGN.md §2 lists them in. Phase 2 emits only 0 and 3. |
| `EnemyNet.telegraph_shape` | 0 None, 1 CircleAoE, 2 ConeSlash, 3 LineCharge. A darter's lunge and the boss's dash are both a `LineCharge`; the other two are reserved for a future telegraphed attack and are not emitted yet. |
| `ProjNet.shape` | 0 ARC, 1 CIRCLE, 2 RAY — the order DESIGN.md §2 lists them in. |
| `ProjNet.weapon_id` | 0 Sword, 1 Axe, 2 Bow, 3 Gun — the order DESIGN.md §3 lists them in. |
| `UpgradeOptionNet.stat_type` | 0 damage, 1 armor, 2 max HP, 3 move speed, 4 cooldown, 5 area, 6 projectiles, 7 crit chance, 8 max mana, 9 max shield. |

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
| §1 says spawn density is linear 3.0 → 14.0/s; §4 gives `3.0 + 2.2t + 0.35t²`, which is 22.75/s at 5:00. Which holds? | The formula. §4 is the section that defines the spawner and §1 is the narrative summary; §1's endpoint is exactly the formula's linear term, so §1 is describing that term rather than a different curve. The reading is pinned by a test. |
| Where does the endless move-speed escalation apply? | At spawn, exactly as the health curve does: `enemy.speedMultiplier(t)` is baked into a new enemy's speed. Below 20:00 it is 1.0, so a standard run is untouched, and past it the horde that keeps respawning gets faster. |
| What is a delta diffed against? | The server's model of the *state* the client holds — its own interest-filtered neighbourhood — not the ring snapshot at a tick. The tick still names the baseline on the wire, but the model is what makes a deferred update stay pending and a changed interest centre report an entry or an exit. |
| When does an acknowledgement correct that model? | On the first tick the model cannot account for. The model accounts for exactly two ticks once it has sent a snapshot — the tick that snapshot carried, and the tick it was diffed against — so an ack naming either is lag rather than correction, and anything else means the model has run past what a single unprocessed snapshot explains. Waiting for the client to repeat itself, which is what the predicate used to do, ignored the first corrective ack and cost a round trip. |
| What does a hostile projectile name in `weapon_id`? | 0. `owner_id = 0xff` is what marks it hostile, so `weapon_id` carries no meaning for one; PROTOCOL.md leaves it open and the field is not read for a hostile record. |

## Protocol v2

Protocol v2 is the current wire format. The client repo's `PROTOCOL.md` is the
authoritative byte layout and both repos must agree on it. On top of the
phase-4 messages it adds the race and weapon ids to the handshake, the player's
dash, mana and shield state to `PlayerNet`, the enemy telegraph to `EnemyNet`,
and the per-option stat deltas to `S2C_LEVELUP_OFFER`. The frame header, the
snapshot header, `S2C_WELCOME`, the projectile and gem records, and every other
message are unchanged.

### Races

`C2S_HELLO` carries a `race_id` (0..9) and a `starting_weapon_id` (0 sword,
1 axe, 2 bow, 3 gun). The race picks one row of `RACE_SPECS` in `races.zig` —
max HP, max shield, max mana, the move-speed and damage multipliers, the dash
cooldown, mana cost, distance and i-frame ticks, flat armor, and the XP and
pickup-radius multipliers. A race id the server does not know is rejected, not
defaulted. The race's multipliers scale on top of the loadout's own, so a race
and a passive that both raise damage multiply together. The run starts with the
one picked weapon; the other three stay empty until the draft offers them.

### Dash

A dash spends `dash_mana_cost` mana, translates the player `dash_distance` world
units along the direction of travel (or the held aim when standing still), grants
`dash_iframe_ticks` of real invulnerability, and then starts a
`dash_cooldown_ticks` cooldown. Mana refills at a flat 4.0 per second, the same
for every race. The player's current mana, shield and dash cooldown are on the
wire — `PlayerNet.mana_pct`, `shield_pct`, `dash_cd_remaining` and
`dash_cd_total` — so the client can draw them without the cost being sent back.

### Telegraphs

An enemy that is about to attack carries a windup on the wire:
`telegraph_progress` (0 = none, 1..255 = the fraction of the windup elapsed),
`telegraph_shape`, `telegraph_angle` (milliradians) and `telegraph_radius`. A
darter's pause before its lunge and the boss's stand-still before its dash are
both a `LineCharge`; the client draws the shape, oriented by the angle and
sized by the radius, so the attack is visible before it lands.

### Stat deltas

Each option in `S2C_LEVELUP_OFFER` carries a `stat_type` and a pair of
fixed-point values (`current_stat_fp`, `upgraded_stat_fp`) scaled by 100, so the
client can show what the purchase changes — "12 ATK → 15 ATK (+25%)" — without
recomputing the whole stat table. A negative delta is a reduction, as with
cooldown per level.

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
| `--debug-loadout <spec>` | **Test affordance, not gameplay.** Start every run with the given loadout. |

The stress flags are a **measurement tool**, not part of the game. The natural
spawn curve of DESIGN.md §4 does not reach 1,000 live enemies until roughly
twelve minutes into a run, which is far too long to sit through while measuring
a frame rate; `--stress-enemies 1000 --stress-projectiles 500` puts the phase-2
load on the wire immediately so the client's side of the definition of done can
be measured against a real server. The load is placed around the players'
centroid, so it only starts once somebody has joined, and it is held at exactly
the requested counts — the top-up runs every tick, and also when a player
joins, so even the first snapshot a client receives carries the full load.

### The `--debug-loadout` test affordance

`--debug-loadout` is a **test affordance, not part of the game** — it exists so
the phase-5 completion criterion *"evolutions appear"* in a live client run can
be observed at all. An evolution needs a level-8 weapon *and* its named passive
at its max, roughly thirteen level-up picks, and a scripted run reaches level
6–7 before dying (see the phase-3 integration check below), so no live run
reaches one on its own. The flag starts a run already partway there, on every
join and every restart, so a scripted restart exercises it too. Without the flag
it is off, and the run's default loadout — the four level-1 weapons of
DESIGN.md §3 — is unchanged.

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/shaped-haven-server --debug-loadout "sword=8,clockwork_gear=5"
```

The spec is comma-separated `name=level` pairs. A name is a DESIGN.md §3 item
name (lower-cased, spaces as underscores), the passive's `P0`–`P9` alias from
PROTOCOL.md, or a decimal item id from PROTOCOL.md "Item ids" — so
`"0=8,18=5"` is the same loadout as `"sword=8,clockwork_gear=5"`. Levels above
an item's cap are clamped to it. Applying a loadout runs the same rule the
level-up draft uses for evolutions (DESIGN.md §3): a weapon at level 8 whose
named passive is at its max fuses into that evolution, so
`"sword=8,clockwork_gear=5"` arms the Vorpal Blender and no separate syntax is
needed to name one. A weapon slot fuses into the first evolution it qualifies
for in DESIGN.md §3 order. An empty spec starts a run with the normal loadout.

## Status

Phase 7 — protocol v2 and the race system. The server now speaks protocol v2:
`C2S_HELLO` carries the race and starting weapon, `PlayerNet` the mana, shield
and dash state, `EnemyNet` the telegraph fields, and `S2C_LEVELUP_OFFER` the
per-option stat deltas (see [Protocol v2](#protocol-v2)). It simulates the ten
races with their distinct stat rows and lore, the dash with its mana cost,
cooldown and i-frames, and the enemy telegraph state machine. `zig build test`
reports **230 tests, 0 failures**.

Phase 4 — the delta protocol and the endless escalation. The server simulates
the phase-2 combat core, the whole phase-3 upgrade system of DESIGN.md §3, and:

- **The four-phase difficulty curve** of DESIGN.md §1 (`M_HP(t)`) on enemy
  health, and the Phase D endless move-speed escalation on top of it.
- **Tier 2 and Tier 3 enemies** (Brute, Spitter, Goliath, Lancer) with their
  stats, unlock times and behaviours, and **the boss** every 180 s: a 12-shot
  radial burst alternating with a telegraphed 22 u/s dash, plus an evolution
  chest that reuses the level-up draft.
- **The four elite modifiers** — Vampiric, Splitter, Shielded, Haste Aura —
  rolled at `1% + 0.5%·t`, capped at 15%.
- **The delta protocol and interest management**, described below.
- **A per-snapshot byte budget** that caps a single frame, with the updates it
  cannot afford re-offered next snapshot rather than dropped.
- **A bandwidth benchmark** that runs the 2,500-enemy 20:00 scenario and
  measures the real encoder's bytes.

The phase-3 systems are all still in:

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
  take over with no cap. The counts are `u32` and increment with a plain
  `+=`, so they cannot wrap — the phase-3 review caught a `u8` counter with a
  wrapping add that silently dropped every bonus on the 256th purchase.
  Attack speed is the one Overclock with a floor: its per-purchase factor
  `1 - 0.015 * n` turns negative at 67 purchases, so the factor is clamped at
  `overclock_cooldown_floor` (0.05) — the cooldown can shrink to 5% of base,
  a 20x attack rate, and the multiplier stays positive at any count.
- **Death and restart.** HP reaching 0 ends the run (`game_state = 2` plus
  `S2C_GAME_OVER`); `C2S_RESTART` starts a fresh run.
- **`S2C_LOADOUT`** whenever level, XP or the item set changes.
- **A starting-loadout test affordance.** `--debug-loadout "sword=8,clockwork_gear=5"`
  starts every run — every join and every restart — with that loadout, fusing
  the evolution the draft would otherwise offer, so the phase-5 criterion
  *"evolutions appear"* is observable in a live client run. It is a test
  affordance, off unless the flag is given, and it is not gameplay.

### The delta protocol

A client holds exactly one complete state and names it with
`C2S_ACK_SNAPSHOT`. The server keeps a model of that state per connection: a
`FilteredWorld`, the receiver's own neighbourhood, entity for entity. The model
is the point of the design, and two behaviours depend on it:

- **Interest membership is decided when the state is captured.** The model was
  filtered around the position the player held *then*, not around wherever the
  player is now. An entity that entered the neighbourhood while the player moved
  is therefore `spawned`, and one that left it is `destroyed`. Filtering both
  sides of the diff around the current position instead — which is what a
  single-centre diff does — mistakes the first for an entity the client already
  knows and the second for one it never had, so neither record is ever sent.
- **Only the records that actually went out move the model.** The per-snapshot
  budget defers some `updated` records. A model that advanced to the snapshot's
  tick regardless would treat a deferred entity as delivered, and if it then
  stopped moving it would never be resent, leaving the client stale forever.
  Leaving the model alone keeps it pending, so the next diff still finds it
  changed and offers it again.

The model is rebuilt from the history ring when an acknowledgement disagrees
with it — the drift correction PROTOCOL.md's baseline rules describe, and the
reason the ring is kept. The ordinary path never reads it: it diffs against the
model.

An acknowledgement corrects the model on the *first* tick the model cannot
account for. What the model can account for, once it has sent a snapshot, is
exactly two ticks: the tick that snapshot carried, which the client holds if it
applied it, and the tick it was diffed against, which the client still holds if
it has not processed it yet. The second is recorded per connection as each frame
is built. An ack naming either is a client keeping up, or lagging by the one
snapshot the model has just carried it past, and it changes nothing; any other
tick is a client holding a state the model cannot explain, so the model is
wrong and the ack is the truth. A repeated ack is still a correction too, since
a client that applied the snapshot it is answering holds a newer tick and cannot
name the same one twice.

### The bandwidth measurement

DESIGN.md §6 sets the phase-4 definition of done as *bandwidth stays under
25 KB/s during a 2,500-enemy 20:00 stress test*. The `bandwidth` test builds
exactly that world and counts the bytes the real encoder emits, through the real
diff, the real per-snapshot budget and the real update rotation:

| Build | Mean | Peak delta frame | Budget |
| --- | --- | --- | --- |
| ReleaseFast | 18,747.6 B/s | 19,980.0 B/s | 25,000 B/s |
| Debug | 18,747.6 B/s | 19,980.0 B/s | 25,000 B/s |

100 snapshots over the measured window, 2,500 enemies held live at the 20:00
curve, ~55 of them inside the 40-unit interest radius at any moment, ~153 kills.
The bytes are identical in both builds because the world and the encoder are
deterministic; only the time taken to compute them differs. The peak is a
*single frame's* bytes at 20 Hz rather than a smoothed average, and the test
asserts it alongside the mean — asserting the mean alone is what let a peak 40%
over budget pass in the first draft of this phase.

The one-off opening full snapshot is reported separately (1,492 bytes): a
connection's first snapshot has no baseline to be a delta against, is not
bounded by the per-snapshot budget, and happens once. The test also asserts that
the world really held the load the DoD names, that interest management was
excluding most of the horde, and that the budget was actually binding — so the
number cannot come from a run that quietly served less than it claims.

Verified: `zig build test` — 230 tests pass. `zig build test
-Doptimize=ReleaseFast` — 230 pass. The phase-7 additions are the ten race rows
and their lore, the dash cost/cooldown/i-frames, the telegraph fields and the
level-up stat deltas; six of the phase-4 review regressions, and each was
checked against the behaviour it replaces: the
held-state test fails against a single-centre diff (which reports neither the
entry nor the exit), the deferred-update test fails against a model that applies
every candidate rather than every sent record (the client's position jumps to
the value it was never sent), the spawn-rate test fails against §1's linear
reading, the endless-speed test fails with the multiplier unwired, and the two
correction tests — the first corrective ack, and the same ack when its tick has
fallen out of the ring — fail against the predicate that waited for the client
to repeat itself (`expected 6, found 12` and `expected 6, found 105`). The
phase-3 regressions are still in place too: the Overclock wrap test fails
against the old `u8` code, the boundary tests do not compile against it, and the
attack-speed test fails where the old formula first went negative.

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
| ReleaseFast | `zig build test -Doptimize=ReleaseFast` | 0.10 ms/tick | 0.16 ms/tick |
| Debug | `zig build test` | 0.95 ms/tick | 1.65 ms/tick |

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

### The phase-3 integration check

A normal run (no stress flags) against the real client at its `phase-3-progress`
branch, driven by `--input-script` and `--choice-script`: 12,000 frames in
83.5 s, a steady **143.7 fps**, 1,668 snapshots received, no malformed, stale
or dropped frames, and a worst prediction error of 0.091 world units. The
level-up flow works end to end — the server offered three choices
(`S2C_LEVELUP_OFFER`), the client answered (`C2S_LEVELUP_CHOICE`), the run
resumed and the new loadout went out (`S2C_LOADOUT`). The run reached level 2
in 140 s of scripted play; an evolution (a level-8 weapon fused with its maxed
passive) takes far more level-ups than that, so none was reached — the
upgrade path is exercised by the smoke test and the unit tests instead. One
transient 5-tick client-side hiccup near frame 9,420 recovered on its own; the
TCP connection stayed up for the whole run (the server logged a single join
and a single final disconnect).

### The phase-4 integration check

A normal run (no stress flags) against the real client at its `phase-4-delta`
branch, driven by `--input-script` (a wide circle, so the interest neighbourhood
churns as the player walks) and `--choice-script`: three runs of 6,000 frames,
in 42.17 s, 41.90 s and 41.92 s, at **142.3, 143.2 and 143.1 fps**, 841, 834 and
839 snapshots received, and **833, 828 and 834 deltas applied** with one refused
in the first two runs and none in the third. Both refusals are inside the first
60 frames, while the model seeds from the first acknowledgements, and the
counter never moves again. The worst prediction error is 0.089, 0.085 and 0.092
world units — the pre-change build measured 0.098 on the same script, and the
2.0-unit snap threshold is an order of magnitude further out.
`interest_radius=40` decoded from the 21-byte welcome, three level-ups were
offered and answered, and the runs reported `stale=0 staleoffers=0 malformed=0
qdropped=0 sendfail=0 ackretry=0` throughout, with the only paused steps being
the level-up drafts themselves.

The seeding refusal is the client's connect timing rather than the correction
rule: the same 300-frame run against the pre-change predicate refused 0, 4 and 3
deltas across three runs, and against this one 0, 2 and 1. It is reported rather
than claimed away, and the steady state after seeding is 0 for both.

The correction rule itself is verified on the wire rather than only in a test. A
probe that falls behind the way a real client does — it applies a delta, does
not acknowledge it, then stops reading for three broadcasts — sends the first
corrective ack the server can see: the tick it holds, newer than its previous
ack and older than the model. Against this build the next delta is diffed
against that tick (`baseline=156`, the tick the probe named) and the probe
applies it; against the pre-change build the same probe gets `baseline=165`, the
model's own tick, which the probe holds no state for and refuses. The two
correction tests in `src/server.zig` pin the same rule, including the case where
the corrected tick has fallen out of the 32-snapshot ring and the honest answer
is a full snapshot rather than a delta.

Not exercised live: a game over and a restart, which a 42-second run does not
reach. The restart boundary is covered by `server.test.a restart takes the held
state back to nothing` and by the client's own tests.

Deliberately not in this phase (DESIGN.md §6 puts them later): the phase-5
multiplayer work — party-pooled XP, the synchronised party pause, per-player
restart, and the catch-up initialisation for a player joining a run already in
progress. The upgrade system, the XP gems, player death, the escalation and the
delta protocol are all in.

### The phase-5 starting-loadout affordance

`--debug-loadout` is the test affordance described under
[Server flags](#server-flags): it starts a run already holding a loadout, so the
phase-5 criterion *"evolutions appear"* can be observed in a live client run
rather than only in the smoke test. It is a test affordance, off unless the flag
is given, and it is not gameplay.

The live run: `zig build -Doptimize=ReleaseFast`, then in one foreground shell

```sh
cd E:/basegame
bash scratch/p5-run.sh evo 6000 --debug-loadout "sword=8,clockwork_gear=5"
```

`scratch/p5-run.sh` starts
`shaped-haven-server.exe --port 7891 --debug-loadout "sword=8,clockwork_gear=5"`,
runs the real client at `E:/basegame/shaped-haven-client/build/bin/Release/shaped-haven-client.exe`
with `--host 127.0.0.1 --port 7891 --name p5-evo --verbose --frames 6000
--input-script scratch/p5_circle.txt --choice-script scratch/p5_choices.txt`,
then stops the server. The server logs the affordance on startup:

```text
  DEBUG LOADOUT: sword=8,clockwork_gear=5   (TEST AFFORDANCE — NOT GAMEPLAY)
[server] player 0 joined as 'p5-evo…'
```

and the client's per-frame `--verbose` line reports a non-zero `evos=` from the
first line onwards — 6,000 frames in 41.84 s (143.4 fps), 100 verbose lines, all
`evos=1`, `stale=0 staleoffers=0 malformed=0 qdropped=0 sendfail=0 ackretry=0`:

```text
haven: frame=60 tick=24 srv_tick=180 acked=18 pred=(4.74,0.00) err=0.010 interp=9 remotes=0 enemies=0 projs=0 gems=0 snaps=11 d=5/2 acks=11 ir=40 stale=0 staleoffers=0 malformed=0 inputs=24 qdropped=0 prewelcome=0 disconnected=0 sendfail=0 ackretry=0 reconciles=9 key=0 move=(100.00,0.00) state=0 level=1 xp=0/16 choices=0 evos=1 restarts=0 upd_ms=0.525
haven: frame=6000 tick=2489 srv_tick=2649 acked=2483 pred=(21.72,39.66) err=0.008 interp=32 remotes=0 enemies=20 projs=14 gems=66 snaps=834 d=828/2 acks=834 ir=40 stale=0 staleoffers=0 malformed=0 inputs=2489 qdropped=0 prewelcome=0 disconnected=10 sendfail=0 ackretry=0 reconciles=832 key=1073742050 move=(-71.00,71.00) state=0 level=3 xp=22/38 choices=2 evos=1 restarts=0 upd_ms=1.383
```

`evos=` counts a weapon slot whose `evolved` byte rose, so `evos=1` is the
Vorpal Blender the loadout arms — the level-8 sword fused with Clockwork Gear at
its max — visible to the client in the `S2C_LOADOUT` sent on join.

The control run, the same script with no flag, reports `evos=0` on every line:

```sh
bash scratch/p5-run.sh ctl 600
# haven: frame=60 … level=1 xp=0/16 choices=0 evos=0 restarts=0 …
# haven: 600 frames in 4.44s (135.1 fps)
```

The `--debug-loadout` spec resolves to the Vorpal Blender through the same rule
the draft uses, which is pinned by `loadout.test.applying a loadout arms it and
fuses the evolution` and by the sim-level tests
`the debug loadout arms the requested loadout and its evolution`,
`the debug loadout survives a restart` and
`a run without the debug loadout keeps the default loadout`. The restart path
itself — that the loadout is re-applied after a `C2S_RESTART` — is covered by
that sim test; the live runs above do not reach a game over, so no live restart
was observed.

