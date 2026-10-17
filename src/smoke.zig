//! Shaped Haven server — the phase-3 smoke test.
//!
//! DESIGN.md §6's phase-3 definition of done is a *run*: a player collects
//! gems, pauses on a level-up, picks an upgrade, triggers every evolution and
//! every synergy, and reaches game over at 0 HP, while the difficulty escalates
//! without bound. This module drives that whole run through the real
//! `Simulation` API in one scripted test, so `zig build test` covers the
//! definition of done rather than a collection of unit tests that each cover a
//! corner of it.
//!
//! Everything here goes through `Simulation.advance`, `Simulation.applyInput`
//! and `Simulation.submitChoice` — the same calls the server makes — so the
//! smoke test cannot pass against a simulation the server cannot drive.

const std = @import("std");
const root = @import("root.zig");
const sim = @import("sim.zig");
const enemy = @import("enemy.zig");
const upgrade = @import("upgrade.zig");
const gem = @import("gem.zig");

const GameState = sim.GameState;
const PlayerState = sim.PlayerState;
const Simulation = sim.Simulation;

/// Strip a player's weapons, so a test can watch the world without the
/// player's own four weapons killing the subject.
fn disarm(p: *PlayerState) void {
    for (&p.weapons) |*slot| {
        slot.id = 0xff;
        slot.cooldown_ticks = 0;
    }
}

/// Put `id` into the loadout at `level`: a weapon into a free slot, a passive
/// into its index.
fn armItem(p: *PlayerState, id: u8, level: u8) void {
    if (id < root.max_weapons) {
        if (upgrade.weaponSlot(&p.weapons, id)) |i| {
            p.weapons[i].level = level;
            return;
        }
        for (&p.weapons) |*slot| {
            if (!slot.isFree()) continue;
            slot.id = id;
            slot.level = level;
            slot.cooldown_ticks = 0;
            slot.evolved = false;
            return;
        }
        return;
    }
    if (upgrade.passiveIndex(id)) |i| {
        p.passives[i] = level;
    }
}

/// Advance one tick and answer any level-up it triggers, so a test that is not
/// about the level curve is never stuck in the pause.
fn tick(s: *Simulation, player_id: u8) !void {
    s.advance();
    var guard: usize = 0;
    while (s.state == .level_up_pause and guard < 100) : (guard += 1) {
        const ev = s.pending_levelups[0];
        try std.testing.expect(s.submitChoice(player_id, ev.event_id, 0));
        s.advance();
    }
}

/// Fill the XP bar and take the resulting offer, without answering it.
fn offerLevelUp(s: *Simulation, player_id: u8) !sim.LevelUp {
    const p = &s.players[player_id];
    p.xp = p.xp_next;
    s.advance();
    try std.testing.expectEqual(GameState.level_up_pause, s.state);
    return s.pending_levelups[0];
}

fn answer(s: *Simulation, player_id: u8, ev: sim.LevelUp, choice_idx: usize) !void {
    try std.testing.expect(s.submitChoice(player_id, ev.event_id, @intCast(choice_idx)));
    try std.testing.expectEqual(GameState.running, s.state);
}

/// Force one level-up and answer it with `choice_idx`.
fn forceLevelUp(s: *Simulation, player_id: u8, choice_idx: usize) !sim.LevelUp {
    const ev = try offerLevelUp(s, player_id);
    try answer(s, player_id, ev, choice_idx);
    return ev;
}

/// Force level-ups until `evo_id` is offered, then take it.
fn forceEvolution(s: *Simulation, player_id: u8, evo_id: u8) !void {
    const p = &s.players[player_id];
    const evo = upgrade.evolutionById(evo_id).?;
    armItem(p, evo.weapon_id, root.max_weapon_level);
    armItem(p, evo.passive_id, upgrade.passiveMaxLevelById(evo.passive_id).?);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);

    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const ev = try offerLevelUp(s, player_id);
        var found: ?usize = null;
        for (ev.options, 0..) |opt, k| {
            if (opt.item_id == evo_id) found = k;
        }
        if (found) |k| {
            try std.testing.expect(ev.options[k].is_evo);
            try answer(s, player_id, ev, k);
            return;
        }
        try answer(s, player_id, ev, 0);
    }
    return error.EvolutionNeverOffered;
}

// ---------------------------------------------------------------------------
// The smoke test
// ---------------------------------------------------------------------------

test "phase 3 smoke: a full run from gems to game over" {
    var s = Simulation.init();
    const p = s.spawnPlayer(0, 0, 0).?;
    // This test is about the run end to end — gems, level-ups, evolutions,
    // synergies, death — not about survival balance, and v2 starts a run with
    // one weapon. The other three are armed at level 1, as the old default
    // loadout was, so the player survives the opening as this test expects.
    for (p.weapons[1..], 1..) |*slot, i| {
        slot.id = @intCast(i);
        slot.level = 1;
        slot.cooldown_ticks = 0;
    }

    // --- 1. Enemies spawn and die -----------------------------------------
    // The natural spawn curve places the first wave at 1:00, and the player's
    // four level-1 weapons kill what reaches them.
    var i: usize = 0;
    while (i < 1200) : (i += 1) try tick(&s, 0);
    try std.testing.expect(s.enemies.count > 0);
    try std.testing.expect(s.kills > 0);
    try std.testing.expect(s.tick > 0);

    // --- 2. XP is collected ------------------------------------------------
    // Gems dropped by the dead are picked up by proximity, and the bar fills.
    try std.testing.expect(p.xp > 0 or p.level > 1);
    try std.testing.expect(s.gems.count <= root.max_gems);

    // --- 3. An upgrade is offered and applied ------------------------------
    const before_level = p.level;
    const ev = try forceLevelUp(&s, 0, 0);
    try std.testing.expectEqual(before_level + 1, p.level);
    try std.testing.expectEqual(p.level, ev.new_level);
    try std.testing.expect(s.loadout_dirty[0]);
    // The chosen option is reflected in the loadout.
    var applied = false;
    for (p.weapons) |slot| {
        if (!slot.isFree() and slot.level > 1) applied = true;
    }
    for (p.passives) |lvl| {
        if (lvl > 0) applied = true;
    }
    try std.testing.expect(applied);

    // --- 4. All eight evolutions trigger -----------------------------------
    // Each one needs its weapon at level 8 and its named passive at max; the
    // offer is drawn until the evolution appears, then taken.
    var evo_id: u8 = 32;
    while (evo_id < 40) : (evo_id += 1) {
        try forceEvolution(&s, 0, evo_id);
        const slot = upgrade.weaponSlot(&p.weapons, upgrade.evolutionById(evo_id).?.weapon_id).?;
        try std.testing.expectEqual(evo_id, p.weapons[slot].id);
        try std.testing.expect(p.weapons[slot].evolved);
        try std.testing.expectEqual(root.max_weapon_level, p.weapons[slot].level);
    }

    // --- 5. All five synergies arm and fire --------------------------------
    // Cross-Slash Mastery: every third axe sweep resets the sword's cooldown.
    armItem(p, upgrade.ids.sword, 8);
    armItem(p, upgrade.ids.axe, 8);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_cross_slash != 0);
    if (upgrade.weaponSlot(&p.weapons, upgrade.ids.sword)) |si| {
        p.weapons[si].cooldown_ticks = 60;
    }
    var swings: usize = 0;
    while (swings < 3) : (swings += 1) {
        if (upgrade.weaponSlot(&p.weapons, upgrade.ids.axe)) |ai| {
            p.weapons[ai].cooldown_ticks = 0;
        }
        try tick(&s, 0);
    }
    if (upgrade.weaponSlot(&p.weapons, upgrade.ids.sword)) |si| {
        try std.testing.expectEqual(@as(u16, 0), p.weapons[si].cooldown_ticks);
    }

    // Target Painter: a gun hit marks the enemy for 3 s.
    armItem(p, upgrade.ids.bow, 8);
    armItem(p, upgrade.ids.gun, 8);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_target_painter != 0);
    disarm(p);
    armItem(p, upgrade.ids.gun, 1);
    if (upgrade.weaponSlot(&p.weapons, upgrade.ids.gun)) |gi| {
        p.weapons[gi].cooldown_ticks = 0;
    }
    const marked = s.enemies.spawn(.circle_t1, .{ 4.0, 0.0 }).?;
    const marked_id = s.enemies.id[marked];
    // Enough HP that the bullet marks it rather than killing it, and the pool
    // does not compact underneath the index.
    s.enemies.hp[marked] = 1000.0;
    s.enemies.max_hp[marked] = 1000.0;
    // The bullet has to travel, so give it the ticks it needs to arrive.
    var mark_ticks: usize = 0;
    while (mark_ticks < 20) : (mark_ticks += 1) try tick(&s, 0);
    var found_mark: u16 = 0;
    for (0..s.enemies.count) |k| {
        if (s.enemies.id[k] == marked_id) found_mark = s.enemies.marked_ticks[k];
    }
    try std.testing.expect(found_mark > 0);

    // Kinetic Charge: moving accumulates charge, and at 100 the next
    // activation is empowered.
    armItem(p, upgrade.ids.thruster_boots, 3);
    armItem(p, upgrade.ids.accelerator_coil, 3);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_kinetic_charge != 0);
    disarm(p);
    s.applyInput(0, .{ .input_seq = 1, .buttons = 0, .axis_x = 100, .axis_y = 0 });
    var moved: usize = 0;
    while (moved < 20) : (moved += 1) try tick(&s, 0);
    try std.testing.expect(p.kinetic_charge > 0.0);

    // Singularity Field and Reactive Carapace arm.
    armItem(p, upgrade.ids.magnet_array, 3);
    armItem(p, upgrade.ids.amplifier_lens, 3);
    armItem(p, upgrade.ids.titanium_plating, 3);
    armItem(p, upgrade.ids.nano_repair, 3);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_singularity_field != 0);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_reactive_carapace != 0);

    // --- 6. The difficulty escalates without bound -------------------------
    var late = Simulation.init();
    const lp = late.spawnPlayer(0, 0, 0).?;
    disarm(lp);
    late.tick = 3600 * 60 * 40; // 40 minutes
    var k: usize = 0;
    while (k < 200) : (k += 1) late.spawnWave();
    try std.testing.expectEqual(root.max_enemies, late.enemies.count);
    try std.testing.expect(late.spawn_debt > root.max_enemies);
    try std.testing.expect(enemy.activeCap(40.0) > enemy.activeCap(5.0));
    try std.testing.expect(enemy.spawnRate(40.0, 1) > enemy.spawnRate(5.0, 1));

    // --- 7. Game over at 0 HP, and a restart -------------------------------
    var dead = Simulation.init();
    const dp = dead.spawnPlayer(0, 0, 0).?;
    disarm(dp);
    dp.hp = 1.0;
    _ = dead.enemies.spawn(.circle_t1, .{ 0.6, 0.0 }).?;
    var ticks: usize = 0;
    while (dead.state != .game_over and ticks < 600) : (ticks += 1) dead.advance();
    try std.testing.expectEqual(GameState.game_over, dead.state);
    try std.testing.expect(dead.game_over_pending);
    try std.testing.expect(!dp.flags.alive);
    try std.testing.expectEqual(@as(u32, 0), dp.hp);
    try std.testing.expect(dead.scoreFor(0) > 0);

    dead.restart(0);
    try std.testing.expectEqual(GameState.running, dead.state);
    try std.testing.expect(dp.flags.alive);
    try std.testing.expectEqual(@as(u16, 1), dp.level);
    try std.testing.expectEqual(@as(u32, 0), dp.xp);
    // The race's own max HP, not the phase-1 default.
    try std.testing.expectEqual(@as(f32, 110.0), dp.hp);
    try std.testing.expectEqual(@as(usize, 0), dead.enemies.count);
}

// ---------------------------------------------------------------------------
// Focused checks the smoke test relies on
// ---------------------------------------------------------------------------

test "Reactive Carapace's shockwave damages the enemies around the player" {
    var s = Simulation.init();
    const p = s.spawnPlayer(0, 0, 0).?;
    disarm(p);
    armItem(p, upgrade.ids.titanium_plating, 3);
    armItem(p, upgrade.ids.nano_repair, 3);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_reactive_carapace != 0);

    const near = s.enemies.spawn(.circle_t1, .{ 0.6, 0.0 }).?;
    const far = s.enemies.spawn(.circle_t1, .{ 20.0, 0.0 }).?;
    // Enough HP that the shockwave is visible rather than inferred from a death.
    s.enemies.hp[near] = 1000.0;
    s.enemies.max_hp[near] = 1000.0;
    s.enemies.hp[far] = 1000.0;
    s.enemies.max_hp[far] = 1000.0;

    const hp_before = s.enemies.hp[near];
    s.advance();
    // The player took contact damage, so the shockwave fired: 12 x 0.8 x 3
    // regen is 28.8 damage, and the enemy next to the player took it.
    try std.testing.expect(s.enemies.hp[near] < hp_before);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), s.enemies.hp[far], 1e-6);
    // The 1 s internal cooldown means a second hit inside the same second does
    // not fire it again.
    try std.testing.expect(p.carapace_cd > 0);
}

test "Singularity Field damages enemies a magnetized gem passes through" {
    var s = Simulation.init();
    const p = s.spawnPlayer(0, 0, 0).?;
    disarm(p);
    armItem(p, upgrade.ids.magnet_array, 3);
    armItem(p, upgrade.ids.amplifier_lens, 3);
    p.synergy_mask = upgrade.synergyMask(&p.weapons, &p.passives);
    try std.testing.expect(p.synergy_mask & upgrade.synergy_singularity_field != 0);

    p.pos = .{ 0.0, 0.0 };
    const e = s.enemies.spawn(.circle_t1, .{ 2.0, 0.0 }).?;
    s.enemies.hp[e] = 1000.0;
    s.enemies.max_hp[e] = 1000.0;
    // A gem just outside the pickup radius, so it magnetizes on the first tick
    // and then flies through the enemy on its way in.
    _ = s.gems.spawn(.{ 2.9, 0.0 }, gem.small_xp).?;

    const hp_before = s.enemies.hp[e];
    var i: usize = 0;
    while (i < 5) : (i += 1) s.advance();
    try std.testing.expect(s.enemies.hp[e] < hp_before);
}
