//! MAM client for the MAM Point Spender
const MamClient = @This();
const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const CookieJar = @import("../cookie_jar.zig");
const types = @import("types.zig");
pub const SnatchSummary = types.SnatchSummary;
pub const UserInfo = types.UserInfo;
const options = @import("build_options");

cookie_jar: *CookieJar,
client: http.Client,

const VERSION = options.version;
const USER_AGENT = "mam-point-spender/" ++ VERSION;
const MAM_BASE_URL = "https://www.myanonamouse.net/";
const MAM_SNATCH_SUMMARY_URL = MAM_BASE_URL ++ "jsonLoad.php?snatch_summary";
const MAM_USER_INFO_URL = MAM_BASE_URL ++ "jsonLoad.php?id={d}";
const MAM_POINTS_URL = MAM_BASE_URL ++ "json/bonusBuy.php/?spendtype=upload&amount={d}&_={d}";
const MAM_VIP_URL = MAM_BASE_URL ++ "json/bonusBuy.php/?spendtype=VIP&duration=max&_={d}";

pub fn deinit(self: *MamClient) void {
    self.client.deinit();
}

pub const CookieOption = union(enum) {
    default,
    override: []const u8,
    none,
};

pub const RequestError = CookieJar.CookieHeaderError ||
    CookieJar.AddCookieError ||
    http.Client.RequestError ||
    http.Client.Request.ReceiveHeadError ||
    Io.Writer.Error ||
    Io.Reader.StreamError ||
    error{BadResponseStatus};

fn get(self: *MamClient, gpa: Allocator, uri: std.Uri, cookie_option: CookieOption) RequestError![]const u8 {
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var transfer_buffer: [8 * 1024]u8 = undefined;

    const cookie = switch (cookie_option) {
        .default => try self.cookie_jar.cookieHeader(gpa, self.client.io, uri),
        .override => |bytes| bytes,
        .none => "",
    };
    defer switch (cookie_option) {
        .default => gpa.free(cookie),
        .override => {},
        .none => {},
    };

    var req = try self.client.request(.GET, uri, .{ .headers = .{ .user_agent = .{ .override = USER_AGENT } }, .extra_headers = &.{
        .{ .name = "Cookie", .value = cookie },
    } });
    defer req.deinit();

    try req.sendBodiless();

    var response = try req.receiveHead(&redirect_buffer);

    // Check status
    if (response.head.status.class() != .success) {
        std.log.err("Failed to fetch snatch summary: HTTP {d}", .{response.head.status});
        return error.BadResponseStatus;
    }

    // Extract useful headers
    const content_length = response.head.content_length orelse 0;

    // Handle set-cookie headers
    var header_it = response.head.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
            try self.cookie_jar.addCookie(self.client.io, uri, header.value);
        }
    }

    // Handle body
    var body: Io.Writer.Allocating = try .initCapacity(gpa, content_length);
    defer body.deinit();

    var reader = response.reader(&transfer_buffer);
    _ = try reader.stream(&body.writer, .unlimited);

    return body.toOwnedSlice();
}

pub fn get_snatch_summary(self: *MamClient, gpa: Allocator, cookie_option: CookieOption) !std.json.Parsed(types.SnatchSummary) {
    const uri = std.Uri.parse(MAM_SNATCH_SUMMARY_URL) catch unreachable;

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Fetched snatch summary: {s}", .{body});

    return try std.json.parseFromSlice(types.SnatchSummary, gpa, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn get_user_info(self: *MamClient, gpa: Allocator, uid: u64, cookie_option: CookieOption) !std.json.Parsed(types.UserInfo) {
    const url = try std.fmt.allocPrint(gpa, MAM_USER_INFO_URL, .{uid});
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Fetched user info for uid {d}: {s}", .{uid, body});

    return try std.json.parseFromSlice(types.UserInfo, gpa, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn buyVip(self: *MamClient, gpa: Allocator, cookie_option: CookieOption) !void {
    const ts = Io.Clock.real.now(self.client.io).toMilliseconds();
    const url = try std.fmt.allocPrint(gpa, MAM_VIP_URL, .{ts});
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Buy VIP response: {s}", .{body});
}

pub fn buyGb(self: *MamClient, gpa: Allocator, amount: u64, cookie_option: CookieOption) !void {
    const ts = Io.Clock.real.now(self.client.io).toMilliseconds();
    const url = try std.fmt.allocPrint(gpa, MAM_POINTS_URL, .{amount, ts});
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Buy points response: {s}", .{body});
}
