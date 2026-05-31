const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zeit = @import("zeit");

const mam_point_spender = @import("mam_point_spender");
const MamClient = mam_point_spender.MamClient;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Load config
    const cfg: mam_point_spender.Config = try .init(init.environ_map);
    std.log.info("Buffer: {d}", .{cfg.buffer});
    std.log.info("VIP: {}", .{cfg.vip});

    // Setup cookie jar
    var cookie_jar = mam_point_spender.CookieJar.init(gpa);
    defer cookie_jar.deinit();
    defer cookie_jar.writeFile(io, Io.Dir.cwd()) catch |e| {
        std.log.err("Failed to write cookie jar: {}", .{e});
    };

    // Setup client
    var client: MamClient = .{ .cookie_jar = &cookie_jar, .client = .{ .allocator = gpa, .io = io } };
    defer client.deinit();

    // Load cookies
    try cookie_jar.readFile(io, Io.Dir.cwd());

    // Get MAM UID
    const user_info = try getUserInfo(gpa, &client, cfg.mam_id);
    defer user_info.deinit();
    std.log.info("UID: {}", .{user_info.value.uid});
    std.log.info("Username: {s}", .{user_info.value.username});

    // Get current points
    std.log.info("Current points: {d}", .{user_info.value.seedbonus});

    // TODO: Wedge buying

    // Maximize VIP
    try maximizeVip(gpa, io, &client, &user_info.value);

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
    // Parse when VIP expires
    const expiry_raw = ui.vip_until orelse "2020-01-01 01:00:00";
    const expiry = (try zeit.instantFromText(.iso8601, expiry_raw, &zeit.utc)).unixTimestamp();

    const now = Io.Clock.real.now(io).toSeconds();

    // VIP has a max duration of 12.8 weeks
    // Calculate how much VIP time we can buy without wasting points
    const SECS_PER_WEEK = 7 * 24 * 3600;
    const max_vip_duration = 128 * SECS_PER_WEEK / 10;
    const min_purchase_duration = SECS_PER_WEEK;
    const remaining = @max(0, expiry - now);
    const available = max_vip_duration - remaining;
    const eligible = if (available >= min_purchase_duration) available else 0;

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

fn purchasePoints(gpa: Allocator, client: *MamClient, points: u32, buffer: u32) !void {
    const POINTS_PER_GB = 500;
    const GB_AMOUNTS = [_]u32{ 100, 50 };
    for (GB_AMOUNTS) |gb| {
        std.log.info("Checking whether to spend {}GB", .{gb});
        const cost = gb * POINTS_PER_GB;
        std.log.info("Cost for {}GB: {d} points (buffer: {d})", .{ gb, cost, buffer });
        if (points >= (cost + buffer)) {
            std.log.info("Purchasing {}GB for {d} points", .{ gb, cost });
            try client.buyGb(gpa, gb, .default);
        }
    }
}
