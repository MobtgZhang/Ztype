//! Ztype 排版系统 —— 库入口
//! 把各模块统一导出，便于测试与外部使用。

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const resolver = @import("resolver.zig");
pub const math = @import("math.zig");
pub const mathlayout = @import("mathlayout.zig");
pub const engine = @import("engine.zig");
pub const style = @import("style.zig");
pub const units = @import("units.zig");
pub const fonts = @import("fonts.zig");
pub const fontmetrics = @import("fontmetrics.zig");
pub const errors = @import("util/error.zig");
pub const layout = @import("util/layout.zig");
pub const string = @import("util/string.zig");
pub const cjk = @import("util/cjk.zig");
pub const typography = @import("util/typography.zig");
pub const arena = @import("util/arena.zig");
pub const hyphenate = @import("hyphenate.zig");

pub const render = struct {
    pub const html = @import("render/html.zig");
    pub const pdf = @import("render/pdf.zig");
    pub const word = @import("render/word.zig");
    pub const debug = @import("render/debug.zig");
};
