# Ztype 包管理器

## 概述

Ztype 包管理器允许你创建可复用的 .zt 库，并在其他文档中导入使用。

## 包配置 (zt.toml)

在项目根目录创建 `zt.toml` 定义包信息：

```toml
[package]
name = "my-project"
version = "0.0.1"
description = "项目描述"

[dependencies]
# 依赖其他包（未来支持）
# common-components = "0.1.0"
```

## 导入 .zt 文件

### 1. 本地文件引入 (%% include)

在文档中任意位置使用页面指令引入外部 .zt 文件：

```
%% include chapters/intro.zt
%% include components/header.zt
```

路径相对于当前 .zt 文件所在目录解析。

### 2. 包内组件

若项目有 `zt.toml`，可将可复用组件放在 `lib/` 目录：

```
my-project/
├── zt.toml
├── lib/
│   ├── header.zt
│   ├── footer.zt
│   └── components/
│       └── note.zt
└── doc.zt
```

在 `doc.zt` 中：

```
%% include lib/header.zt
%% include lib/components/note.zt
```

## 命令

| 命令 | 说明 |
|------|------|
| `ztype init` | 初始化项目，创建 zt.toml |
| `ztype add <package>` | 添加依赖（规划中） |
| `ztype install` | 安装依赖到 .ztype/packages（规划中） |

## 脚本块中的 import()

脚本块中的 `import()` 用于导入**数据文件**（JSON、TOML），与 `%% include` 不同：

```
@{
  let data = import("data/stats.json")
  let config = import("config.toml")
}
```

- `%% include` → 引入 .zt 排版内容
- `import()` → 引入 JSON/TOML 数据（供脚本使用）
