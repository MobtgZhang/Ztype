//! Ztype 排版系统 - 主入口
//! 用法: ztype <input.zt> [options]
//!  ztype hello.zt -o hello.html       # 输出 HTML（默认）
//!  ztype hello.zt -o out.pdf -f pdf   # 输出 PDF
//!  ztype hello.zt -o out.rtf -f word  # 输出 Word (RTF)
//!  ztype hello.zt --debug             # 调试输出 AST

const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Resolver = @import("resolver.zig").Resolver;
const html_render = @import("render/html.zig");
const pdf_render = @import("render/pdf.zig");
const word_render = @import("render/word.zig");
const debug_render = @import("render/debug.zig");

pub const OutputFormat = enum {
    html,
    pdf,
    word,
};

fn formatFromExt(path: []const u8) OutputFormat {
    if (std.mem.endsWith(u8, path, ".pdf")) return .pdf;
    if (std.mem.endsWith(u8, path, ".rtf") or std.mem.endsWith(u8, path, ".doc")) return .word;
    return .html;
}

fn defaultExtForFormat(fmt: OutputFormat) []const u8 {
    return switch (fmt) {
        .html => ".html",
        .pdf => ".pdf",
        .word => ".rtf",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // 跳过程序名

    // 早期检查：单独 -h/--help 时显示帮助
    const first = args.next();
    if (first) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            return;
        }
    }

    var input_path: ?[]const u8 = first;
    var output_path: ?[]const u8 = null;
    var explicit_format: ?OutputFormat = null;
    var debug_mode = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args.next();
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const fmt_arg = args.next() orelse {
                std.log.err("请指定格式: html, pdf, word\n", .{});
                return;
            };
            if (std.mem.eql(u8, fmt_arg, "html")) {
                explicit_format = .html;
            } else if (std.mem.eql(u8, fmt_arg, "pdf")) {
                explicit_format = .pdf;
            } else if (std.mem.eql(u8, fmt_arg, "word") or std.mem.eql(u8, fmt_arg, "rtf")) {
                explicit_format = .word;
            } else {
                std.log.err("未知格式 '{s}'，支持: html, pdf, word\n", .{fmt_arg});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (input_path == null) {
            input_path = arg;
        }
    }

    const inp = input_path orelse {
        printUsage();
        return;
    };

    const source = std.fs.cwd().readFileAlloc(allocator, inp, 10 * 1024 * 1024) catch |err| {
        std.log.err("无法读取文件 {s}: {}\n", .{ inp, err });
        return;
    };
    defer allocator.free(source);

    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch |err| {
        std.log.err("解析错误: {}\n", .{err});
        return;
    };
    defer doc.deinit();

    var resolver = Resolver.init(allocator);
    defer resolver.deinit();

    // 先执行所有脚本块，以便变量在渲染时可用
    for (doc.content.items) |node| {
        switch (node) {
            .script_block => |sb| resolver.evalScript(sb.source) catch {},
            else => {},
        }
    }

    const format: OutputFormat = explicit_format orelse (if (output_path) |p| formatFromExt(p) else .html);

    const out_path = output_path orelse blk: {
        const base = if (std.mem.endsWith(u8, inp, ".zt"))
            inp[0 .. inp.len - 3]
        else
            inp;
        const ext = defaultExtForFormat(format);
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext });
    };
    defer if (output_path == null) allocator.free(out_path);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    if (debug_mode) {
        try debug_render.render(allocator, &doc, output.writer());
    } else switch (format) {
        .html => try html_render.render(allocator, &doc, &resolver, output.writer()),
        .pdf => try pdf_render.render(allocator, &doc, &resolver, output.writer()),
        .word => try word_render.render(allocator, &doc, &resolver, output.writer()),
    }

    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output.items });
    std.log.info("已输出: {s}\n", .{out_path});
}

fn printUsage() void {
    std.log.info(
        \\用法: ztype <input.zt> [选项]
        \\
        \\选项:
        \\  -o, --output <path>  指定输出文件路径
        \\  -f, --format <fmt>  输出格式: html, pdf, word
        \\  --debug             输出 AST 调试信息到 stdout
        \\  -h, --help          显示此帮助
        \\
        \\示例:
        \\  ztype doc.zt                    # 输出 doc.html
        \\  ztype doc.zt -o out.html        # 输出 HTML
        \\  ztype doc.zt -o out.pdf -f pdf  # 输出 PDF
        \\  ztype doc.zt -o out.rtf -f word # 输出 Word (RTF)
        \\  ztype doc.zt --debug            # 调试模式
        \\
    , .{});
}

test "lexer basic" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: Hello
        \\---
        \\
        \\= 标题
    ;
    var lexer = Lexer.init(allocator, source);
    var count: usize = 0;
    while (try lexer.next()) |_| {
        count += 1;
        if (count > 20) break;
    }
}

test "parser basic" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: 测试
        \\---
        \\
        \\= 第一章
        \\
        \\这是段落内容。
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();

    try std.testing.expect(doc.metadata != null);
    try std.testing.expect(doc.content.items.len >= 1);
}

test "render: HTML 输出" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: 渲染测试
        \\---
        \\= 标题
        \\
        \\段落内容
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try html_render.render(allocator, &doc, &resolver, buf.writer());
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<h1>") != null);
}

test "render: PDF 输出" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: PDF 测试
        \\---
        \\= 标题
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try pdf_render.render(allocator, &doc, &resolver, buf.writer());
    try std.testing.expect(std.mem.startsWith(u8, buf.items, "%PDF-1.4"));
}

test "render: Word (RTF) 输出" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: RTF 测试
        \\---
        \\= 标题
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();
    var resolver = Resolver.init(allocator);
    defer resolver.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try word_render.render(allocator, &doc, &resolver, buf.writer());
    try std.testing.expect(std.mem.startsWith(u8, buf.items, "{\\rtf1"));
}
