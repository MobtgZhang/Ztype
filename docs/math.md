# 数学公式排版

数学语法以 **Typst** 为主要参考（`$ x = y + 1 $`、`$ sum_(i=1)^n i $`），同时兼容常见
的 LaTeX 命令别名（`\frac`、`\int`、`\alpha`、`begin{pmatrix}` 等）。

## 行内与独立公式

```
行内公式 $a^2 + b^2 = c^2$ 与正文混排。

$$ \int_0^\infty e^{-x^2} dx = frac(1, 2) sqrt(pi) $$
```

- `$ ... $`：行内公式，分数与上下标使用缩小字号。
- `$$ ... $$`：独立公式，居中，自动编号 `(1)`、`(2)`……
- `:: math` 块等价于 `$$`，可带 `caption` 与 `id`。

独立公式在版心内居中，编号贴右边缘。`tag(...)` 用自定义标签替代编号，`notag()` 关闭编号：

```
$$ x = y tag(7) $$
$$ a = b notag() $$
```

## 上下标与限

Typst 用 `_` 和 `^`，LaTeX 的 `_{...}`、`^{...}` 同样可用：

```
$x_i$          $x^2$          $x_(i+1)^n$
$sum_(i=1)^n i$
```

display 模式下的大运算符（`sum` `prod` `int` `bigcup` …）默认把上下限居中放置
（Typst 行为）；用 `scripts(...)` 强制改为行内式上下标，用 `limits(...)` 强制改为上下限。

## 分数、根式、二项式

```
$frac(1, 2)$          $dfrac(1, 2)$        $tfrac(1, 2)$
$sqrt(x)$             $sqrt[3]{x}$         $root(3)(x)$
$binom(n, k)$
```

- `dfrac` 强制 display 分数，`tfrac` 强制文本分数。
- 分数线厚度、轴高、分子分母字号按字号比例计算（Typst 常数）。

## 矩阵与分段

```
$mat(a, b; c, d)$                 无定界符
$mat(p)(a, b; c, d)$              p = ( )，b = [ ]，bra = { }，v = | |，c = ceil，f = floor
$pmatrix(a, b; c, d)$             圆括号
$bmatrix$ `Bmatrix` `vmatrix` `Vmatrix`
$cases(x, y; 1, 2)$               左花括号分段
$stack(a, b, c)$                  垂直堆叠
$vec(a, b)$                       列向量（单参数时是向量重音）
```

行分隔符用 `;` 或 `\`，列分隔符用 `,` 或 `&`。`align` 环境使用交替对齐。

## 定界符

`(`、`[`、`{` 包裹的内容自动作为可拉伸定界符，随内容高度放大：

```
$( frac(1, 2) )$      $[ x ]$      $| x |$
$delim(p)$            $delim(none)$
```

## 重音与样式

```
$hat(x)$ $bar(x)$ $tilde(x)$ $dot(x)$ $ddot(x)$ $vec(x)$ $check(x)$ $breve(x)$
$widehat(x)$ $widetilde(x)$ $overline(x)$ $underline(x)$ $cancel(x)$
```

宽重音（`widehat`、`widetilde`）在基座足够宽时拉伸。

字体样式（Typst 名称与 LaTeX 别名都可用）：

```
$mathbb R$   $mathcal L$   $mathfrak H$   $mathbf x$   $mathsf y$   $mathtt z$   $mathrm{word}$
$text(文字)$   $boldsymbol(alpha)$   $emph(x)$
```

无括号的样式名作用于紧随其后的原子：`mathbb R` 等价于 `mathbb(R)`。

## 符号

希腊字母、运算符、箭头、集合与逻辑符号按名称解析：

```
$alpha beta gamma delta$   $pm times div cdot approx equiv leq geq$
$sum prod int oint coprod bigcup bigcap$   $to implies mapsto leftrightarrow$
$in notin subset cup cap emptyset forall exists$   $infty partial nabla hbar ell$
$ldots cdots vdots ddots$   $angle therefore because propto parallel mid$
```

## 间距

```
$ x thin y $      $ x medium y $     $ x thick y $
$ x quad y $      $ x qquad y $      $ x space(0.5) y $
```

`thin` = 3/18 em，`medium` = 5/18 em，`thick` = 6/18 em（TeX 的 mu）。

## 函数名

`sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh log ln exp lim liminf limsup max min sup inf gcd lcm deg mod arg dim`
在 display 模式下默认带上下限（`lim_(x->0)`），可用 `scripts` 关闭。

## 断行与对齐

display 公式超出版心时按 Typst 的 `align` 行为断行：只在**顶层关系符**（`=` `<=` `>=`
`equiv` `approx` `to` …）处切段，每段以关系符开头，各行共用同一个对齐点。对齐点由
各行的"左侧伸出量"与"右侧宽度"共同决定——首段是前缀（关系符之前的内容）时它会把
对齐点向右推。行距沿用 TeX 的 `max(leading, 上一行深度 + 本行高度 + lineskip)`。

`tag(...)` 从公式主体中分离出来，贴到版心右边缘，并停在**最后一行**的基线上；
自动编号同样落在最后一行。`notag()` 关闭编号。

## 盒模型

每个公式节点被测量为 `(宽度, 上升高度, 下降深度)` 的盒子，并附带斜体补偿
（italic correction）。排版常数（轴高、规则厚度、脚本比例、重音最小字号、
大运算符缩放、单元格内边距）与 Typst 一致，全部以当前字号的倍数表示。

## 输出

| 后端 | 数学呈现 |
|------|----------|
| HTML | MathML（浏览器原生渲染），公式编号为 `.equation .number` |
| PDF | 使用数学字形度量直接绘制文本与规则线 |
| Word (RTF) | 近似为文本 + `^()`/`_()` 上下标 |

## 已知限制

- PDF 后端不嵌入字体，依赖阅读器内置的 Symbol 字体映射。
- RTF 没有真正的分式与矩阵布局，只能近似。
- HTML 的 MathML 渲染质量取决于浏览器。
