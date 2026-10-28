//! 数学排版盒模型
//! 参考 Typst：每个公式节点都被测量为 (宽度, 上升高度, 下降深度) 的盒子，
//! 并附带一组相对基线定位的绘制项（文本 run 与规则线）。

const std = @import("std");
const math = @import("math.zig");
const fonts = @import("fonts.zig");
const metrics = @import("fontmetrics.zig");

pub const Item = union(enum) {
    text: TextItem,
    rule: RuleItem,
};

pub const TextItem = struct {
    text: []const u8,
    font: fonts.Font,
    size: f64,
    /// 相对盒子原点（左边界 + 基线）的坐标，y 轴向上
    x: f64,
    y: f64,
    scale_x: f64 = 1.0,
    scale_y: f64 = 1.0,
};

pub const RuleItem = struct {
    x: f64,
    y: f64,
    w: f64,
    thickness: f64,
};

pub const Box = struct {
    w: f64,
    /// 基线以上的高度
    h: f64,
    /// 基线以下的深度
    d: f64,
    /// 斜体补偿（仅斜体字形非零），用于后续元素前的补偿间距
    italic: f64 = 0,
    items: []Item,

    pub fn empty(self: *const Box) bool {
        return self.w == 0 and self.h == 0 and self.d == 0;
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    family: fonts.Family,
    /// display 模式：大运算符使用更大的字形，上下限居中放置
    display: bool = false,

    pub fn init(allocator: std.mem.Allocator, family: fonts.Family) Layout {
        return .{ .allocator = allocator, .family = family };
    }

    // ---- 排版常数（均以当前字号的倍数表示，与 Typst 一致）----
    pub const axis_height = 0.25;
    pub const rule_thickness = 0.04;
    pub const script_factor = 0.7;
    pub const clearance = 0.12;
    pub const side_margin = 0.12;
    /// display 模式下大运算符（\sum、\int 等）的放大系数
    pub const big_operator_scale = 1.2;
    /// 矩阵/网格的列内边距与行间距
    pub const cell_pad = 0.18;
    pub const row_gap = 0.30;

    /// TeX 的 mu 单位：1mu = 1/18 em。thin = 3mu，medium = 5mu，thick = 6mu。
    /// Typst 对二元运算符使用 medium，这里与 Typst 保持一致。
    pub const thin = 3.0 / 18.0;
    pub const medium = 5.0 / 18.0;
    pub const thick = 6.0 / 18.0;

    /// 脚本字号下限（Typst 的 min-script-size），避免嵌套脚本无限缩小
    pub const script_min = 5.0;

    /// 相邻数学元素之间的间距（TeX/Typst 分类间距表）
    pub fn spacing(self: *const Layout, prev: ?math.TexClass, next: math.TexClass, size: f64) f64 {
        _ = self;
        const p = prev orelse return 0;
        // 二元运算符只有左侧存在可操作对象时才加间距（否则视为一元运算符）
        if (next == .bin) return if (p == .ord or p == .op) thick * size else 0;
        if (p == .bin) return if (next == .ord) thick * size else 0;
        // 标点前后、定界符内侧不加间距
        if (p == .open or next == .open or next == .punct) return 0;
        switch (p) {
            .ord, .op, .close, .punct => {
                if (next == .op) return thin * size;
                if (next == .rel) return medium * size;
                return 0;
            },
            .rel => {
                if (next == .ord or next == .op) return medium * size;
                return 0;
            },
            else => return 0,
        }
    }

    /// 斜体字母后接非 ord 元素（或上标）时补回 italic correction
    pub fn needsItalicCorrection(self: *const Layout, prev: ?math.TexClass, next: math.TexClass) bool {
        _ = self;
        if (prev == null) return false;
        return prev.? != next;
    }

    pub fn axis(self: *const Layout, size: f64) f64 {
        _ = self;
        return axis_height * size;
    }
    pub fn ruleThickness(self: *const Layout, size: f64) f64 {
        _ = self;
        return rule_thickness * size;
    }
    pub fn scriptSize(self: *const Layout, size: f64) f64 {
        _ = self;
        return @max(script_min, script_factor * size);
    }

    fn fontFor(self: *const Layout, cp: u21, class: math.Class, style: math.FontStyle, size: f64) fonts.Font {
        _ = size;
        if (fonts.isCjk(cp)) return .cjk;
        const fam = if (style == .monospace) fonts.Family.mono else self.family;
        // 大型运算符（求和、积分、根号等）在 Typst 中始终使用直立字形
        if (math.isBigOperator(cp)) {
            if (fonts.symbolGlyph(cp) != null) return .symbol;
            return fonts.familyFont(fam, .regular);
        }
        switch (style) {
            .bold => return fonts.familyFont(fam, .bold),
            .italic, .script, .fraktur, .double_struck => return fonts.familyFont(fam, .italic),
            .monospace => return fonts.familyFont(fam, .regular),
            .normal, .upright => {
                if (class == .letter) return fonts.familyFont(fam, .italic);
                if (class == .symbol or class == .delimiter) {
                    if (fonts.symbolGlyph(cp) != null) return .symbol;
                }
                return fonts.familyFont(fam, .regular);
            },
        }
    }

    fn cpText(self: *const Layout, cp: u21) []const u8 {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return "";
        return self.allocator.dupe(u8, buf[0..n]) catch "";
    }

    fn glyphBox(self: *const Layout, g: math.Glyph, size: f64) Box {
        const font = self.fontFor(g.cp, g.class, g.style, size);
        // display 模式的大运算符使用更大的字形变体（Typst 行为）
        var sx: f64 = 1.0;
        var sy: f64 = 1.0;
        if (self.display and math.isBigOperator(g.cp)) {
            sx = big_operator_scale;
            sy = big_operator_scale;
        }
        const w = fonts.glyphWidth(g.cp, font, size) * sx;
        var items = std.array_list.Managed(Item).init(self.allocator);
        items.append(.{ .text = .{
            .text = self.cpText(g.cp),
            .font = font,
            .size = size,
            .x = 0,
            .y = 0,
            .scale_x = sx,
            .scale_y = sy,
        } }) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        return .{
            .w = w,
            .h = fonts.ascent(font, size) * sy,
            .d = fonts.descent(font, size) * sy,
            .italic = fonts.italicCorrection(g.cp, font, size) * sx,
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    fn textBox(self: *const Layout, text: []const u8, size: f64) Box {
        var items = std.array_list.Managed(Item).init(self.allocator);
        var h: f64 = 0;
        var d: f64 = 0;
        var x: f64 = 0;
        var view = std.unicode.Utf8View.init(text) catch {
            items.append(.{ .text = .{ .text = text, .font = fonts.familyFont(self.family, .regular), .size = size, .x = 0, .y = 0 } }) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
            return .{ .w = fonts.measure(text, fonts.familyFont(self.family, .regular), size), .h = 0, .d = 0, .items = items.toOwnedSlice() catch &.{} };
        };
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            const font = self.fontFor(cp, .symbol, .upright, size);
            const w = fonts.glyphWidth(cp, font, size);
            items.append(.{ .text = .{
                .text = self.cpText(cp),
                .font = font,
                .size = size,
                .x = x,
                .y = 0,
            } }) catch break;
            x += w;
            h = @max(h, fonts.ascent(font, size));
            d = @max(d, fonts.descent(font, size));
        }
        return .{ .w = x, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
    }

    fn rowBox(self: *const Layout, nodes: []math.Node, size: f64) Box {
        var items = std.array_list.Managed(Item).init(self.allocator);
        var x: f64 = 0;
        var h: f64 = 0;
        var d: f64 = 0;
        var prev_class: ?math.TexClass = null;
        var prev_italic: f64 = 0;

        for (nodes) |node| {
            const b = self.layout(node, size);
            if (b.empty()) continue;

            const cur_class = math.texClass(node);
            if (prev_class) |pc| {
                x += self.spacing(pc, cur_class, size);
                if (prev_italic > 0 and self.needsItalicCorrection(pc, cur_class)) {
                    x += prev_italic;
                }
            }
            prev_class = cur_class;
            prev_italic = b.italic;

            for (b.items) |it| {
                switch (it) {
                    .text => |t| items.append(.{ .text = .{
                        .text = t.text,
                        .font = t.font,
                        .size = t.size,
                        .x = x + t.x,
                        .y = t.y,
                        .scale_x = t.scale_x,
                        .scale_y = t.scale_y,
                    } }) catch {},
                    .rule => |r| items.append(.{ .rule = .{
                        .x = x + r.x,
                        .y = r.y,
                        .w = r.w,
                        .thickness = r.thickness,
                    } }) catch {},
                }
            }
            x += b.w;
            h = @max(h, b.h);
            d = @max(d, b.d);
        }

        return .{
            .w = x,
            .h = h,
            .d = d,
            .italic = prev_italic,
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    pub fn layout(self: *const Layout, node: math.Node, size: f64) Box {
        switch (node) {
            .glyph => |g| return self.glyphBox(g, size),
            .text => |t| return self.textBox(t, size),
            .row => |r| return self.rowBox(r, size),
            .frac => |f| return self.fracBox(f, size),
            .sqrt => |s| return self.sqrtBox(s, size),
            .script => |s| return self.scriptBox(s, size),
            .accent => |a| return self.accentBox(a, size),
            .delim => |d| return self.delimBox(d, size),
            .matrix => |m| return self.matrixBox(m, size),
            .cases => |c| return self.casesBox(c, size),
            .stack => |s| return self.stackBox(s, size),
            .binom => |b| return self.binomBox(b, size),
            .over_under => |o| return self.overUnderBox(o, size),
            .tag => |t| return self.layout(t.body.*, size),
            .space => |sp| return .{ .w = sp * size, .h = 0, .d = 0, .items = &.{} },
            .rule => |r| {
                var items = std.array_list.Managed(Item).init(self.allocator);
                const t = r.thickness * size;
                items.append(.{ .rule = .{ .x = 0, .y = self.axis(size), .w = r.length * size, .thickness = t } }) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
                return .{ .w = r.length * size, .h = t, .d = 0, .items = items.toOwnedSlice() catch &.{} };
            },
            .op => |o| return self.opBox(o, size),
            .style => |s| return self.layout(s.body.*, s.size * size),
        }
    }

    fn fracBox(self: *const Layout, f: math.Frac, size: f64) Box {
        const inner_size = if (f.display) size else self.scriptSize(size);
        const num = self.layout(f.num.*, inner_size);
        const den = self.layout(f.denom.*, inner_size);
        const ax = self.axis(size);
        const bar = self.ruleThickness(size);
        const gap = clearance * size + 0.1 * inner_size;

        const num_y = ax + bar / 2.0 + gap + num.d;
        const den_y = -(ax + bar / 2.0 + gap + den.h);

        const w = @max(num.w, den.w) + 2 * side_margin * size;
        const h = num_y + num.h;
        const d = -(den_y) + den.d;

        var items = std.array_list.Managed(Item).init(self.allocator);
        const left = side_margin * size;
        appendShifted(&items, &num, left + (w - 2 * side_margin * size - num.w) / 2.0, num_y);
        appendShifted(&items, &den, left + (w - 2 * side_margin * size - den.w) / 2.0, den_y);
        items.append(.{ .rule = .{ .x = 0, .y = ax, .w = w, .thickness = bar } }) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        return .{ .w = w, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
    }

    fn sqrtBox(self: *const Layout, s: math.Sqrt, size: f64) Box {
        const body = self.layout(s.body.*, size);
        const bar = self.ruleThickness(size);
        const gap = clearance * size;
        // 根号线在内容上方：至少位于 axis + clearance，且不低于内容顶部 + clearance
        const bar_y = @max(self.axis(size) + gap, body.h + gap);
        const body_y = 0;

        var items = std.array_list.Managed(Item).init(self.allocator);
        const sym_font = fonts.Font.symbol;
        const rad_cp: u21 = 0x221A;
        const natural_h = fonts.ascent(sym_font, size);
        const natural_d = fonts.descent(sym_font, size);
        // 只纵向拉伸：让字形顶端正好到达根号线（Typst 会把 radical 延伸过去）
        const need = bar_y + bar * 0.5;
        const scale_y = @min(6.0, @max(1.0, need / @max(1e-6, natural_h)));
        const rad_w = fonts.glyphWidth(rad_cp, sym_font, size);
        const glyph_top = -natural_d * scale_y + natural_h * scale_y;
        const glyph_bottom = -natural_d * scale_y;

        items.append(.{ .text = .{
            .text = self.cpText(rad_cp),
            .font = sym_font,
            .size = size,
            .x = 0,
            .y = glyph_bottom,
            .scale_x = 1.0,
            .scale_y = scale_y,
        } }) catch {};
        if (glyph_top < bar_y) {
            verticalRule(&items, rad_w - bar, glyph_top, bar_y, bar);
        }
        if (glyph_bottom > -(body.d + gap)) {
            verticalRule(&items, rad_w - bar, -(body.d + gap), glyph_bottom, bar);
        }
        items.append(.{ .rule = .{ .x = rad_w, .y = bar_y, .w = body.w, .thickness = bar } }) catch {};
        appendShifted(&items, &body, rad_w, body_y);

        var h = @max(body_y + body.h, bar_y + bar);
        const d = @max(body.d, gap);
        if (s.index) |idx| {
            const ib = self.layout(idx.*, self.scriptSize(size) * 0.8);
            const iy = bar_y + bar + clearance * size + ib.h;
            appendShifted(&items, &ib, 0.02 * size, iy);
            h = @max(h, iy + ib.h);
        }
        return .{ .w = rad_w + body.w, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
    }

    fn scriptBox(self: *const Layout, s: math.Script, size: f64) Box {
        const base = self.layout(s.base.*, size);
        const script_size = self.scriptSize(size);
        const ax = self.axis(size);
        const clr = clearance * size;
        var items = std.array_list.Managed(Item).init(self.allocator);
        appendShifted(&items, &base, 0, 0);

        var h = base.h;
        var d = base.d;
        var w = base.w;

        if (s.limits) {
            // TeX/Typst：上下限居中置于基座上下方，间隙为 clearance
            var sup_b: ?Box = null;
            var sub_b: ?Box = null;
            if (s.sup) |sup| sup_b = self.layout(sup.*, script_size);
            if (s.sub) |sub| sub_b = self.layout(sub.*, script_size);

            if (sup_b) |b| w = @max(w, b.w);
            if (sub_b) |b| w = @max(w, b.w);
            const shift = (w - base.w) / 2.0;
            for (items.items) |*it| {
                switch (it.*) {
                    .text => |*t| t.x += shift,
                    .rule => |*r| r.x += shift,
                }
            }
            if (sup_b) |b| {
                const y = base.h + clr + b.h;
                appendShifted(&items, &b, shift + (w - b.w) / 2.0, y);
                h = @max(h, y + b.h);
            }
            if (sub_b) |b| {
                const y = -(base.d + clr + b.h);
                appendShifted(&items, &b, shift + (w - b.w) / 2.0, y);
                d = @max(d, -(y) + b.d);
            }
            return .{ .w = w, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
        }

        // TeX 规则：上标基线不低于 axis + clearance，且与基座保持 clearance 间隙
        if (s.sup) |sup| {
            const b = self.layout(sup.*, script_size);
            const y = @max(ax + clr + b.d, base.h + clr);
            appendShifted(&items, &b, base.w + base.italic, y);
            h = @max(h, y + b.h);
            w += base.italic + b.w;
        }
        if (s.sub) |sub| {
            const b = self.layout(sub.*, script_size);
            const y = -@max(ax + clr + b.h, base.d + clr);
            appendShifted(&items, &b, base.w + base.italic, y);
            d = @max(d, -(y) + b.d);
            w += base.italic + b.w;
        }
        return .{ .w = w, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
    }

    fn accentBox(self: *const Layout, a: math.Accent, size: f64) Box {
        const base = self.layout(a.base.*, size);
        var items = std.array_list.Managed(Item).init(self.allocator);
        appendShifted(&items, &base, 0, 0);
        const font = fonts.Font.symbol;
        const bar = self.ruleThickness(size);
        const y = base.h + clearance * size;
        const ah = metrics.accentHeight(a.cp) * size;
        // base-14 字体没有组合附点符号：映射到可打印的等价字符
        const render_cp = metrics.accentRenderCp(a.cp);
        const accent_font = if (fonts.symbolGlyph(render_cp) != null) font else fonts.familyFont(self.family, .regular);
        const text_y = y - metrics.accentBaseline(a.cp) * size;

        // 横线类重音（bar / overline / underline）按规则线绘制
        if (ah <= 0.1 * size) {
            const rule_y = if (a.cp == 0x0332) -(base.d + clearance * size) else y;
            items.append(.{ .rule = .{ .x = 0, .y = rule_y, .w = base.w, .thickness = bar } }) catch
                return .{ .w = base.w, .h = base.h, .d = base.d, .items = items.toOwnedSlice() catch &.{} };
            return .{
                .w = base.w,
                .h = @max(base.h, rule_y + bar),
                .d = @max(base.d, -(rule_y - bar)),
                .italic = base.italic,
                .items = items.toOwnedSlice() catch &.{},
            };
        }

        // 宽重音（hat / tilde / vec）横向拉伸以覆盖整个基座
        const natural_w = fonts.glyphWidth(render_cp, accent_font, size);
        const scale_x = if (metrics.isWideAccent(a.cp) and base.w > natural_w * 1.3)
            @max(1.0, base.w / @max(1e-6, natural_w))
        else
            1.0;

        items.append(.{ .text = .{
            .text = self.cpText(render_cp),
            .font = accent_font,
            .size = size,
            .x = (base.w - natural_w * scale_x) / 2.0,
            .y = text_y,
            .scale_x = scale_x,
            .scale_y = 1.0,
        } }) catch return .{ .w = base.w, .h = base.h, .d = base.d, .items = &.{} };
        return .{
            .w = base.w,
            .h = @max(base.h, y + ah),
            .d = base.d,
            .italic = base.italic,
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    fn delimBox(self: *const Layout, d: math.Delim, size: f64) Box {
        const body = self.layout(d.body.*, size);
        var items = std.array_list.Managed(Item).init(self.allocator);
        const font = fonts.Font.symbol;
        const pad = 0.12 * size;
        var total_w: f64 = pad;

        if (d.left != 0) {
            const b = self.glyphBox(.{ .cp = d.left, .class = .delimiter }, size);
            const scale = if (d.stretchy) @max(1.0, (body.h + body.d) / @max(1e-6, b.h + b.d)) else 1.0;
            const center = (body.h - body.d) / 2.0;
            const y = center - scale * (b.h - b.d) / 2.0;
            items.append(.{ .text = .{
                .text = self.cpText(d.left),
                .font = if (fonts.symbolGlyph(d.left) != null) font else fonts.familyFont(self.family, .regular),
                .size = size,
                .x = total_w,
                .y = y,
                .scale_x = scale,
                .scale_y = scale,
            } }) catch {};
            total_w += b.w * scale + pad;
        }
        appendShifted(&items, &body, total_w, 0);
        total_w += body.w + pad;
        if (d.right != 0) {
            const b = self.glyphBox(.{ .cp = d.right, .class = .delimiter }, size);
            const scale = if (d.stretchy) @max(1.0, (body.h + body.d) / @max(1e-6, b.h + b.d)) else 1.0;
            const center = (body.h - body.d) / 2.0;
            const y = center - scale * (b.h - b.d) / 2.0;
            items.append(.{ .text = .{
                .text = self.cpText(d.right),
                .font = if (fonts.symbolGlyph(d.right) != null) font else fonts.familyFont(self.family, .regular),
                .size = size,
                .x = total_w,
                .y = y,
                .scale_x = scale,
                .scale_y = scale,
            } }) catch {};
            total_w += b.w * scale + pad;
        }
        return .{ .w = total_w, .h = @max(body.h, itemsTop(&items)), .d = @max(body.d, itemsBottom(&items)), .items = items.toOwnedSlice() catch &.{} };
    }

    fn matrixBox(self: *const Layout, m: math.Matrix, size: f64) Box {
        return self.gridBox(m.rows, m.left, m.right, size, m.alignment);
    }

    fn casesBox(self: *const Layout, c: math.Cases, size: f64) Box {
        return self.gridBox(c.rows, c.left, 0, size, c.alignment);
    }

    fn gridBox(self: *const Layout, rows_in: [][]math.Node, left: u21, right: u21, size: f64, alignment: math.Alignment) Box {
        if (rows_in.len == 0) return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        const rows = self.allocator.alloc(Box, rows_in.len) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        for (rows_in, 0..) |row, i| rows[i] = self.rowBox(row, size);

        var cols: usize = 0;
        for (rows_in) |row| cols = @max(cols, row.len);
        if (cols == 0) return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };

        var col_w = self.allocator.alloc(f64, cols) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        // 逐列宽度：需要重新测量每个单元格
        for (0..cols) |j| {
            var wmax: f64 = 0;
            for (rows_in) |row| {
                if (j >= row.len) continue;
                const b = self.layout(row[j], size);
                wmax = @max(wmax, b.w);
            }
            col_w[j] = wmax;
        }

        const gap = row_gap * size;
        const pad_x = cell_pad * size;
        var content_w: f64 = 0;
        for (col_w) |w| content_w += w + 2 * pad_x;

        // 行基线（自上而下）
        const baselines = self.allocator.alloc(f64, rows.len) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        baselines[0] = rows[0].h;
        for (1..rows.len) |i| {
            baselines[i] = baselines[i - 1] - (rows[i - 1].d + gap + rows[i].h);
        }
        var top: f64 = baselines[0] + rows[0].h;
        var bottom: f64 = baselines[rows.len - 1] - rows[rows.len - 1].d;
        for (rows, 0..) |row, i| {
            top = @max(top, baselines[i] + row.h);
            bottom = @min(bottom, baselines[i] - row.d);
        }
        const shift = self.axis(size) - (top + bottom) / 2.0;

        var items = std.array_list.Managed(Item).init(self.allocator);
        const pad = 0.15 * size;
        var total_w: f64 = pad;
        if (left != 0) {
            const b = self.glyphBox(.{ .cp = left, .class = .delimiter }, size);
            const scale = @max(1.0, (top - bottom) / @max(1e-6, b.h + b.d));
            const center = (top + bottom) / 2.0;
            items.append(.{ .text = .{
                .text = self.cpText(left),
                .font = if (fonts.symbolGlyph(left) != null) fonts.Font.symbol else fonts.familyFont(self.family, .regular),
                .size = size,
                .x = total_w,
                .y = center - scale * (b.h - b.d) / 2.0 - shift,
                .scale_x = scale,
                .scale_y = scale,
            } }) catch {};
            total_w += b.w * scale + pad;
        }

        for (0..rows.len) |i| {
            var x: f64 = total_w;
            for (0..cols) |j| {
                if (j >= rows_in[i].len) continue;
                const cell = self.layout(rows_in[i][j], size);
                const cx = switch (alignment) {
                    .left => x + pad_x,
                    .center => x + pad_x + (col_w[j] - cell.w) / 2.0,
                    .right => x + pad_x + col_w[j] - cell.w,
                    .alternate => if (j % 2 == 0) x + pad_x + col_w[j] - cell.w else x + pad_x,
                };
                appendShifted(&items, &cell, cx, baselines[i] + shift);
                x += col_w[j] + 2 * pad_x;
            }
        }
        total_w += content_w + pad;

        if (right != 0) {
            const b = self.glyphBox(.{ .cp = right, .class = .delimiter }, size);
            const scale = @max(1.0, (top - bottom) / @max(1e-6, b.h + b.d));
            const center = (top + bottom) / 2.0;
            items.append(.{ .text = .{
                .text = self.cpText(right),
                .font = if (fonts.symbolGlyph(right) != null) fonts.Font.symbol else fonts.familyFont(self.family, .regular),
                .size = size,
                .x = total_w,
                .y = center - scale * (b.h - b.d) / 2.0 - shift,
                .scale_x = scale,
                .scale_y = scale,
            } }) catch {};
            total_w += b.w * scale + pad;
        }

        return .{
            .w = total_w,
            .h = top + shift,
            .d = -(bottom + shift),
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    fn stackBox(self: *const Layout, s: math.Stack, size: f64) Box {
        var items = std.array_list.Managed(Item).init(self.allocator);
        var wmax: f64 = 0;
        const boxes = self.allocator.alloc(Box, s.items.len) catch return .{ .w = 0, .h = 0, .d = 0, .items = &.{} };
        for (s.items, 0..) |item, i| {
            boxes[i] = self.layout(item.*, size);
            wmax = @max(wmax, boxes[i].w);
        }
        const gap = 0.2 * size;
        var y: f64 = 0;
        for (boxes) |b| y += b.h;
        const top = y;
        for (boxes) |b| {
            const baseline = top - b.h;
            appendShifted(&items, &b, (wmax - b.w) / 2.0, baseline);
            y -= b.h + gap + b.d;
        }
        const bottom = y + boxes[boxes.len - 1].d + gap;
        const shift = self.axis(size) - (top + bottom) / 2.0;
        for (items.items) |*it| {
            switch (it.*) {
                .text => |*t| t.y += shift,
                .rule => |*r| r.y += shift,
            }
        }
        return .{ .w = wmax, .h = top + shift, .d = -(bottom + shift), .items = items.toOwnedSlice() catch &.{} };
    }

    fn binomBox(self: *const Layout, b: math.Binom, size: f64) Box {
        const top = self.layout(b.top.*, size);
        const bot = self.layout(b.bottom.*, size);
        const gap = 0.25 * size;
        const pad = side_margin * size;
        const top_y = gap / 2.0 + top.d;
        const bot_y = -(gap / 2.0 + bot.h);
        const top_extent = top_y + top.h;
        const bottom_extent = bot_y - bot.d;

        var items = std.array_list.Managed(Item).init(self.allocator);
        const wmax = @max(top.w, bot.w);
        const content_w = wmax + 2 * pad;
        appendShifted(&items, &top, pad + (wmax - top.w) / 2.0, top_y);
        appendShifted(&items, &bot, pad + (wmax - bot.w) / 2.0, bot_y);

        const font = fonts.Font.symbol;
        const g = self.glyphBox(.{ .cp = '(', .class = .delimiter }, size);
        const scale = @max(1.0, (top_extent - bottom_extent) / @max(1e-6, g.h + g.d));
        const center = (top_extent + bottom_extent) / 2.0;
        const delim_y = center - scale * (g.h - g.d) / 2.0;
        const delim_w = g.w * scale;
        for ([_]u21{ '(', ')' }) |cp| {
            const x = if (cp == '(') pad else pad + content_w;
            items.append(.{ .text = .{
                .text = self.cpText(cp),
                .font = font,
                .size = size,
                .x = x,
                .y = delim_y,
                .scale_x = scale,
                .scale_y = scale,
            } }) catch {};
        }
        return .{
            .w = content_w + 2 * (pad + delim_w),
            .h = top_extent,
            .d = -(bottom_extent),
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    fn opBox(self: *const Layout, o: math.Op, size: f64) Box {
        const name = self.textBox(o.name, size);
        var items = std.array_list.Managed(Item).init(self.allocator);
        appendShifted(&items, &name, 0, 0);
        var w = name.w;
        var h = name.h;
        var d = name.d;
        if (o.body) |body| {
            const b = self.layout(body.*, size);
            appendShifted(&items, &b, w + 0.17 * size, 0);
            w += 0.17 * size + b.w;
            h = @max(h, b.h);
            d = @max(d, b.d);
        }
        return .{ .w = w, .h = h, .d = d, .items = items.toOwnedSlice() catch &.{} };
    }

    /// 横向缩放后平移：用于 overbrace / underbrace 这类需要覆盖基座的符号
    fn appendScaledShifted(items: *std.array_list.Managed(Item), b: *const Box, dx: f64, dy: f64, scale: f64) void {
        for (b.items) |it| {
            switch (it) {
                .text => |t| items.append(.{ .text = .{
                    .text = t.text,
                    .font = t.font,
                    .size = t.size,
                    .x = t.x * scale + dx,
                    .y = t.y + dy,
                    .scale_x = t.scale_x * scale,
                    .scale_y = t.scale_y,
                } }) catch {},
                .rule => |r| items.append(.{ .rule = .{
                    .x = r.x * scale + dx,
                    .y = r.y + dy,
                    .w = r.w * scale,
                    .thickness = r.thickness,
                } }) catch {},
            }
        }
    }

    fn overUnderBox(self: *const Layout, o: math.OverUnder, size: f64) Box {
        const base = self.layout(o.base.*, size);
        const mark = self.layout(o.mark.*, size);
        var items = std.array_list.Managed(Item).init(self.allocator);
        appendShifted(&items, &base, 0, 0);

        const gap = clearance * size;
        const w = @max(base.w, mark.w);
        const scale: f64 = if (o.stretchy and mark.w > 0 and base.w > mark.w) base.w / mark.w else 1.0;
        const mark_w = mark.w * scale;
        const left = (w - mark_w) / 2.0;

        if (o.above) {
            const y = base.h + gap + mark.d;
            appendScaledShifted(&items, &mark, left, y, scale);
            return .{
                .w = w,
                .h = y + mark.h,
                .d = base.d,
                .italic = base.italic,
                .items = items.toOwnedSlice() catch &.{},
            };
        }

        const y = -(base.d + gap + mark.h);
        appendScaledShifted(&items, &mark, left, y, scale);
        return .{
            .w = w,
            .h = base.h,
            .d = -(y - mark.d),
            .italic = base.italic,
            .items = items.toOwnedSlice() catch &.{},
        };
    }

    fn appendShifted(items: *std.array_list.Managed(Item), b: *const Box, dx: f64, dy: f64) void {
        for (b.items) |it| {
            switch (it) {
                .text => |t| items.append(.{ .text = .{
                    .text = t.text,
                    .font = t.font,
                    .size = t.size,
                    .x = t.x + dx,
                    .y = t.y + dy,
                    .scale_x = t.scale_x,
                    .scale_y = t.scale_y,
                } }) catch {},
                .rule => |r| items.append(.{ .rule = .{
                    .x = r.x + dx,
                    .y = r.y + dy,
                    .w = r.w,
                    .thickness = r.thickness,
                } }) catch {},
            }
        }
    }

    /// 竖直段：用一条宽度为 thickness 的横线表示（后端把它当作矩形描边绘制）
    fn verticalRule(items: *std.array_list.Managed(Item), x: f64, y0: f64, y1: f64, thickness: f64) void {
        if (y1 <= y0) return;
        items.append(.{ .rule = .{
            .x = x,
            .y = (y0 + y1) / 2.0,
            .w = thickness,
            .thickness = y1 - y0,
        } }) catch {};
    }
};

fn itemsTop(items: *const std.array_list.Managed(Item)) f64 {
    var top: f64 = 0;
    for (items.items) |it| {
        switch (it) {
            .text => |t| top = @max(top, t.y + fonts.ascent(t.font, t.size) * t.scale_y),
            .rule => |r| top = @max(top, r.y + r.thickness),
        }
    }
    return top;
}

fn itemsBottom(items: *const std.array_list.Managed(Item)) f64 {
    var bottom: f64 = 0;
    for (items.items) |it| {
        switch (it) {
            .text => |t| bottom = @max(bottom, -(t.y - fonts.descent(t.font, t.size) * t.scale_y)),
            .rule => |r| bottom = @max(bottom, -(r.y - r.thickness)),
        }
    }
    return bottom;
}

pub fn classOf(node: math.Node) math.Class {
    switch (node) {
        .glyph => |g| return g.class,
        .delim => return .delimiter,
        .op => return .function,
        .row => |r| {
            if (r.len > 0) return classOf(r[0]);
            return .symbol;
        },
        else => return .symbol,
    }
}

test "math layout: 基本盒子测量" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = Layout.init(a, .serif);

    var p = math.Parser.init(a, "x^2");
    const nodes = try p.parse();
    const b = l.layout(nodes[0], 10);
    try std.testing.expect(b.w > 0);
    try std.testing.expect(b.h > 0);

    var p2 = math.Parser.init(a, "frac(a, b)");
    const nodes2 = try p2.parse();
    const b2 = l.layout(nodes2[0], 10);
    try std.testing.expect(b2.h > 10 * 0.25);
    try std.testing.expect(b2.d > 0);
}

test "math layout: 矩阵与根号" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = Layout.init(a, .serif);

    var p = math.Parser.init(a, "mat(a, b; c, d)");
    const nodes = try p.parse();
    const b = l.layout(nodes[0], 10);
    try std.testing.expect(b.w > 0 and b.h > 0 and b.d > 0);

    var p2 = math.Parser.init(a, "sqrt(x)");
    const n2 = try p2.parse();
    const b2 = l.layout(n2[0], 10);
    try std.testing.expect(b2.h > 0);
}
