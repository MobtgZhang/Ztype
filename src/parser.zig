//! Ztype 语法解析器
//! 把行法分析器输出的逻辑行解析为 AST。
//!
//! 语法概览：
//!   ---                     元数据块（key: value）
//!   = .. ======             1-6 级标题，可带 [id]
//!   - / + / 1.              无序、有序列表（缩进表示嵌套）
//!   | a | b |               表格行；| < | ^ | > | 为对齐行
//!   :: figure|code|quote|note|...  语义块，属性后用 --- 分隔内容
//!   %% pagebreak|toc|rule|include   页面指令
//!   @{ ... }                脚本块
//!   *粗体* _斜体_ `代码` $公式$ [链接](url) [->引用] [^脚注] @(表达式) ^上标^ ~下标~
//!   ; 行注释   ;{ 块注释 }

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const math = @import("math.zig");
const typography = @import("util/typography.zig");

pub const ParseError = error{
    Parse,
    OutOfMemory,
    InvalidMetadata,
    InvalidBlock,
    MathParse,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer.Lexer,
    base_dir: []const u8 = ".",
    io: std.Io,
    /// 智能排版开关（可用元数据 smart: false 关闭）
    smart: typography.Options = typography.defaults,
    /// 引号方向等跨片段上下文
    state: typography.State = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !Parser {
        return .{
            .allocator = allocator,
            .lexer = try lexer.Lexer.init(allocator, source),
            .io = io,
        };
    }

    pub fn setBaseDir(self: *Parser, dir: []const u8) void {
        self.base_dir = dir;
    }

    pub fn setSmart(self: *Parser, opts: typography.Options) void {
        self.smart = opts;
    }

    pub fn parse(self: *Parser) ParseError!ast.Document {
        var content = std.array_list.Managed(ast.Block).init(self.allocator);
        var metadata = ast.Metadata{ .values = std.StringHashMap([]const u8).init(self.allocator) };

        if (self.lexer.peek()) |first| {
            if (!first.blank and std.mem.eql(u8, first.text, "---")) {
                _ = self.lexer.next();
                while (self.lexer.next()) |line| {
                    if (std.mem.eql(u8, line.text, "---")) break;
                    if (line.blank) continue;
                    const sep = std.mem.indexOfScalar(u8, line.text, ':') orelse return ParseError.InvalidMetadata;
                    const key = std.mem.trim(u8, line.text[0..sep], " \t");
                    const value = std.mem.trim(u8, line.text[sep + 1 ..], " \t");
                    try metadata.values.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
                }
            }
        }

        if (metadata.get("smart")) |v| {
            self.smart.quotes = !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "off"));
            self.smart.dashes = self.smart.quotes;
            self.smart.ellipsis = self.smart.quotes;
            self.smart.symbols = self.smart.quotes;
        }

        while (self.lexer.next()) |line| {
            if (line.blank) continue;
            if (try self.parseBlock(line, &content)) continue;
        }

        return .{ .metadata = metadata, .content = try content.toOwnedSlice() };
    }

    // ---- 块级 ----

    fn parseBlock(self: *Parser, line: lexer.Line, out: *std.array_list.Managed(ast.Block)) !bool {
        const text = line.text;

        if (std.mem.eql(u8, text, "---")) return false;

        // 标题
        if (text[0] == '=') {
            var level: u8 = 0;
            while (level < text.len and text[level] == '=') level += 1;
            if (level == 0 or level > 6) return false;
            const raw = std.mem.trim(u8, text[level..], " \t");
            var id: ?[]const u8 = null;
            var body = raw;
            if (std.mem.endsWith(u8, raw, "]")) {
                if (std.mem.indexOfScalar(u8, raw, '[')) |open| {
                    id = try self.allocator.dupe(u8, raw[open + 1 .. raw.len - 1]);
                    body = std.mem.trim(u8, raw[0..open], " \t");
                }
            }
            try out.append(.{ .heading = .{
                .level = level,
                .text = try self.parseInline(body),
                .id = id,
            } });
            return true;
        }

        // 页面指令
        if (std.mem.startsWith(u8, text, "%%")) {
            const name = std.mem.trim(u8, text[2..], " \t");
            if (std.mem.eql(u8, name, "pagebreak") or std.mem.eql(u8, name, "page-break")) {
                try out.append(.{ .page_break = {} });
            } else if (std.mem.eql(u8, name, "columnbreak") or std.mem.eql(u8, name, "column-break")) {
                try out.append(.{ .column_break = {} });
            } else if (std.mem.eql(u8, name, "toc")) {
                try out.append(.{ .toc = {} });
            } else if (std.mem.eql(u8, name, "rule") or std.mem.eql(u8, name, "hr")) {
                try out.append(.{ .rule = {} });
            } else if (std.mem.startsWith(u8, name, "include ")) {
                try self.parseInclude(std.mem.trim(u8, name[8..], " \t"), out);
            }
            return true;
        }

        // 脚本块
        if (std.mem.startsWith(u8, text, "@{")) {
            var body = std.array_list.Managed(u8).init(self.allocator);
            try body.appendSlice(text[2..]);
            while (self.lexer.next()) |l| {
                if (std.mem.eql(u8, l.text, "}")) break;
                try body.append('\n');
                try body.appendSlice(l.text);
            }
            try out.append(.{ .script = .{ .source = try body.toOwnedSlice() } });
            return true;
        }

        // 语义块
        if (std.mem.startsWith(u8, text, "::")) {
            try self.parseSemanticBlock(std.mem.trim(u8, text[2..], " \t"), out);
            return true;
        }

        // 表格
        if (text[0] == '|') {
            try self.parseTable(text, out);
            return true;
        }

        // 列表
        if (isListMarker(text)) {
            try self.parseList(line, out);
            return true;
        }

        // 段落：收集到下一个空行
        var lines = std.array_list.Managed([]const u8).init(self.allocator);
        try lines.append(text);
        while (self.lexer.peek()) |nxt| {
            if (nxt.blank) break;
            if (isBlockStart(nxt.text)) break;
            _ = self.lexer.next();
            try lines.append(nxt.text);
        }
        var joined = std.array_list.Managed(u8).init(self.allocator);
        for (lines.items, 0..) |l, i| {
            if (i > 0) try joined.append(' ');
            try joined.appendSlice(l);
        }
        try self.appendParagraph(try joined.toOwnedSlice(), out);
        return true;
    }

    fn isBlockStart(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text[0] == '=' or text[0] == '|' or text[0] == ';') return true;
        if (text[0] == '-' and text.len >= 2 and std.ascii.isWhitespace(text[1])) return true;
        if (std.mem.startsWith(u8, text, "::") or std.mem.startsWith(u8, text, "%%")) return true;
        if (std.mem.startsWith(u8, text, "@{")) return true;
        return false;
    }

    fn isListMarker(text: []const u8) bool {
        if (text.len < 2) return false;
        if ((text[0] == '-' or text[0] == '+') and std.ascii.isWhitespace(text[1])) return true;
        var i: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i > 0 and i + 1 <= text.len and text[i] == '.' and std.ascii.isWhitespace(text[i + 1])) return true;
        return false;
    }

    fn parseList(self: *Parser, first: lexer.Line, out: *std.array_list.Managed(ast.Block)) ParseError!void {
        var lines = std.array_list.Managed(lexer.Line).init(self.allocator);
        try lines.append(first);
        while (self.lexer.peek()) |nxt| {
            if (nxt.blank or !isListMarker(nxt.text)) break;
            _ = self.lexer.next();
            try lines.append(nxt);
        }

        const ordered = isOrderedMarker(first.text);
        const items = try self.buildListItems(lines.items, lines.items[0].indent / 2);
        try out.append(.{ .list = .{ .items = items, .ordered = ordered } });
    }

    /// 按缩进深度递归构建列表树：同深度的行属于同一层，更深的行成为上一项的子列表
    fn buildListItems(self: *Parser, lines: []const lexer.Line, depth: usize) ParseError![]ast.ListItem {
        var items = std.array_list.Managed(ast.ListItem).init(self.allocator);
        var i: usize = 0;
        while (i < lines.len) {
            var j = i + 1;
            while (j < lines.len and lines[j].indent / 2 > depth) j += 1;
            var item = try self.parseListItem(lines[i].text);
            if (j > i + 1) item.children = try self.buildListItems(lines[i + 1 .. j], lines[i + 1].indent / 2);
            try items.append(item);
            i = j;
        }
        return try items.toOwnedSlice();
    }

    fn parseListItem(self: *Parser, raw: []const u8) ParseError!ast.ListItem {
        var body = raw;
        if (body[0] == '-' or body[0] == '+') {
            body = std.mem.trim(u8, body[1..], " \t");
        } else {
            if (std.mem.indexOfScalar(u8, body, '.')) |dot| body = std.mem.trim(u8, body[dot + 1 ..], " \t");
        }
        return .{ .content = try self.parseInline(body) };
    }

    fn isOrderedMarker(text: []const u8) bool {
        return std.ascii.isDigit(text[0]);
    }

    fn parseTable(self: *Parser, first: []const u8, out: *std.array_list.Managed(ast.Block)) ParseError!void {
        var rows = std.array_list.Managed(ast.Row).init(self.allocator);
        var alignments = std.array_list.Managed(ast.Alignment).init(self.allocator);
        var widths = std.array_list.Managed(ast.ColumnWidth).init(self.allocator);

        try rows.append(try self.parseTableRow(first));
        while (self.lexer.peek()) |nxt| {
            if (nxt.blank or nxt.text[0] != '|') break;
            _ = self.lexer.next();
            const cells = try self.parseTableRow(nxt.text);
            var is_align = cells.len > 0;
            for (cells) |cell| {
                if (cell.len != 1 or cell[0] != .text or cell[0].text.len == 0) {
                    is_align = false;
                    break;
                }
                const c = cell[0].text[0];
                if (c != '<' and c != '^' and c != '>') {
                    is_align = false;
                    break;
                }
            }
            if (is_align) {
                for (cells) |cell| {
                    const spec = cell[0].text;
                    try alignments.append(switch (spec[0]) {
                        '<' => .left,
                        '^' => .center,
                        else => .right,
                    });
                    try widths.append(try self.parseColumnWidth(spec[1..]));
                }
                continue;
            }
            try rows.append(cells);
        }

        var headers: ast.Row = &.{};
        var body_rows: []ast.Row = &.{};
        if (rows.items.len > 0) {
            headers = try self.allocator.dupe(ast.Cell, rows.items[0]);
            if (rows.items.len > 1) body_rows = try self.allocator.dupe(ast.Row, rows.items[1..]);
        }

        try out.append(.{ .table = .{
            .headers = headers,
            .rows = body_rows,
            .alignments = try alignments.toOwnedSlice(),
            .widths = try widths.toOwnedSlice(),
        } });
    }

    /// 对齐行中的列宽：`<2cm`、`^30%`、`>2fr`，无后缀则按自然宽度分配
    fn parseColumnWidth(_: *Parser, spec: []const u8) ParseError!ast.ColumnWidth {
        const s = std.mem.trim(u8, spec, " \t");
        if (s.len == 0) return .{ .auto = {} };

        if (std.mem.endsWith(u8, s, "%")) {
            const n = std.fmt.parseFloat(f64, s[0 .. s.len - 1]) catch return .{ .auto = {} };
            return .{ .fraction = n / 100.0 };
        }
        if (std.mem.endsWith(u8, s, "fr")) {
            const n = std.fmt.parseFloat(f64, s[0 .. s.len - 2]) catch return .{ .auto = {} };
            return .{ .fr = n };
        }
        // 纯数字按 Typst 的 fr 处理；带单位则是绝对长度
        var i: usize = 0;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
        if (i == s.len) {
            const n = std.fmt.parseFloat(f64, s) catch return .{ .auto = {} };
            return .{ .fr = n };
        }
        const len = unitsLength(s) orelse return .{ .auto = {} };
        return .{ .length = len };
    }

    fn parseTableRow(self: *Parser, raw: []const u8) ParseError!ast.Row {
        var cells = std.array_list.Managed(ast.Cell).init(self.allocator);
        var rest = raw;
        if (rest[0] == '|') rest = rest[1..];
        if (rest.len > 0 and rest[rest.len - 1] == '|') rest = rest[0 .. rest.len - 1];
        var iter = std.mem.splitScalar(u8, rest, '|');
        while (iter.next()) |cell| {
            try cells.append(try self.parseInline(std.mem.trim(u8, cell, " \t")));
        }
        return try cells.toOwnedSlice();
    }

    fn parseSemanticBlock(self: *Parser, header: []const u8, out: *std.array_list.Managed(ast.Block)) !void {
        var name = header;
        var language: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, header, ' ')) |sp| {
            name = std.mem.trim(u8, header[0..sp], " \t");
            language = std.mem.trim(u8, header[sp + 1 ..], " \t");
        }

        // 属性行只在存在 `---` 分隔符时才生效；没有分隔符时整段都是正文
        var attr_lines = std.array_list.Managed(lexer.Line).init(self.allocator);
        while (self.lexer.peek()) |line| {
            if (line.blank or std.mem.eql(u8, line.text, "---")) break;
            try attr_lines.append(line);
            _ = self.lexer.next();
        }

        var attrs = std.StringHashMap([]const u8).init(self.allocator);
        var body: []lexer.Line = &.{};
        if (self.lexer.peek()) |line| {
            if (std.mem.eql(u8, line.text, "---")) {
                _ = self.lexer.next();
                for (attr_lines.items) |attr| {
                    const sep = std.mem.indexOfScalar(u8, attr.text, ':') orelse continue;
                    try attrs.put(attr.text[0..sep], attr.text[sep + 1 ..]);
                }
                body = try self.lexer.collectUntilBlank();
            } else {
                body = attr_lines.items;
            }
        } else {
            body = attr_lines.items;
        }

        const id = attrs.get("id");
        const caption = attrs.get("caption");

        if (std.mem.eql(u8, name, "code")) {
            var source = std.array_list.Managed(u8).init(self.allocator);
            for (body, 0..) |l, i| {
                if (i > 0) try source.append('\n');
                try source.appendSlice(l.text);
            }
            try out.append(.{ .code = .{
                .language = language,
                .caption = caption,
                .id = id,
                .source = try source.toOwnedSlice(),
            } });
            return;
        }

        if (std.mem.eql(u8, name, "math")) {
            var source = std.array_list.Managed(u8).init(self.allocator);
            for (body, 0..) |l, i| {
                if (i > 0) try source.append(' ');
                try source.appendSlice(l.text);
            }
            try self.appendMathBlock(try source.toOwnedSlice(), out, id, caption);
            return;
        }

        if (std.mem.eql(u8, name, "figure")) {
            var width: ?f64 = null;
            if (attrs.get("width")) |w| width = unitsLength(w);
            try out.append(.{ .figure = .{
                .src = attrs.get("src"),
                .alt = attrs.get("alt"),
                .caption = caption,
                .id = id,
                .width = width,
            } });
            return;
        }

        if (std.mem.eql(u8, name, "quote")) {
            try out.append(.{ .quote = .{
                .content = try self.parseBodyBlocks(body),
                .source = attrs.get("source"),
                .caption = caption,
                .id = id,
            } });
            return;
        }

        if (std.mem.eql(u8, name, "definitions") or std.mem.eql(u8, name, "definition")) {
            var entries = std.array_list.Managed(ast.Definition).init(self.allocator);
            for (body) |l| {
                const sep = std.mem.indexOfScalar(u8, l.text, ':') orelse continue;
                try entries.append(.{
                    .term = try self.parseInline(std.mem.trim(u8, l.text[0..sep], " \t")),
                    .definition = try self.parseInline(std.mem.trim(u8, l.text[sep + 1 ..], " \t")),
                });
            }
            try out.append(.{ .definition_list = .{ .entries = try entries.toOwnedSlice() } });
            return;
        }

        if (std.mem.eql(u8, name, "bibliography") or std.mem.eql(u8, name, "bib")) {
            var entries = std.array_list.Managed(ast.BibEntry).init(self.allocator);
            for (body) |l| {
                if (l.text.len == 0) continue;
                if (l.text[0] != '[') continue;
                const close = findClose(l.text, 1, ']') orelse continue;
                const key = std.mem.trim(u8, l.text[1..close], " \t");
                if (key.len == 0) continue;
                try entries.append(.{
                    .key = try self.allocator.dupe(u8, key),
                    .id = id,
                    .text = try self.parseInline(std.mem.trim(u8, l.text[close + 1 ..], " \t")),
                });
            }
            try out.append(.{ .bibliography = .{
                .entries = try entries.toOwnedSlice(),
                .title = attrs.get("title"),
                .id = id,
            } });
            return;
        }

        // 其余名称都是提示框
        const kind = calloutKind(name);
        try out.append(.{ .callout = .{
            .kind = kind,
            .title = attrs.get("title"),
            .content = try self.parseBodyBlocks(body),
            .id = id,
            .caption = caption,
        } });
    }

    /// 语义块内部的内容：已经收集好的行，不再消费词法流
    fn parseBodyBlocks(self: *Parser, body: []lexer.Line) ParseError![]ast.Block {
        var out = std.array_list.Managed(ast.Block).init(self.allocator);
        var i: usize = 0;
        while (i < body.len) {
            const line = body[i];
            if (line.blank) {
                i += 1;
                continue;
            }
            if (isListMarker(line.text)) {
                var items = std.array_list.Managed(ast.ListItem).init(self.allocator);
                const ordered = isOrderedMarker(line.text);
                while (i < body.len and !body[i].blank and isListMarker(body[i].text)) {
                    try items.append(try self.parseListItem(body[i].text));
                    i += 1;
                }
                try out.append(.{ .list = .{ .items = try items.toOwnedSlice(), .ordered = ordered } });
                continue;
            }
            var group = std.array_list.Managed([]const u8).init(self.allocator);
            while (i < body.len and !body[i].blank and !isListMarker(body[i].text)) {
                try group.append(body[i].text);
                i += 1;
            }
            var joined = std.array_list.Managed(u8).init(self.allocator);
            for (group.items, 0..) |l, k| {
                if (k > 0) try joined.append(' ');
                try joined.appendSlice(l);
            }
            try self.appendParagraph(try joined.toOwnedSlice(), &out);
        }
        return out.toOwnedSlice();
    }

    /// 独立公式：Typst 的 $$ ... $$，以及整段只有一个 $...$ 的情况
    fn appendParagraph(self: *Parser, text: []const u8, out: *std.array_list.Managed(ast.Block)) !void {
        const start = std.mem.indexOf(u8, text, "$$");
        if (start == null) {
            if (text.len >= 2 and text[0] == '$' and text[text.len - 1] == '$' and
                std.mem.indexOfScalar(u8, text[1 .. text.len - 1], '$') == null)
            {
                try self.appendMathBlock(std.mem.trim(u8, text[1 .. text.len - 1], " \t"), out, null, null);
                return;
            }
            try out.append(.{ .paragraph = .{ .content = try self.parseInline(text) } });
            return;
        }
        var i: usize = 0;
        while (i < text.len) {
            const at = std.mem.indexOf(u8, text[i..], "$$") orelse {
                const rest = std.mem.trim(u8, text[i..], " \t");
                if (rest.len > 0) try out.append(.{ .paragraph = .{ .content = try self.parseInline(rest) } });
                break;
            };
            const before = std.mem.trim(u8, text[i .. i + at], " \t");
            if (before.len > 0) try out.append(.{ .paragraph = .{ .content = try self.parseInline(before) } });
            const from = i + at + 2;
            const end = std.mem.indexOf(u8, text[from..], "$$") orelse {
                try out.append(.{ .paragraph = .{ .content = try self.parseInline(std.mem.trim(u8, text[i..], " \t")) } });
                break;
            };
            try self.appendMathBlock(std.mem.trim(u8, text[from .. from + end], " \t"), out, null, null);
            i = from + end + 2;
        }
    }

    fn appendMathBlock(self: *Parser, source: []const u8, out: *std.array_list.Managed(ast.Block), id: ?[]const u8, caption: ?[]const u8) !void {
        var math_parser = math.Parser.init(self.allocator, source);
        math_parser.setDisplay(true);
        const nodes = try math_parser.parse();
        try out.append(.{ .math = .{ .source = source, .nodes = nodes, .id = id, .caption = caption } });
    }

    fn parseInclude(self: *Parser, path: []const u8, out: *std.array_list.Managed(ast.Block)) !void {
        const full = try std.fs.path.join(self.allocator, &.{ self.base_dir, path });
        const file = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), self.io, full, self.allocator, .limited(1 << 20)) catch return ParseError.Parse;
        var sub = try Parser.init(self.allocator, self.io, file);
        sub.setBaseDir(std.fs.path.dirname(full) orelse self.base_dir);
        const doc = sub.parse() catch return ParseError.Parse;
        for (doc.content) |block| try out.append(block);
    }

    // ---- 行内 ----

    fn parseInline(self: *Parser, text: []const u8) ParseError![]ast.Inline {
        var out = std.array_list.Managed(ast.Inline).init(self.allocator);
        var i: usize = 0;
        var buf = std.array_list.Managed(u8).init(self.allocator);

        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len) {
                try buf.append(text[i + 1]);
                i += 2;
                continue;
            }

            if (c == '*' or c == '_' or c == '`' or c == '$' or c == '^' or c == '~') {
                const closer = c;
                const end = findClose(text, i + 1, closer);
                if (end != null) {
                    try self.flush(&buf, &out);
                    const inner = text[i + 1 .. end.?];
                    switch (closer) {
                        '*' => try out.append(.{ .strong = try self.parseInline(inner) }),
                        '_' => try out.append(.{ .em = try self.parseInline(inner) }),
                        '`' => try out.append(.{ .code = try self.allocator.dupe(u8, inner) }),
                        '$' => {
                            var math_parser = math.Parser.init(self.allocator, inner);
                            try out.append(.{ .math = try math_parser.parse() });
                        },
                        '^' => try out.append(.{ .sup = try self.parseInline(inner) }),
                        else => try out.append(.{ .sub = try self.parseInline(inner) }),
                    }
                    i = end.? + 1;
                    continue;
                }
            }

            if (c == '[') {
                const close = findClose(text, i + 1, ']');
                if (close != null and i + 1 < close.?) {
                    const label = text[i + 1 .. close.?];
                    const after = close.? + 1;
                    if (after < text.len and text[after] == '(') {
                        const paren = findClose(text, after + 1, ')');
                        if (paren != null) {
                            try self.flush(&buf, &out);
                            try out.append(.{ .link = .{
                                .text = try self.parseInline(label),
                                .url = try self.allocator.dupe(u8, text[after + 1 .. paren.?]),
                            } });
                            i = paren.? + 1;
                            continue;
                        }
                    }
                    if (label[0] == '-' and label.len > 1 and label[1] == '>') {
                        try self.flush(&buf, &out);
                        try out.append(.{ .ref = try self.allocator.dupe(u8, std.mem.trim(u8, label[2..], " \t")) });
                        i = close.? + 1;
                        continue;
                    }
                    if (label[0] == '^') {
                        try self.flush(&buf, &out);
                        try out.append(.{ .footnote = try self.parseInline(label[1..]) });
                        i = close.? + 1;
                        continue;
                    }
                    if (label[0] == '@' and label.len > 1) {
                        try self.flush(&buf, &out);
                        try out.append(.{ .cite = try self.allocator.dupe(u8, std.mem.trim(u8, label[1..], " \t")) });
                        i = close.? + 1;
                        continue;
                    }
                }
            }

            if (c == '@' and i + 1 < text.len and text[i + 1] == '(') {
                const close = findClose(text, i + 2, ')');
                if (close != null) {
                    try self.flush(&buf, &out);
                    try out.append(.{ .expr = try self.allocator.dupe(u8, text[i + 2 .. close.?]) });
                    i = close.? + 1;
                    continue;
                }
            }

            try buf.append(c);
            i += 1;
        }
        try self.flush(&buf, &out);
        return out.toOwnedSlice();
    }

    fn flush(self: *Parser, buf: *std.array_list.Managed(u8), out: *std.array_list.Managed(ast.Inline)) !void {
        if (buf.items.len == 0) return;
        const raw = try buf.toOwnedSlice();
        if (self.smart.quotes or self.smart.dashes or self.smart.ellipsis or self.smart.symbols) {
            var out_buf = std.array_list.Managed(u8).init(self.allocator);
            try typography.append(&out_buf, raw, self.smart, &self.state);
            try out.append(.{ .text = try out_buf.toOwnedSlice() });
        } else {
            try out.append(.{ .text = raw });
        }
    }
};

fn findClose(text: []const u8, from: usize, closer: u8) ?usize {
    var i = from;
    while (i < text.len) {
        if (text[i] == '\\') {
            i += 2;
            continue;
        }
        if (text[i] == closer) return i;
        i += 1;
    }
    return null;
}

fn calloutKind(name: []const u8) ast.CalloutKind {
    if (std.mem.eql(u8, name, "warning")) return .warning;
    if (std.mem.eql(u8, name, "tip")) return .tip;
    if (std.mem.eql(u8, name, "caution")) return .caution;
    if (std.mem.eql(u8, name, "important")) return .important;
    return .note;
}

fn unitsLength(value: []const u8) ?f64 {
    const units = @import("units.zig");
    return units.parseLength(value, units.pt);
}
