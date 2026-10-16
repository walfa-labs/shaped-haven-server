//! Shaped Haven server — deterministic pseudo-random numbers.
//!
//! The simulation has to be reproducible from its seed: the same seed and the
//! same inputs must produce the same spawns, the same archetypes and the same
//! angles. Nothing here reads the clock or the operating system, and the
//! generator is a plain counter (SplitMix64) so a seed fully determines the
//! sequence — including the sequence a *later* phase's code would see, because
//! each draw advances the same single state.

const std = @import("std");

pub const Rng = struct {
    state: u64 = 0,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    /// SplitMix64. The state *is* the output, mixed: cheap, and with none of
    /// the state-recovery weaknesses of a bare xorshift.
    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform in `[0, 1)`.
    ///
    /// Built from the top 24 bits, which is exactly the mantissa width of an
    /// f32, so every value is representable and no draw is rounded onto a
    /// neighbour (which would make the extremes twice as likely).
    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) * (1.0 / 16777216.0);
    }

    /// Uniform in `[lo, hi)`.
    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.unit();
    }

    /// Uniform in `[0, n)`; 0 when `n` is 0.
    pub fn below(self: *Rng, n: usize) usize {
        if (n == 0) return 0;
        return @intCast(self.next() % n);
    }
};

test "the same seed produces the same sequence" {
    var a = Rng.init(0x5eed);
    var b = Rng.init(0x5eed);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try std.testing.expectEqual(a.next(), b.next());
    }

    var c = Rng.init(0x5eee);
    var d = Rng.init(0x5eed);
    var differs = false;
    i = 0;
    while (i < 8) : (i += 1) {
        if (c.next() != d.next()) differs = true;
    }
    try std.testing.expect(differs);
}

test "unit draws stay inside [0, 1)" {
    var r = Rng.init(1);
    var lo: f32 = 1.0;
    var hi: f32 = 0.0;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const v = r.unit();
        try std.testing.expect(v >= 0.0 and v < 1.0);
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    // A uniform draw over 10k samples should reach both ends of the interval.
    try std.testing.expect(lo < 0.01);
    try std.testing.expect(hi > 0.99);
}

test "range and below stay within their bounds" {
    var r = Rng.init(7);
    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        const v = r.range(-3.0, 4.0);
        try std.testing.expect(v >= -3.0 and v < 4.0);
        try std.testing.expect(r.below(4) < 4);
    }
    try std.testing.expectEqual(@as(usize, 0), r.below(0));
}
