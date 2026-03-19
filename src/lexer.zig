//! Ztype 词法分析器
//! 将 .zt 源文件解析为 Token 流

const std = @import("std");
const Token = @import("ast.zig").Token;
const TokenType = @import("ast.zig").TokenType;

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,
    in_metadata: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .source = source,
            .allocator = allocator,
        };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekN(self: *Lexer, n: usize) ?u8 {
        if (self.pos + n >= self.source.len) return null;
        return self.source[self.pos + n];
    }

    fn advance(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn isLineStart(self: *Lexer) bool {
        return self.column == 1 or (self.pos > 0 and self.source[self.pos - 1] == '\n');
    }

    pub fn next(self: *Lexer) !?Token {
        const start_pos = self.pos;
        const start_line = self.line;
        const start_col = self.column;

        const c = self.peek() orelse return null;

        // 空白
        if (std.ascii.isWhitespace(c)) {
            var has_newline = false;
            while (self.peek()) |ch| {
                if (!std.ascii.isWhitespace(ch)) break;
                if (ch == '\n') has_newline = true;
                _ = self.advance();
            }
            return Token{
                .type = if (has_newline) .newline else .space,
                .start = start_pos,
                .end = self.pos,
                .line = start_line,
                .column = start_col,
            };
        }

        // 行首检测
        const at_line_start = self.pos == 0 or self.source[self.pos - 1] == '\n';

        if (at_line_start) {
            // 元数据分隔符 --- (根据状态区分 start/end)
            if (c == '-' and self.peekN(1) == '-' and self.peekN(2) == '-') {
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                const tok_type: TokenType = if (self.in_metadata) .meta_end else .meta_start;
                self.in_metadata = !self.in_metadata;
                return Token{ .type = tok_type, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 标题 =
            if (c == '=') {
                var level: u8 = 0;
                while (self.peek() == '=') {
                    _ = self.advance();
                    level += 1;
                }
                return Token{
                    .type = .heading,
                    .start = start_pos,
                    .end = self.pos,
                    .line = start_line,
                    .column = start_col,
                    .extra = .{ .heading_level = @min(level, 4) },
                };
            }

            // 脚本块 @{
            if (c == '@' and self.peekN(1) == '{') {
                _ = self.advance();
                _ = self.advance();
                return Token{ .type = .script_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 语义块 ::
            if (c == ':' and self.peekN(1) == ':') {
                _ = self.advance();
                _ = self.advance();
                return Token{ .type = .block_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 页面指令 %%
            if (c == '%' and self.peekN(1) == '%') {
                _ = self.advance();
                _ = self.advance();
                return Token{ .type = .directive_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 注释 ;
            if (c == ';') {
                _ = self.advance();
                if (self.peek() == '{') {
                    _ = self.advance();
                    return Token{ .type = .comment_block_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
                }
                return Token{ .type = .comment_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 表格行 |
            if (c == '|') {
                _ = self.advance();
                return Token{ .type = .table_pipe, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }

            // 列表项 -
            if (c == '-') {
                _ = self.advance();
                return Token{ .type = .list_dash, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }
        }

        // 脚本块结束 }
        if (c == '}' and self.pos > 0) {
            var i: usize = self.pos;
            while (i > 0 and std.ascii.isWhitespace(self.source[i - 1])) i -= 1;
            if (i > 0 and self.source[i - 1] == '\n') {
                _ = self.advance();
                return Token{ .type = .script_end, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
            }
        }

        // 注释块结束 };
        if (c == ';' and self.peekN(1) == '}') {
            _ = self.advance();
            _ = self.advance();
            return Token{ .type = .comment_block_end, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 行内表达式 @(
        if (c == '@' and self.peekN(1) == '(') {
            _ = self.advance();
            _ = self.advance();
            return Token{ .type = .expr_start, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 表达式结束 )
        if (c == ')') {
            _ = self.advance();
            return Token{ .type = .expr_end, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 字符串 "..."
        if (c == '"') {
            _ = self.advance();
            while (self.peek()) |ch| {
                if (ch == '\\') {
                    _ = self.advance();
                    _ = self.advance();
                    continue;
                }
                if (ch == '"') break;
                _ = self.advance();
            }
            if (self.peek() == '"') _ = self.advance();
            return Token{ .type = .string, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 标识符或关键字
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            while (self.peek()) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') break;
                _ = self.advance();
            }
            return Token{ .type = .identifier, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 冒号 :
        if (c == ':') {
            _ = self.advance();
            return Token{ .type = .colon, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 分隔符 --- (块内容分隔)
        if (c == '-' and self.peekN(1) == '-' and self.peekN(2) == '-') {
            _ = self.advance();
            _ = self.advance();
            _ = self.advance();
            return Token{ .type = .block_separator, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
        }

        // 其他字符作为字面量
        _ = self.advance();
        return Token{ .type = .literal, .start = start_pos, .end = self.pos, .line = start_line, .column = start_col };
    }

    pub fn slice(self: *Lexer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }

    pub fn getAllTokens(self: *Lexer) ![]Token {
        var tokens = std.array_list.Managed(Token).init(self.allocator);
        errdefer tokens.deinit();

        while (try self.next()) |token| {
            try tokens.append(token);
        }
        return tokens.toOwnedSlice();
    }
};
