//! Ztype 语法解析器
//! 将词法 Token 流解析为 AST

const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Token = ast.Token;
const TokenType = ast.TokenType;

pub const ParseError = error{
    UnexpectedToken,
    ExpectedIdentifier,
    InvalidMetadata,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    lexer: Lexer,
    current: ?Token = null,
    peeked: ?Token = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .lexer = Lexer.init(allocator, source),
        };
    }

    fn nextToken(self: *Parser) !?Token {
        if (self.peeked) |t| {
            self.peeked = null;
            self.current = t;
            return t;
        }
        const t = try self.lexer.next();
        self.current = t;
        return t;
    }

    fn peekToken(self: *Parser) !?Token {
        if (self.peeked) |t| return t;
        self.peeked = try self.lexer.next();
        return self.peeked;
    }

    fn slice(self: *Parser, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    fn skipWhitespace(self: *Parser) !void {
        while (try self.peekToken()) |t| {
            switch (t.type) {
                .space, .newline => _ = try self.nextToken(),
                else => break,
            }
        }
    }

    pub fn parse(self: *Parser) !ast.Document {
        var doc = ast.Document.init(self.allocator);
        errdefer doc.deinit();

        const first = try self.nextToken();

        // 可选的元数据块
        if (first) |t| {
            if (t.type == .meta_start) {
                doc.metadata = try self.parseMetadata();
            } else {
                self.peeked = t;
            }
        } else if (first) |t| {
            // 非元数据时，将第一个 token 放回供主循环处理
            self.peeked = t;
        }

        try self.skipWhitespace();

        // 解析主体内容
        while (true) {
            try self.skipWhitespace();
            const next = try self.peekToken();
            if (next == null) break;

            const tok = next.?;
            switch (tok.type) {
                .meta_start, .meta_end => {
                    _ = try self.nextToken();
                },
                .heading => {
                    try doc.content.append(try self.parseHeading());
                },
                .script_start => {
                    try doc.content.append(.{ .script_block = try self.parseScriptBlock() });
                },
                .block_start => {
                    try doc.content.append(.{ .semantic_block = try self.parseSemanticBlock() });
                },
                .directive_start => {
                    try doc.content.append(.{ .page_directive = try self.parsePageDirective() });
                },
                .comment_start => {
                    _ = try self.parseComment();
                },
                .comment_block_start => {
                    _ = try self.parseCommentBlock();
                },
                .list_dash => {
                    try doc.content.append(.{ .list = try self.parseList() });
                },
                .table_pipe => {
                    try doc.content.append(.{ .table = try self.parseTable() });
                },
                .newline, .space => {
                    _ = try self.nextToken();
                },
                else => {
                    // 段落或正文
                    if (self.hasParagraphContent(tok)) {
                        try doc.content.append(.{ .paragraph = try self.parseParagraph() });
                    } else {
                        _ = try self.nextToken();
                    }
                },
            }
        }

        return doc;
    }

    fn hasParagraphContent(self: *Parser, t: Token) bool {
        _ = self;
        return switch (t.type) {
            .identifier, .string, .literal, .expr_start => true,
            else => false,
        };
    }

    fn parseMetadata(self: *Parser) !ast.Metadata {
        var meta = ast.Metadata.init(self.allocator);
        errdefer meta.deinit(self.allocator);

        _ = try self.nextToken(); // consume meta_start
        try self.skipWhitespace();

        while (try self.nextToken()) |t| {
            if (t.type == .meta_end) break;
            try self.skipWhitespace();

            if (t.type == .identifier) {
                const key = try self.allocator.dupe(u8, self.slice(t));
                try self.skipWhitespace();

                const colon_t = try self.nextToken();
                if (colon_t == null or colon_t.?.type != .colon) continue;
                try self.skipWhitespace();

                const value_t = try self.nextToken();
                if (value_t) |vt| {
                    var value_str = std.array_list.Managed(u8).init(self.allocator);
                    if (vt.type == .string) {
                        const raw = self.slice(vt);
                        if (raw.len >= 2) {
                            try value_str.appendSlice(raw[1 .. raw.len - 1]);
                        }
                    } else if (vt.type == .identifier or vt.type == .literal) {
                        try value_str.appendSlice(self.slice(vt));
                    }
                    // 同行内可能有更多 literal/identifier（不消耗换行，以免吃掉下一行 key）
                    while (try self.peekToken()) |pt| {
                        if (pt.type == .newline or pt.type == .meta_end) break;
                        _ = try self.nextToken();
                        if (pt.type == .space) {
                            try value_str.append(' ');
                        } else if (pt.type == .literal or pt.type == .identifier) {
                            if (value_str.items.len > 0 and value_str.items[value_str.items.len - 1] != ' ')
                                try value_str.append(' ');
                            try value_str.appendSlice(self.slice(pt));
                        }
                    }
                    const value = try value_str.toOwnedSlice();
                    try meta.pairs.put(key, value);
                }
            }
        }

        return meta;
    }

    fn parseHeading(self: *Parser) !ast.Node {
        const t = (try self.nextToken()).?;
        const level: u8 = switch (t.extra) {
            .heading_level => |l| l,
            .none => 1,
        };
        try self.skipWhitespace();

        var text_buf = std.array_list.Managed(u8).init(self.allocator);
        var has_id = false;
        var id_buf = std.array_list.Managed(u8).init(self.allocator);

        while (try self.nextToken()) |nt| {
            if (nt.type == .newline) break;
            if (nt.type == .identifier and std.mem.eql(u8, self.slice(nt), "#")) {
                has_id = true;
                try self.skipWhitespace();
                const id_t = try self.nextToken();
                if (id_t) |it| {
                    if (it.type == .identifier) {
                        try id_buf.appendSlice(self.slice(it));
                    }
                }
                break;
            }
            if (nt.type != .space) {
                if (text_buf.items.len > 0) try text_buf.append(' ');
                try text_buf.appendSlice(self.slice(nt));
            }
        }

        const text = try text_buf.toOwnedSlice();
        const id = if (has_id and id_buf.items.len > 0) try id_buf.toOwnedSlice() else null;

        return .{
            .heading = .{
                .level = level,
                .text = text,
                .id = id,
            },
        };
    }

    fn parseScriptBlock(self: *Parser) !ast.ScriptBlock {
        _ = try self.nextToken(); // script_start
        const start_pos = self.lexer.pos;
        var depth: u32 = 1;

        while (try self.nextToken()) |t| {
            if (t.type == .script_start) depth += 1
            else if (t.type == .script_end) {
                depth -= 1;
                if (depth == 0) {
                    const end_pos = t.start;
                    const source = try self.allocator.dupe(u8, self.source[start_pos..end_pos]);
                    return .{ .source = source, .allocator = self.allocator };
                }
            }
        }

        return error.UnexpectedToken;
    }

    fn parseSemanticBlock(self: *Parser) !ast.SemanticBlock {
        var block = ast.SemanticBlock.init(self.allocator);
        errdefer block.deinit(self.allocator);

        _ = try self.nextToken(); // block_start
        try self.skipWhitespace();

        // 块类型和修饰符 (e.g. :: code zig)
        const type_t = try self.nextToken();
        if (type_t) |tt| {
            if (tt.type == .identifier) {
                block.block_type = try self.allocator.dupe(u8, self.slice(tt));
            }
        }
        try self.skipWhitespace();

        const modifier_t = try self.peekToken();
        if (modifier_t) |mt| {
            if (mt.type == .identifier and !std.mem.eql(u8, self.slice(mt), "if") and
                !std.mem.eql(u8, self.slice(mt), "for") and !std.mem.eql(u8, self.slice(mt), "else")) {
                _ = try self.nextToken();
                block.modifier = try self.allocator.dupe(u8, self.slice(mt));
            }
        }
        try self.skipWhitespace();

        const next = try self.peekToken();
        if (if (next) |n| n.type == .newline else false) {
            _ = try self.nextToken();
            try self.skipWhitespace();

            // 解析缩进属性 key: value
            while (try self.nextToken()) |t| {
                if (t.type == .block_separator) break;
                if (t.type == .newline) {
                    try self.skipWhitespace();
                    const pt = try self.peekToken();
                    if (pt == null) break;
                    if (pt.?.type != .identifier) break;
                    continue;
                }
                if (t.type == .identifier) {
                    const key = try self.allocator.dupe(u8, self.slice(t));
                    try self.skipWhitespace();
                    const ct = try self.nextToken();
                    if (ct != null and ct.?.type == .colon) {
                        try self.skipWhitespace();
                        const vt = try self.nextToken();
                        if (vt) |v| {
                            var val = std.array_list.Managed(u8).init(self.allocator);
                            if (v.type == .string) {
                                const raw = self.slice(v);
                                if (raw.len >= 2) try val.appendSlice(raw[1 .. raw.len - 1]);
                            } else {
                                try val.appendSlice(self.slice(v));
                            }
                            const value = try val.toOwnedSlice();
                            try block.attrs.put(key, value);
                        }
                    }
                }
            }

            if (self.current != null and self.current.?.type == .block_separator) {
                _ = try self.nextToken();
                try self.skipWhitespace();
                var content_buf = std.array_list.Managed(u8).init(self.allocator);
                while (try self.nextToken()) |t| {
                    if (t.type == .block_start) {
                        // 嵌套块，暂时作为内容
                        const tok_slice = self.slice(t);
                        try content_buf.appendSlice(tok_slice);
                        continue;
                    }
                    if (t.type == .newline) {
                        try self.skipWhitespace();
                        const pt = try self.peekToken();
                        if (pt) |p| {
                            if (p.type == .block_start or p.type == .heading or p.type == .script_start) break;
                            if (p.type == .identifier and std.mem.startsWith(u8, self.slice(p), "::")) break;
                        }
                        try content_buf.append('\n');
                        continue;
                    }
                    try content_buf.appendSlice(self.slice(t));
                }
                block.content = try content_buf.toOwnedSlice();
            }
        }

        return block;
    }

    fn parsePageDirective(self: *Parser) !ast.PageDirective {
        _ = try self.nextToken(); // directive_start
        try self.skipWhitespace();

        var args_buf = std.array_list.Managed(u8).init(self.allocator);
        while (try self.nextToken()) |t| {
            if (t.type == .newline) break;
            if (t.type != .space or args_buf.items.len > 0) {
                try args_buf.appendSlice(self.slice(t));
            }
        }

        const kind_end = std.mem.indexOfScalar(u8, args_buf.items, ' ') orelse args_buf.items.len;
        const kind = try self.allocator.dupe(u8, args_buf.items[0..kind_end]);
        const args = if (kind_end < args_buf.items.len)
            try self.allocator.dupe(u8, std.mem.trim(u8, args_buf.items[kind_end..], " "))
        else
            try self.allocator.dupe(u8, "");

        args_buf.deinit();
        return .{ .kind = kind, .args = args };
    }

    fn parseComment(self: *Parser) !void {
        _ = try self.nextToken();
        while (try self.nextToken()) |t| {
            if (t.type == .newline) break;
        }
    }

    fn parseCommentBlock(self: *Parser) !void {
        _ = try self.nextToken();
        while (try self.nextToken()) |t| {
            if (t.type == .comment_block_end) break;
        }
    }

    fn parseParagraph(self: *Parser) !ast.Paragraph {
        var para = ast.Paragraph.init(self.allocator);
        errdefer para.deinit(self.allocator);

        var text_buf = std.array_list.Managed(u8).init(self.allocator);
        while (try self.nextToken()) |t| {
            if (t.type == .newline) {
                try self.skipWhitespace();
                const pt = try self.peekToken();
                if (pt == null) break;
                if (pt.?.type == .heading or pt.?.type == .block_start or pt.?.type == .script_start or
                    pt.?.type == .directive_start or pt.?.type == .list_dash or pt.?.type == .table_pipe) break;
                try text_buf.append(' ');
                continue;
            }
            if (t.type == .expr_start) {
                if (text_buf.items.len > 0) {
                    try para.spans.append(.{ .text = try text_buf.toOwnedSlice() });
                    text_buf = std.array_list.Managed(u8).init(self.allocator);
                }
                var expr_buf = std.array_list.Managed(u8).init(self.allocator);
                while (try self.nextToken()) |et| {
                    if (et.type == .expr_end) break;
                    try expr_buf.appendSlice(self.slice(et));
                }
                try para.spans.append(.{ .expr = try expr_buf.toOwnedSlice() });
                continue;
            }
            if (t.type == .literal or t.type == .identifier or t.type == .string or t.type == .space) {
                try text_buf.appendSlice(self.slice(t));
            }
        }

        if (text_buf.items.len > 0) {
            try para.spans.append(.{ .text = try text_buf.toOwnedSlice() });
        }

        return para;
    }

    fn parseList(self: *Parser) !ast.List {
        var list = ast.List.init(self.allocator);
        errdefer list.deinit(self.allocator);

        while (try self.peekToken()) |t| {
            if (t.type != .list_dash) break;
            _ = try self.nextToken();
            try self.skipWhitespace();

            var item = ast.Paragraph.init(self.allocator);
            while (try self.nextToken()) |it| {
                if (it.type == .newline) {
                    try self.skipWhitespace();
                    const pt = try self.peekToken();
                    if (pt == null or pt.?.type != .list_dash and pt.?.type != .table_pipe) {}
                    if (pt != null and pt.?.type == .list_dash) break;
                    if (pt != null and (pt.?.type == .heading or pt.?.type == .block_start)) break;
                    try item.spans.append(.{ .text = try self.allocator.dupe(u8, " ") });
                    continue;
                }
                try item.spans.append(.{ .text = try self.allocator.dupe(u8, self.slice(it)) });
            }
            try list.items.append(item);
        }

        return list;
    }

    fn parseTable(self: *Parser) !ast.Table {
        var table = ast.Table.init(self.allocator);
        errdefer table.deinit(self.allocator);

        // 解析表头行
        _ = try self.nextToken(); // 第一个 |
        try self.skipWhitespace();
        while (try self.nextToken()) |t| {
            if (t.type == .newline) break;
            if (t.type == .identifier or t.type == .literal) {
                try table.headers.append(try self.allocator.dupe(u8, self.slice(t)));
            }
            if (t.type == .table_pipe) {}
        }

        // 分隔行 | < | ^ | > |
        try self.skipWhitespace();
        while (try self.nextToken()) |t| {
            if (t.type == .newline) break;
            if (t.type == .literal) {
                const s = self.slice(t);
                if (std.mem.eql(u8, s, "<")) try table.alignments.append(.left)
                else if (std.mem.eql(u8, s, "^")) try table.alignments.append(.center)
                else if (std.mem.eql(u8, s, ">")) try table.alignments.append(.right);
            }
        }

        // 数据行
        try self.skipWhitespace();
        while (try self.peekToken()) |t| {
            if (t.type != .table_pipe) break;
            _ = try self.nextToken();
            var row = std.array_list.Managed([]const u8).init(self.allocator);
            while (try self.nextToken()) |rt| {
                if (rt.type == .newline) break;
                if (rt.type == .identifier or rt.type == .literal) {
                    try row.append(try self.allocator.dupe(u8, self.slice(rt)));
                }
            }
            if (row.items.len > 0) try table.rows.append(row);
        }

        return table;
    }
};
