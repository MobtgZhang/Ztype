# Ztype 排版系统

> A minimal, elegant typesetting language powered by Zig — write clean `.zt` markup, get beautiful HTML / PDF / Word output.

基于项目 idea 文档设计的现代排版语言，核心理念：**书写优先，编程有度**。

## 快速开始

```bash
# 编译
zig build

# 将 .zt 文件编译为 HTML（默认）
./zig-out/bin/ztype examples/hello.zt

# 指定输出路径
./zig-out/bin/ztype examples/hello.zt -o output.html

# 输出 PDF
./zig-out/bin/ztype examples/hello.zt -o report.pdf -f pdf

# 输出 Word (RTF)
./zig-out/bin/ztype examples/hello.zt -o document.rtf -f word

# 调试模式（输出 AST 调试信息）
./zig-out/bin/ztype examples/hello.zt --debug

# 显示帮助
./zig-out/bin/ztype -h

# 运行测试
zig build test
```

## 命令行选项

| 选项 | 说明 |
|------|------|
| `-o`, `--output <path>` | 指定输出文件路径 |
| `-f`, `--format <fmt>` | 输出格式：`html`、`pdf`、`word` |
| `--debug` | 输出 AST 调试信息到 stdout |
| `-h`, `--help` | 显示帮助信息 |

更多说明见 [docs/cli.md](docs/cli.md)。

## 支持的语法

- **元数据块**：`---` 包裹的 YAML 风格键值对
- **标题**：`=` `==` `===` 表示 1–4 级标题
- **脚本块**：`@{ }` 定义变量，`@()` 行内表达式
- **语义块**：`:: figure` `:: code` `:: quote` `:: note` 等
- **列表**：行首 `-` 表示无序列表
- **表格**：`|` 分隔的快速表格
- **页面指令**：`%% pagebreak` 等

## 项目结构

```
ztype/
├── src/
│   ├── main.zig       # CLI 入口
│   ├── lexer.zig      # 词法分析
│   ├── parser.zig     # 语法解析
│   ├── ast.zig        # AST 定义
│   ├── resolver.zig   # 变量解析
│   ├── render/        # 渲染后端
│   │   ├── html.zig   # HTML 输出
│   │   ├── pdf.zig    # PDF 输出
│   │   ├── word.zig   # Word (RTF) 输出
│   │   └── debug.zig  # 调试输出
│   └── util/          # 工具函数
├── docs/
│   └── cli.md         # CLI 用法文档
├── examples/
│   └── *.zt           # 示例文档
└── ideas/             # 设计文档
```

## 技术栈

- **语言**：Zig 0.15+
- **构建**：zig build

## 参考

详细语法与设计说明见 `ideas/` 目录下的文档。
