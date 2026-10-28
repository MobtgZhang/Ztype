# 渲染后端

Ztype 分两层：排版引擎产出**页 → 绘制项**（文本 run、规则线、矩形、图片），
后端只负责把这些项写成目标格式。因此断行、分页、编号、目录、脚注在所有后端中一致。

## 支持的格式

| 格式 | 扩展名 | 渲染器 | 说明 |
|------|--------|--------|------|
| HTML | `.html` | `src/render/html.zig` | 自包含 HTML5 + 原生 MathML |
| PDF | `.pdf` | `src/render/pdf.zig` | PDF 1.7，多页 |
| Word | `.rtf` | `src/render/word.zig` | RTF 1.5 |
| 调试 | — | `src/render/debug.zig` | 元数据、风格、AST、分页、目录、引用 |

## HTML 后端

### 特性

- 自包含单文件，不依赖 CDN 或外部字体
- 原生 MathML（浏览器直接渲染），公式编号为 `.equation .number`
- 现代排版 CSS：`font-kerning`、`font-variant-numeric`、`font-optical-sizing`、
  `hanging-punctuation`、`text-wrap: pretty` / `balance`、`hyphens: auto`、
  `text-rendering: optimizeLegibility`
- `@page` 与 `@media print`：纸张、页边距、`orphans` / `widows`
  （取自元数据），图形、提示框、表格 `break-inside: avoid`
- 多栏用 `column-count`；目录、脚注、交叉引用为页内锚点
- 显式列宽用 `<colgroup>` 表达；字距用 `letter-spacing: var(--tracking)`
- 标题、图片、表格、语义块、定义列表、参考文献

### 限制

- 页眉页脚只在打印时生效（`@page` 的 margin box 支持有限）
- MathML 渲染质量取决于浏览器
- 浏览器断行与引擎断行不完全一致（HTML 是近似呈现）

### 使用场景

网页发布、打印为 PDF、响应式阅读。

## PDF 后端

### 特性

- PDF 1.7，多页输出
- base-14 标准字体 + Symbol 数学字体 + Type0 CJK 字体（`STSong-Light`，UniGB-UCS2-H）
- 书签大纲（`/Outlines`）、内部与外部链接注释
- 前置内容与正文页码样式不同时写 `/PageLabels`（`/D` `/R` `/r` `/A`）
- 字距按 run 输出 `Tc`，与引擎计入自然宽度的字距一致
- JPEG 图片作为 XObject 嵌入
- 逐页绘制页眉、页脚、脚注区与规则线
- 文本 run 携带 `scale_x` / `scale_y`，用于拉伸定界符与宽重音

### 限制

- 不嵌入字体文件，CJK 依赖阅读器的 `STSong-Light` 回退
- 只支持 JPEG 图片（PNG 需先转换）
- 没有真正的数学字体度量，符号按标准字形近似

### 使用场景

正式文档分发、归档、打印。

## Word (RTF) 后端

### 特性

- RTF 1.5：字体表、样式表、标题编号、上下标、脚注字段、表格、链接
- CJK 以 `\uN?` 输出
- 纸张尺寸与页边距
- `%% pagebreak` / `%% columnbreak` 输出 `\page`

### 限制

- 数学公式是文本近似（`^()` / `_()`），没有分式与矩阵的真实布局
- 页眉页脚需在 Word 中进一步设置
- 图片需在 Word 中单独插入

### 使用场景

需要在 Word 中继续编辑，或与现有办公流程集成。

## 扩展新后端

1. 在 `src/render/` 下新增 `xxx.zig`
2. 实现 `pub fn render(allocator, doc, engine, resolver, writer) !void`
3. 在 `src/main.zig` 的 `OutputFormat` 中注册并调用

渲染器之间不共享状态；排版结果（`Engine.pages`）是唯一的输入。

## 相关文档

- 排版模型：[typography.md](typography.md)
- 页面布局：[layout.md](layout.md)
- 数学：[math.md](math.md)
