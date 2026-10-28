# 微观排版

Ztype 的排版引擎不是"按宽度换行"，而是按 TeX 的模型分行：把文本切成 run、glue 与
discretionary 三种 token，再用动态规划在全部候选断点中选择总 demerit 最小的一组。

## 分行的代价模型

```
demerit = (1 + 可伸缩度) × badness + penalty (+ brokenpenalty)
badness = ((版心宽度 − 自然宽度) / 版心宽度)² × 10000
```

最后一行只惩罚"太宽"，不惩罚"太短"（末行允许参差）。

| 惩罚 | 值 | 说明 |
|------|----|------|
| `hyphen_penalty` | 50 | 断词处断行 |
| `broken_penalty` | 50 | 连续两行都以断词结尾（TeX 的 brokenpenalty） |
| `forbidden_penalty` | 10000 | 禁止断行的位置 |

## 两端对齐

对齐时把多余宽度按每个 glue 的**可伸缩度比例**分配，而不是平均分摊——这样词间空格
不会被拉得比句末空格更夸张。分配结果限制在 `[-0.30 × 字号, +0.15 × 字号]` 之间，
超出时宁可让行尾参差，也不产生"河流"。

拉伸的基准是**该段实际可用的宽度**，而不是整栏宽度：引用块、清单、提示框、参考文献
的悬挂缩进都会缩小 measure，避免缩进文本被拉到越过栏右边界。表格单元格按列宽减去
左右内边距计算。

## 断词

Knuth–Liang 模式匹配，模式表来自 TeX 的 `hyph-en-us.pat`：

- 奇数强度为可断点，偶数强度禁止断词。
- 词首至少保留 2 个字母，词尾至少保留 3 个（`min_left` / `min_right`）。
- 少于 6 个字母的词不断词（`min_word`）。
- 连字符复合词的每一部分独立断词，已有连字符本身是断点（`exhyphenpenalty` = 100）。
- 断点只在真正断行的位置显示连字符（discretionary），未断行时不可见。
- 标题、代码块、表格单元格关闭断词。
- CJK 文本不断词。

元数据 `hyphen: false` 可整体关闭。

代码块中的行超过 measure 时按字形宽度折行，优先在空白处断开，找不到空白才硬折；
等宽字体不加字距、不断词。

## 行距模型

基线到基线的距离取 TeX 的公式：

```
span = max(leading, 上一行的深度 + 本行的高度 + lineskip)
```

单行比 leading 矮时仍按现代排版在行盒内居中（首行从行盒顶部起算），只有行盒相碰
（混合字号、行内公式、下伸部）时才产生 `lineskip` 的额外间隙。换页或换栏后上一行的
深度不再参与计算。

## 字距（tracking）

`tracking` 是字形之间的固定空隙，按字形数计入 token 的自然宽度，因此断行时同样参与
badness 计算。PDF 用 `Tc`（character spacing）绘制，HTML 用 `letter-spacing`。
标题用 `heading_tracking`（默认 `-0.012em`，大字号视觉收紧），代码块与表格不追加字距。

## 孤行 / 寡行 / club

- **孤行**：本页只能放下段落的第一行 → 整段移到下一页。
- **寡行**：段落最后一行会单独出现在下一页 → 少放一行，让末两行一起走。
- **club**：只有两行留在本页而段落更长 → 整段移到下一页。

行数由元数据 `orphans` / `widows` 配置（默认各 2）。判定顺序是：先算本页能放下多少行，
再应用孤行/寡行约束——放不下 `orphans` 行就整段移走，剩余部分不足 `widows` 行就少放几行。

标题至少与后一行内容留在同一页（keep-with-next）。

## spacefactor

TeX 的 spacefactor：句末标点（`.` `!` `?` `:` `;` `…` `”` `’`）之后的空格宽度为
`1.25 ×` 基准 glue，可伸缩度也更高。元数据 `spacefactor: false` 可关闭。

## 字距调整（kerning）

按字体度量表（Times、Helvetica）逐对字符计算 kerning，单位为 units/1000 em。
等宽字体与 CJK 字体不做 kerning。HTML 后端同时输出 `font-kerning: normal`。

## 悬挂标点与光学对齐

行首的标点（引号、破折号、CJK 标点）突入左边距，使视觉左边界对齐而不是数学左边界：

```
“这是引用，标点突入页边距。”
```

行尾的标点同样计入悬挂宽度，对齐时不会把它算进自然宽度。HTML 使用
`hanging-punctuation: first`。

## CJK 禁则（kinsoku）

行首禁则：`、。！？：；…` 等不能出现在行首。
行末禁则：`“‘（【《` 等不能出现在行末。

CJK 字符之间不产生自然宽度的 glue（可伸缩度 1.0），因此两端对齐时 CJK 段落同样
能均匀拉伸，同时保持禁则限制。

## HTML 中的对应 CSS

```css
body { font-kerning: normal; font-variant-numeric: oldstyle-nums;
       font-optical-sizing: auto; hanging-punctuation: first;
       text-wrap: pretty; text-rendering: optimizeLegibility; }
p    { hyphens: auto; overflow-wrap: break-word; text-wrap: pretty; }
h1-h6{ text-wrap: balance; break-after: avoid; hyphens: manual; }
@media print { p, li, blockquote { orphans: 2; widows: 2; } }
```

## 智能标点

见 [syntax.md](syntax.md) 的"智能排版"一节。引号方向依赖前一个字符的上下文
（`State`），跨片段保持状态，因此 `"a"` 后接 `"` 会正确判断开引号/闭引号。
