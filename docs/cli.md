# Ztype 命令行用法

## 基本用法

```
ztype <input.zt> [选项]
ztype init
```

将 `.zt` 源文件编译为 HTML、PDF 或 Word (RTF) 格式。

## 命令

| 命令 | 说明 |
|------|------|
| `init` | 在当前目录创建 `zt.toml` 项目配置 |

## 选项

| 选项 | 说明 |
|------|------|
| `-o`, `--output <path>` | 指定输出文件路径（默认与输入同名，扩展名按格式） |
| `-f`, `--format <fmt>` | 输出格式：`html`、`pdf`、`word`（`rtf` 等价） |
| `--debug` | 输出元数据、风格、AST、分页、目录与交叉引用 |
| `-h`, `--help` | 显示帮助信息 |

未指定 `-f` 时按输出文件扩展名判断：`.pdf` → PDF，`.rtf`/`.doc` → Word，其余 → HTML。

## 处理流程

```
词法分析 → 语法解析 → 脚本求值 → 风格 → 排版引擎 → 后端渲染
                                    (分行/分页/编号/目录/脚注)
```

排版引擎先跑编号遍（标题、图、表、清单、公式、脚注、引文），再跑布局遍，
目录需要收敛时最多迭代 4 次。

## 调试输出

```bash
ztype doc.zt --debug
```

输出分区：

- `=== METADATA ===` 元数据
- `=== STYLE ===` 生效的排版参数
- `=== AST ===` 块与行内结构，公式含盒模型节点类型
- `=== PAGES ===` 每页尺寸、页边距、页眉页脚、绘制项（文本 run、规则线、矩形、图片）
- `=== TOC ===` 目录条目与页码
- `=== REFERENCES ===` 交叉引用解析结果

## 示例

```bash
ztype init                            # 创建 zt.toml
ztype doc.zt                          # 输出 doc.html
ztype doc.zt -o out.html              # 指定路径
ztype doc.zt -o report.pdf -f pdf     # 输出 PDF
ztype doc.zt -o document.rtf -f word  # 输出 Word (RTF)
ztype doc.zt --debug                  # 调试模式
```

## 库用法

`src/lib.zig` 导出各模块，可作为库使用：

```zig
const ztype = @import("ztype");

var p = try ztype.parser.Parser.init(allocator, io, source);
var doc = try p.parse();
const st = ztype.style.Style.fromMetadata(&doc.metadata);
var engine = ztype.engine.Engine.init(allocator, &doc, st, null);
const pages = try engine.run();
```

`Engine` 公开的关键接口：

- `run()` — 完整排版，返回页列表
- `tokensFromInlines(inlines, size, family, color)` — 把行内节点切成 run/glue/discretionary token
- `breakTokens(tokens, measure)` — Knuth–Plass 最优断行

## 参考

- 语法：[syntax.md](syntax.md)
- 数学：[math.md](math.md)
- 微观排版：[typography.md](typography.md)
- 页面布局：[layout.md](layout.md)
- 后端：[backends.md](backends.md)
- 包管理：[package-manager.md](package-manager.md)
