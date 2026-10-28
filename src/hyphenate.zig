//! 断词（hyphenation）
//! Knuth–Liang 模式匹配算法。模式表来自 TeX 的 hyph-en-us.pat（pyphen 发行版），
//! 以数据文件形式嵌入，运行时构建哈希表。
//! 仅在元数据 `hyphen: true` 时启用；CJK 文本不断词。

const std = @import("std");

const raw_patterns = @embedFile("hyph_en_us.pat");

pub const Options = struct {
    /// 词首最少保留的字母数（TeX 英文 hyphenmin）
    min_left: usize = 2,
    /// 词尾最少保留的字母数
    min_right: usize = 3,
    /// 参与断词的最短单词
    min_word: usize = 6,
};

pub const min_word = 6;

/// 模式表：key 为模式（保留前导点表示只在词首匹配），
/// value 为逐位强度串，长度 = key.len + 1，value[k] 表示 key 第 k 个字符之后位置的强度。
pub const Table = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),
    max_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Table {
        var self = Table{ .allocator = allocator, .entries = std.StringHashMap([]const u8).init(allocator) };
        var lines = std.mem.splitScalar(u8, raw_patterns, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '%') continue;
            const key = try allocator.alloc(u8, line.len);
            const value = try allocator.alloc(u8, line.len + 1);
            @memset(value, '0');
            var n: usize = 0;
            for (line) |ch| {
                if (ch >= '0' and ch <= '9') {
                    value[n] = ch;
                    continue;
                }
                key[n] = ch;
                n += 1;
            }
            if (n == 0) continue;
            try self.entries.put(key[0..n], value[0..n + 1]);
            if (n > self.max_len) self.max_len = n;
        }
        return self;
    }

    pub fn lookup(self: *const Table, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
};

/// 计算单词内可断的位置（1..n-1），按 Knuth–Liang 规则取最大强度
pub fn points(self: *const Table, word: []const u8, opts: Options) ![]usize {
    const n = word.len;
    if (n == 0) return &.{};

    var dotted = std.array_list.Managed(u8).init(self.allocator);
    try dotted.append('.');
    try dotted.appendSlice(word);

    const levels = try self.allocator.alloc(u8, n + 1);
    @memset(levels, 0);

    for (0..dotted.items.len) |s| {
        const max_len = @min(self.max_len, dotted.items.len - s);
        for (1..max_len + 1) |L| {
            const key = dotted.items[s .. s + L];
            // 带前导点的模式只在词首匹配
            if (key[0] == '.' and s != 0) continue;
            const hit = self.lookup(key) orelse continue;
            for (0..hit.len) |k| {
                if (s == 0 and k == 0) continue;
                const pos = s + k - 1;
                if (pos > n) continue;
                const v = hit[k] - '0';
                if (v > levels[@intCast(pos)]) levels[@intCast(pos)] = v;
            }
        }
    }

    var out = std.array_list.Managed(usize).init(self.allocator);
    for (1..n) |p| {
        // TeX 规则：奇数强度表示可断点（偶数表示禁止断词）
        if (levels[p] % 2 == 0) continue;
        if (p < opts.min_left) continue;
        if (n - p < opts.min_right) continue;
        try out.append(p);
    }
    return out.toOwnedSlice();
}

/// 按模式强度切分成音节
pub fn syllables(self: *const Table, word: []const u8, opts: Options) ![]const []const u8 {
    const p = try points(self, word, opts);
    if (p.len == 0) return &.{word};
    var out = std.array_list.Managed([]const u8).init(self.allocator);
    var start: usize = 0;
    for (p) |x| {
        try out.append(word[start..x]);
        start = x;
    }
    try out.append(word[start..]);
    return out.toOwnedSlice();
}

test "hyphenation: Knuth-Liang 模式匹配" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try Table.init(a);

    const pts = try points(&t, "hyphenation", .{});
    try std.testing.expectEqualStrings("hy-phen-ation", try join(a, pts, "hyphenation", "-"));
    try std.testing.expectEqualStrings("char-ac-ter-is-tic", try join(a, try points(&t, "characteristic", .{}), "characteristic", "-"));
    try std.testing.expectEqualStrings("ty-pog-ra-phy", try join(a, try points(&t, "typography", .{}), "typography", "-"));

    const pts2 = try points(&t, "typography", .{});
    try std.testing.expect(pts2.len >= 2);

    // 太短的词不断词
    const pts3 = try points(&t, "word", .{});
    try std.testing.expectEqual(@as(usize, 0), pts3.len);
}

fn join(allocator: std.mem.Allocator, pts: []const usize, word: []const u8, sep: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var start: usize = 0;
    for (pts) |p| {
        try out.appendSlice(word[start..p]);
        try out.appendSlice(sep);
        start = p;
    }
    try out.appendSlice(word[start..]);
    return out.toOwnedSlice();
}
