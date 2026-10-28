//! Ztype 排版系统 —— 命令行入口
//!
//! 用法：
//!   ztype <input.zt> [选项]
//!   ztype init                       初始化项目，创建 zt.toml
//!
//! 选项：
//!   -o, --output <path>  输出文件路径（默认与输入同名）
//!   -f, --format <fmt>   输出格式：html / pdf / word（RTF）
//!   --debug              输出 AST 与分页调试信息
//!   -h, --help           显示帮助
//!
//! 流程：词法 → 语法 → 脚本求值 → 风格 → 排版引擎（分行/分页/编号/目录）→ 后端渲染。

const std = @import("std");
const ztype = @import("ztype");

const Parser = ztype.parser.Parser;
const Resolver = ztype.resolver.Resolver;
const Engine = ztype.engine.Engine;
const Style = ztype.style.Style;

const OutputFormat = enum { html, pdf, word };

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);

    var it = init.minimal.args.iterateAllocator(allocator) catch return;
    _ = it.next();

    const first = it.next();
    if (first) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printUsage(&stdout.interface);
            try stdout.interface.flush();
            return;
        }
    }

    var input_path: ?[]const u8 = first;
    var output_path: ?[]const u8 = null;
    var explicit_format: ?OutputFormat = null;
    var debug_mode = false;

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = it.next();
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const fmt_arg = it.next() orelse {
                std.log.err("请指定格式：html, pdf, word", .{});
                return error.Usage;
            };
            if (std.mem.eql(u8, fmt_arg, "html")) {
                explicit_format = .html;
            } else if (std.mem.eql(u8, fmt_arg, "pdf")) {
                explicit_format = .pdf;
            } else if (std.mem.eql(u8, fmt_arg, "word") or std.mem.eql(u8, fmt_arg, "rtf")) {
                explicit_format = .word;
            } else {
                std.log.err("未知格式 '{s}'，支持：html, pdf, word", .{fmt_arg});
                return error.Usage;
            }
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(&stdout.interface);
            try stdout.interface.flush();
            return;
        } else if (input_path == null) {
            input_path = arg;
        }
    }

    const inp = input_path orelse {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    };

    if (std.mem.eql(u8, inp, "init")) {
        try runInit(io, &stdout.interface);
        try stdout.interface.flush();
        return;
    }

    const source = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, inp, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        std.log.err("无法读取文件 {s}: {t}", .{ inp, err });
        return err;
    };

    var parser = try Parser.init(allocator, io, source);
    if (std.fs.path.dirname(inp)) |dir| parser.setBaseDir(dir);

    var doc = parser.parse() catch |err| {
        std.log.err("解析错误: {t}", .{err});
        return err;
    };

    // 先执行脚本块，使 @() 表达式在渲染时可用
    var resolver = Resolver.init(allocator);
    for (doc.content) |block| {
        if (block == .script) try resolver.evalScript(block.script.source);
    }

    const st = Style.fromMetadata(&doc.metadata);
    var engine = Engine.init(allocator, &doc, st, &resolver);
    const pages = try engine.run();

    const format: OutputFormat = explicit_format orelse (if (output_path) |p| formatFromExt(p) else .html);

    const out_path = output_path orelse blk: {
        const base = if (std.mem.endsWith(u8, inp, ".zt")) inp[0 .. inp.len - 3] else inp;
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, defaultExtForFormat(format) });
    };

    if (debug_mode) {
        try ztype.render.debug.render(allocator, &doc, &engine, pages, &stdout.interface);
        try stdout.interface.flush();
        return;
    }

    var file = if (out_path[0] == '/')
        try std.Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, out_path, .{});
    var file_writer = file.writer(io, &buf);
    const writer = &file_writer.interface;

    switch (format) {
        .html => try ztype.render.html.render(allocator, &doc, st, &resolver, writer),
        .pdf => try ztype.render.pdf.render(allocator, io, pages, st, doc.metadata.getOr("title", "Untitled"), doc.metadata.getOr("author", ""), &engine.heading_pages, writer),
        .word => try ztype.render.word.render(allocator, &doc, &engine, &resolver, writer),
    }

    try writer.flush();
    file.close(io);
    std.log.info("已生成 {s}（{d} 页）", .{ out_path, pages.len });
}

fn runInit(io: std.Io, writer: *std.Io.Writer) !void {
    const content =
        \\# Ztype 包配置文件
        \\
        \\[package]
        \\name = "my-project"
        \\version = "0.0.1"
        \\description = ""
        \\
        \\# [dependencies]
        \\# other-package = "0.1.0"
        \\
    ;
    var file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, "zt.toml", .{});
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
    file.close(io);
    try writer.writeAll("已创建 zt.toml\n");
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\用法: ztype <input.zt> [选项]  或  ztype init
        \\
        \\命令:
        \\  init                 初始化项目，创建 zt.toml
        \\
        \\选项:
        \\  -o, --output <path>  指定输出文件路径
        \\  -f, --format <fmt>   输出格式: html, pdf, word
        \\  --debug              输出 AST 与分页调试信息
        \\  -h, --help           显示此帮助
        \\
        \\示例:
        \\  ztype init                        # 创建 zt.toml
        \\  ztype doc.zt                      # 输出 doc.html
        \\  ztype doc.zt -o out.html          # 输出 HTML
        \\  ztype doc.zt -o out.pdf -f pdf    # 输出 PDF
        \\  ztype doc.zt -o out.rtf -f word   # 输出 Word (RTF)
        \\  ztype doc.zt --debug              # 调试模式
        \\
    );
}
