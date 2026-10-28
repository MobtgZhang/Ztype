//! Ztype 数学公式引擎
//! 语法以 Typst 为主要参考：`$ x = y + 1 $`、`$ sum_(i=1)^n i $`、`$ mat(a, b; c, d) $`
//! 同时兼容常见的 LaTeX 命令别名（`\frac`、`\int`、`\alpha` 等）

const std = @import("std");
const fonts = @import("fonts.zig");

/// 显式错误集：避免解析函数之间的推断错误集互相递归
pub const ParseError = error{ MathParse, OutOfMemory };

/// TeX 的 mu 间距（以 em 为单位）
pub const thin_space = 3.0 / 18.0;
pub const medium_space = 5.0 / 18.0;
pub const thick_space = 6.0 / 18.0;

pub const Class = enum { letter, number, operator, punctuation, delimiter, function, symbol };

pub const FontStyle = enum { normal, italic, upright, script, fraktur, double_struck, monospace, bold };

pub const Glyph = struct {
    cp: u21,
    class: Class,
    style: FontStyle = .normal,
};

pub const Node = union(enum) {
    glyph: Glyph,
    text: []const u8,
    row: []Node,
    frac: Frac,
    sqrt: Sqrt,
    script: Script,
    accent: Accent,
    delim: Delim,
    matrix: Matrix,
    cases: Cases,
    stack: Stack,
    binom: Binom,
    over_under: OverUnder,
    /// Typst 的 tag(...)：display 模式下把标签放到行末；notag() 关闭公式编号
    tag: Tag,
    space: f64,
    rule: Rule,
    op: Op,
    style: Style,
};

pub const Frac = struct { num: *Node, denom: *Node, display: bool = true };
pub const Sqrt = struct { body: *Node, index: ?*Node = null };
pub const Script = struct {
    base: *Node,
    sub: ?*Node = null,
    sup: ?*Node = null,
    /// limits：上下限居中放置（display 模式的大运算符）
    limits: bool = false,
};
pub const Accent = struct { base: *Node, cp: u21 };
pub const Delim = struct { left: u21, right: u21, body: *Node, stretchy: bool = true };
pub const Matrix = struct { rows: [][]Node, left: u21, right: u21, alignment: Alignment = .center };
pub const Cases = struct { rows: [][]Node, left: u21, alignment: Alignment = .left };
pub const Stack = struct { items: []*Node, alignment: Alignment = .center };
/// 网格对齐方式；`.align` 表示 TeX align 环境的交替对齐（& 前右对齐、& 后左对齐）
pub const Alignment = enum { left, center, right, alternate };
pub const Binom = struct { top: *Node, bottom: *Node };
/// overset / underset / overbrace / underbrace：把标记放在基座上或下
pub const OverUnder = struct {
    base: *Node,
    mark: *Node,
    /// true 表示标记在基座上方（overset / overbrace）
    above: bool,
    /// 标记是否横向拉伸以覆盖基座（花括号类）
    stretchy: bool = false,
    /// display 模式下把上下标改为上下限（stackrel）
    limits: bool = false,
};
pub const Tag = struct { body: *Node, suppress: bool = false };
pub const Rule = struct { thickness: f64, length: f64 };
pub const Op = struct { name: []const u8, body: ?*Node = null, limits: bool = false };
pub const Style = struct { font: FontStyle, size: f64, body: *Node };

/// 符号名 -> Unicode 码点
pub const symbols = std.StaticStringMap(u21).initComptime(.{
    .{ "alpha", 0x3B1 },           .{ "beta", 0x3B2 },        .{ "gamma", 0x3B3 },      .{ "delta", 0x3B4 },
    .{ "epsilon", 0x3B5 },         .{ "varepsilon", 0x3F5 },  .{ "zeta", 0x3B6 },       .{ "eta", 0x3B7 },
    .{ "theta", 0x3B8 },           .{ "vartheta", 0x3D1 },    .{ "iota", 0x3B9 },       .{ "kappa", 0x3BA },
    .{ "lambda", 0x3BB },          .{ "mu", 0x3BC },          .{ "nu", 0x3BD },         .{ "xi", 0x3BE },
    .{ "omicron", 0x3BF },         .{ "pi", 0x3C0 },          .{ "rho", 0x3C1 },        .{ "sigma", 0x3C3 },
    .{ "varsigma", 0x3C2 },        .{ "tau", 0x3C4 },         .{ "upsilon", 0x3C5 },    .{ "phi", 0x3C6 },
    .{ "varphi", 0x3D5 },          .{ "chi", 0x3C7 },         .{ "psi", 0x3C8 },        .{ "omega", 0x3C9 },
    .{ "Alpha", 0x391 },           .{ "Beta", 0x392 },        .{ "Gamma", 0x393 },      .{ "Delta", 0x394 },
    .{ "Epsilon", 0x395 },         .{ "Zeta", 0x396 },        .{ "Eta", 0x397 },        .{ "Theta", 0x398 },
    .{ "Iota", 0x399 },            .{ "Kappa", 0x39A },       .{ "Lambda", 0x39B },     .{ "Mu", 0x39C },
    .{ "Nu", 0x39D },              .{ "Xi", 0x39E },          .{ "Omicron", 0x39F },    .{ "Pi", 0x3A0 },
    .{ "Rho", 0x3A1 },             .{ "Sigma", 0x3A3 },       .{ "Tau", 0x3A4 },        .{ "Upsilon", 0x3A5 },
    .{ "Phi", 0x3A6 },             .{ "Chi", 0x3A7 },         .{ "Psi", 0x3A8 },        .{ "Omega", 0x3A9 },

    .{ "pm", 0x00B1 },             .{ "mp", 0x2213 },         .{ "times", 0x00D7 },     .{ "div", 0x00F7 },
    .{ "cdot", 0x22C5 },           .{ "ast", 0x2217 },        .{ "star", 0x2217 },      .{ "bullet", 0x2022 },
    .{ "circ", 0x2218 },           .{ "bigcirc", 0x25EF },    .{ "setminus", 0x2216 },  .{ "plus", 0x002B },
    .{ "minus", 0x2212 },          .{ "eq", 0x003D },         .{ "neq", 0x2260 },       .{ "approx", 0x2248 },
    .{ "equiv", 0x2261 },          .{ "cong", 0x2245 },       .{ "sim", 0x223C },       .{ "simeq", 0x2243 },
    .{ "leq", 0x2264 },            .{ "geq", 0x2265 },        .{ "ll", 0x226A },        .{ "gg", 0x226B },
    .{ "prec", 0x227A },           .{ "succ", 0x227B },       .{ "propto", 0x221D },    .{ "subset", 0x2282 },
    .{ "subseteq", 0x2286 },       .{ "supset", 0x2283 },     .{ "supseteq", 0x2287 },  .{ "nsubset", 0x2288 },
    .{ "in", 0x2208 },             .{ "notin", 0x2209 },      .{ "ni", 0x220B },        .{ "cup", 0x222A },
    .{ "cap", 0x2229 },            .{ "uplus", 0x228E },      .{ "emptyset", 0x2205 },  .{ "varnothing", 0x2205 },
    .{ "land", 0x2227 },           .{ "lor", 0x2228 },        .{ "not", 0x00AC },       .{ "oplus", 0x2295 },
    .{ "otimes", 0x2297 },         .{ "perp", 0x22A5 },       .{ "to", 0x2192 },        .{ "arrow", 0x2192 },
    .{ "rightarrow", 0x2192 },     .{ "leftarrow", 0x2190 },  .{ "uparrow", 0x2191 },   .{ "downarrow", 0x2193 },
    .{ "leftrightarrow", 0x2194 }, .{ "Rightarrow", 0x21D2 }, .{ "implies", 0x21D2 },   .{ "Leftarrow", 0x21D0 },
    .{ "Leftrightarrow", 0x21D4 }, .{ "iff", 0x21D4 },        .{ "mapsto", 0x21A6 },    .{ "hookrightarrow", 0x21AA },
    .{ "nearrow", 0x2197 },        .{ "searrow", 0x2198 },    .{ "sum", 0x2211 },       .{ "prod", 0x220F },
    .{ "int", 0x222B },            .{ "integral", 0x222B },   .{ "iint", 0x222C },      .{ "iiint", 0x222D },
    .{ "oint", 0x222C },           .{ "coprod", 0x2210 },     .{ "bigcup", 0x22C3 },    .{ "bigcap", 0x22C2 },
    .{ "bigoplus", 0x2295 },       .{ "bigotimes", 0x2297 },  .{ "sqrt", 0x221A },      .{ "root", 0x221A },
    .{ "sqrtsign", 0x221A },       .{ "infty", 0x221E },      .{ "partial", 0x2202 },   .{ "nabla", 0x2207 },
    .{ "aleph", 0x2135 },          .{ "angle", 0x2220 },      .{ "therefore", 0x2234 }, .{ "because", 0x2235 },
    .{ "forall", 0x2200 },         .{ "exists", 0x2203 },     .{ "prime", 0x2032 },     .{ "degree", 0x00B0 },
    .{ "percent", 0x0025 },        .{ "dagger", 0x2020 },     .{ "lozenge", 0x25CA },   .{ "hbar", 0x210F },
    .{ "ell", 0x2113 },            .{ "Re", 0x211C },         .{ "Im", 0x2111 },        .{ "wp", 0x2118 },
    .{ "ldots", 0x2026 },          .{ "cdots", 0x22EF },      .{ "vdots", 0x22EE },     .{ "ddots", 0x2261 },
    .{ "colon", 0x003A },          .{ "mid", 0x2223 },        .{ "parallel", 0x2225 },  .{ "hat", 0x0302 },
    .{ "widehat", 0x0302 },        .{ "bar", 0x0305 },        .{ "overline", 0x0305 },  .{ "tilde", 0x0303 },
    .{ "widetilde", 0x0303 },      .{ "dot", 0x0307 },        .{ "ddot", 0x0308 },      .{ "acute", 0x0301 },
    .{ "grave", 0x0300 },          .{ "check", 0x030C },      .{ "breve", 0x0306 },     .{ "vec", 0x20D7 },
    .{ "cancel", 0x0338 },         .{ "underline", 0x0332 },
});

/// 重音符号：无括号时作用于紧随其后的原子（Typst 行为）
pub const accents = std.StaticStringMap(u21).initComptime(.{
    .{ "hat", 0x0302 },   .{ "widehat", 0x0302 },   .{ "bar", 0x0305 },       .{ "overline", 0x0305 },
    .{ "tilde", 0x0303 }, .{ "widetilde", 0x0303 }, .{ "dot", 0x0307 },       .{ "ddot", 0x0308 },
    .{ "acute", 0x0301 }, .{ "grave", 0x0300 },     .{ "check", 0x030C },     .{ "breve", 0x0306 },
    .{ "vec", 0x20D7 },   .{ "cancel", 0x0338 },    .{ "underline", 0x0332 },
});

/// 单字母以外的“函数名”（正体显示）
pub const functions = std.StaticStringMap([]const u8).initComptime(.{
    .{ "sin", "sin" },       .{ "cos", "cos" },       .{ "tan", "tan" },       .{ "cot", "cot" },
    .{ "sec", "sec" },       .{ "csc", "csc" },       .{ "arcsin", "arcsin" }, .{ "arccos", "arccos" },
    .{ "arctan", "arctan" }, .{ "sinh", "sinh" },     .{ "cosh", "cosh" },     .{ "tanh", "tanh" },
    .{ "log", "log" },       .{ "ln", "ln" },         .{ "exp", "exp" },       .{ "lim", "lim" },
    .{ "liminf", "liminf" }, .{ "limsup", "limsup" }, .{ "max", "max" },       .{ "min", "min" },
    .{ "sup", "sup" },       .{ "inf", "inf" },       .{ "gcd", "gcd" },       .{ "lcm", "lcm" },
    .{ "deg", "deg" },       .{ "mod", "mod" },       .{ "arg", "arg" },       .{ "dim", "dim" },
});

/// 字体样式命令：Typst 的 bb/cal/fr/... 与 LaTeX 的 mathbb/mathcal/... 别名
pub const styles = std.StaticStringMap(FontStyle).initComptime(.{
    .{ "cal", .script },           .{ "fr", .fraktur },      .{ "bb", .double_struck },
    .{ "mono", .monospace },       .{ "serif", .normal },    .{ "sans", .normal },
    .{ "italic", .italic },        .{ "upright", .upright }, .{ "bold", .bold },
    .{ "mathbb", .double_struck }, .{ "mathcal", .script },  .{ "mathfrak", .fraktur },
    .{ "mathbf", .bold },          .{ "boldsymbol", .bold }, .{ "mathsf", .normal },
    .{ "mathtt", .monospace },     .{ "mathrm", .upright },  .{ "textbf", .bold },
    .{ "textit", .italic },        .{ "emph", .italic },
});

pub const delimiter_names = std.StaticStringMap([2]u21).initComptime(.{
    .{ "none", .{ 0, 0 } },
    .{ "p", .{ '(', ')' } },
    .{ "b", .{ '[', ']' } },
    .{ "bra", .{ '{', '}' } },
    .{ "v", .{ '|', '|' } },
    .{ "c", .{ 0x2308, 0x2309 } }, // ceil
    .{ "f", .{ 0x230A, 0x230B } }, // floor
    .{ "m", .{ 0, 0 } },
    .{ "d", .{ 0x7C, 0x7C } },
    .{ "angle", .{ 0x2329, 0x232A } },
});

/// TeX / Typst 的数学元素分类：间距由相邻两个元素的类别决定
pub const TexClass = enum { ord, op, bin, rel, punct, open, close };

/// 运算符码点 -> 具体类别（二元运算符 / 关系符 / 标点）
pub fn operatorClass(cp: u21) TexClass {
    // 二元运算符：两侧均为 thick（6mu）
    switch (cp) {
        0x002B, 0x002D, 0x2212, 0x00D7, 0x00F7, 0x2213, 0x2216, 0x2217, 0x2218, 0x2219, 0x221F, 0x22C4, 0x22C5, 0x22C6, 0x22C7, 0x22C8, 0x22C9, 0x22CA, 0x22CB, 0x22CC, 0x22CD, 0x22CE, 0x22CF, 0x2295, 0x2297, 0x2299, 0x229A, 0x229B, 0x229C, 0x229D, 0x229E, 0x229F, 0x22A0, 0x22A1, 0x22A2, 0x22A3, 0x22A4, 0x22BB, 0x22BC, 0x22BD => return .bin,
        // 标点：TeX 中 , ; : ! 均为 punctuation
        0x0021, 0x002C, 0x003A, 0x003B => return .punct,
        // 关系符与箭头：medium（5mu）
        0x003C, 0x003D, 0x003E => return .rel,
        0x2208...0x220D, 0x221D, 0x2223, 0x2225 => return .rel,
        0x2242...0x226F, 0x227A...0x228F, 0x2291, 0x2292, 0x22A5...0x22B1, 0x22B4...0x22B9, 0x22FB...0x22FF, 0x2190...0x21FF => return .rel,
        else => return .ord,
    }
}

/// 大运算符：display 模式下上下限居中放置
pub fn isBigOperator(cp: u21) bool {
    switch (cp) {
        0x220F, 0x2210, 0x2211, 0x222B...0x2233, 0x22C0...0x22C3, 0x22A2...0x22A5, 0x22A6...0x22B9, 0x22C4, 0x22C6...0x22CF, 0x2295, 0x2297 => return true,
        else => return false,
    }
}

/// 数学元素的 TeX 分类
pub fn texClass(node: Node) TexClass {
    switch (node) {
        .glyph => |g| switch (g.class) {
            .letter, .number => return .ord,
            .punctuation => return .punct,
            .delimiter => return .open,
            .function => return .op,
            .operator => return operatorClass(g.cp),
            .symbol => {
                if (isBigOperator(g.cp)) return .op;
                return switch (g.cp) {
                    0x2026, 0x22EE, 0x2261 => .punct,
                    0x22EF => .ord,
                    else => .ord,
                };
            },
        },
        .text => return .ord,
        .row => |r| {
            if (r.len > 0) return texClass(r[0]);
            return .ord;
        },
        .op => return .op,
        .delim => return .ord,
        .script => return .ord,
        else => return .ord,
    }
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    /// display 模式：大运算符的上下限居中放置
    display: bool = false,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{ .allocator = allocator, .src = source, .pos = 0 };
    }

    pub fn setDisplay(self: *Parser, value: bool) void {
        self.display = value;
    }

    /// 在 display 模式下默认带上下限的运算符
    const limits_default = std.StaticStringMap(void).initComptime(.{
        .{ "lim", {} },    .{ "limsup", {} },   .{ "liminf", {} },    .{ "max", {} },
        .{ "min", {} },    .{ "sup", {} },      .{ "inf", {} },       .{ "gcd", {} },
        .{ "lcm", {} },    .{ "deg", {} },      .{ "arg", {} },       .{ "dim", {} },
        .{ "sum", {} },    .{ "prod", {} },     .{ "coprod", {} },    .{ "bigcup", {} },
        .{ "bigcap", {} }, .{ "bigoplus", {} }, .{ "bigotimes", {} },
    });

    fn delimiterSpec(node: Node) ?[2]u21 {
        if (node == .glyph and node.glyph.class == .letter) {
            const name = switch (node.glyph.cp) {
                'd' => "d",
                'p' => "p",
                'b' => "b",
                'v' => "v",
                'c' => "c",
                'f' => "f",
                'm' => "m",
                'a' => "angle",
                'n' => "none",
                else => return null,
            };
            return delimiter_names.get(name);
        }
        if (node == .text) return delimiter_names.get(node.text);
        return null;
    }

    /// 尝试读取 mat 的定界符规格，例如 mat(d)(...)；不匹配时不消耗输入
    fn peekDelimiterSpec(self: *Parser) ?[2]u21 {
        const save = self.pos;
        if (self.peek() != '(') return null;
        self.pos += 1;
        self.skipSpace();
        const c = self.peek() orelse 0;
        const d = switch (c) {
            'd' => delimiter_names.get("d"),
            'p' => delimiter_names.get("p"),
            'b' => delimiter_names.get("b"),
            'v' => delimiter_names.get("v"),
            'c' => delimiter_names.get("c"),
            'f' => delimiter_names.get("f"),
            'm' => delimiter_names.get("m"),
            'a' => delimiter_names.get("angle"),
            'n' => delimiter_names.get("none"),
            else => null,
        };
        if (d == null) {
            self.pos = save;
            return null;
        }
        self.pos += 1;
        self.skipSpace();
        if (self.peek() != ')') {
            self.pos = save;
            return null;
        }
        self.pos += 1;
        self.skipSpace();
        const nx = self.peek() orelse 0;
        if (nx != '(' and nx != '{') {
            self.pos = save;
            return null;
        }
        return d;
    }

    /// 读取原始文本（用于 text() / "..."）
    fn parseRawText(self: *Parser) ParseError![]const u8 {
        const c = self.peek() orelse return "";
        var close: u8 = 0;
        if (c == '(') {
            close = ')';
            self.pos += 1;
        } else if (c == '{') {
            close = '}';
            self.pos += 1;
        } else return "";
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == close) break;
            if (ch == '\\') {
                self.pos += 1;
                if (self.peek()) |_| self.pos += 1;
                continue;
            }
            self.pos += 1;
        }
        const text = self.src[start..self.pos];
        if (self.peek() == close) self.pos += 1;
        return text;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn skipSpace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.pos += 1;
        }
    }

    fn readName(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isAlphabetic(c)) break;
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }

    /// 解析整个公式（一个水平序列）
    pub fn parse(self: *Parser) ParseError![]Node {
        return self.parseRow(null);
    }

    fn parseRow(self: *Parser, stop: ?u8) ParseError![]Node {
        var items = std.array_list.Managed(Node).init(self.allocator);
        while (true) {
            self.skipSpace();
            const c = self.peek() orelse break;
            if (stop) |s| {
                if (c == s) break;
            }
            if (c == '}' or c == ')') break;

            // \limits / \nolimits：修饰前一个运算符
            if (c == '\\') {
                const save = self.pos;
                self.pos += 1;
                const name = self.readName();
                if (std.mem.eql(u8, name, "limits") or std.mem.eql(u8, name, "nolimits")) {
                    if (items.items.len > 0) {
                        const want = std.mem.eql(u8, name, "limits");
                        const last = &items.items[items.items.len - 1];
                        if (last.* == .script) {
                            last.script.limits = want;
                        } else if (last.* == .op) {
                            last.op.limits = want and self.display;
                        }
                    }
                    continue;
                }
                self.pos = save;
            }

            // 撇号：上标素数，附着到前一个元素
            if (c == '\'' or c == 0x2032) {
                const primes = try self.parsePrimes();
                if (items.items.len > 0) {
                    const last = &items.items[items.items.len - 1];
                    if (last.* == .script) {
                        if (last.script.sup == null) {
                            last.script.sup = try self.allocNode(.{ .row = primes });
                        } else {
                            const existing = last.script.sup.?;
                            if (existing.* == .row) {
                                const merged = try self.allocator.alloc(Node, existing.row.len + primes.len);
                                @memcpy(merged[0..existing.row.len], existing.row);
                                @memcpy(merged[existing.row.len..], primes);
                                existing.row = merged;
                            } else {
                                var merged = std.array_list.Managed(Node).init(self.allocator);
                                try merged.append(existing.*);
                                try merged.appendSlice(primes);
                                last.script.sup = try self.allocNode(.{ .row = try merged.toOwnedSlice() });
                            }
                        }
                    } else {
                        const base_copy = last.*;
                        last.* = .{ .script = .{
                            .base = try self.allocNode(base_copy),
                            .sup = try self.allocNode(.{ .row = primes }),
                            .limits = false,
                        } };
                    }
                    continue;
                }
                try items.append(.{ .script = .{
                    .base = try self.allocNode(.{ .text = "" }),
                    .sup = try self.allocNode(.{ .row = primes }),
                } });
                continue;
            }

            const item = try self.parseAtom();
            try items.append(item);
        }
        return items.toOwnedSlice();
    }

    fn parsePrimes(self: *Parser) ParseError![]Node {
        var primes = std.array_list.Managed(Node).init(self.allocator);
        while (true) {
            const c = self.peek() orelse break;
            if (c != '\'' and c != 0x2032) break;
            self.pos += 1;
            try primes.append(.{ .glyph = .{ .cp = 0x2032, .class = .symbol } });
        }
        return primes.toOwnedSlice();
    }

    fn parseCell(self: *Parser, stops: []const u8) ParseError![]Node {
        var items = std.array_list.Managed(Node).init(self.allocator);
        while (true) {
            self.skipSpace();
            const c = self.peek() orelse break;
            var is_stop = false;
            for (stops) |s| {
                if (c == s) {
                    is_stop = true;
                    break;
                }
            }
            if (is_stop) break;
            try items.append(try self.parseAtom());
        }
        return items.toOwnedSlice();
    }

    fn allocNode(self: *Parser, n: Node) ParseError!*Node {
        const p = try self.allocator.create(Node);
        p.* = n;
        return p;
    }

    fn parseEnvironment(self: *Parser) ParseError!Node {
        const env = try self.parseRawText();
        if (env.len == 0) return .{ .text = "begin" };

        var rows = std.array_list.Managed([]Node).init(self.allocator);
        while (true) {
            self.skipSpace();
            const ch = self.peek() orelse break;
            if (ch == '\\') {
                const save = self.pos;
                self.pos += 1;
                const n = self.readName();
                if (std.mem.eql(u8, n, "end")) {
                    _ = try self.parseRawText();
                    break;
                }
                self.pos = save;
            }
            var row = std.array_list.Managed(Node).init(self.allocator);
            while (true) {
                const cell = try self.parseCell(&.{ '&', ',', ';', '\\', '}', ')' });
                if (cell.len > 0) try row.append(.{ .row = cell });
                const sep = self.peek();
                if (sep == '&' or sep == ',') {
                    self.pos += 1;
                    continue;
                }
                break;
            }
            if (row.items.len > 0) try rows.append(try row.toOwnedSlice());
            const sep = self.peek();
            if (sep == '\\') {
                const save2 = self.pos;
                self.pos += 1;
                if (std.mem.eql(u8, self.readName(), "end")) {
                    _ = try self.parseRawText();
                    break;
                }
                self.pos = save2;
                self.pos += 2;
                continue;
            }
            if (sep == ';' or sep == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }

        var left: u21 = 0;
        var right: u21 = 0;
        if (std.mem.eql(u8, env, "cases")) {
            return .{ .cases = .{
                .rows = try rows.toOwnedSlice(),
                .left = '{',
                .alignment = .left,
            } };
        }
        if (std.mem.eql(u8, env, "pmatrix")) {
            left = '(';
            right = ')';
        }
        if (std.mem.eql(u8, env, "bmatrix")) {
            left = '[';
            right = ']';
        }
        if (std.mem.eql(u8, env, "Bmatrix")) {
            left = '{';
            right = '}';
        }
        if (std.mem.eql(u8, env, "vmatrix")) {
            left = '|';
            right = '|';
        }
        if (std.mem.eql(u8, env, "Vmatrix")) {
            left = 0x2016;
            right = 0x2016;
        }
        if (std.mem.eql(u8, env, "matrix")) {
            left = 0;
            right = 0;
        }
        return .{ .matrix = .{
            .rows = try rows.toOwnedSlice(),
            .left = left,
            .right = right,
            .alignment = if (std.mem.eql(u8, env, "cases")) .left else if (std.mem.eql(u8, env, "align")) .alternate else .center,
        } };
    }

    fn parseAtom(self: *Parser) ParseError!Node {
        self.skipSpace();
        const c = self.peek() orelse return .{ .glyph = .{ .cp = 0, .class = .punctuation } };

        // 分组
        if (c == '(' or c == '[' or c == '{') {
            const open = c;
            const close: u8 = switch (open) {
                '(' => ')',
                '[' => ']',
                else => '}',
            };
            self.pos += 1;
            const body = try self.parseRow(close);
            if (self.peek() == close) self.pos += 1;
            if (body.len == 1 and body[0] == .row and body[0].row.len == 0) {
                return .{ .glyph = .{ .cp = open, .class = .delimiter } };
            }
            return .{ .delim = .{ .left = open, .right = close, .body = try self.allocNode(.{ .row = body }), .stretchy = true } };
        }

        // 字符串文本
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.peek()) |ch| {
                if (ch == '"') break;
                if (ch == '\\') {
                    self.pos += 1;
                    if (self.peek()) |_| self.pos += 1;
                    continue;
                }
                self.pos += 1;
            }
            const text = self.src[start..self.pos];
            if (self.peek() == '"') self.pos += 1;
            return .{ .text = text };
        }

        // 表达式插值
        if (c == '#') {
            self.pos += 1;
            const start = self.pos;
            while (self.peek()) |ch| {
                if (ch == ')' or ch == ',' or ch == ';' or ch == '_' or ch == '^' or ch == ' ') break;
                self.pos += 1;
            }
            return .{ .text = self.src[start..self.pos] };
        }

        // LaTeX 风格命令
        if (c == '\\') {
            self.pos += 1;
            const name = self.readName();
            if (name.len == 0) {
                const ch = self.peek() orelse return .{ .glyph = .{ .cp = 0, .class = .punctuation } };
                self.pos += 1;
                // TeX 的细/中/粗间距
                if (ch == ',') return .{ .space = thin_space };
                if (ch == ':') return .{ .space = medium_space };
                if (ch == ';') return .{ .space = thick_space };
                if (ch == ' ' or ch == '\\') return .{ .space = 0.25 };
                return try self.applyScript(.{ .glyph = .{ .cp = ch, .class = .symbol } }, false);
            }
            if (std.mem.eql(u8, name, "begin")) return try self.parseEnvironment();
            if (std.mem.eql(u8, name, "text")) {
                const raw = try self.parseRawText();
                if (raw.len > 0) return .{ .text = raw };
                return .{ .text = name };
            }
            return try self.applyScript(try self.callFunction(name), self.display and limits_default.has(name));
        }

        // 标识符 / 函数调用
        if (std.ascii.isAlphabetic(c)) {
            const name = self.readName();
            const next = self.peek();
            // Typst 用 (a, b)，LaTeX 用 {a}{b}：两种参数形式都接受
            if (next == '(' or next == '{') {
                if (std.mem.eql(u8, name, "begin")) return try self.parseEnvironment();
                if (functions.has(name) or builtin_functions.has(name)) {
                    return try self.callFunction(name);
                }
            }
            if (name.len == 1) {
                const cp = symbols.get(name) orelse name[0];
                return try self.applyScript(.{ .glyph = .{ .cp = cp, .class = .letter, .style = .italic } }, false);
            }
            if (accents.get(name)) |cp| {
                if (self.peek() == null) return .{ .glyph = .{ .cp = cp, .class = .symbol } };
                const base = try self.parseAtom();
                return .{ .accent = .{ .base = try self.allocNode(base), .cp = cp } };
            }
            // 无括号的样式命令：作用于紧随其后的原子（Typst 行为）
            if (styles.get(name)) |st| {
                self.skipSpace();
                if (self.peek() == null) return .{ .style = .{ .font = st, .size = 1.0, .body = try self.allocNode(.{ .text = name }) } };
                const base = try self.parseAtom();
                return try self.applyScript(.{ .style = .{ .font = st, .size = 1.0, .body = try self.allocNode(base) } }, false);
            }
            if (symbols.get(name)) |cp| {
                return try self.applyScript(.{ .glyph = .{ .cp = cp, .class = .symbol, .style = .italic } }, false);
            }
            return try self.applyScript(.{ .text = name }, false);
        }

        // 数字
        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch) and ch != '.') break;
                self.pos += 1;
            }
            return .{ .text = self.src[start..self.pos] };
        }

        // 上下标
        if (c == '_' or c == '^') {
            return try self.parseScript(.{ .text = "" });
        }

        // 箭头：-> 与 <-
        if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
            self.pos += 2;
            return try self.applyScript(.{ .glyph = .{ .cp = 0x2192, .class = .operator } }, false);
        }
        if (c == '<' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
            self.pos += 2;
            return try self.applyScript(.{ .glyph = .{ .cp = 0x2190, .class = .operator } }, false);
        }

        // 运算符与标点
        self.pos += 1;
        const class: Class = switch (c) {
            '(', ')', '[', ']', '{', '}' => .delimiter,
            ',', ';', ':' => .punctuation,
            '+', '=', '<', '>', '-', '*', '/', '!' => .operator,
            else => .symbol,
        };
        return try self.applyScript(.{ .glyph = .{ .cp = c, .class = class } }, false);
    }

    const builtin_functions = std.StaticStringMap(void).initComptime(.{
        .{ "frac", {} },       .{ "dfrac", {} },     .{ "tfrac", {} },      .{ "ratio", {} },
        .{ "sqrt", {} },       .{ "root", {} },      .{ "mat", {} },        .{ "pmatrix", {} },
        .{ "bmatrix", {} },    .{ "Bmatrix", {} },   .{ "vmatrix", {} },    .{ "Vmatrix", {} },
        .{ "cases", {} },      .{ "vec", {} },       .{ "stack", {} },      .{ "binom", {} },
        .{ "text", {} },       .{ "math", {} },      .{ "cal", {} },        .{ "fr", {} },
        .{ "bb", {} },         .{ "mono", {} },      .{ "serif", {} },      .{ "sans", {} },
        .{ "italic", {} },     .{ "upright", {} },   .{ "bold", {} },       .{ "script", {} },
        .{ "op", {} },         .{ "limits", {} },    .{ "scripts", {} },    .{ "space", {} },
        .{ "quad", {} },       .{ "thin", {} },      .{ "medium", {} },     .{ "widehat", {} },
        .{ "widetilde", {} },  .{ "hat", {} },       .{ "bar", {} },        .{ "tilde", {} },
        .{ "dot", {} },        .{ "ddot", {} },      .{ "vec", {} },        .{ "cancel", {} },
        .{ "overline", {} },   .{ "underline", {} }, .{ "stretch", {} },    .{ "delim", {} },
        .{ "tag", {} },        .{ "align", {} },     .{ "begin", {} },      .{ "end", {} },
        .{ "notag", {} },
        .{ "overset", {} },    .{ "underset", {} },  .{ "stackrel", {} },   .{ "overbrace", {} },
        .{ "underbrace", {} }, .{ "mathbb", {} },    .{ "mathcal", {} },    .{ "mathfrak", {} },
        .{ "mathbf", {} },     .{ "mathsf", {} },    .{ "mathtt", {} },     .{ "mathrm", {} },
        .{ "textbf", {} },     .{ "textit", {} },    .{ "boldsymbol", {} }, .{ "emph", {} },
        .{ "space", {} },      .{ "limits", {} },
    });

    /// 参数模式：普通参数（逗号分隔）或矩阵行（分号分行、逗号/and 分列）
    pub const ArgMode = enum { args, rows };

    /// 参数列表：Typst 用 (a, b)，同时兼容 LaTeX 的 {a}{b}
    fn parseArgs(self: *Parser, mode: ArgMode) ParseError![]Node {
        const c = self.peek();
        if (c == null) return &.{};

        if (c == '{') {
            var items = std.array_list.Managed(Node).init(self.allocator);
            while (self.peek() == '{') {
                self.pos += 1;
                const body = try self.parseRow('}');
                if (self.peek() == '}') self.pos += 1;
                try items.append(.{ .row = body });
            }
            return items.toOwnedSlice();
        }

        if (c != '(') return &.{};
        self.pos += 1;
        var items = std.array_list.Managed(Node).init(self.allocator);
        while (true) {
            self.skipSpace();
            const ch = self.peek() orelse break;
            if (ch == ')') break;
            const stops: []const u8 = if (mode == .rows) &.{ '&', ';', ')', '}' } else &.{ ',', '&', ';', ')', '}' };
            const cell = try self.parseCell(stops);
            if (cell.len > 0) try items.append(.{ .row = cell });
            const sep = self.peek();
            if (sep == null) break;
            if (sep == '\\') {
                self.pos += 2;
                continue;
            }
            if (sep == ',' or sep == ';' or sep == '&') self.pos += 1;
        }
        if (self.peek() == ')') self.pos += 1;
        return items.toOwnedSlice();
    }

    /// 网格参数：`;` 或 `\\` 分行，`,` 或 `&` 分列
    fn parseGrid(self: *Parser) ParseError![][]Node {
        const c = self.peek();
        if (c == null) return &.{};

        if (c == '{') {
            var rows = std.array_list.Managed([]Node).init(self.allocator);
            while (self.peek() == '{') {
                self.pos += 1;
                const body = try self.parseCell(&.{ '}', '\\', ')' });
                if (self.peek() == '}') self.pos += 1;
                try rows.append(body);
                const sep = self.peek();
                if (sep == '\\') {
                    self.pos += 2;
                    continue;
                }
                if (sep == ';' or sep == ',') {
                    self.pos += 1;
                    continue;
                }
                break;
            }
            return rows.toOwnedSlice();
        }

        if (c != '(') return &.{};
        self.pos += 1;
        var rows = std.array_list.Managed([]Node).init(self.allocator);
        while (true) {
            self.skipSpace();
            const ch = self.peek() orelse break;
            if (ch == ')') break;
            var row = std.array_list.Managed(Node).init(self.allocator);
            while (true) {
                const cell = try self.parseCell(&.{ '&', ',', ';', '\\', ')', '}' });
                if (cell.len > 0) try row.append(.{ .row = cell });
                const sep = self.peek();
                if (sep == '&' or sep == ',') {
                    self.pos += 1;
                    continue;
                }
                break;
            }
            if (row.items.len > 0) try rows.append(try row.toOwnedSlice());
            const sep = self.peek();
            if (sep == '\\') {
                self.pos += 2;
                continue;
            }
            if (sep == ';' or sep == ',') {
                self.pos += 1;
                continue;
            }
            break;
        }
        if (self.peek() == ')') self.pos += 1;
        return rows.toOwnedSlice();
    }

    fn callFunction(self: *Parser, name: []const u8) ParseError!Node {
        const row_mode = std.mem.eql(u8, name, "mat") or std.mem.eql(u8, name, "cases") or
            std.mem.eql(u8, name, "align") or std.mem.eql(u8, name, "vec") or
            std.mem.eql(u8, name, "stack") or std.mem.eql(u8, name, "pmatrix") or
            std.mem.eql(u8, name, "bmatrix") or std.mem.eql(u8, name, "Bmatrix") or
            std.mem.eql(u8, name, "vmatrix") or std.mem.eql(u8, name, "Vmatrix");

        if (row_mode) {
            var left: u21 = 0;
            var right: u21 = 0;
            if (std.mem.eql(u8, name, "mat")) {
                // Typst: mat(d)(a, b; c, d) —— 第一个参数是定界符规格
                if (self.peekDelimiterSpec()) |d| {
                    left = d[0];
                    right = d[1];
                }
            } else if (std.mem.eql(u8, name, "pmatrix")) {
                left = '(';
                right = ')';
            } else if (std.mem.eql(u8, name, "bmatrix")) {
                left = '[';
                right = ']';
            } else if (std.mem.eql(u8, name, "Bmatrix")) {
                left = '{';
                right = '}';
            } else if (std.mem.eql(u8, name, "vmatrix")) {
                left = '|';
                right = '|';
            } else if (std.mem.eql(u8, name, "Vmatrix")) {
                left = 0x2016;
                right = 0x2016;
            }

            const grid = try self.parseGrid();
            if (grid.len == 0) return .{ .text = name };

            // Typst 的 vec(x) 单个参数是向量重音，多参数才是列向量
            if (std.mem.eql(u8, name, "vec") and grid.len == 1 and grid[0].len == 1) {
                return .{ .accent = .{ .base = try self.allocNode(grid[0][0]), .cp = 0x20D7 } };
            }

            if (std.mem.eql(u8, name, "cases")) {
                return .{ .cases = .{ .rows = grid, .left = '{', .alignment = .left } };
            }
            if (std.mem.eql(u8, name, "stack")) {
                var items = std.array_list.Managed(*Node).init(self.allocator);
                for (grid) |row| {
                    if (row.len == 1) {
                        try items.append(try self.allocNode(row[0]));
                    } else {
                        try items.append(try self.allocNode(.{ .row = row }));
                    }
                }
                return .{ .stack = .{ .items = try items.toOwnedSlice(), .alignment = .center } };
            }
            const alignment: Alignment = if (std.mem.eql(u8, name, "align")) .alternate else .center;
            return .{ .matrix = .{ .rows = grid, .left = left, .right = right, .alignment = alignment } };
        }

        // sqrt 的根指数 [n] 必须先于参数解析：\sqrt[3]{x}
        if (std.mem.eql(u8, name, "sqrt")) {
            var index: ?*Node = null;
            if (self.peek() == '[') {
                self.pos += 1;
                const idx = try self.parseRow(']');
                if (self.peek() == ']') self.pos += 1;
                if (idx.len > 0) index = try self.allocNode(.{ .row = idx });
            }
            const a = try self.parseArgs(ArgMode.args);
            if (a.len >= 1) return .{ .sqrt = .{ .body = try self.allocNode(a[0]), .index = index } };
            return .{ .glyph = .{ .cp = 0x221A, .class = .symbol } };
        }

        // Typst: root(n)(x) —— 第一个参数是根指数
        if (std.mem.eql(u8, name, "root")) {
            const a = try self.parseArgs(ArgMode.args);
            if (a.len >= 2) {
                return .{ .sqrt = .{ .body = try self.allocNode(a[1]), .index = try self.allocNode(a[0]) } };
            }
            if (a.len == 1) {
                const index = try self.allocNode(a[0]);
                const second = try self.parseArgs(ArgMode.args);
                if (second.len >= 1) return .{ .sqrt = .{ .body = try self.allocNode(second[0]), .index = index } };
                return .{ .sqrt = .{ .body = index, .index = null } };
            }
            return .{ .glyph = .{ .cp = 0x221A, .class = .symbol } };
        }

        const a = try self.parseArgs(ArgMode.args);

        if (std.mem.eql(u8, name, "overset") or std.mem.eql(u8, name, "underset") or std.mem.eql(u8, name, "stackrel")) {
            if (a.len >= 2) {
                const mark = try self.allocNode(a[0]);
                const base = try self.allocNode(a[1]);
                return .{ .over_under = .{
                    .base = base,
                    .mark = mark,
                    .above = !std.mem.eql(u8, name, "underset"),
                    .limits = std.mem.eql(u8, name, "stackrel") and self.display,
                } };
            }
            return .{ .text = name };
        }
        if (std.mem.eql(u8, name, "overbrace") or std.mem.eql(u8, name, "underbrace")) {
            if (a.len >= 1) {
                const base = try self.allocNode(a[0]);
                const brace_cp: u21 = if (std.mem.eql(u8, name, "overbrace")) 0x23DE else 0x23DF;
                var mark: *Node = try self.allocNode(.{ .glyph = .{ .cp = brace_cp, .class = .symbol } });
                if (a.len >= 2) mark = try self.allocNode(a[1]);
                return .{ .over_under = .{
                    .base = base,
                    .mark = mark,
                    .above = std.mem.eql(u8, name, "overbrace"),
                    .stretchy = a.len < 2,
                } };
            }
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "tag")) {
            if (a.len >= 1) return .{ .tag = .{ .body = try self.allocNode(a[0]) } };
            return .{ .text = name };
        }
        if (std.mem.eql(u8, name, "notag")) {
            return .{ .tag = .{ .body = try self.allocNode(.{ .text = "" }), .suppress = true } };
        }

        if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "dfrac") or
            std.mem.eql(u8, name, "tfrac") or std.mem.eql(u8, name, "ratio"))
        {
            if (a.len >= 2) {
                return .{ .frac = .{
                    .num = try self.allocNode(a[0]),
                    .denom = try self.allocNode(a[1]),
                    .display = !std.mem.eql(u8, name, "tfrac"),
                } };
            }
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "binom")) {
            if (a.len >= 2) {
                return .{ .binom = .{ .top = try self.allocNode(a[0]), .bottom = try self.allocNode(a[1]) } };
            }
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "mat")) {
            // Typst: mat(d)(a, b; c, d) —— 第一个参数可以是定界符规格
            if (a.len == 1) {
                const spec_node = if (a[0] == .row and a[0].row.len == 1) a[0].row[0] else a[0];
                if (delimiterSpec(spec_node)) |d| {
                    const second = try self.parseGrid();
                    if (second.len > 0) return .{ .matrix = .{ .rows = second, .left = d[0], .right = d[1], .alignment = .center } };
                }
            }
            return .{ .matrix = .{ .rows = try self.parseGrid(), .left = 0, .right = 0, .alignment = .center } };
        }
        if (std.mem.eql(u8, name, "pmatrix")) return try self.parseMatrix(a, '(', ')');
        if (std.mem.eql(u8, name, "bmatrix")) return try self.parseMatrix(a, '[', ']');
        if (std.mem.eql(u8, name, "Bmatrix")) return try self.parseMatrix(a, '{', '}');
        if (std.mem.eql(u8, name, "vmatrix")) return try self.parseMatrix(a, '|', '|');
        if (std.mem.eql(u8, name, "Vmatrix")) return try self.parseMatrix(a, 0x2016, 0x2016);
        if (std.mem.eql(u8, name, "cases")) {
            return .{ .cases = .{ .rows = try self.parseGrid(), .left = '{', .alignment = .left } };
        }
        if (std.mem.eql(u8, name, "align")) {
            return .{ .matrix = .{ .rows = try self.parseGrid(), .left = 0, .right = 0, .alignment = .left } };
        }
        if (std.mem.eql(u8, name, "stack")) {
            const alignment: Alignment = if (a.len > 0) blk: {
                const spec = a[0];
                if (spec == .text and std.mem.eql(u8, spec.text, "left")) break :blk .left;
                if (spec == .text and std.mem.eql(u8, spec.text, "right")) break :blk .right;
                break :blk .center;
            } else .center;
            const items = try self.allocator.alloc(*Node, a.len);
            for (a, 0..) |arg, i| items[i] = try self.allocNode(arg);
            return .{ .stack = .{ .items = items, .alignment = alignment } };
        }
        if (std.mem.eql(u8, name, "vec")) {
            const grid = try self.parseGrid();
            if (grid.len > 0) return .{ .matrix = .{ .rows = grid, .left = '(', .right = ')', .alignment = .center } };
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "text")) {
            if (a.len >= 1 and a[0] == .text) return a[0];
            if (a.len >= 1) return .{ .style = .{ .font = .upright, .size = 1.0, .body = try self.allocNode(a[0]) } };
            return .{ .text = "" };
        }

        if (std.mem.eql(u8, name, "op")) {
            if (a.len >= 1) return .{ .op = .{ .name = name, .body = try self.allocNode(a[0]) } };
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "limits") or std.mem.eql(u8, name, "scripts")) {
            if (a.len >= 1) {
                const base = a[0];
                if (base == .script) {
                    const s = base.script;
                    return .{ .script = .{ .base = s.base, .sub = s.sub, .sup = s.sup, .limits = std.mem.eql(u8, name, "limits") } };
                }
                return try self.applyScript(base, std.mem.eql(u8, name, "limits"));
            }
            return .{ .text = name };
        }

        if (std.mem.eql(u8, name, "space")) {
            if (a.len >= 1 and a[0] == .text) {
                const n = std.fmt.parseFloat(f64, a[0].text) catch 0.25;
                return .{ .space = n };
            }
            return .{ .space = 0.25 };
        }
        if (std.mem.eql(u8, name, "thin")) return .{ .space = thin_space };
        if (std.mem.eql(u8, name, "medium")) return .{ .space = medium_space };
        if (std.mem.eql(u8, name, "thick")) return .{ .space = thick_space };
        if (std.mem.eql(u8, name, "quad")) return .{ .space = 1.0 };
        if (std.mem.eql(u8, name, "qquad")) return .{ .space = 2.0 };

        if (std.mem.eql(u8, name, "delim")) {
            if (a.len >= 1 and a[0] == .text) {
                const d = delimiter_names.get(a[0].text) orelse delimiter_names.get("none").?;
                return .{ .glyph = .{ .cp = d[0], .class = .delimiter } };
            }
            return .{ .text = name };
        }

        if (accents.get(name)) |cp| {
            if (a.len >= 1) return .{ .accent = .{ .base = try self.allocNode(a[0]), .cp = cp } };
            // Typst 行为：无括号时重音作用于紧随其后的原子
            self.skipSpace();
            if (self.peek() == null) return .{ .glyph = .{ .cp = cp, .class = .symbol } };
            return .{ .accent = .{ .base = try self.allocNode(try self.parseAtom()), .cp = cp } };
        }

        if (styles.get(name)) |st| {
            if (a.len >= 1) return .{ .style = .{ .font = st, .size = 1.0, .body = try self.allocNode(a[0]) } };
            return .{ .text = name };
        }

        if (functions.get(name)) |fname| {
            const limits = self.display and limits_default.has(name);
            if (a.len >= 1) return .{ .op = .{ .name = fname, .body = try self.allocNode(a[0]), .limits = limits } };
            return .{ .text = fname };
        }

        if (symbols.get(name)) |cp| {
            return .{ .glyph = .{ .cp = cp, .class = .symbol, .style = .italic } };
        }

        return .{ .text = name };
    }

    fn parseRows(self: *Parser, cells: []Node) ParseError![][]Node {
        var rows = std.array_list.Managed([]Node).init(self.allocator);
        for (cells) |arg| {
            if (arg == .row) {
                try rows.append(arg.row);
            } else {
                const single = try self.allocator.alloc(Node, 1);
                single[0] = arg;
                try rows.append(single);
            }
        }
        return rows.toOwnedSlice();
    }

    fn parseMatrix(self: *Parser, cells: []Node, left: u21, right: u21) ParseError!Node {
        var rows = std.array_list.Managed([]Node).init(self.allocator);
        for (cells) |arg| {
            if (arg == .row) {
                try rows.append(arg.row);
            } else {
                const single = try self.allocator.alloc(Node, 1);
                single[0] = arg;
                try rows.append(single);
            }
        }
        return .{ .matrix = .{ .rows = try rows.toOwnedSlice(), .left = left, .right = right } };
    }

    fn parseScript(self: *Parser, base: Node) ParseError!Node {
        const base_node = try self.allocNode(base);
        var sub: ?*Node = null;
        var sup: ?*Node = null;
        var limits = false;

        while (true) {
            self.skipSpace();
            const c = self.peek() orelse break;
            if (c != '_' and c != '^') break;
            self.pos += 1;
            const arg = try self.parseScriptArg();
            if (c == '_') {
                if (sub == null) {
                    sub = arg;
                } else {
                    var merged = std.array_list.Managed(Node).init(self.allocator);
                    try merged.append(.{ .row = sub.?.row });
                    try merged.append(arg.*);
                    sub = try self.allocNode(.{ .row = try merged.toOwnedSlice() });
                }
            } else {
                if (sup == null) {
                    sup = arg;
                } else {
                    var merged = std.array_list.Managed(Node).init(self.allocator);
                    try merged.append(.{ .row = sup.?.row });
                    try merged.append(arg.*);
                    sup = try self.allocNode(.{ .row = try merged.toOwnedSlice() });
                }
            }
        }

        if (base_node.* == .glyph and isBigOperator(base_node.glyph.cp)) limits = true;

        return .{ .script = .{ .base = base_node, .sub = sub, .sup = sup, .limits = limits } };
    }

    fn applyScript(self: *Parser, base: Node, force_limits: bool) ParseError!Node {
        self.skipSpace();
        const c = self.peek() orelse return base;
        if (c != '_' and c != '^') return base;
        const r = try self.parseScript(base);
        if (r == .script and force_limits) return .{ .script = .{ .base = r.script.base, .sub = r.script.sub, .sup = r.script.sup, .limits = true } };
        return r;
    }

    fn parseScriptArg(self: *Parser) ParseError!*Node {
        self.skipSpace();
        const c = self.peek() orelse return try self.allocNode(.{ .text = "" });
        if (c == '(' or c == '{') {
            const close: u8 = if (c == '(') ')' else '}';
            self.pos += 1;
            const body = try self.parseRow(close);
            if (self.peek() == close) self.pos += 1;
            return try self.allocNode(.{ .row = body });
        }
        const single = try self.parseAtom();
        return try self.allocNode(single);
    }
};

/// 判断码点是否应使用 Symbol 字体渲染
pub fn isMathSymbol(cp: u21) bool {
    return fonts.symbolGlyph(cp) != null;
}
