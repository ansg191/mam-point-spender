//! Configuration for the MAM Point Spender
const std = @import("std");

const Config = @This();

// MAM Authentication ID
mam_id: []const u8,

// Stay above 25000
buffer: u32 = 25000,
// Set this to true to enable buying of VIP
vip: bool = true,

// Environment variable names
const MAM_ID_ENV_VAR = "MAMID";
const BUFFER_ENV_VAR = "MAM_BUFFER";
const VIP_ENV_VAR = "MAM_VIP";

// Load configuration from the environment
pub fn init(env: *const std.process.Environ.Map) !Config {
    var cfg: Config = .{
        .mam_id = env.get(MAM_ID_ENV_VAR) orelse return error.MissingEnvVar,
    };
    if (cfg.mam_id.len == 0) {
        return error.MissingEnvVar;
    }

    if (env.get(BUFFER_ENV_VAR)) |s| {
        cfg.buffer = try std.fmt.parseUnsigned(u32, s, 10);
    }
    if (env.get(VIP_ENV_VAR)) |s| {
        cfg.vip = try parseBool(s);
    }

    return cfg;
}

// Parses a boolean value from a string. Accepts "true", "false", "1", "0" (case-insensitive).
fn parseBool(s: []const u8) error{InvalidBoolean}!bool {
    // Trim whitespace
    const trimmed: []const u8 = std.mem.trim(u8, s, " \t\n\r");

    if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "1")) {
        return true;
    } else if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "0")) {
        return false;
    } else {
        return error.InvalidBoolean;
    }
}

test "parseBool correctly parses true values" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(try parseBool("1"));
    try std.testing.expect(try parseBool("TRUE"));
    try std.testing.expect(try parseBool("  true  "));
}

test "parseBool correctly parses false values" {
    try std.testing.expect(!try parseBool("false"));
    try std.testing.expect(!try parseBool("0"));
    try std.testing.expect(!try parseBool("FALSE"));
    try std.testing.expect(!try parseBool("  false  "));
}

test "parseBool returns InvalidBoolean for unrecognized input" {
    try std.testing.expectError(error.InvalidBoolean, parseBool(""));
    try std.testing.expectError(error.InvalidBoolean, parseBool("yes"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("no"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("2"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("truthy"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("   "));
}

test "Config.init reads MAMID and applies defaults" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "abc123");

    const cfg = try Config.init(&env);
    try std.testing.expectEqualStrings("abc123", cfg.mam_id);
    try std.testing.expectEqual(@as(u32, 25000), cfg.buffer);
    try std.testing.expect(cfg.vip);
}

test "Config.init returns MissingEnvVar when MAMID is missing" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(error.MissingEnvVar, Config.init(&env));
}

test "Config.init returns MissingEnvVar when MAMID is empty" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "");

    try std.testing.expectError(error.MissingEnvVar, Config.init(&env));
}

test "Config.init parses buffer override" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "id");
    try env.put(BUFFER_ENV_VAR, "12345");

    const cfg = try Config.init(&env);
    try std.testing.expectEqual(@as(u32, 12345), cfg.buffer);
}

test "Config.init propagates buffer parse errors" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "id");
    try env.put(BUFFER_ENV_VAR, "not-a-number");

    try std.testing.expectError(error.InvalidCharacter, Config.init(&env));
}

test "Config.init parses VIP override" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "id");
    try env.put(VIP_ENV_VAR, "false");

    const cfg = try Config.init(&env);
    try std.testing.expect(!cfg.vip);
}

test "Config.init propagates VIP parse errors" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put(MAM_ID_ENV_VAR, "id");
    try env.put(VIP_ENV_VAR, "maybe");

    try std.testing.expectError(error.InvalidBoolean, Config.init(&env));
}
