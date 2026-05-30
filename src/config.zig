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
