const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const clap = @import("clap");
const zeit = @import("zeit");

const mam_point_spender = @import("mam_point_spender");
const MamClient = mam_point_spender.MamClient;

const MAX_BUFFER = 99_999;
const SECS_PER_WEEK = 7 * 24 * 3600;

// Cap on how much of a rejected server-supplied vip_until value is echoed into the log.
const MAX_LOGGED_VIP_UNTIL = 64;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\-b, --buffer <u32>    Buffer points to preserve (default: $MAM_BUFFER).
        \\--vip                 Maximize VIP before purchasing upload (default: $MAM_VIP).
        \\--no-vip              Do not maximize VIP, only purchase upload (overrides --vip).
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const exec = std.fs.path.basename(res.exe_arg orelse "mam-point-spender");
        std.debug.print("Usage: {s} ", .{exec});
        try clap.usageToFile(io, .stderr(), clap.Help, &params);
        std.debug.print("\n\n", .{});
        try clap.helpToFile(io, .stderr(), clap.Help, &params, .{});
        return;
    }

    // Load config
    var cfg = mam_point_spender.Config.init(init.environ_map) catch |err| switch (err) {
        mam_point_spender.Config.Error.MissingEnvVar => {
            std.log.err("Missing required environment variable: MAMID", .{});
            return err;
        },
        else => {
            std.log.err("Failed to load config: {}", .{err});
            return err;
        },
    };

    // Process command-line overrides
    if (res.args.buffer) |b| {
        cfg.buffer = b;
    }
    if (res.args.vip != 0) {
        cfg.vip = true;
    }
    if (res.args.@"no-vip" != 0) {
        cfg.vip = false;
    }

    std.log.info("Buffer: {d}", .{cfg.buffer});
    std.log.info("VIP: {}", .{cfg.vip});

    if (cfg.buffer > MAX_BUFFER) {
        std.log.err("Buffer cannot exceed {d} points", .{MAX_BUFFER});
        return error.InvalidBuffer;
    }

    // Setup cookie jar
    var cookie_jar = mam_point_spender.CookieJar.init(gpa);
    defer cookie_jar.deinit();

    // Load cookies before arming the write-back defer: if the read fails the jar
    // is empty or only partially filled, and writing it back would destroy the
    // existing cookie file.
    try cookie_jar.readFile(io, Io.Dir.cwd());

    defer cookie_jar.writeFile(io, Io.Dir.cwd()) catch |e| {
        std.log.err("Failed to write cookie jar: {}", .{e});
    };

    // Setup client
    var client: MamClient = .{ .cookie_jar = &cookie_jar, .client = .{ .allocator = gpa, .io = io } };
    defer client.deinit();

    // Get MAM UID
    var user_info = try getUserInfo(gpa, &client, cfg.mam_id);
    defer user_info.deinit();
    std.log.info("UID: {}", .{user_info.value.uid});
    std.log.info("Username: {s}", .{user_info.value.username});

    // Get current points
    std.log.info("Current points: {d}", .{user_info.value.seedbonus});

    // TODO: Wedge buying

    // Maximize VIP
    if (cfg.vip) {
        try maximizeVip(gpa, io, &client, &user_info.value);

        // Refresh user info after VIP purchase
        const refreshed = try getUserInfo(gpa, &client, cfg.mam_id);
        user_info.deinit();
        user_info = refreshed;
    }

    // Purchase points
    try purchasePoints(gpa, &client, user_info.value.seedbonus, cfg.buffer);
}

fn getUserInfo(gpa: Allocator, client: *MamClient, mam_id: []const u8) !std.json.Parsed(MamClient.SnatchSummary) {
    if (client.get_snatch_summary(gpa, .default)) |s| {
        return s;
    } else |e| switch (e) {
        error.BadResponseStatus => {
            // This is likely due to an invalid session cookie.
            // Override the cookie with mam_id and try again.
            std.log.warn("Bad response status, likely due to invalid session cookie. Retrying with mam_id override.", .{});
            const cookie = try std.fmt.allocPrint(gpa, "mam_id={s}", .{mam_id});
            defer gpa.free(cookie);
            const s = try client.get_snatch_summary(gpa, .{ .override = cookie });
            return s;
        },
        else => return e,
    }
}

fn maximizeVip(gpa: Allocator, io: Io, client: *MamClient, ui: *const MamClient.SnatchSummary) !void {
    // Parse when VIP expires. The timestamp comes straight from the server, so
    // a value we cannot parse is treated as an already expired VIP instead of
    // aborting the run.
    var expiry: i64 = 0;
    if (ui.vip_until) |raw| {
        expiry = parseVipExpiry(raw) catch |err| blk: {
            // `raw` is server-supplied: escape it so control characters cannot forge
            // log lines, and bound it so an oversized value cannot flood the log.
            std.log.warn("Failed to parse vip_until \"{f}\" ({d} bytes): {}", .{
                std.zig.fmtString(raw[0..@min(raw.len, MAX_LOGGED_VIP_UNTIL)]),
                raw.len,
                err,
            });
            break :blk 0;
        };
    }

    const now = Io.Clock.real.now(io).toSeconds();

    // Keep this signed: `@max` narrows its result type to the smallest integer
    // type covering the possible range, so `@max(0, expiry -| now)` yields a
    // `u63` and every subtraction derived from it would be unsigned.
    const remaining: i64 = @max(0, expiry -| now);
    const eligible = eligibleVipDuration(remaining);

    const remaining_weeks = @as(f64, @floatFromInt(remaining)) / @as(f64, @floatFromInt(SECS_PER_WEEK));
    const eligible_weeks = @as(f64, @floatFromInt(eligible)) / @as(f64, @floatFromInt(SECS_PER_WEEK));
    std.log.info("VIP expires in {} weeks, we can buy {} weeks of VIP", .{ remaining_weeks, eligible_weeks });

    if (eligible == 0) {
        std.log.info("VIP is already maxed out, no purchase necessary", .{});
        return;
    }

    std.log.info("Attempting to max out VIP", .{});
    try client.buyVip(gpa, .default);
}

/// Calculate how much VIP time we can buy without wasting points, given how
/// many seconds of VIP time are left.
///
/// `remaining` can exceed the cap when MAM reports an expiry far in the future,
/// so the arithmetic has to be signed: an unsigned subtraction would underflow
/// and report a nonsensical amount of eligible time.
fn eligibleVipDuration(remaining: i64) i64 {
    // VIP has a max duration of 12.8 weeks
    const max_vip_duration = 128 * SECS_PER_WEEK / 10;
    const min_purchase_duration = SECS_PER_WEEK;
    const available: i64 = max_vip_duration - remaining;
    return if (available >= min_purchase_duration) available else 0;
}

// Parses a VIP expiry timestamp into a unix timestamp.
//
// MAM reports the expiry as a MySQL DATETIME ("YYYY-MM-DD hh:mm:ss"). The value
// is server-controlled and the ISO8601 parser reads past the end of its input
// on truncated timestamps, so the exact shape is validated here before the
// string is handed over.
fn parseVipExpiry(raw: []const u8) !i64 {
    // "YYYY-MM-DD hh:mm:ss"
    if (raw.len != 19) return error.InvalidTimestamp;
    if (raw[4] != '-' or raw[7] != '-') return error.InvalidTimestamp;
    // MAM uses a space, but ISO8601 uses 'T' as the date/time separator.
    if (raw[10] != ' ' and raw[10] != 'T') return error.InvalidTimestamp;
    if (raw[13] != ':' or raw[16] != ':') return error.InvalidTimestamp;

    for (raw[0..4]) |c| if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    const month = try parseTwoDigits(raw[5..7]);
    const day = try parseTwoDigits(raw[8..10]);
    const hour = try parseTwoDigits(raw[11..13]);
    const minute = try parseTwoDigits(raw[14..16]);
    const second = try parseTwoDigits(raw[17..19]);

    // The month is cast straight into an `enum(u4)`, so anything outside 1-12
    // would produce an invalid enum value.
    if (month < 1 or month > 12) return error.InvalidTimestamp;
    if (day < 1 or day > 31) return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;

    return (try zeit.instantFromText(.iso8601, raw, &zeit.utc)).unixTimestamp();
}

// Parses a zero-padded two digit field, rejecting anything that is not a digit
// (including the signs `std.fmt.parseInt` would otherwise accept).
fn parseTwoDigits(field: *const [2]u8) error{InvalidTimestamp}!u8 {
    for (field) |c| if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    return (field[0] - '0') * 10 + (field[1] - '0');
}

fn purchasePoints(gpa: Allocator, client: *MamClient, points: u32, buffer: u32) !void {
    const POINTS_PER_GB = 500;
    const GB_AMOUNTS = [_]u32{ 100, 50 };
    var pts = points;
    for (GB_AMOUNTS) |gb| {
        std.log.info("Checking whether to spend {}GB", .{gb});
        const cost = gb * POINTS_PER_GB;
        std.log.info("Cost for {}GB: {d} points (buffer: {d})", .{ gb, cost, buffer });
        if (pts >= (cost + buffer)) {
            std.log.info("Purchasing {}GB for {d} points", .{ gb, cost });
            try client.buyGb(gpa, gb, .default);
            pts -= cost;
        }
    }
}

// =============================================================================
// TESTS
// =============================================================================

test "eligibleVipDuration offers the full cap when VIP has lapsed" {
    try std.testing.expectEqual(@as(i64, 128 * SECS_PER_WEEK / 10), eligibleVipDuration(0));
}

test "eligibleVipDuration subtracts the time already banked" {
    try std.testing.expectEqual(
        @as(i64, 128 * SECS_PER_WEEK / 10 - SECS_PER_WEEK),
        eligibleVipDuration(SECS_PER_WEEK),
    );
}

test "eligibleVipDuration returns 0 below the minimum purchase" {
    const remaining = 128 * SECS_PER_WEEK / 10 - SECS_PER_WEEK + 1;
    try std.testing.expectEqual(@as(i64, 0), eligibleVipDuration(remaining));
}

test "eligibleVipDuration returns 0 when VIP outlasts the cap" {
    // An expiry well past the 12.8 week cap used to underflow and report
    // ~2^63 seconds of eligible time, triggering a wasted purchase.
    try std.testing.expectEqual(@as(i64, 0), eligibleVipDuration(52 * SECS_PER_WEEK));
    try std.testing.expectEqual(@as(i64, 0), eligibleVipDuration(std.math.maxInt(i64)));
}

test "parseVipExpiry parses MAM timestamps" {
    try std.testing.expectEqual(@as(i64, 1796126400), try parseVipExpiry("2026-12-01 12:00:00"));
    try std.testing.expectEqual(@as(i64, 1796126400), try parseVipExpiry("2026-12-01T12:00:00"));
    try std.testing.expectEqual(@as(i64, 1577840400), try parseVipExpiry("2020-01-01 01:00:00"));
}

test "parseVipExpiry rejects truncated timestamps" {
    // Each of these makes the ISO8601 parser read past the end of the input.
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-0"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 0"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:00:"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:00:00+"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry(""));
}

test "parseVipExpiry rejects out of range fields" {
    // A zero month is cast into an `enum(u4)` that has no such value.
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("0000-00-00 00:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-13-01 01:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-32 01:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 24:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:60:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:00:60"));
}

test "parseVipExpiry rejects malformed timestamps" {
    // Ten fractional digits underflow the parser's significand arithmetic.
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:00:00.1234567890"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020/01/01 01:00:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("2020-01-01 01:00:+0"));
    try std.testing.expectError(error.InvalidTimestamp, parseVipExpiry("not a timestamp!!!!"));
}
