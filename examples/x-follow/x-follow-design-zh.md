# X Follow Campaign — 工厂 + Clone 设计

> 开发者部署工厂合约，A 通过工厂创建 campaign（免 gas），B 在子合约中领取关注奖励（免 gas）。三方激励模型：开发者靠每次 claim 的手续费获利，A 不用懂合约即可获得粉丝，B 关注即赚钱无需支付 gas。

---

## 1. 概述

### 1.1 三方模型

| 角色 | 做什么 | 收益 |
|------|--------|------|
| **开发者** | 部署工厂 + implementation，设定 protocolFee，预充 relayer vault | 每次 claim 收手续费 |
| **A（Campaign 创建者）** | 在工厂调 createDeal()，存入预算 | 无需部署合约或支付 gas |
| **B（关注者）** | 在 X 上关注目标账号，在子合约调 claim() | 赚取固定 USDC 奖励，零 gas 成本 |

### 1.2 架构

```
XFollowFactory（开发者部署一次）
  │  ├── implementation: XFollowCampaign（逻辑合约）
  │  ├── protocolFee, feeCollector（→ 开发者）
  │  ├── trustedForwarder（ERC2771，所有子合约共享）
  │  ├── requiredSpec, platformSigner（共享配置）
  │  └── relayer vault 为 A + B 的 gasless 交易提供 gas（开发者预充）
  │
  ├── createDeal() → Clones.clone(impl) + initialize()
  │     └── XFollowCampaign（子合约 1，A₁ 的 campaign）
  │           ├── claim() → B₁ 获得 dealIndex 0
  │           ├── claim() → B₂ 获得 dealIndex 1
  │           └── withdrawRemaining()
  │
  ├── createDeal() → clone + initialize
  │     └── XFollowCampaign（子合约 2，A₂ 的 campaign）
  └── ...
```

### 1.3 要点

- **继承链：** `XFollowFactory` 与 `XFollowCampaign` 都是完整的 `IDeal → DealBase` 合约；factory 负责入口与索引，child 负责实际 campaign 执行
- **Clone 模式：** EIP-1167 最小代理。所有子合约共享 implementation 字节码，各自有独立 storage
- **Gasless：** 工厂设置 `trustedForwarder` → 子合约继承 → A 的 createDeal 和 B 的 claim() 均通过 relayer 免 gas。Gas 由开发者的 relayer vault 支付
- **生命周期：** `createDeal()` → 子合约直接进入 OPEN（无 TESTING 阶段）
- **自动注册：** 工厂 emit `SubContractCreated(address subContract)` → 平台监听工厂事件 → 自动发现并注册子合约
- **身份：** Binding Attestation（platformSigner 验签）为 B 的强制要求
- **协议费：** 按 claim 收取，从 campaign 预算扣除 → 开发者的 feeCollector
- **失败限制：** `MAX_FAILURES = 3`，每地址每 campaign
- **重入保护：** `claim()`、`onVerificationResult()`、`resetVerification()`、`withdrawRemaining()` 均带 `nonReentrant` 修饰符（自定义 `_lock` 模式的 reentrancy guard）

---

## 2. 合约结构

### 2.1 XFollowFactory

```solidity
contract XFollowFactory is DealBase {

    // ===================== 不可变量 =====================

    address public immutable implementation;     // XFollowCampaign 逻辑合约
    address public immutable FEE_COLLECTOR;      // 开发者的费用接收地址
    uint96  public immutable PROTOCOL_FEE;       // 每次 claim 的手续费（如 10000 = 0.01 USDC）
    address public immutable REQUIRED_SPEC;      // XFollowVerifierSpec 地址
    address public immutable PLATFORM_SIGNER;    // Binding Attestation 签名者
    address public immutable TRUSTED_FORWARDER;  // ERC2771 转发器（A + B 免 gas）
    address public immutable FEE_TOKEN;          // USDC 地址

    // ===================== 事件 =====================

    /// @dev 协议级事件，定义在 IDeal 中。平台监听此事件自动注册子合约。
    event SubContractCreated(address indexed subContract);

    // ===================== 函数 =====================

    /// @notice A 创建 campaign。一笔 tx 完成 Clone + initialize。
    function createDeal(
        uint96  grossAmount,
        address verifier,
        uint96  verifierFee,
        uint96  rewardPerFollow,
        uint256 sigDeadline,
        bytes calldata sig,
        uint64 target_user_id,
        uint48  deadline
    ) external returns (address campaign);
}
```

### 2.2 XFollowCampaign（子合约 / Implementation）

```solidity
contract XFollowCampaign is DealBase, ERC2771Mixin {

    // ===================== initialize() 设置 =====================

    address public factory;              // 父工厂
    address public partyA;               // campaign 创建者
    address public verifier;
    uint96  public rewardPerFollow;
    uint96  public verifierFee;
    uint48  public deadline;
    uint96  public budget;               // 剩余未锁定预算
    uint32  public pendingClaims;
    uint32  public completedClaims;
    uint32  public verifierTimeoutCount;
    uint256 public signatureDeadline;
    uint64  public target_user_id;
    bytes   public verifierSignature;
    bool    public closed;               // true = CLOSED

    // ===================== 工厂配置（initialize 时传入并存储） =====================

    // FEE_COLLECTOR, PROTOCOL_FEE, REQUIRED_SPEC, PLATFORM_SIGNER, feeToken
    // 由工厂在 initialize() 时传入并存储在 campaign storage 中

    // ===================== Per-Claim =====================

    struct Claim {
        address claimer;
        uint48  timestamp;
        uint8   status;              // VERIFYING(0) / COMPLETED(2) / REJECTED(3) / TIMED_OUT(4) / INCONCLUSIVE(5)
        string  follower_username;
    }

    mapping(uint256 => Claim) internal claims;
    mapping(address => bool)  public claimed;
    mapping(address => uint8) public failCount;
}
```

---

## 3. 函数参考

### 3.1 XFollowFactory 函数

| 方法 | 调用者 | 说明 |
|------|--------|------|
| `constructor(impl, feeCollector, protocolFee, spec, registry, forwarder, feeToken)` | 开发者 | 部署工厂，设置共享配置 |
| `createDeal(grossAmount, verifier, verifierFee, rewardPerFollow, sigDeadline, sig, target_user_id, deadline)` | A（免 gas） | Clone impl → initialize → 转 USDC 到子合约 → emit SubContractCreated。返回子合约地址 |

### 3.2 XFollowCampaign 函数

| 方法 | 调用者 | 说明 |
|------|--------|------|
| `initialize(...)` | 仅工厂 | 设置 campaign 参数并立即进入 OPEN。仅可调用一次，仅工厂可调 |
| `claim(userId, bindingSig)` | 任何 B（免 gas） | 验证 Binding Attestation。从预算锁定 claimCost。发出 VerificationRequested。返回 dealIndex |
| `onVerificationResult(dealIndex, 0, result, reason)` | Verifier | result>0 → 付款给 B；result<0 → 奖励+协议费退回预算，failCount++；result==0 → 全额退回预算 |
| `resetVerification(dealIndex, 0)` | 任何人 | VERIFICATION_TIMEOUT 后。全额 claimCost 退回预算。verifierTimeoutCount++，emit VerifierTimeout |
| `withdrawRemaining()` | A | CLOSED 且 pendingClaims==0 时。budget → A |

### 3.3 查询函数

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `claimCost()` | `uint96` | rewardPerFollow + verifierFee + PROTOCOL_FEE |
| `campaignStatus()` | `uint8` | OPEN(0) / CLOSED(1) |
| `dealStatus(dealIndex)` | `uint8` | VERIFYING(0) / VERIFIER_TIMED_OUT(1) / COMPLETED(2) / REJECTED(3) / TIMED_OUT(4) / INCONCLUSIVE(5) / NOT_FOUND(255) |
| `canClaim(addr)` | `bool` | addr 是否可 claim |
| `failures(addr)` | `uint8` | 失败次数 |
| `remainingSlots()` | `uint256` | budget / claimCost |

### 3.4 IDeal 接口

| 方法 | 说明 |
|------|------|
| `name()` | `"X Follow Campaign"` |
| `description()` | Campaign 描述 |
| `tags()` | `["x", "follow"]` |
| `version()` | `"5.0"` |
| `instruction()` | A 和 B 的 Markdown 操作指南 |
| `requiredSpecs()` | `[REQUIRED_SPEC]`（initialize 时存储） |
| `verificationParams(dealIndex, 0)` | specParams = abi.encode(follower_user_id, target_user_id) |
| `requestVerification(dealIndex, 0)` | 始终 revert — 由 claim() 自动触发 |
| `phase(dealIndex)` | 0=不存在，2=活跃，3=成功，4=失败 |
| `dealExists(dealIndex)` | claim 是否存在 |

---

## 4. 验证系统

### 4.1 EIP-712 签名（per-campaign）

TYPEHASH：
```
Verify(uint64 targetUserId,uint256 fee,uint256 deadline)
```

A 在调用 `createDeal()` 前向 verifier 请求签名。工厂将签名传递给子合约的 `initialize()`，在其中验证。

约束：`sigDeadline >= campaignDeadline`。

### 4.2 specParams（per-claim）

```solidity
specParams = abi.encode(
    uint64 follower_user_id,   // 来自 Binding Attestation（claim 参数）
    uint64 target_user_id     // campaign 配置
)
```

### 4.3 链下验证流程

```
Verifier 收到 notify_verify（dealIndex = claim，verificationIndex = 0）
  │
  ├── 0. 读取 dealStatus(dealIndex) — 仅在 VERIFYING(0) 时继续
  ├── 1. 读取 verificationParams(dealIndex, 0) → 解码 specParams
  ├── 2. 双源关注检查（twitterapi.io + twitter-api45）
  ├── 3. 合并：任一关注 → 1，未关注 → 重试 → -1 或 1，均出错 → 0
  ├── 4. 再次读取 dealStatus(dealIndex) — 仍必须是 VERIFYING(0)
  └── 5. reportResult(campaign, dealIndex, 0, result, reason, expectedFee)
```

---

## 5. 交易流程

```mermaid
sequenceDiagram
    participant Dev as 开发者
    participant A as Campaign 创建者 (A)
    participant P as SyncTx 平台
    participant B as 关注者 (B)
    participant Fac as XFollowFactory
    participant C as XFollowCampaign（子合约）
    participant V as Verifier
    participant PS as PlatformSigner

    Note over Dev: 一次性设置
    Dev->>Dev: 部署 XFollowCampaign（implementation）
    Dev->>Dev: 部署 XFollowFactory(impl, feeCollector, protocolFee,<br/>spec, registry, forwarder, feeToken)
    Dev->>Dev: 为 relayer vault 充值 gas 费用
    Dev->>P: 在平台注册工厂

    Note over A,Fac: Campaign 创建（通过 relayer 免 gas）

    A->>P: 🟣 request_sign(verifier, {target_user_id}, deadline)
    P-->>V: 异步消息
    V->>P: 回复 {accepted, fee, sig}
    P-->>A: 异步消息

    Note over A: 🟢 USDC.approve(factory, grossAmount)
    A->>Fac: 🟢 createDeal(grossAmount, verifier, verifierFee,<br/>rewardPerFollow, sigDeadline, sig, target_user_id, deadline)
    Note over Fac: 1. Clone implementation → 子合约地址<br/>2. USDC.transferFrom(A → 子合约, grossAmount)<br/>3. child.initialize(params)<br/>4. initialize 中验证签名<br/>🔵 SubContractCreated(child)
    Note over P: 平台监听工厂事件<br/>→ 自动注册子合约
    A->>P: 🟣 report_transaction(tx_hash, chain_id)

    Note over B,C: 领取阶段（通过 relayer 免 gas）

    Note over B: 1. 完成 Twitter 认证，获取 Binding Attestation
    Note over B: 2. 在 X 上关注 target_user_id
    B->>C: 🟡 canClaim(B.address) → true
    B->>C: 🟢 claim() → dealIndex
    Note over C: 读取 R.usernameOf[B] → 未绑定则 revert<br/>从预算锁定 claimCost<br/>🔵 DealCreated(dealIndex, [B], [verifier])<br/>🔵 VerificationRequested(dealIndex, 0, verifier)
    B->>P: 🟣 notify_verifier(verifier, campaign, dealIndex, 0)
    P-->>V: 异步消息

    V->>C: 🟡 verificationParams(dealIndex, 0)
    Note over V: 双源关注检查

    V->>C: 🟢 reportResult(campaign, dealIndex, 0, result, reason, expectedFee)

    alt result > 0 — 已关注
        Note over C: reward → B，verifierFee → V<br/>protocolFee → 开发者 FeeCollector<br/>🔵 DealPhaseChanged(dealIndex, 3)
    else result < 0 — 未关注
        Note over C: reward → 预算，verifierFee → V<br/>protocolFee → 预算，failCount[B]++<br/>🔵 DealPhaseChanged(dealIndex, 4)
    else result == 0 — 不确定
        Note over C: claimCost → 预算<br/>🔵 DealPhaseChanged(dealIndex, 4)
    end

    Note over A,C: 提取阶段（deadline 到期后）

    A->>C: 🟢 withdrawRemaining()
    Note over C: budget → A
```

---

## 6. 状态机与转换

### 6.1 Campaign 状态

| 代码 | 状态 | 含义 |
|------|------|------|
| 0 | OPEN | 接受 claim（未过 deadline，预算 ≥ claimCost） |
| 1 | CLOSED | 不接受新 claim。待处理的验证继续解决 |

> 无 TESTING 状态 — `createDeal()` 直接初始化为 OPEN。
> CLOSED 在 deadline 到达或预算耗尽时自动触发（作为副作用）。

### 6.2 Per-Claim `dealStatus(dealIndex)`

| 代码 | 状态 | 存储/派生 | 含义 |
|------|------|---------|------|
| 0 | VERIFYING | 存储 | 等待 verifier |
| 1 | VERIFIER_TIMED_OUT | 派生 | 超过 VERIFICATION_TIMEOUT。`reportResult()` 不再接受，只能调用 `resetVerification()` |
| 2 | COMPLETED | 存储 | B 已收款 |
| 3 | REJECTED | 存储 | 未关注，奖励已退回 |
| 4 | TIMED_OUT | 存储 | resetVerification 后，claimCost 已退回 |
| 5 | INCONCLUSIVE | 存储 | 不确定结果，claimCost 全额退回 |
| 255 | NOT_FOUND | — | Claim 不存在 |

### 6.3 Per-Claim `phase(dealIndex)`

| dealStatus | phase | 名称 |
|------------|-------|------|
| NOT_FOUND | 0 | NotFound |
| VERIFYING / VERIFIER_TIMED_OUT | 2 | Active |
| COMPLETED | 3 | Success |
| REJECTED / TIMED_OUT / INCONCLUSIVE | 4 | Failed |

### 6.4 状态转换图

```mermaid
flowchart TD
    subgraph "Campaign"
        OPEN["OPEN<br/>接受 claim"]
        CLOSED["CLOSED<br/>不接受新 claim"]

        OPEN -->|"过了 deadline"| CLOSED
        OPEN -->|"预算 < claimCost<br/>且 pendingClaims == 0"| CLOSED
        CLOSED -->|"pendingClaims == 0<br/>A: withdrawRemaining()"| DONE["预算 → A"]
    end

    subgraph "Per-Claim（dealIndex）"
        VERIFYING["0 VERIFYING"]
        VTO["1 VERIFIER_TIMED_OUT<br/>（派生）"]
        COMPLETED["2 COMPLETED ✅"]
        REJECTED["3 REJECTED ❌"]
        TO["4 TIMED_OUT ⏰"]
        INCONCLUSIVE["5 INCONCLUSIVE ❓"]

        VERIFYING -->|"result > 0"| COMPLETED
        VERIFYING -->|"result < 0"| REJECTED
        VERIFYING -->|"result == 0"| INCONCLUSIVE
        VERIFYING -->|"超时"| VTO
        VTO -->|"resetVerification()"| TO
    end
```

### 6.5 事件

| 操作 | 事件 |
|------|------|
| `createDeal()` | `SubContractCreated(child)`（工厂，协议级） |
| `claim()` | `DealCreated` → `DealStatusChanged(0)` → `DealPhaseChanged(2)` → `VerificationRequested` |
| `onVerificationResult(>0)` | `VerificationReceived` → `DealStatusChanged(2)` → `DealPhaseChanged(3)` |
| `onVerificationResult(<0)` | `VerificationReceived` → `DealStatusChanged(3)` → `DealPhaseChanged(4)` |
| `onVerificationResult(==0)` | `VerificationReceived` → `DealStatusChanged(5)` → `DealPhaseChanged(4)` |
| `resetVerification()` | `VerifierTimeout` → `DealStatusChanged(4)` → `DealPhaseChanged(4)` |

### 6.6 Claim 资格

```
campaign CLOSED          → CampaignNotOpen
claimed[B]               → AlreadyClaimed
failCount[B] >= 3        → MaxFailures
Binding Attestation 无效  → InvalidBindingSignature
budget < claimCost       → 自动关闭 → CLOSED
有待处理 claim            → PendingClaim
否则                      → 可 claim
```

---

## 7. Gasless 架构

### 7.1 设置

```
开发者部署：
  1. SyncTxForwarder（ERC2771 信任转发器）
  2. XFollowCampaign implementation（含 ERC2771Mixin）
  3. XFollowFactory(impl, ..., trustedForwarder = forwarder)
  4. 为 relayer vault 充值（gas 预算）

所有子合约在 initialize() 时调用 _initForwarder() 设置 trustedForwarder。
```

### 7.2 谁支付 Gas

| 操作 | Tx 发送者 | Gas 由谁支付 |
|------|----------|-------------|
| A: createDeal | Relayer（meta-tx） | 开发者的 vault |
| B: claim | Relayer（meta-tx） | 开发者的 vault |
| B: notify_verifier | 平台 MCP 调用 | 无 gas（链下） |
| Verifier: reportResult | Verifier signer EOA | Verifier（自有 gas） |
| A: withdrawRemaining | Relayer（meta-tx） | 开发者的 vault |

### 7.3 经济模型

```
开发者每次 claim 收入 = PROTOCOL_FEE
开发者每次 claim 成本 = B 的 claim() meta-tx gas + A 的摊销创建成本
净利润              = PROTOCOL_FEE - gas 成本
```

开发者设置 PROTOCOL_FEE 需足以覆盖 gas + 利润空间。

---

## 8. 资金流向

### 8.1 Campaign 创建

```
A approve USDC 给工厂。
工厂：USDC.transferFrom(A → 子合约, grossAmount)
child.initialize()：budget = grossAmount
无预收协议费 — 按 claim 收取。
```

### 8.2 每次 Claim 成本

```
claimCost = rewardPerFollow + verifierFee + PROTOCOL_FEE
每次 claim() 从 budget 锁定 claimCost。
```

### 8.3 验证结果 → 资金分配

| 结果 | 奖励 | Verifier 费用 | 协议费 | 预算变化 |
|------|------|--------------|--------|---------|
| 通过 (>0) | → B | → Verifier | → FeeCollector | — |
| 失败 (<0) | → 预算 | → Verifier | → 预算 | +rewardPerFollow + protocolFee |
| 不确定 (0) | → 预算 | → 预算 | → 预算 | +claimCost |
| 超时 | → 预算 | → 预算 | → 预算 | +claimCost |

### 8.4 Campaign 结束

```
deadline 到期 + pendingClaims == 0 后：
  budget → A（通过 withdrawRemaining()）
```

---

## 9. 验证清单

### 9.1 Factory.createDeal

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | `rewardPerFollow > 0` | InvalidParams |
| 2 | `deadline > block.timestamp` | InvalidParams |
| 3 | `verifier != address(0)`，是合约 | VerifierNotContract |
| 4 | `target_user_id > 0` | InvalidParams |
| 5 | `grossAmount >= claimCost`（至少可 claim 1 次） | InvalidParams |
| 6 | Clone implementation → 子合约 | — |
| 7 | `USDC.transferFrom(A → 子合约, grossAmount)` | TransferFailed |
| 8 | `child.initialize(params)` | — |
| 9 | Emit `SubContractCreated(child)` | — |

### 9.2 Campaign.initialize

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | 调用者是工厂 | NotFactory |
| 2 | 尚未初始化 | AlreadyInitialized |
| 3 | `sigDeadline >= deadline` | SignatureExpired |
| 4 | Verifier spec 匹配 + EIP-712 签名有效 | InvalidVerifierSignature |
| 5 | 设置所有参数，budget = grossAmount，状态 = OPEN | — |

### 9.3 Campaign.claim

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | 未关闭，未过 deadline | CampaignNotOpen |
| 2 | `budget >= claimCost` | 自动关闭 |
| 3 | `!claimed[sender]` | AlreadyClaimed |
| 4 | `failCount[sender] < MAX_FAILURES` | MaxFailures |
| 5 | Binding Attestation 有效（platformSigner 验签） | InvalidBindingSignature |
| 6 | 无待处理 claim | PendingClaim |
| 7 | 锁定 claimCost，pendingClaims++ | — |

### 9.4 Campaign.onVerificationResult

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | `msg.sender == verifier` | NotVerifier |
| 2 | Claim 状态 == VERIFYING | InvalidStatus |
| 3 | 分配资金，更新计数器，检查自动关闭 | — |

### 9.5 Campaign.withdrawRemaining

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | `sender == partyA` | NotPartyA |
| 2 | Campaign 已 CLOSED | NotClosed |
| 3 | `pendingClaims == 0` | PendingClaims |
| 4 | `budget > 0` | NoFunds |

---

## 10. 常量

| 常量 | 值 | 位置 | 说明 |
|------|---|------|------|
| `VERIFICATION_TIMEOUT` | 30 分钟 | Campaign | 每个 claim 的 verifier 响应时限 |
| `MAX_FAILURES` | 3 | Campaign | 每地址最大失败次数 |
| `MIN_PROTOCOL_FEE` | 10,000（0.01 USDC） | Factory | 部署时的最低协议费 |
