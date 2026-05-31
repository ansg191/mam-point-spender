//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

// Import config
pub const Config = @import("config.zig");
pub const CookieJar = @import("cookie_jar.zig");
pub const MamClient = @import("mam_client/root.zig");

test {
    _ = Config;
    _ = CookieJar;
    _ = MamClient;
}
