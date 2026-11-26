# MoonBit 十一月黑客松验收对照

项目已通过报名初审。按参赛者于 2026-11-26 提供的验收指南，初审通过后持续开发并将成果上传 GitHub，验收前无需再填表。交付范围为 SQLite WAL 提交历史、行级差异和受控离线采集。 [十一月赛事页](https://moonbitlang.github.io/Hackathon2026/)

## 初审要求

十一月官网将报名和资格审核列为两个阶段。报名需要公开仓库和一页项目说明，未通过可修改原表，审核滚动进行。章程第 4.1 节要求先查 Mooncakes，存在功能高度重合的成熟实现时优先考虑复用、维护、扩展或协作。仍采用独立项目时，申报书需解释具体缺口与独立实现理由。 [十一月赛事页](https://moonbitlang.github.io/Hackathon2026/#process) · [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

章程第 5.1 节列出项目名称、介绍、方向与通用性、至少三个完整使用场景、核心范围、原创或参考方式、上游出处及许可证，以及公开 GitHub 仓库和至少十个有效提交。十一月官网的最终验收日期以官方通知为准。 [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

## 生态项目对照

原方案的 SQLite 文件读取、溢出记录解码和最新已提交 WAL 快照已由 `prowk/moonsqlitefile` 覆盖。其公开 API 还提供帧与提交边界，以及最新快照的页来源。此次实际接入其 Mooncakes 0.8.1 版本。旧的最新快照命令改用上游 `RangeWalSource`，历史路径用上游 `inspect_wal_source`、`open_range_source` 和 `BTreeCursor` 读帧、目录与记录。独立实现的是跨提交页版本索引、按指定提交读取、带两侧来源的行级归并和离线采集复现。 [MoonSQLiteFile 0.8.1](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.1) · [上游 WAL 文档](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.1/docs/wal.md)

| 场景 | MoonSQLiteFile 0.8.1 可提供的能力 | MoonSQLite Inspect 此次新增 |
| --- | --- | --- |
| 客户端状态两次提交中先变更再恢复 | 列出两个提交的帧边界，查看最新状态 | 对同一份 WAL 比较 `0→1` 与 `1→2`。示例中两次都找到 `rowid=41` 的变化，`0→2` 的净差异为空 |
| 同一行在中间版本和最新版本位于不同页镜像 | 查看最新快照的页来源和记录位置 | 在任意已索引提交按 rowid 直接定位，返回基线页或确切 WAL 帧、页号与文件偏移。也可对历史表按 rowid 范围分批续传 |
| 数据文件增长后缩小并再次增长 | 恢复最新提交的有效页集合 | 为每次提交维护逻辑页数与历史页版本有效期，检查每次增长所需的页覆盖，并保留缩小前的可读视图 |

历史视图需要在同一 WAL 周期的首次写入前保留已 checkpoint 的基线。上游最新快照使用同一次静态采集的主文件与 WAL。备份基线、逐提交检查和差异输出组成独立的历史工作流，适合在下游交付。所需历史页可能在 checkpoint 后被覆盖。 [历史视图的采集约定](wal-timeline.md) · [SQLite WAL 格式](https://sqlite.org/walformat.html)

## 验收证据

以下按本期指南的九条顺序列出对应证据。 [官网验收标准](https://moonbitlang.github.io/Hackathon2026/#entry-rules)

| 验收项 | 证据或状态 |
| --- | --- |
| 1. MoonBit 为主，`moonc` 至少 0.10.16 | 核心库和 CLI 用 MoonBit 实现。0.5.1 发布检查使用 1.0.0-rc1，CI 在检查、构建和测试前核对编译器版本。 [发布检查](https://github.com/sssssurf/moonsqlite-inspect/actions/runs/45821395923) · [CI 配置](../.github/workflows/ci.yml) |
| 2. 公开仓库与清晰提交 | 默认分支为公开的 `main`。历史记录涵盖历史视图、逐提交导出、采集清单、误报修复和历史点查与分页。 [公开仓库](https://github.com/sssssurf/moonsqlite-inspect) · [提交记录](https://github.com/sssssurf/moonsqlite-inspect/commits/main/) |
| 3. 源代码结构与核心功能 | 历史页索引、行级差异和来源、连续提交比较分模块实现。CLI 通过库访问指定历史版本，Python 脚本负责生成受控采集和测试数据。 [页版本索引](../timeline.mbt) · [行读取与比较](../history_rows.mbt) · [连续比较](../series.mbt) · [设计和边界](wal-timeline.md) |
| 4. README 与复现 | README 说明用途、包安装、库 API、CLI 命令、输入约定和复现步骤。 [README](../README.md) |
| 5. CI 覆盖检查、构建和测试 | CI 对 JS、native、Wasm、Wasm GC 运行 `moon check`、`moon build` 和 `moon test`，并验证格式、SQLite 对照、分发包和 README 示例。 [CI 配置](../.github/workflows/ci.yml) · [运行记录](https://github.com/sssssurf/moonsqlite-inspect/actions/workflows/ci.yml) |
| 6. 可运行示例 | `wal_demo.py` 生成基线、WAL 和清单。干净分发包执行 README 的 14 条命令并验证 10 份 JSON，包括历史点查、分页续传和版本差异。 [示例步骤](../README.md#reproduce-a-wal-history) · [复现检查](../scripts/verify_readme.py) |
| 7. 核心路径测试 | 四后端各通过 9 项库测试和 7 项独立消费测试。SQLite 对照核验 6,012 条基础记录、100 个多页历史快照和 120 组差异，另覆盖损坏尾部、回滚、溢出、采集错配和输出限额。 [SQLite 对照](../scripts/sqlite_oracle.py) · [多页工作负载](../scripts/history_stress.py) |
| 8. Mooncakes 发布 | `0.5.1` 已发布，独立工程从注册表安装后四个后端各通过 7 项接口测试，实际上传包的 SHA-256 与注册表一致。 [公开版本](https://mooncakes.io/docs/sssssurf/moonsqlite-inspect) · [安装验证](../scripts/verify_distribution.py) |
| 9. OSI 许可证与上游来源 | 项目和 MoonSQLiteFile 0.8.1 均为 Apache-2.0。`moon.mod` 固定上游版本，通过其公开接口复用读取和 WAL 校验能力。 [OSI 许可条目](https://opensource.org/license/apache-2.0) · [项目许可](../LICENSE) · [上游许可](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.1/LICENSE) |

代码、测试与文档使用 AI 辅助开发。页版本有效期、缩小后的页失效、二分选择页面和读事务保护采集顺序均有实现及对照检查。 [设计和边界](wal-timeline.md)

`0.5.1` 在 MoonBit 编译器 1.0.0-rc1、Node.js 24、SQLite 3.46.1 的线上环境通过完整 CI。四个后端各通过 9 项库测试和 7 项独立消费测试，README 的 14 条命令完整运行并核对 10 份 JSON。新版工具链弃用了原有集合写入方法和 JSON 嵌套参数，本版修复兼容性并保留清单的八层嵌套上限与重复键拒绝。Windows 上使用 0.10.21 从注册表安装并通过独立消费测试。 [发布源码](https://github.com/sssssurf/moonsqlite-inspect/tree/6c338931eeb45fcdb56450d6b0b9e4f3a2ac5bd9) · [代码 CI](https://github.com/sssssurf/moonsqlite-inspect/actions/runs/45821395923)

### 重现验收检查

```sh
moon update
for target in js native wasm wasm-gc; do
  moon check --target "$target" --deny-warn
  moon build --target "$target" --frozen --deny-warn
  moon test --target "$target" --frozen --deny-warn
done
moon fmt --check
python -B scripts/sqlite_oracle.py
python -B scripts/history_stress.py
python -B scripts/verify_distribution.py
python -B scripts/verify_readme.py
```

`sqlite_oracle.py` 使用 SQLite 生成数据并查询结果，核对 6,012 条基础读取记录，另检查历史快照、批次续传、BLOB 溢出、回收后再增长和损坏尾部。历史路径在三种页大小和三种文本编码的九种组合下逐版本、逐比较核对。

`0.4.0` 增加历史行与任意两版本差异的逐条接口，保留数组接口。`wal-rows`、`wal-changes` 和 `wal-series` 共用 8 MiB UTF-8 JSON 输出限额，超限或后续记录损坏时无标准输出。测试覆盖单个超大 BLOB、多行累计、JSON 转义、多字节文本和接近限额的成功结果。 [逐条接口与边界](wal-timeline.md#visit-historical-rows-and-arbitrary-pairs)

`history_stress.py` 用两个固定随机种子和两种页大小，生成四份各含 24 次提交的多页数据库采集。逐一核对 100 个历史快照、120 组相邻及跨版本比较和原始页来源。工作负载含索引写入、B-tree 扩展、溢出页、完整及保存点回滚、自动回收后再增长，以及目标表无变化的旁表提交。`verify_distribution.py` 解压实际分发包，在新工程中运行七个公开 API 测试，覆盖四个后端。它验证主动停止、历史点查、单元来源与从首个未接收行号续传。

使用 `python -B scripts/verify_distribution.py --registry --version 0.5.1` 从 Mooncakes 安装发布版本后执行同一组公开 API 检查。

### 2026-11-23 复查与修复

复查覆盖输入采集顺序、WAL 截断与回滚、页版本来源、行级比较、输出限额、跨后端安装和 README 复现。复现到一个结果错误。存储为 IEEE NaN 的 REAL 使用普通浮点相等判断时不等于自身，导致同一文件或同一版本与自身比较也报告更新。`0.4.1` 将存储值比较中的 NaN 视为相等，保留精确有限数值比较和存储类型的区分。

回归样例从 SQLite 数据库生成，再注入三种明确的 NaN 位模式，使用 SQLite 自身的完整性检查确认可读。它检查自身比较、旁表提交、相邻版本、NaN 变为有限数值、NaN 变为存储 NULL，以及 INTEGER 变为 REAL。原始 NaN 的读取保留 REAL 类型，SQL 层投影成 NULL 的行为在文档中单独说明。独立消费工程新增第六项公开 API 回归，并在四个后端执行。 [数值样例](../scripts/float_fixture.py) · [比较规则](wal-timeline.md)

新增 `verify_readme.py` 在解压后的干净分发包中执行 README 历史示例的全部命令，检查七份 JSON 结果，避免仅在已有构建目录里验证。CLI 的 `--help` 与 `-h` 正常显示说明并成功退出。 [示例复现检查](../scripts/verify_readme.py)

### 验收演示与技术说明

1. 按 README 生成采集，先运行 `wal-verify`，展示五个版本及清单校验结果。基线必须早于本周期首次写入，SHA-256 用于确认采集字节未变化，读事务负责保护采集顺序。
2. 比较 `0→1`、`1→2`，分别展示 `rowid=41` 的更新，再比较 `0→2` 得到空差异。这样说明最新快照或净差异无法替代中间提交的检查。
3. 展示记录的页号、页内偏移和 WAL 帧来源。该位置指向存放单元的页，溢出 BLOB 可以使用其他页，页被重写也不等于这一行的值改变。
4. 演示 `wal-series` 的 `next_from` 续传。逐条接口的回调返回 `false` 表示主动停止。访问函数返回 `true` 才表示整个访问完成，某个版本对的 `CommitFinished` 表示该版本对完整。命令行缓冲有界输出，发生错误时不输出半份 JSON。
5. 说明使用边界。历史路径支持普通 rowid 表及相同存储表定义，输入需满足采集约定，记录、扫描和输出均有预算。项目复用上游 WAL 校验与记录游标，独立新增的是历史页索引、多版本行差异和来源工作流。

### 0.5.0 历史点查与范围分页

用 `wal-row` 在修订 1 直接查看 `rowid=41` 的 `waiting` 值和 WAL 帧。用 `wal-range` 以两个 64 位边界作为查询范围，在修订 3 输出前两行，再把 `next_rowid` 的值 `9223372036854775807` 用作起点取得最后一行。范围游标按行数和 8 MiB 输出预算返回完整页面。它利用现有 B-tree 区间游标，历史索引为游标提供对应提交的页字节。 [优化规划](optimization-plan-0.5.0.md) · [查询与续传约定](wal-timeline.md#seek-rows-at-a-revision)

在相同 8,000 行采集上，将旧版全表导出后筛选与历史点查各运行 7 次。目标行和来源完全一致，中位耗时从 233.0 ms 降到 83.5 ms，峰值 RSS 中位值从 81.9 MiB 降到 43.9 MiB。结果针对所记录的 Windows 工作负载。 [复现步骤与环境](optimization-plan-0.5.0.md#本地基准)

### 性能与边界

`0.3.0` 在 JS 上把传给上游 WAL 校验器的帧切片改为共享只读视图。以 `01b8477` 为对照，同一份 12,000 次提交的 WAL 各运行五次，最新快照读取中位耗时从 562.0 ms 降到 400.1 ms，峰值内存中位值从 87.0 MiB 降到 81.5 MiB，输出逐项相同。结果来自本机 Windows、Node.js 24.13.0 和 SQLite 3.45.3。 [基准脚本](../scripts/benchmark.py)

历史行、点查、范围、两版本差异和逐提交导出各返回最多 8 MiB 的 JSON，批量命令默认比较 32 个相邻提交。历史范围在行数或字节数限额到达时返回续传行号，单条超限时可改用库接口。输出限额之外仍有页索引和记录解码的内存开销。历史比较以普通 rowid 表的相同存储定义为前提。采集清单校验文件是否与受控采集时一致，采集顺序由 SQLite 读事务保护。 [历史导出和采集约定](wal-timeline.md)
