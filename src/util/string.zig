const std = @import("std");

/// 去除字符串首尾空白
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

/// 检查字符串是否为空或仅含空白
pub fn isBlank(s: []const u8) bool {
    return trim(s).len == 0;
}

/// 检查行是否为元数据分隔符 ---
pub fn isMetadataDelimiter(line: []const u8) bool {
    const trimmed = trim(line);
    return trimmed.len >= 3 and std.mem.eql(u8, trimmed[0..3], "---");
}
