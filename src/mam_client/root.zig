//! MAM client for the MAM Point Spender
const MamClient = @This();
const std = @import("std");
const http = std.http;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const CookieJar = @import("../cookie_jar.zig");
const types = @import("types.zig");
pub const SnatchSummary = types.SnatchSummary;
pub const UserInfo = types.UserInfo;
const options = @import("build_options");

cookie_jar: *CookieJar,
client: http.Client,
// MAM base URL, e.g. "https://www.myanonamouse.net"
// Should not have a trailing slash, as the client will append paths to it.
base_url: []const u8 = MAM_BASE_URL,

const VERSION = options.version;
const USER_AGENT = "mam-point-spender/" ++ VERSION;
const MAM_BASE_URL = "https://www.myanonamouse.net";
const MAM_SNATCH_SUMMARY_URL = "{s}/jsonLoad.php?snatch_summary";
const MAM_USER_INFO_URL = "{s}/jsonLoad.php?id={d}";
const MAM_POINTS_URL = "{s}/json/bonusBuy.php/?spendtype=upload&amount={d}&_={d}";
const MAM_VIP_URL = "{s}/json/bonusBuy.php/?spendtype=VIP&duration=max&_={d}";

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
    error{ BadResponseStatus, ResponseBodyTooLarge };

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
    const content_length = std.math.cast(usize, response.head.content_length orelse 0) orelse return error.ResponseBodyTooLarge;

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
    const url = try std.fmt.allocPrint(gpa, MAM_SNATCH_SUMMARY_URL, .{self.base_url});
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Fetched snatch summary: {s}", .{body});

    return try std.json.parseFromSlice(types.SnatchSummary, gpa, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn get_user_info(self: *MamClient, gpa: Allocator, uid: u64, cookie_option: CookieOption) !std.json.Parsed(types.UserInfo) {
    const url = try std.fmt.allocPrint(gpa, MAM_USER_INFO_URL, .{ self.base_url, uid });
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Fetched user info for uid {d}: {s}", .{ uid, body });

    return try std.json.parseFromSlice(types.UserInfo, gpa, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn buyVip(self: *MamClient, gpa: Allocator, cookie_option: CookieOption) !void {
    const ts = Io.Clock.real.now(self.client.io).toMilliseconds();
    const url = try std.fmt.allocPrint(gpa, MAM_VIP_URL, .{ self.base_url, ts });
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Buy VIP response: {s}", .{body});
}

pub fn buyGb(self: *MamClient, gpa: Allocator, amount: u64, cookie_option: CookieOption) !void {
    const ts = Io.Clock.real.now(self.client.io).toMilliseconds();
    const url = try std.fmt.allocPrint(gpa, MAM_POINTS_URL, .{ self.base_url, amount, ts });
    defer gpa.free(url);
    const uri = try std.Uri.parse(url);

    const body = try self.get(gpa, uri, cookie_option);
    defer gpa.free(body);

    std.log.debug("Buy points response: {s}", .{body});
}

// =============================================================================
// TESTS
// =============================================================================

const TestServer = struct {
    server: std.Io.net.Server,
    recorder: *RequestRecorder,
    future: std.Io.Future(anyerror!void),
    base_url_buf: [32]u8,
    base_url: []const u8,

    const RequestRecorder = struct {
        gpa: std.mem.Allocator,
        request_line: std.ArrayList(u8) = .empty,
        headers: std.ArrayList(u8) = .empty,
        response_status: std.http.Status = .ok,
        response_extra_headers: []const std.http.Header = &.{},
        response_body: []const u8 = "",

        fn deinit(self: *RequestRecorder) void {
            self.request_line.deinit(self.gpa);
            self.headers.deinit(self.gpa);
        }
    };

    fn start(gpa: std.mem.Allocator, recorder: *RequestRecorder) !*TestServer {
        const ts = try gpa.create(TestServer);
        errdefer gpa.destroy(ts);

        const listen_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        ts.server = try listen_addr.listen(testing.io, .{ .reuse_address = true });
        errdefer ts.server.deinit(testing.io);

        const port = ts.server.socket.address.getPort();
        ts.base_url = try std.fmt.bufPrint(&ts.base_url_buf, "http://127.0.0.1:{d}", .{port});
        ts.recorder = recorder;

        ts.future = try testing.io.concurrent(serve, .{ &ts.server, recorder });
        return ts;
    }

    fn finish(self: *TestServer, gpa: std.mem.Allocator) !void {
        defer gpa.destroy(self);
        defer self.server.deinit(testing.io);
        return self.future.await(testing.io);
    }

    fn serve(server: *std.Io.net.Server, recorder: *RequestRecorder) anyerror!void {
        var stream = try server.accept(testing.io);
        defer stream.close(testing.io);

        var read_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(testing.io, &read_buf);
        const r = &stream_reader.interface;

        const req_line = (try r.takeDelimiter('\n')) orelse return error.UnexpectedEof;
        try recorder.request_line.appendSlice(recorder.gpa, std.mem.trimEnd(u8, req_line, "\r"));

        while (true) {
            const line = (try r.takeDelimiter('\n')) orelse return error.UnexpectedEof;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) break;
            try recorder.headers.appendSlice(recorder.gpa, trimmed);
            try recorder.headers.append(recorder.gpa, '\n');
        }

        var write_buf: [4096]u8 = undefined;
        var stream_writer = stream.writer(testing.io, &write_buf);
        const w = &stream_writer.interface;
        try w.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n",
            .{
                @intFromEnum(recorder.response_status),
                recorder.response_status.phrase().?,
                recorder.response_body.len,
            },
        );
        for (recorder.response_extra_headers) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try w.print("\r\n", .{});
        try w.writeAll(recorder.response_body);
        try w.flush();
    }
};

fn makeTestClient(cookie_jar: *CookieJar, base_url: []const u8) MamClient {
    return .{
        .cookie_jar = cookie_jar,
        .client = .{ .allocator = testing.allocator, .io = testing.io },
        .base_url = base_url,
    };
}

test "get_snatch_summary parses the response into SnatchSummary" {
    const response_body =
        \\{"classname":"VIP","seedbonus":50000,"uid":12345,"username":"tester","vip_until":"2026-12-01 12:00:00","wedges":42}
    ;

    var recorder: TestServer.RequestRecorder = .{ .gpa = testing.allocator, .response_body = response_body };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_snatch_summary(testing.allocator, .none);
    defer parsed.deinit();

    try ts.finish(testing.allocator);

    try testing.expectEqualStrings("VIP", parsed.value.classname);
    try testing.expectEqual(@as(u32, 50000), parsed.value.seedbonus);
    try testing.expectEqual(@as(u64, 12345), parsed.value.uid);
    try testing.expectEqualStrings("tester", parsed.value.username);
    try testing.expect(parsed.value.vip_until != null);
    try testing.expectEqualStrings("2026-12-01 12:00:00", parsed.value.vip_until.?);
    try testing.expectEqual(@as(u64, 42), parsed.value.wedges);

    try testing.expect(std.mem.indexOf(u8, recorder.request_line.items, "GET /jsonLoad.php?snatch_summary") != null);
    try testing.expect(std.mem.indexOf(u8, recorder.headers.items, "user-agent: " ++ USER_AGENT) != null);
}

test "get_snatch_summary ignores unknown JSON fields" {
    const response_body =
        \\{"classname":"User","seedbonus":1,"uid":2,"username":"u","vip_until":null,"wedges":3,"unknown_field":42}
    ;

    var recorder: TestServer.RequestRecorder = .{ .gpa = testing.allocator, .response_body = response_body };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_snatch_summary(testing.allocator, .none);
    defer parsed.deinit();
    try ts.finish(testing.allocator);

    try testing.expect(parsed.value.vip_until == null);
    try testing.expectEqualStrings("u", parsed.value.username);
}

test "get_user_info embeds the uid in the URL and parses UserInfo" {
    const response_body =
        \\{"classname":"User","country_code":"US","country_name":"United States","downloaded":"1.5 GB","downloaded_bytes":1610612736,"ratio":2.5,"seedbonus":12345,"uid":98765,"uploaded":"3.75 GB","uploaded_bytes":4026531840,"username":"someone","vip_until":null,"wedges":7}
    ;

    var recorder: TestServer.RequestRecorder = .{ .gpa = testing.allocator, .response_body = response_body };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_user_info(testing.allocator, 98765, .none);
    defer parsed.deinit();
    try ts.finish(testing.allocator);

    try testing.expectEqual(@as(u64, 98765), parsed.value.uid);
    try testing.expectEqualStrings("someone", parsed.value.username);
    try testing.expectEqualStrings("US", parsed.value.country_code);
    try testing.expectApproxEqAbs(@as(f64, 2.5), parsed.value.ratio, 0.001);

    try testing.expect(std.mem.indexOf(u8, recorder.request_line.items, "GET /jsonLoad.php?id=98765") != null);
}

test "buyVip issues a GET to the VIP endpoint with a timestamp" {
    var recorder: TestServer.RequestRecorder = .{ .gpa = testing.allocator, .response_body = "{}" };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    try client.buyVip(testing.allocator, .none);
    try ts.finish(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, recorder.request_line.items, "GET /json/bonusBuy.php/?spendtype=VIP&duration=max&_=") != null);
}

test "buyGb embeds the amount and a timestamp in the URL" {
    var recorder: TestServer.RequestRecorder = .{ .gpa = testing.allocator, .response_body = "{}" };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    try client.buyGb(testing.allocator, 100, .none);
    try ts.finish(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, recorder.request_line.items, "GET /json/bonusBuy.php/?spendtype=upload&amount=100&_=") != null);
}

test "get sends cookies from the jar when CookieOption is .default" {
    var recorder: TestServer.RequestRecorder = .{
        .gpa = testing.allocator,
        .response_body =
        \\{"classname":"u","seedbonus":0,"uid":0,"username":"u","vip_until":null,"wedges":0}
        ,
    };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    const jar_uri = try std.Uri.parse(ts.base_url);
    try cookie_jar.addCookie(testing.io, jar_uri, "mam_id=secret-token");

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_snatch_summary(testing.allocator, .default);
    defer parsed.deinit();
    try ts.finish(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, recorder.headers.items, "Cookie: mam_id=secret-token") != null);
}

test "get sends the override cookie verbatim" {
    var recorder: TestServer.RequestRecorder = .{
        .gpa = testing.allocator,
        .response_body =
        \\{"classname":"u","seedbonus":0,"uid":0,"username":"u","vip_until":null,"wedges":0}
        ,
    };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_snatch_summary(testing.allocator, .{ .override = "mam_id=override-value" });
    defer parsed.deinit();
    try ts.finish(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, recorder.headers.items, "Cookie: mam_id=override-value") != null);
}

test "get stores Set-Cookie response headers into the jar" {
    var recorder: TestServer.RequestRecorder = .{
        .gpa = testing.allocator,
        .response_extra_headers = &.{
            .{ .name = "Set-Cookie", .value = "sid=abc123; Path=/" },
        },
        .response_body =
        \\{"classname":"u","seedbonus":0,"uid":0,"username":"u","vip_until":null,"wedges":0}
        ,
    };
    defer recorder.deinit();

    var ts = try TestServer.start(testing.allocator, &recorder);

    var cookie_jar = CookieJar.init(testing.allocator);
    defer cookie_jar.deinit();

    var client = makeTestClient(&cookie_jar, ts.base_url);
    defer client.deinit();

    const parsed = try client.get_snatch_summary(testing.allocator, .none);
    defer parsed.deinit();
    try ts.finish(testing.allocator);

    try testing.expectEqual(@as(usize, 1), cookie_jar.cookies.items.len);
    try testing.expectEqualStrings("sid", cookie_jar.cookies.items[0].name);
    try testing.expectEqualStrings("abc123", cookie_jar.cookies.items[0].value);
}
