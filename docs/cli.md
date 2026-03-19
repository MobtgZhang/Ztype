# Ztype 命令行用法

## 基本用法

```
ztype <input.zt> [选项]
```

将 `.zt` 源文件编译为 HTML、PDF 或 Word (RTF) 格式。

## 选项

| 选项 | 说明 |
|------|------|
| `-o`, `--output <path>` | 指定输出文件路径 |
| `-f`, `--format <fmt>` | 输出格式：`html`、`pdf`、`word` |
| `--debug` | 输出 AST 调试信息（到 stdout） |
| `-h`, `--help` | 显示帮助信息 |

## 输出格式

- **html**（默认）：输出 HTML5 文档，可用浏览器打开
- **pdf**：输出 PDF 文档
- **word**：输出 RTF 格式，可用 Microsoft Word、LibreOffice 等打开

## 示例

```bash
# 编译为 HTML（默认），输出到 doc.html
ztype doc.zt

# 指定输出路径
ztype doc.zt -o output.html

# 输出 PDF
ztype doc.zt -o report.pdf -f pdf

# 输出 Word (RTF)
ztype doc.zt -o document.rtf -f word

# 根据输出文件后缀自动推断格式（-o out.pdf 即为 PDF）
ztype doc.zt -o out.pdf

# 调试模式：输出 AST 结构
ztype doc.zt --debug

# 显示帮助
ztype -h
ztype --help
```

## 格式推断规则

当未指定 `-f/--format` 时，根据 `-o` 输出路径后缀自动推断：

- `.html` → HTML
- `.pdf` → PDF
- `.rtf`、`.doc` → Word (RTF)

默认输出格式为 HTML，默认扩展名为 `.html`。
