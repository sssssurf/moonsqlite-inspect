# MoonBit 十一月黑客松复审与验收对照

## 初审要求

十一月官网将报名和资格审核列为两个阶段。报名需要公开仓库和一页项目说明，未通过可修改原表，审核滚动进行。章程第 4.1 节要求先查 Mooncakes，存在功能高度重合的成熟实现时优先考虑复用、维护、扩展或协作。仍采用独立项目时，申报书需解释具体缺口与独立实现理由。 [十一月赛事页](https://moonbitlang.github.io/Hackathon2026/#process) · [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

章程第 5.1 节列出项目名称、介绍、方向与通用性、至少三个完整使用场景、核心范围、原创或参考方式、上游出处及许可证，以及公开 GitHub 仓库和至少十个有效提交。项目说明应由参赛者亲自撰写，体现问题、方案及边界。十一月官网的报名和验收日期以官方通知为准。已收到的初审邮件给出的 `2026-11-30` 是修改本项目报名材料的期限。 [赛事章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)

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
| 公开仓库与开发记录 | `0.2.0` 加入历史视图，`0.3.0` 加入逐提交导出、采集清单验证和 JS 读取优化。 [默认分支提交](https://github.com/sssssurf/moonsqlite-inspect/commits/main/) |
| 安装、示例、核心测试与 CI | README 提供从源码构建与复现命令。CI 运行四个 MoonBit 后端、格式检查、SQLite 对照与打包。测试覆盖原始 cell 来源、缩小再增长、全部历史批次与逐对结果、仅溢出页更新、输出上限和错配清单。 [README](../README.md) · [CI](https://github.com/sssssurf/moonsqlite-inspect/actions/workflows/ci.yml) |
| 许可与依赖来源 | 项目新增代码 Apache-2.0，上游同为 Apache-2.0，由 Mooncakes 安装。示例数据库由 SQLite 生成。 [项目许可](../LICENSE) · [上游许可](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.1/LICENSE) |
| Mooncakes 发布 | `0.3.0` 已生成本地分发包。Mooncakes 公开发布和从注册表安装复验待完成 |

### 性能与边界

`0.3.0` 在 JS 上把传给上游 WAL 校验器的帧切片改为共享只读视图。以 `01b8477` 为对照，同一份 12,000 次提交的 WAL 各运行五次，最新快照读取中位耗时从 562.0 ms 降到 400.1 ms，峰值内存中位值从 87.0 MiB 降到 81.5 MiB，输出逐项相同。结果来自本机 Windows、Node.js 24.13.0 和 SQLite 3.45.3。 [基准脚本](../scripts/benchmark.py)

命令行每批返回最多 8 MiB 的 JSON，默认比较 32 个相邻提交，超限可缩小范围或改用库的逐行访问接口。历史比较以普通 rowid 表的相同存储定义为前提。采集清单校验文件是否与受控采集时一致，采集顺序由 SQLite 读事务保护。 [历史导出和采集约定](wal-timeline.md)
