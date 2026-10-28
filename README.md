# Ztype 排版系统

> A modern typesetting system powered by Zig — write clean `.zt` markup, get beautiful HTML / PDF / Word output.

核心理念：**书写优先，编程有度**。语法取自 Typst 的简洁，排版模型取自 TeX 的严谨，
视觉风格是当代的。

## 快速开始

```bash
# 编译（需要 Zig 0.17+）
zig build

# 编译为 HTML（默认）
./zig-out/bin/ztype examples/hello.zt

# 指定输出路径
./zig-out/bin/ztype examples/hello.zt -o output.html

# 输出 PDF / Word (RTF)
./zig-out/bin/ztype examples/hello.zt -o report.pdf -f pdf
./zig-out/bin/ztype examples/hello.zt -o document.rtf -f word

# 调试模式（元数据、风格、AST、分页、目录、引用）
./zig-out/bin/ztype examples/hello.zt --debug

# 运行测试
zig build test
```

## 排版能力

- **断行**：Knuth–Plass 动态规划最优断行，demerit = (1 + 可伸缩度) × badness + penalty
- **两端对齐**：按 glue 可伸缩度比例分配（TeX 风格），压缩/拉伸有上限
- **断词**：Knuth–Liang 模式匹配（TeX `hyph-en-us.pat`），连字符复合词按部分独立断词
- **孤行 / 寡行 / club 控制**、标题 keep-with-next
- **行距模型**：基线到基线 = `max(leading, 上一行深度 + 本行高度 + lineskip)`
- **字距（tracking）**：正文字距计入断行宽度，标题默认负字距
- **字距调整**：Times / Helvetica kerning 表
- **悬挂标点与光学对齐**：行首标点突入页边距
- **CJK 禁则（kinsoku）**：行首/行末禁则标点，CJK 间可伸缩 glue
- **spacefactor**：句末标点后的空格加宽
- **智能标点**：弯引号、en/em dash、省略号、`© ® ™ ℗ ± ÷ × →`
- **数学**：Typst 语法（`$ sum_(i=1)^n i $`）+ LaTeX 别名，盒模型与斜体补偿
- **display 公式断行**：只在顶层关系符处切段，各行共用同一个对齐点（Typst `align` 语义）
- **多栏排版**、目录（点引导线 + 收敛迭代）、脚注、交叉引用、参考文献
- **表格列宽**：auto / `fr` / 绝对长度 / 百分比，配合对齐行 `< ^ >`
- **代码块软换行**：优先在空白处断行，必要时按字形宽度硬断
- **脚注放不下时整组顺延**到下一栏或下一页
- **页码样式**：arabic / roman / roman_lower / letters，前置内容单独编号
- **页眉页脚**：三区模板变量 `{{page}}` `{{pages}}` `{{title}}` `{{author}}` `{{date}}` `{{section}}`
- **输出映射**：PDF `/PageLabels` 与 `Tc`、HTML `<colgroup>` / `letter-spacing` / `break-inside`、RTF `\page`

## 支持的语法

- **元数据块**：`---` 包裹的 `key: value`
- **标题**：`=` … `======`（1–6 级），可带 `[id]`
- **行内**：`*粗体*` `_斜体_` `` `代码` `` `$公式$` `[链接](url)` `[->引用]` `[^脚注]` `[@引文]` `@(表达式)` `^上标^` `~下标~`
- **语义块**：`:: figure` `:: code` `:: quote` `:: note|warning|tip|caution|important` `:: math` `:: definitions` `:: bibliography`
- **列表**：`-` `+` `1.`（缩进嵌套）
- **表格**：`| a | b |` + 对齐行 `| < | ^ | > |`
- **表格列宽**：对齐行可带宽度 `| <2cm | ^30% | >2fr |`，无后缀为 auto，纯数字为 `fr`
- **页面指令**：`%% pagebreak` `%% columnbreak` `%% toc` `%% rule` `%% include path`
- **脚本**：`@{ let x = 1 }` 与 `@(x)`
- **注释**：`;` 行注释、`;{ … }` 块注释

## 项目结构

```
ztype/
├── src/
│   ├── main.zig          # CLI 入口
│   ├── lib.zig           # 库入口（测试与主程序共用）
│   ├── lexer.zig         # 词法分析
│   ├── parser.zig        # 语法解析
│   ├── ast.zig           # AST 定义
│   ├── resolver.zig      # 变量求值与交叉引用
│   ├── style.zig         # 排版参数与默认值
│   ├── units.zig         # 长度单位与纸张规格
│   ├── fonts.zig         # 字体度量与 kerning
│   ├── fontmetrics.zig   # 字形度量表
│   ├── hyphenate.zig     # Knuth–Liang 断词
│   ├── hyph_en_us.pat    # TeX 英文断词模式表
│   ├── math.zig          # 数学解析与符号表
│   ├── mathlayout.zig    # 数学盒模型
│   ├── engine.zig        # 排版引擎（分行/分页/编号/目录/脚注）
│   ├── render/
│   │   ├── html.zig      # HTML5 + MathML
│   │   ├── pdf.zig       # PDF 1.7
│   │   ├── word.zig      # RTF
│   │   └── debug.zig     # 调试输出
│   └── util/
│       ├── arena.zig
│       ├── cjk.zig
│       ├── error.zig
│       ├── layout.zig
│       ├── string.zig
│       └── typography.zig  # 智能标点
├── docs/                 # 语法、数学、微观排版、布局、后端
├── examples/             # 示例文档
└── tests/                # 单元测试
```

## 文档

| 文档 | 内容 |
|------|------|
| [docs/syntax.md](docs/syntax.md) | 语法参考 |
| [docs/math.md](docs/math.md) | 数学公式排版（Typst 语法） |
| [docs/typography.md](docs/typography.md) | 断行、断词、对齐、kerning、禁则、spacefactor |
| [docs/layout.md](docs/layout.md) | 纸张、页边距、多栏、页码、目录、页眉页脚 |
| [docs/cli.md](docs/cli.md) | 命令行用法与库接口 |
| [docs/backends.md](docs/backends.md) | 各输出格式的特性与限制 |
| [docs/package-manager.md](docs/package-manager.md) | `zt.toml` 与 `%% include` |

## 技术栈

- **语言**：Zig 0.17+
- **构建**：`zig build`
- **测试**：`zig build test`

## 参考

- Typst — 语法与盒模型的主要参考
- TeX / LaTeX — 断行模型、断词、penalty、spacefactor
- Modern typography — 视觉风格与 CSS 呈现
