# MoonKCP 重复查重与边界说明

- 查重日期：2026-10-13
- 候选方向：MoonBit 实现 KCP v1 兼容可靠数据报状态机
- 候选仓库名：`LuoYunxin1/moon-kcp`（本地选定；远程创建前仍须核验账号、权限与名称）
- 上游行为参照：[`skywind3000/kcp`](https://github.com/skywind3000/kcp/tree/8004f7eba5d1bf33f0691eef5f887f2cd3140cb5)，固定版本 `8004f7eba5d1bf33f0691eef5f887f2cd3140cb5`，MIT

## 候选指纹

MoonKCP 的中心能力是 KCP v1 的线协议与状态机兼容，而不是泛化的“可靠 UDP”。核心模型包含会话 conversation id、PUSH/ACK/WASK/WINS 命令、序号与 UNA、发送/接收窗口、ACK 列表、分片重组、RTT/RTO、超时及快速重传，以及调用方驱动的 input/update/flush/check 生命周期。网络收发由宿主提供；项目不拥有 socket，不实现 QUIC、SCTP、加密、通用 RPC、游戏服务或新的拥塞控制算法。

预期下游至少分属三类：

1. 游戏或实时交互运行时：通过数据报送达有序控制事件或可靠状态更新。
2. RPC、远程管理与隧道组件：为消息调用提供 KCP 对端兼容的可靠传递层。
3. 边缘遥测、设备配置代理或离线链路代理：在丢包网络中传输分片消息并在应用层恢复顺序。

这些场景共用同一 KCP 状态机和 wire contract；它们不是三个互不相关的功能承诺。

## 检索范围与方法

1. 阅读 `moonbit-hackathon-builder/references/project-registry.md` 全部永久保留指纹，并检查其中的 MoonWire 等相邻项目；注册表中已完成、reserved 的方向均按保留处理。
2. 已运行 MoonBit `moon search --limit 100 --json` 相关检索，共记录 29 个查询；直接 KCP 词项没有返回可确认的 KCP 实现。该结果只说明所查索引和词项的返回情况，不单独构成放行依据。
3. 按用户要求纳入 MoonCakes、MoonBit GitHub 仓库及相邻实现语义审查。对相邻仓库不止看项目名，也核阅 README、公开 API、源码和测试所表达的协议能力。
4. 对照固定上游 KCP v1 的 README、头文件、实现与测试，将功能边界限定为 wire/state-machine 兼容；本项目计划独立以 MoonBit 重写，不复制上游实现源码。
5. 候选比较期间同时完成了其他问题域的筛选：XPath 1.0 因 `cravan371/xpath-evaluator` 直接重合而淘汰；稀疏凸 QP 因 `moon-certified` 已包含一般线性约束凸 QP/KKT 能力而淘汰。最终选择 KCP 不是因没有同名包，而是依据功能语义对比后仍保留的协议差异。

## 相邻项目逐项审阅

| 项目 | 已记录的源码/文档范围 | 重合与边界判断 |
|---|---|---|
| [MoonQuic](https://github.com/moonbitstack/moonquic/tree/09887f8b78ec32a11b2077e6de1ddff0e3bc746e) | README、QUIC recovery 相关实现/API 与测试；固定提交 `09887f8b78ec32a11b2077e6de1ddff0e3bc746e` | 包含 RTT/PTO、恢复与拥塞控制等可靠传输子系统能力；其协议由 QUIC 规定，不提供 KCP v1 的控制块、segment 编码或 KCP 对端 wire compatibility。属于相邻而非可替代 KCP 实现。 |
| [rtc.mbt](https://github.com/moonbit-community/rtc.mbt/tree/0d823a5d5da14eae526b37b9dae905f1e3bc72ff) | README、SCTP association/fragmentation/retransmission 代码与测试；固定提交 `0d823a5d5da14eae526b37b9dae905f1e3bc72ff` | 有可靠数据传递和重传的语义交集，但协议、association 模型及线格式属于 SCTP/RTC；不兼容 KCP v1。 |
| ROS2 / RTPS MoonBit 相关实现 | 注册表与候选审阅中涉及的 reader、可靠分发与 RTPS 行为 | 服务于 RTPS reader/distribution 语义，并非可嵌入的 KCP v1 状态机；不声称无算法交集。 |
| MoonWire | 永久注册表中的项目描述及 framing 边界 | 提供分帧，不承担可靠传输、ACK、重传或有序交付。MoonKCP 不会将其扩展成传输层，也不将 framing 算作差异化。 |
| `chensuiyi/packet` | README、解析/统计 API 与所审阅测试 | 属于数据包解析与统计；审阅范围内未见 KCP 式可靠有序交付状态机。 |
| `skywind3000/kcp` | 固定提交 README、头文件、C 实现及测试 | 这是本移植的协议行为参照，也是直接功能来源，不是 MoonBit 生态替代项。项目必须清楚标注移植关系、MIT 许可证与未实现边界。 |

## 判定与限制

**在已记录检索范围内未发现成熟直接替代。** 这不是对整个 MoonBit 生态或所有未索引代码作绝对断言。MoonBit 包索引、GitHub 检索和仓库快照均可能不完整；查重结果仅支持当前有边界的候选判断。

MoonKCP 与上游 KCP 在功能语义上必然高度重合，因为目标是实现同一协议，而非声称新发明可靠传输算法。可验证的项目价值应来自对 KCP v1 wire/state-machine 行为的忠实 MoonBit 实现、清晰的 sans-I/O API、完整测试及与固定 C/Go 参考实现的差分/互通验证。单凭“MoonBit 实现”或“sans-I/O”本身不能宣称生态首创。

## 来源与许可证处理

参考上游：[`skywind3000/kcp`](https://github.com/skywind3000/kcp/tree/8004f7eba5d1bf33f0691eef5f887f2cd3140cb5)，MIT。计划保留上游版权/许可证归属说明；移植将独立编写 MoonBit 代码，仅依据协议与行为测试，不复制来源不明或许可证不兼容的代码。最终归属文件应明确标注上游项目、固定参考版本、实现差异和未支持行为。