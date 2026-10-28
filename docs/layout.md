# 页面布局设置

本文档说明 Ztype 的页面布局功能，设计参考 LaTeX 的 `\documentclass`、`geometry`、`fancyhdr` 等包。

## 元数据配置

在文档开头的元数据块中设置布局参数：

```
---
title:    文档标题
paper:    A4
margin:   2.5cm
margin_top:    2cm
margin_bottom: 2cm
margin_left:   2.5cm
margin_right:  2.5cm
header_left:   @(title)
header_right:  第 {{page}} 页
footer_center: {{page}} / {{pages}}
---
```

## 全部元数据键

| 键 | 默认值 | 说明 |
|----|--------|------|
| `title` `author` `date` | — | 文档信息，用于页眉页脚与 PDF Info |
| `lang` | `en` | 语言，影响编号前缀（图/表/清单/式/参考文献/目录） |
| `paper` | `A4` | 纸张规格 |
| `margin` / `margin_top` `margin_bottom` `margin_left` `margin_right` | 72pt | 页边距 |
| `font` | `sans` | 正文字族：`sans` `serif` `mono` |
| `heading_font` | `sans` | 标题字族 |
| `fontsize` | 10pt | 正文字号（同时把 leading 设为 1.5 倍） |
| `leading` | 15pt | 行距 |
| `measure` | 版心宽度 | 单栏行宽 |
| `parskip` | 7pt | 段间距 |
| `indent` | 0 | 首行缩进 |
| `justify` | `false` | 两端对齐 |
| `hyphen` | `true` | 断词 |
| `spacefactor` | `true` | 句末空格加宽 |
| `smart` | `true` | 智能标点（引号、破折号、省略号、符号） |
| `lineskip` | 0 | TeX 的 lineskip：行盒相碰时行与行之间的最小间隙 |
| `tracking` | 0 | 正文字距（letter-spacing），计入断行宽度 |
| `heading_tracking` | -0.012em | 标题的负字距（大字号收紧） |
| `orphans` | 2 | 段首在本页至少保留的行数 |
| `widows` | 2 | 段末带到下一页的最少行数 |
| `footnote_size` | 8pt | 脚注字号 |
| `code_size` | 8.5pt | 行内代码与代码块字号 |
| `quote_size` | 9.5pt | 引用块字号 |
| `caption_size` | 8.5pt | 图注 / 表注字号 |
| `header_size` | 8pt | 页眉页脚字号 |
| `math_size` | 10pt | display 公式字号 |
| `heading_before` `heading_after` | 按层级 | 标题上下间距，单值覆盖全部层级 |
| `numbering` | `true` | 标题与图/表/清单/公式自动编号 |
| `toc` | `false` | 生成目录 |
| `toc_depth` | 6 | 目录最深层级 |
| `columns` | 1 | 栏数 |
| `column_gap` | 18pt | 栏间距 |
| `pagenum` | `arabic` | 正文页码样式 |
| `front_pagenum` | `roman_lower` | 前置内容页码样式 |
| `front_matter` | 0 | 前置内容页数 |
| `plain_first_page` | `false` | 首页不显示页眉页脚 |
| `color` | `black` | 正文颜色 |
| `muted_color` | `gray` | 次要文字颜色（编号、页眉页脚、定义项） |
| `accent_color` | `blue` | 链接与强调色 |
| `header_left` `header_center` `header_right` | — | 页眉三区 |
| `footer_left` `footer_center` `footer_right` | — | 页脚三区 |

微观排版的细节（断词、悬挂标点、孤寡行、spacefactor）见 [typography.md](typography.md)。

## 纸张规格 (paper)

支持规格与 LaTeX `paper` 兼容：

| 值 | 尺寸 (mm) | 用途 |
|----|-----------|------|
| `A0` | 841 × 1189 | 海报、大幅展示 |
| `A1` | 594 × 841 | 海报 |
| `A2` | 420 × 594 | 展板 |
| `A3` | 297 × 420 | 小报、图表 |
| `A4` | 210 × 297 | **默认**，常用文档 |
| `A5` | 148 × 210 | 小册子 |
| `A6` | 105 × 148 | 明信片 |
| `Letter` | 216 × 279 | 美式信纸 |
| `Legal` | 216 × 356 | 美式法律用纸 |

未指定时默认为 `A4`。

## 页边距 (margin)

支持统一或分边设置。

### 统一页边距

```
margin: 2.5cm
margin: 1in
margin: 72pt
```

### 分边设置

```
margin_top:    2cm
margin_bottom: 2cm
margin_left:   2.5cm
margin_right:  2.5cm
```

### 单位

| 单位 | 说明 | 示例 |
|------|------|------|
| `cm` | 厘米 | `2.5cm` |
| `mm` | 毫米 | `25mm` |
| `in` | 英寸 | `1in` |
| `pt` | 点 (1/72 inch) | `72pt` |

未指定单位时按 `cm` 处理。默认约 72pt (1 inch)。

## 页眉 (header)

页眉支持左、中、右三区，与 LaTeX `fancyhdr` 类似：

| 键 | 位置 | 示例 |
|----|------|------|
| `header_left` | 左侧 | `@(title)` |
| `header_center` | 居中 | 空 |
| `header_right` | 右侧 | `第 {{page}} 页` |

可在内容中使用脚本变量 `@(title)` 等，以及模板变量 `{{page}}`、`{{pages}}`。

## 页脚 (footer)

页脚同样支持三区：

| 键 | 位置 | 示例 |
|----|------|------|
| `footer_left` | 左侧 | `@(author)` |
| `footer_center` | 居中 | `{{page}} / {{pages}}` |
| `footer_right` | 右侧 | `@(date)` |

## 模板变量

页眉/页脚中可用的系统变量：

| 变量 | 含义 | 示例输出 |
|------|------|----------|
| `{{page}}` | 当前页码 | 1 |
| `{{pages}}` | 总页数 | 10 |
| `{{title}}` | 文档标题 | 从 metadata |
| `{{author}}` | 作者 | 从 metadata |
| `{{date}}` | 日期 | 从 metadata |
| `{{section}}` | 当前页最近的标题 | 从最近一次标题 |

> 注意：`{{...}}` 为排版系统变量，`@()` 为脚本变量，语义不同。

## 各输出格式支持情况

| 功能 | HTML | PDF | Word (RTF) |
|------|------|-----|------------|
| 纸张尺寸 | ✅ @page | ✅ MediaBox | ✅ \paperw \paperh |
| 页边距 | ✅ @page | ✅ 布局 | ✅ \margl 等 |
| 页眉 | ✅ @page/@media print | ✅ 每页 | 部分支持 |
| 页脚 | ✅ @page/@media print | ✅ 每页 | 部分支持 |

- **HTML**：通过 `@page` 和 `@media print` 实现，打印时生效。
- **PDF**：多页输出，页眉页脚逐页绘制。
- **Word**：支持纸张和页边距；页眉页脚需在 Word 中进一步设置。

## 多栏排版

```
---
columns:     2
column_gap:  18pt
---
```

内容按栏顺序流动，栏宽 = `(版心宽度 − (栏数−1) × 栏间距) / 栏数`。断行、对齐、
悬挂标点都按当前栏宽计算。

## 页码样式

| 键 | 说明 | 示例 |
|----|------|------|
| `pagenum` | 正文页码样式 | `arabic`（默认）、`roman`、`roman_lower`、`letters` |
| `front_pagenum` | 前置内容页码样式 | `roman_lower`（默认） |
| `front_matter` | 前 N 页视为前置内容（目录、摘要等） | `3` |
| `plain_first_page` | 首页不显示页眉页脚 | `true` |

```
---
pagenum:       arabic
front_pagenum: roman_lower
front_matter:  2
plain_first_page: true
---
```

## 目录

元数据 `toc: true` 或在正文中写 `%% toc`。目录带点引导线、按层级缩进，并在 HTML/PDF
中生成链接与书签。

```
---
toc: true
toc_depth: 3
---
```

目录页码需要收敛：引擎最多迭代 4 次，直到目录条目自身占用的页数稳定。

## 脚注

`[^内容]` 在正文里只留下上标标记，内容排在所在栏的栏底：一条细分隔线，然后是按
`footnote_size` 与 1.35 倍行距测量的编号与文本。

出现标记时引擎先按整段宽度估算脚注块高度并预留空间；如果实际断行超出预留（长词无法
断词、行更窄等），整组脚注顺延到下一栏或下一页，当前页不画分隔线。文档末尾的脚注就地
排下，不再顺延。脚注的归属页就是实际绘制页，`--debug`、HTML 与 PDF 的脚注列表都按该页显示。

单组脚注本身超过整栏高度时只能就地排下（避免无限翻页）。

## 参考文献

```
:: bibliography
---
knuth: Knuth, D. E. *Computer Modern Typography*, 1999.
typst: Cozens, C. *Typst: Reliable and Beautiful Document Preparation*, 2024.
```

正文中用 `[@knuth]` 引用，输出 `[1]`，条目按出现顺序编号并使用悬挂缩进。
标题由 `title` 属性指定，默认按语言取 `参考文献` / `References`。

## 完整示例

```
---
title:    技术报告
author:   张三
date:     2025-03-19
paper:    A4
margin:   2.5cm
header_left:   @(title)
header_right:  第 {{page}} 页
footer_center: — {{page}} / {{pages}} —
---

= 正文开始

内容...
```

## 参考

- LaTeX: `geometry`, `fancyhdr`, `\documentclass[paper=a4]`
- CSS: `@page`, `@media print`
