# Realm 全功能一键网络转发管理,纯脚本快速搭建中转服务器

[中文](README.md) | [English](README_EN.md) | [端口流量狗脚本介绍](port-traffic-dog-README.md)

---

> 🚀 **网络转发管理脚本** - 同步官方 Realm 最新版全部功能，网络链路测试，端口流量犬，保持极简本质,可视化规则操作提高效率，纯脚本构建网络转发服务

## 脚本界面预览

<details>
<summary>点击查看界面截图</summary>

### xwPF.sh realm转发脚本

![81ce7ea9e40068f6fda04b66ca3bd1ff.gif](https://i.mji.rip/2025/12/12/81ce7ea9e40068f6fda04b66ca3bd1ff.gif)

### 端口流量犬

![cc59017896d277a8b35109ae44eac977.gif](https://i.mji.rip/2025/12/12/cc59017896d277a8b35109ae44eac977.gif)

### 中转网络链路测试脚本
```
===================== 网络链路测试功能完整报告 =====================

✍️ 参数测试报告
─────────────────────────────────────────────────────────────────
  本机（客户端）发起测试
  目标: 92.112.*.*:5201
  测试方向: 客户端 ↔ 服务端 
  单项测试时长: 30秒
  系统：Debian GNU/Linux 12 | 内核: 6.1.0-35-cloud-amd64
  本机：cubic+htb（拥塞控制算法+队列）
  TCP接收缓冲区（rmem）：4096   131072  6291456
  TCP发送缓冲区（wmem）：4096   16384   4194304

🧭 TCP大包路由路径分析（基于nexttrace）
─────────────────────────────────────────────────────────────────
 AS路径: AS979 > AS209699
 运营商: Private Customer - SBC Internet Services
 地理路径: 日本 > 新加坡
 地图链接: https://assets.nxtrace.org/tracemap/b4a9ec9f-8b69-5793-a9b6-0cd0981d8de0.html
─────────────────────────────────────────────────────────────────
🌐 BGP对等体关系分析 (基于bgp.tools)
─────────────────────────────────────────────────────────────────
上游节点(Upstreams) :9 │ 对等节点(Peers):44

AS979       │AS21859     │AS174       │AS2914      │AS3257      │AS3356      │AS3491      
NetLab      │Zenlayer    │Cogent      │NTT         │GTT         │Lumen       │PCCW        

AS5511      │AS6453      │AS6461      │AS6762      │AS6830      │AS12956     │AS1299      
Orange      │TATA        │Zayo        │Sparkle     │Liberty     │Telxius     │Arelion     

AS3320      
DTAG        
─────────────────────────────────────────────────────────────────
 图片链接：https://bgp.tools/pathimg/979-55037bdd89ab4a8a010e70f46a2477ba7456640ec6449f518807dd2e
─────────────────────────────────────────────────────────────────
⚡ 网络链路参数分析（基于hping3 & iperf3）
─────────────────────────────────────────────────────────────────────────────────
    PING & 抖动           ⬆️ TCP上行带宽                     ⬇️ TCP下行带宽
─────────────────────  ─────────────────────────────  ─────────────────────────────
  平均: 72.3ms          220 Mbps (27.5 MB/s)             10 Mbps (1.2 MB/s)           
  最低: 69.5ms          总传输量: 786 MB             总传输量: 35.4 MB        
  最高: 75.9ms          重传: 0 次                    重传: 5712 次             
  抖动: 6.4ms       

─────────────────────────────────────────────────────────────────────────────────────────────
 方向       │ 吞吐量                   │ 丢包率                   │ 抖动
─────────────────────────────────────────────────────────────────────────────────────────────
 ⬆️ UDP上行 │ 219.0 Mbps (27.4 MB/s)    │ 2021/579336 (0.35%)       │ 0.050 ms                 
 ⬇️ UDP下行 │ 10.0 Mbps (1.2 MB/s)      │ 0/26335 (0%)              │ 0.040 ms                 

─────────────────────────────────────────────────────────────────
测试完成时间: 2025-08-28 20:12:29 | 脚本开源地址：https://github.com/zywe03/realm-xwPF
```

</details>

## 快速开始

### 一键安装

```bash
wget -qO- https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install
```

### 网络受限使用加速源,一键安装

```bash
wget -qO- https://v6.gh-proxy.org/https://raw.githubusercontent.com/zywe03/realm-xwPF/main/xwPF.sh | sudo bash -s install
```
若加速源失效，可多次重试或更换其他具有内置加速功能的代理源

## 无法联网的离线安装

<details>
<summary>点击展开离线安装方法</summary>

适用于完全无法连接网络

**1. 在有网络的设备上下载以下文件**

- **主脚本**：[xwPF.sh](https://github.com/zywe03/realm-xwPF/raw/main/xwPF.sh)
- **模块文件**（全部需要）：https://github.com/zywe03/realm-xwPF/tree/main/lib

- **Realm 程序**（根据系统架构选择）：

| 架构 | 适用系统 | 下载链接 | 检测命令 |
|------|----------|----------|----------|
| x86_64 | 常见64位系统 | [realm-x86_64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/latest) | `uname -m` 显示 `x86_64` |
| aarch64 | ARM64系统 | [realm-aarch64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/latest) | `uname -m` 显示 `aarch64` |
| armv7 | ARM32系统（如树莓派） | [realm-armv7-unknown-linux-gnueabihf.tar.gz](https://github.com/zhboner/realm/releases/latest) | `uname -m` 显示 `armv7l` 或 `armv6l` |

**2. 将文件放置到目标服务器**

```
/usr/local/bin/            ← 脚本安装目录（固定路径）
├── xwPF.sh                ← 主脚本
└── lib/                   ← 创建 lib 子目录
    ├── core.sh
    ├── rules.sh
    ├── server.sh
    ├── realm.sh
    └── ui.sh

~/                         ← Realm 压缩包放在任意其他位置
└── realm-xxx.tar.gz
```

**3. 执行离线安装**

```bash
chmod +x /usr/local/bin/xwPF.sh
ln -sf /usr/local/bin/xwPF.sh /usr/local/bin/pf
bash /usr/local/bin/xwPF.sh
```

选择 **1. 安装配置** 后：
1. 提示 **是否更新脚本？(y/N):** → 直接回车跳过（离线无法更新）
2. 提示 **离线安装realm输入完整路径(回车默认自动下载):** → 输入 Realm 压缩包的完整路径即可

</details>


## ✨ 核心特性

- **原生Realm全功能** - 同步支持最新版realm的所有原生功能
  - tcp/udp协议
  - ws/wss/tls 加密解密并转发
  - 单中转多出口
  - 多中转单出口
  - Proxy Protocol
  - MPTCP
  - 指定中转机的某个入口 IP,或指定某个出口 IP (适用于多IP情况和一入口多出口和多入口一出口的情况)
  - 指定中转机的入口网卡,或指定某个出口网卡 (适用于多网卡情况)
  - 更多玩法参考[zhboner/realm](https://github.com/zhboner/realm)
- **多发行版支持** - 适配 Debian/Ubuntu、Alpine、CentOS/RHEL 系列，自动识别包管理器与 init 系统（systemd / OpenRC）
- **快速体验** - 一键安装快速轻量上手体验网络转发
- **智能检测** - 自动检测系统架构、端口冲突,连接可用性

- **搭建隧道** - 双端realm架构支持 TLS,ws,wss,搭建隧道
- **负载均衡** - 支持轮询、IP哈希等策略，可配置权重分配
- **故障转移** - 使用系统工具,完成自动故障检测,保持轻量化
- **规则备注** - 清晰的备注功能,不再需要额外记忆

- **端口流量犬** - 统计端口流量，控制端口限速，限流，可设置通知方式
- **直观配置系统MPTCP** - 清晰的展示MPTCP界面
- **网络链路脚本** - 测试链路延迟、带宽、稳定性,大包路由情况（基于hping3 & iperf3 & nexttrace & bgp.tools）

- **一键导出** - 打包全部文件为压缩包自由迁移(包括备注等等信息完全迁移)
- **一键导入** - 识别导出的压缩包完成自由迁移
- **一键识别批量导入** 自写realm的规则配置,方便管理和维护自己的规则集
- **完整卸载** - 分阶段全面清理，“轻轻的我走了，正如我轻轻的来”

## 示意图理解不同场景下工作原理(推荐阅读理解)

<details>
<summary><strong>单端realm架构只负责转发（常见）</strong></summary>

中转机安装realm,落地机安装业务软件

中转机realm只负责原模原样把设置的监听IP：端口收到的数据包进行转发到出口机,加密解密由业务软件负责

所以整个链路的加密协议由出口机业务软件决定

![e3c0a9ebcee757b95663fc73adc4e880.png](https://i.mji.rip/2025/07/17/e3c0a9ebcee757b95663fc73adc4e880.png)

</details>

<details>
<summary><strong>双端realm架构搭建隧道</strong></summary>

中转机安装realm,落地机要安装realm和业务软件

在realm和realm之间多套一层realm支持的加密传输

#### 所以中转机realm选择的加密,伪装域名等等,必须与落地机一致,否则无法解密

![4c1f0d860cd89ca79f4234dd23f81316.png](https://i.mji.rip/2025/07/17/4c1f0d860cd89ca79f4234dd23f81316.png)

</details>

<details>
<summary><strong>负载均衡+故障转移</strong></summary>

- 同一端口转发有多个落地机
![a9f7c94e9995022557964011d35c3ad4.png](https://i.mji.rip/2025/07/15/a9f7c94e9995022557964011d35c3ad4.png)

- 前置>多中转>单落地
![2cbc533ade11a8bcbbe63720921e9e05.png](https://i.mji.rip/2025/07/17/2cbc533ade11a8bcbbe63720921e9e05.png)

- `轮询`模式 (roundrobin)

不断切换规则组里的落地机

- `IP哈希`模式 (iphash)

基于源 IP 的哈希值，决定流量走向，保证同一 IP 的请求始终落到同一落地机

- 权重即分配概率

- 故障转移

检测到某个出口故障，暂时移出负载均衡列表，恢复之后会自动添加进负载均衡列表

原生realm暂不支持故障转移

- 脚本的实现原理
```
1. systemd定时器触发 (每4秒)
   ↓
2. 执行健康检查脚本
   ↓
3. 读取规则配置文件
   ↓
4. 对每个目标执行TCP连通性检测
   ├── nc -z -w3 target port
   └── 备用: telnet target port
   ↓
5. 更新健康状态文件（原子更新）
   ├── 成功: success_count++, fail_count=0
   └── 失败: fail_count++, success_count=0
   ↓
6. 判断状态变化
   ├── 连续失败2次 → 标记为故障
   └── 连续成功2次+冷却期120秒(避免抖动频繁切换) → 标记为恢复
   ↓
7. 如有状态变化，创建更新标记文件
```

客户端可使用指令`while ($true) { (Invoke-WebRequest -Uri 'http://ifconfig.me/ip' -UseBasicParsing).Content; Start-Sleep -Seconds 1 }` 或 `while true; do curl -s ifconfig.me; echo; sleep 1; done` 实时监听IP变化情况,确定模式生效

</details>

<details>
<summary>
<strong>双端realm调用系统MPTCP</strong>
</summary>

**Q:MPTCP端点是不是创建一张新的虚拟网卡?**
不是，是告诉MPTCP协议栈：这个IP地址可以用于MPTCP连接指定路径：数据可以通过这个IP地址和对应的网卡传输
建立多路径：让一个TCP连接可以同时使用多个网络路径

**Q:为什么需要同时指定IP和网卡？**
网卡接口：系统需要知道这个IP地址对应哪个物理网卡，用于路由选择
IP地址：MPTCP协议需要知道可以使用哪些IP地址建立子流
192.168.1.100 dev eth0 subflow fullmesh = 告诉MPTCP可以通过eth0网卡的这个IP建立连接
10.0.0.50 dev eth1 subflow fullmesh = 告诉MPTCP可以通过eth1网卡的这个IP建立连接

如果想要更精细的控制，可以考虑：

服务端也设置signal端点：
精细化控制mptcp

</details>

<details>
<summary><strong>端口转发 vs 链式代理(分段代理)</strong></summary>

容易搞混的两个概念

**简单理解**

端口转发只负责把某个端口的流量转发到另一个端口

链式代理是分成了两段代理链,所以又称为分段代理,二级代理（有机会再细讲配置）

**各有各的优点**看使用场景 | 注意有的地区服务器不允许安装代理 | 不过某些场景链式会很灵活

| 链式代理 (Chained Proxy) | 端口转发 (Port Forwarding) |
| :------------------- | :--------------------- |
| 链路的机都要安装代理软件           | 中转机安装转发(不需要安装代理),出口机安装代理        |
| 配置文件复杂度较高            | 配置文件复杂度低（L4层转发）        |
| 会有每跳解包/封包开销          | 原生 TCP/UDP 透传，理论上更快    |
| 出站控制分流更精确（每跳配置出口）    | 难出站控制                  |

</details>

### 依赖工具
原则均优先**Linux 原生轻量化工具**，保持系统干净轻量化

| 工具       | 用途           | 工具        | 用途             |
|------------|----------------|-------------|------------------|
| `curl`     | 下载和IP获取   | `wget`      | 备用下载工具     |
| `tar`      | 解压缩工具     | `unzip`     | ZIP解压缩        |
| `bc`       | 数值计算       | `nc`        | 网络连接测试     |
| `bash /dev/tcp` | 网络连接测试（内置） | `inotify`   | 标记文件         |
| `grep`/`cut` | 文本处理识别 | `jq`        | JSON数据处理     |
| `iproute2` | MPTCP端点管理  | `nftables`  | 端口流量统计     |
| `tc`       | 流量控制限制   |             |                  |

## 文件结构

> 脚本按需索取，其他功能点击对应菜单才会下载

### 使用realm转发核心安装（安装即有）

```
系统文件
├── /usr/local/bin/
│   ├── realm                    # Realm 主程序
│   ├── xwPF.sh                  # 管理脚本入口
│   ├── lib/                     # 模块目录
│   │   ├── core.sh              # 核心工具（系统检测/依赖/网络/验证）
│   │   ├── rules.sh             # 规则管理（规则CRUD/负载均衡/权重）
│   │   ├── server.sh            # 服务器配置（中转/出口交互/MPTCP管理）
│   │   ├── realm.sh             # Realm 安装/配置生成/服务管理
│   │   └── ui.sh                # 交互菜单/状态显示/卸载
│   └── pf                       # 快捷启动命令
│
├── /etc/realm/                  # Realm 配置目录
│   ├── manager.conf             # 状态管理文件
│   ├── config.json              # Realm 工作配置文件
│   └── rules/                   # 转发规则目录
│       ├── rule-1.conf          # 规则1配置
│       └── ...
│
└── /etc/systemd/system/
    └── realm.service            # Realm 主服务文件
```

### 按需下载（点击对应功能时才会下载）

```
故障转移（开启故障转移时下载）
├── /usr/local/bin/xwFailover.sh         # 故障转移管理脚本
├── /etc/realm/health/
│   └── health_status.conf               # 健康状态文件
└── /etc/systemd/system/
    ├── realm-health-check.service       # 健康检查服务
    └── realm-health-check.timer         # 健康检查定时器

端口流量犬（选择端口流量犬时下载）
├── /usr/local/bin/port-traffic-dog.sh   # 端口流量犬脚本
├── /usr/local/bin/dog                   # 快捷启动命令
└── /etc/port-traffic-dog/
    ├── config.json                      # 流量监控配置文件
    ├── traffic_data.json                # 流量数据备份
    ├── notifications/                   # 通知模块目录
    │   └── telegram.sh                  # Telegram通知模块
    └── logs/                            # 日志目录

中转网络链路测试（选择链路测试时下载）
└── /usr/local/bin/speedtest.sh          # 网络链路测试脚本

配置识别导入（选择识别导入时下载）
└── /etc/realm/xw_realm_OCR.sh           # Realm配置识别脚本

MPTCP（启用MPTCP时创建）
└── /etc/sysctl.d/90-enable-MPTCP.conf   # MPTCP系统配置
```

## 🧪 测试

`tests/` 下提供了基于 [ptyunit](https://github.com/fissible/ptyunit) 的自动化测试套件，包含 `lib/*.sh` 纯函数的单元测试，以及通过真实伪终端(PTY)驱动 `xwPF.sh` 交互菜单的界面测试（安装流程、转发规则管理、服务启停等）。

脚本会写入真实系统路径（`/etc/realm`、`/usr/local/bin`、`/etc/systemd/system/...`），因此测试**只在一次性 Docker 容器内运行**，不会在宿主机上执行。本地手动运行和 CI（GitHub Actions）使用完全相同的命令：

```bash
bash tests/run.sh
```

该命令会构建 `tests/Dockerfile` 镜像并在容器中执行完整测试套件（需要本机已安装并运行 Docker）。

当前测试覆盖范围：`core.sh` 的校验函数与传输配置生成、`rules.sh` 的基础规则CRUD、`realm.sh` 的配置生成，以及主菜单/转发配置管理/服务重启停止/离线安装等 TUI 交互流程。MPTCP 管理、负载均衡/权重、Proxy Protocol，以及按需下载的辅助脚本（故障转移、端口流量犬、链路测试、配置识别导入）暂未纳入覆盖范围。

## 🤝 技术支持

- **其他开源项目：** [https://github.com/zywe03](https://github.com/zywe03)
- **介绍主页：** [https://zywe.de](https://zywe.de)
- **问题反馈：** [GitHub Issues](https://github.com/zywe03/realm-xwPF/issues)
- **纯闲聊群** [tg交流群](https://t.me/zywe_chat) 

---

**⭐ 如果这个项目对您有帮助，请给个 Star 支持一下！**

[![Star History Chart](https://api.star-history.com/svg?repos=zywe03/realm-xwPF&type=Date)](https://www.star-history.com/#zywe03/realm-xwPF&Date)