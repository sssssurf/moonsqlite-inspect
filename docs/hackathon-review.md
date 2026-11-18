# MoonBit 十一月黑客松验收对照

项目已通过报名初审，依据参赛者于 2026-11-18 提供的组委会通知。交付范围为 SQLite WAL 提交历史、行级差异和受控离线采集。本文件记录实现、发布与复现证据。

## 初审要求

十一月官网将报名和资格审核列为两个阶段。报名需要公开仓库和一页项目说明，未通过可修改原表，审核滚动进行。章程第 4.1 节要求先查 Mooncakes，存在功能高度重合的成熟实现时优先考虑复用、维护、扩展或协作。仍采用独立项目时，申报书需解释具体缺口与独立实现理由。 [十一月赛事页](https://moonbitlang.github.io/Hackathon2026/#process) · [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

章程第 5.1 节列出项目名称、介绍、方向与通用性、至少三个完整使用场景、核心范围、原创或参考方式、上游出处及许可证，以及公开 GitHub 仓库和至少十个有效提交。十一月官网的最终验收日期以官方通知为准。 [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

## 生态项目对照

原方案的 SQLite 文件读取、溢出记录解码和最新已提交 WAL 快照已由 `prowk/moonsqlitefile` 覆盖。其公开 API 还提供帧与提交边界，以及最新快照的页来源。此次实际接入其 Mooncakes 0.8.1 版本。旧的最新快照命令改用上游 `RangeWalSource`，历史路径用上游 `inspect_wal_source`、`open_range_source` 和 `BTreeCursor` 读帧、目录与记录。独立实现的是跨提交页版本索引、按指定提交读取、带两侧来源的行级归并和离线采集复现。 [MoonSQLiteFile 0.8.1](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.1) · [上游 WAL 文档](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.1/docs/wal.md)

| 场景 | MoonSQLiteFile 0.8.1 可提供的能力 | MoonSQLite Inspect 此次新增 |
| --- | --- | --- |
| 客户端状态两次提交中先变更再恢复 | 列出两个提交的帧边界，查看最新状态 | 对同一份 WAL 比较 `0→1` 与 `1→2`。示例中两次都找到 `rowid=41` 的变化，`0→2` 的净差异为空 |
| 同一行在中间版本和最新版本位于不同页镜像 | 查看最新快照的页来源和记录位置 | 按提交打开任意已索引视图，将其 B-tree 单元定位到基线文件或确切的 WAL 帧，附页号与文件偏移 |
| 数据文件增长后缩小并再次增长 | 恢复最新提交的有效页集合 | 为每次提交维护逻辑页数与历史页版本有效期，检查每次增长所需的页覆盖，并保留缩小前的可读视图 |

历史视图需要在同一 WAL 周期的首次写入前保留已 checkpoint 的基线。上游最新快照使用同一次静态采集的主文件与 WAL。备份基线、逐提交检查和差异输出组成独立的历史工作流，适合在下游交付。所需历史页可能在 checkpoint 后被覆盖。 [历史视图的采集约定](wal-timeline.md) · [SQLite WAL 格式](https://sqlite.org/walformat.html)

## 验收证据

官网要求 MoonBit 为主、公开且有可追踪记录、能运行、有实质工程贡献、许可证清楚，参赛者能够解释技术决策。章程第 5.1 节进一步列出可复现的 README、CI 检查/构建/测试、至少一个可运行示例、核心路径测试和 Mooncakes 发布。 [官网验收标准](https://moonbitlang.github.io/Hackathon2026/#entry-rules) · [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

| 验收项 | 证据或状态 |
| --- | --- |
| MoonBit 实现与实质贡献 | `timeline.mbt` 实现页版本索引和历史视图，`history_rows.mbt` 实现行级对比与来源，`series.mbt` 复用同一索引导出连续提交。受控采集脚本持有基线读事务并生成 SHA-256 清单。 [页版本索引](../timeline.mbt) · [批量导出](../series.mbt) · [采集脚本](../scripts/wal_capture.py) |
| 公开仓库与开发记录 | `0.2.0` 加入历史视图，`0.3.0` 加入逐提交导出与采集清单，`0.3.2` 加入可复现的分发验证和历史编码矩阵。 [默认分支提交](https://github.com/sssssurf/moonsqlite-inspect/commits/main/) |
| 安装、示例、核心测试与 CI | README 包含包安装与 CLI 运行示例。CI 运行四个后端、格式检查、SQLite 对照与独立分发包验证。覆盖原始 cell 来源、缩小再增长、仅溢出页更新、输出超限和错配清单。 [README](../README.md) · [CI](https://github.com/sssssurf/moonsqlite-inspect/actions/workflows/ci.yml) |
| 许可与依赖来源 | 项目新增代码 Apache-2.0，上游同为 Apache-2.0，由 Mooncakes 安装。示例数据库由 SQLite 生成。 [项目许可](../LICENSE) · [上游许可](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.1/LICENSE) |
| Mooncakes 发布 | 模块 `sssssurf/moonsqlite-inspect@0.3.2`。`verify_distribution.py --registry` 从注册表安装并执行公开 API 测试。 [发布入口](https://mooncakes.io/docs/sssssurf/moonsqlite-inspect) |

### 重现验收检查

```sh
moon update
moon check --target all --deny-warn
moon build --target all --frozen --deny-warn
moon test --target all --frozen --deny-warn
moon fmt --check
python -B scripts/sqlite_oracle.py
python -B scripts/verify_distribution.py
```

`sqlite_oracle.py` 使用 SQLite 生成数据并查询结果，核对 6,012 条基础读取记录，另检查历史快照、批次续传、BLOB 溢出、回收后再增长和损坏尾部。历史路径在三种页大小和三种文本编码的九种组合下逐版本、逐比较核对。`verify_distribution.py` 解压实际分发包，在新工程中运行三个公开 API 测试，覆盖四个后端，并验证访问顺序、主动停止和错误边界。

使用 `python -B scripts/verify_distribution.py --registry --version 0.3.2` 从 Mooncakes 安装发布版本后执行同一组公开 API 检查。

### 性能与边界

`0.3.0` 在 JS 上把传给上游 WAL 校验器的帧切片改为共享只读视图。以 `01b8477` 为对照，同一份 12,000 次提交的 WAL 各运行五次，最新快照读取中位耗时从 562.0 ms 降到 400.1 ms，峰值内存中位值从 87.0 MiB 降到 81.5 MiB，输出逐项相同。结果来自本机 Windows、Node.js 24.13.0 和 SQLite 3.45.3。 [基准脚本](../scripts/benchmark.py)

命令行每批返回最多 8 MiB 的 JSON，默认比较 32 个相邻提交，超限可缩小范围或改用库的逐行访问接口。历史比较以普通 rowid 表的相同存储定义为前提。采集清单校验文件是否与受控采集时一致，采集顺序由 SQLite 读事务保护。 [历史导出和采集约定](wal-timeline.md)
