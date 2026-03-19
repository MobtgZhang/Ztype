# 渲染后端说明

Ztype 支持多种输出格式，每种由独立渲染器实现。

## 支持的格式

| 格式 | 扩展名 | 渲染器 | 说明 |
|------|--------|--------|------|
| HTML | .html | html.zig | HTML5 文档，适合浏览器与打印 |
| PDF | .pdf | pdf.zig | PDF 1.4，支持 CJK |
| Word | .rtf | word.zig | RTF 格式，可用 Word / LibreOffice 打开 |

## HTML 后端

### 特性

- 完整 HTML5 结构
- CJK 字体支持（Noto Sans CJK、微软雅黑等）
- KaTeX 数学公式渲染
- 表格、图片、语义块
- `@page` 打印样式（纸张、页边距、页眉页脚）

### 使用场景

- 网页发布
- 打印为 PDF（浏览器“打印”）
- 响应式阅读

## PDF 后端

### 特性

- 标准 PDF 1.4
- CJK 字符（UTF-16BE hex 编码）
- 可配置纸张（A0–A6、Letter、Legal）
- 页边距、页眉、页脚

### 限制

- 当前为单页输出
- 无嵌入 CJK 字体时，部分阅读器可能用系统字体回退

### 使用场景

- 正式文档分发
- 归档、打印

## Word (RTF) 后端

### 特性

- RTF 1.5 格式
- CJK Unicode（\uN?）
- 纸张尺寸与页边距
- 表格、列表、粗体/斜体

### 限制

- 数学公式输出为 LaTeX 源码
- 图片需在 Word 中单独插入

### 使用场景

- 需在 Word 中继续编辑
- 与现有办公流程集成

## 页面布局

各后端均支持通过元数据设置：

- `paper`：纸张规格
- `margin`：页边距
- `header_*` / `footer_*`：页眉、页脚

详见 [layout.md](layout.md)。

## 扩展

新增后端时：

1. 在 `src/render/` 下新增 `xxx.zig`
2. 实现 `pub fn render(allocator, doc, resolver, writer) !void`
3. 在 `main.zig` 中注册格式并调用

渲染器之间相互独立，不共享状态。
