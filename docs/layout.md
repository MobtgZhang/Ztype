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

> 注意：`{{...}}` 为排版系统变量，`@()` 为脚本变量，语义不同。

## 各输出格式支持情况

| 功能 | HTML | PDF | Word (RTF) |
|------|------|-----|------------|
| 纸张尺寸 | ✅ @page | ✅ MediaBox | ✅ \paperw \paperh |
| 页边距 | ✅ @page | ✅ 布局 | ✅ \margl 等 |
| 页眉 | ✅ 打印时显示 | ✅ 单页 | 部分支持 |
| 页脚 | ✅ 打印时显示 | ✅ 单页 | 部分支持 |

- **HTML**：通过 `@page` 和 `@media print` 实现，打印时生效。
- **PDF**：当前为单页输出，页眉页脚显示在首页。
- **Word**：支持纸张和页边距；页眉页脚需在 Word 中进一步设置。

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
