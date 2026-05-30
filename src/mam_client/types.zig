pub const SnatchSummary = struct {
    classname: []const u8,
    seedbonus: u32,
    uid: u64,
    username: []const u8,
    vip_until: ?[]const u8,
    wedges: u64,
};

pub const UserInfo = struct {
    classname: []const u8,
    country_code: []const u8,
    country_name: []const u8,
    downloaded: []const u8,
    downloaded_bytes: u64,
    ratio: f64,
    seedbonus: u32,
    uid: u64,
    uploaded: []const u8,
    uploaded_bytes: u64,
    username: []const u8,
    vip_until: ?[]const u8,
    wedges: u64,
};
