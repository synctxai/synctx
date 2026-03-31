# XFollowDealContract 设计文档

> 合约即 campaign。A 部署并存入预算，任何已认证 TwitterRegistry 的用户均可关注后领取固定奖励。每个 claim 就是一个 dealIndex。全自动，无需协商。

---

## 1. 概述

XFollowDealContract 是一个具体的 DealContract 实现，用于 **"A 为关注 X 上指定账号支付固定奖励"** 的 campaign 场景。

- **继承链：** `IDeal → DealBase → XFollowDealContract`
- **模型：** 一个合约 = 一个 campaign。每个 B 的 `claim()` 创建一个新的 dealIndex
- **验证系统：** 单 verifier（每个 campaign），要求 `XFollowVerifierSpec`
- **支付代币：** USDC
- **标签：** `["x", "follow"]`
- **身份：** `TwitterRegistry` 绑定为强制要求 — 合约在链上读取 `usernameOf[msg.sender]`，未绑定则 revert
- **验证语义：** 验证者检查验证时刻关注关系是否存在。身份由 TwitterRegistry 保证（钱包 ↔ 用户名）
- **链下验证：** 双源并行检查：twitterapi.io + twitter-api45
- **结束条件：** 预算耗尽或截止时间到达 — A 不可提前关闭
- **deadline 约束：** `sigDeadline >= campaignDeadline`
- **协议费：** 按 claim 收取，每次 claim 从预算中扣除（不在创建时预收）
- **失败限制：** `MAX_FAILURES = 3` — B 在此合约中失败 3 次后被封禁

---

## 2. 核心数据结构

### 2.1 合约级存储（Campaign）

```solidity
// ===================== 不可变量 =====================

address public immutable FEE_COLLECTOR;
uint96  public immutable PROTOCOL_FEE;
address public immutable REQUIRED_SPEC;
address public immutable TWITTER_REGISTRY;

// ===================== Campaign 状态 =====================

address public partyA;               // campaign 创建者
address public verifier;             // verifier 合约地址
uint96  public rewardPerFollow;      // 每次关注的固定 USDC 奖励
uint96  public verifierFee;          // 每次验证的费用（从预算扣除）
uint48  public deadline;             // campaign 截止时间（Unix 秒）
uint96  public budget;               // 剩余未锁定 USDC 预算
uint32  public pendingClaims;        // 等待验证的 claim 数
uint32  public completedClaims;      // 已成功验证的 claim 数
uint256 public signatureDeadline;    // verifier 签名到期时间（必须 >= deadline）
string  public target_username;      // 规范化：无 @，全小写
bytes   public verifierSignature;    // EIP-712 签名
bool    public closed;               // A 提取剩余后为 true
```

### 2.2 Per-Claim 存储（每个 claim = 一个 dealIndex）

```solidity
struct Claim {
    address claimer;             // B 的地址
    uint48  timestamp;           // claim 创建时间
    uint8   status;              // VERIFYING / COMPLETED / REJECTED / TIMED_OUT
    string  follower_username;   // claim 时从 TwitterRegistry 读取
}

mapping(uint256 => Claim) internal claims;
mapping(address => bool)  public claimed;      // 成功领取后为 true
mapping(address => uint8) public failCount;    // 失败次数；>= MAX_FAILURES → 封禁
```

---

## 3. 函数参考

### 3.1 Campaign 设置

| 方法 | 参数 | 调用者 | 说明 |
|------|------|--------|------|
| `constructor(...)` | `address feeCollector, uint96 protocolFee, address requiredSpec, address twitterRegistry` | 部署 | 设置不可变量 |
| `createDeal(...)` | `uint96 grossAmount, address verifier, uint96 verifierFee, uint96 rewardPerFollow, uint256 sigDeadline, bytes sig, string target_username, uint48 deadline` | A（仅一次） | 初始化 campaign。`grossAmount` 全额存入作为 budget。要求 `sigDeadline >= deadline` 且 `budget >= claimCost()`。仅可调用一次 |

### 3.2 Claim 操作（每个 claim = 一个 dealIndex）

| 方法 | 参数 | 调用者 | 说明 |
|------|------|--------|------|
| `claim()` | — | 任何 B | B 无需传参。读取 `TwitterRegistry.usernameOf[msg.sender]`。未绑定则 revert，已成功则 revert，失败 ≥ 3 次则 revert。从预算锁定 `claimCost()`。返回 `dealIndex`。发出 VerificationRequested |
| `onVerificationResult(...)` | `uint256 dealIndex, uint256 verificationIndex, int8 result, string reason` | Verifier | result>0 → 付款给 B，claimed[B]=true，completedClaims++；result<0 → 奖励退回预算，failCount[B]++；result==0 → 全部退回预算 |
| `resetVerification(...)` | `uint256 dealIndex, uint256 verificationIndex` | 任何人 | VERIFICATION_TIMEOUT 后重置超时 claim。全额 claimCost 退回预算 |

### 3.3 Campaign 结束

| 方法 | 参数 | 调用者 | 说明 |
|------|------|--------|------|
| `withdrawRemaining()` | — | A | deadline 到期 + pendingClaims==0 后，A 提取剩余预算。closed=true |

### 3.4 查询函数

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `claimCost()` | `uint96` | `rewardPerFollow + verifierFee + PROTOCOL_FEE` |
| `campaignStatus()` | `uint8` | OPEN / EXHAUSTED / EXPIRED / CLOSED |
| `dealStatus(dealIndex)` | `uint8` | Per-claim 状态：VERIFYING / COMPLETED / REJECTED / TIMED_OUT / NOT_FOUND |
| `canClaim(addr)` | `bool` | addr 是否可 claim |
| `failures(addr)` | `uint8` | addr 的失败次数 |
| `remainingSlots()` | `uint256` | `budget / claimCost()` |

### 3.5 继承自 DealBase / IDeal

| 方法 | 说明 |
|------|------|
| `name()` | `"X Follow Deal"` |
| `description()` | Campaign 描述 |
| `tags()` | `["x", "follow"]` |
| `version()` | `"2.0"` |
| `instruction()` | Markdown 操作指南 |
| `requiredSpecs()` | `[XFollowVerifierSpec]` |
| `verificationParams(dealIndex, 0)` | 返回指定 claim 的 verifier + specParams |
| `requestVerification(dealIndex, 0)` | 始终 revert — 验证由 `claim()` 自动触发 |
| `phase(dealIndex)` | 见 Section 6.3 |
| `dealExists(dealIndex)` | claim 是否存在 |

---

## 4. 验证系统

### 4.1 合约结构

```
VerifierSpec ← XFollowVerifierSpec（业务规范）
IVerifier ← VerifierBase ← XFollowVerifier（实例）
XFollowVerifier.spec() → XFollowVerifierSpec
```

### 4.2 EIP-712 签名（per-campaign）

TYPEHASH：
```
Verify(string targetUsername,uint256 fee,uint256 deadline)
```

Verifier 每个 campaign 签名一次。`createDeal` 时检查 `sigDeadline >= campaignDeadline`。

### 4.3 specParams（per-claim）

```solidity
specParams = abi.encode(
    string follower_username,  // claim 时从 TwitterRegistry.usernameOf[claimer] 读取
    string target_username     // campaign 目标账号
)
```

B 不提供任何用户名 — 合约在链上从 TwitterRegistry 读取。

### 4.4 链下验证流程

```
Verifier 服务收到 notify_verify（dealIndex = claim，verificationIndex = 0）
  │
  ├── 0. 读取链上 dealStatus(dealIndex) — 仅在 VERIFYING 时继续
  ├── 1. 读取 verificationParams(dealIndex, 0) → 解码 specParams
  ├── 2. 并行 API 调用：
  │     ├── twitterapi.io: check_follow_relationship
  │     └── twitter-api45: checkfollow.php
  ├── 3. 合并逻辑：
  │     ├── 任一确认关注 → result = 1（通过）
  │     ├── 两者均否定 → 5 秒后重试 → result = -1 或 1
  │     └── 两者均出错 → result = 0（不确定）
  └── 4. reportResult(contract, dealIndex, 0, result, reason, expectedFee)
```

---

## 5. 交易流程

```mermaid
sequenceDiagram
    participant A as Campaign 创建者 (A)
    participant P as SyncTx (MCP)
    participant B as 关注者 (B)
    participant C as Contract（= Campaign）
    participant V as Verifier
    participant R as TwitterRegistry
    participant F as FeeCollector

    Note over A,V: 部署与设置（一次）

    A->>P: 🟣 request_sign(verifier_address, {target_username}, deadline)
    P-->>V: 异步消息
    V->>P: 回复 {accepted, fee, sig}
    P-->>A: 异步消息

    Note over A: 部署 XFollowDealContract(feeCollector, protocolFee, spec, registry)
    Note over A: 🟢 USDC.approve(contract, grossAmount)
    A->>C: 🟢 createDeal(grossAmount, verifier, verifierFee,<br/>rewardPerFollow, sigDeadline, sig, target_username, deadline)
    Note over C: grossAmount → budget<br/>Campaign 状态：OPEN
    A->>P: 🟣 report_transaction(tx_hash, chain_id)

    Note over B,C: 领取阶段（每个 claim = 一个 dealIndex）

    Note over B: 1. 通过 TwitterRegistry 绑定 Twitter
    Note over B: 2. 在 X 上关注 target_username
    B->>C: 🟡 canClaim(B.address) → true
    B->>C: 🟢 claim() → dealIndex
    Note over C: 读取 R.usernameOf[B] → 未绑定则 revert<br/>从预算锁定 claimCost<br/>🔵 DealCreated(dealIndex, [B], [verifier])<br/>🔵 VerificationRequested(dealIndex, 0, verifier)
    B->>P: 🟣 report_transaction + notify_verifier(verifier, contract, dealIndex, 0)
    P-->>V: 异步消息

    V->>C: 🟡 verificationParams(dealIndex, 0)
    Note over V: 双源关注检查

    V->>C: 🟢 reportResult(contract, dealIndex, 0, result, reason, expectedFee)

    alt result > 0 — 已确认关注
        Note over C: reward → B，verifierFee → V，protocolFee → F<br/>claimed[B]=true，completedClaims++<br/>🔵 DealPhaseChanged(dealIndex, 3)
    else result < 0 — 未关注
        Note over C: reward → budget，verifierFee → V，protocolFee → F<br/>failCount[B]++<br/>🔵 DealPhaseChanged(dealIndex, 4)
    else result == 0 — 不确定
        Note over C: claimCost → budget<br/>🔵 DealPhaseChanged(dealIndex, 4)
    end

    Note over A,C: 提取阶段（deadline 到期后）

    A->>C: 🟢 withdrawRemaining()
    Note over C: budget → A，closed = true
```

---

## 6. 状态机与转换

### 6.1 Campaign 状态（`campaignStatus()`）

| 代码 | 状态 | 含义 |
|------|------|------|
| 0 | OPEN | 接受 claim（预算 ≥ claimCost，未过期） |
| 1 | EXHAUSTED | 预算 < claimCost（claim 被拒后可能恢复） |
| 2 | EXPIRED | 已过 deadline，待处理 claim 仍可解决 |
| 3 | CLOSED | A 已提取剩余预算 |

> EXHAUSTED 和 EXPIRED 在运行时派生。存储标志仅有 `closed`。

### 6.2 Per-Claim `dealStatus(dealIndex)`

> 遵循与 XQuoteDealContract 相同的存储+派生模式。存储状态在状态变更时写入。派生状态由存储状态 + 超时条件在运行时计算。`dealStatus()` 不依赖调用者 — 任何人看到的值相同。

| 代码 | 状态 | 存储/派生 | 含义 |
|------|------|---------|------|
| 0 | VERIFYING | 存储 | 等待 verifier 响应，未超时 |
| 1 | VERIFIER_TIMED_OUT | 派生（VERIFYING + 已超时） | Verifier 超期，可调用 `resetVerification()` |
| 2 | COMPLETED | 存储 | 关注已验证，B 已收款 |
| 3 | REJECTED | 存储 | 未检测到关注或不确定，奖励已退回 |
| 4 | TIMED_OUT | 存储（`resetVerification` 后） | Verifier 超时，全额 claimCost 退回预算 |
| 255 | NOT_FOUND | — | Claim 不存在 |

```solidity
function dealStatus(uint256 dealIndex) external view override returns (uint8) {
    Claim storage c = claims[dealIndex];
    if (c.claimer == address(0)) return NOT_FOUND;       // 255

    if (c.status == VERIFYING) {
        if (block.timestamp > uint256(c.timestamp) + VERIFICATION_TIMEOUT) {
            return VERIFIER_TIMED_OUT;                    // 1
        }
        return VERIFYING;                                 // 0
    }
    return c.status;  // COMPLETED(2), REJECTED(3), TIMED_OUT(4)
}
```

### 6.3 Per-Claim `phase(dealIndex)`

> 映射到 IDeal 的统一 phase：0=NotFound，1=Pending，2=Active，3=Success，4=Failed，5=Cancelled。
> Claim 跳过 Pending（创建即 Active），不可 Cancelled。

| dealStatus | phase | IDeal phase 名称 |
|------------|-------|------------------|
| NOT_FOUND (255) | 0 | NotFound |
| VERIFYING (0) | 2 | Active |
| VERIFIER_TIMED_OUT (1) | 2 | Active（仍可解决） |
| COMPLETED (2) | 3 | Success |
| REJECTED (3) | 4 | Failed |
| TIMED_OUT (4) | 4 | Failed |

```solidity
function phase(uint256 dealIndex) external view override returns (uint8) {
    Claim storage c = claims[dealIndex];
    if (c.claimer == address(0)) return 0;  // NotFound
    uint8 s = c.status;
    if (s == VERIFYING) return 2;           // Active
    if (s == COMPLETED) return 3;           // Success
    return 4;                               // Failed (REJECTED or TIMED_OUT)
}
```

### 6.4 状态转换图

```mermaid
flowchart TD
    subgraph "Campaign 生命周期"
        OPEN["OPEN<br/>接受 claim"]
        EXHAUSTED["EXHAUSTED<br/>预算 < claimCost<br/>（可恢复）"]
        EXPIRED["EXPIRED<br/>已过 deadline"]
        CLOSED["CLOSED ✅<br/>A 已提取"]

        OPEN -->|"预算 < claimCost"| EXHAUSTED
        OPEN -->|"过期"| EXPIRED
        EXHAUSTED -->|"claim 被拒<br/>预算恢复"| OPEN
        EXHAUSTED -->|"过期"| EXPIRED
        EXPIRED -->|"withdrawRemaining()<br/>(pendingClaims == 0)"| CLOSED
    end

    subgraph "Per-Claim（dealIndex）生命周期"
        VERIFYING["0 VERIFYING<br/>等待 verifier"]
        VERIFIER_TIMED_OUT["1 VERIFIER_TIMED_OUT<br/>（派生）"]
        COMPLETED["2 COMPLETED ✅<br/>B 已收款，claimed=true"]
        REJECTED["3 REJECTED ❌<br/>failCount[B]++"]
        CLAIM_TIMEOUT["4 TIMED_OUT ⏰<br/>claimCost → budget"]

        VERIFYING -->|"result > 0"| COMPLETED
        VERIFYING -->|"result < 0"| REJECTED
        VERIFYING -->|"result == 0"| REJECTED
        VERIFYING -->|"超过 VERIFICATION_TIMEOUT"| VERIFIER_TIMED_OUT
        VERIFIER_TIMED_OUT -->|"resetVerification()"| CLAIM_TIMEOUT
    end
```

### 6.5 事件发射

| 操作 | 发出的事件 |
|------|-----------|
| `claim()` | `DealCreated(dealIndex, [B], [verifier])` → `DealStateChanged(dealIndex, 0)` → `DealPhaseChanged(dealIndex, 2)` → `VerificationRequested(dealIndex, 0, verifier)` |
| `onVerificationResult(result > 0)` | `VerificationReceived(dealIndex, 0, verifier, result)` → `DealStateChanged(dealIndex, 2)` → `DealPhaseChanged(dealIndex, 3)` |
| `onVerificationResult(result < 0)` | `VerificationReceived(dealIndex, 0, verifier, result)` → `DealStateChanged(dealIndex, 3)` → `DealPhaseChanged(dealIndex, 4)` |
| `onVerificationResult(result == 0)` | `VerificationReceived(dealIndex, 0, verifier, result)` → `DealStateChanged(dealIndex, 3)` → `DealPhaseChanged(dealIndex, 4)` |
| `resetVerification()` | `DealStateChanged(dealIndex, 4)` → `DealPhaseChanged(dealIndex, 4)` |

### 6.6 B 的 Claim 资格

```
claimed[B] == true       → AlreadyClaimed（已成功领取，完成）
failCount[B] >= 3        → MaxFailures（在此合约中被封禁）
无 TwitterRegistry 绑定   → NotVerified
budget < claimCost       → BudgetExhausted
已过 deadline            → CampaignExpired
有待处理的 claim          → PendingClaim（同时只能有一个）
否则                      → 可 claim
```

---

## 7. 超时与异常路径

### 7.1 常量

| 常量 | 值 | 说明 |
|------|---|------|
| `VERIFICATION_TIMEOUT` | 30 分钟 | 每个 claim 的 verifier 响应时限 |
| `MAX_FAILURES` | 3 | 每地址最大失败次数 |

### 7.2 Verifier 超时（单个 Claim）

```mermaid
sequenceDiagram
    participant X as 任何人
    participant C as Contract

    Note over X,C: dealIndex 处于 VERIFYING，<br/>verifier 未在 VERIFICATION_TIMEOUT 内响应
    X->>C: 🟢 resetVerification(dealIndex, 0)
    Note over C: claimCost → budget<br/>pendingClaims--<br/>claim → TIMED_OUT
```

### 7.3 Campaign 到期且有剩余预算

```mermaid
sequenceDiagram
    participant A as A
    participant C as Contract

    Note over A,C: 已过 deadline，pendingClaims == 0
    A->>C: 🟢 withdrawRemaining()
    Note over C: budget → A，closed = true
```

### 7.4 Campaign 到期但有待处理 Claim

```mermaid
sequenceDiagram
    participant A as A
    participant V as Verifier
    participant C as Contract

    Note over A,C: 已过 deadline，pendingClaims > 0

    alt Verifier 及时响应
        V->>C: 🟢 reportResult(...)
    else Verifier 超时
        A->>C: 🟢 resetVerification(dealIndex, 0)
    end

    Note over A: pendingClaims == 0 后：
    A->>C: 🟢 withdrawRemaining()
```

### 7.5 预算耗尽 → 拒绝后恢复

```
EXHAUSTED → claim 被拒 → budget += rewardPerFollow → OPEN（如果预算 ≥ claimCost）
```

### 7.6 设计原则

| 原则 | 实现 |
|------|------|
| 合约 = campaign | 一个合约实例 = 一个 campaign，无 deal mapping |
| claim = dealIndex | 每个 B 的 claim 从 `_recordStart` 获得唯一 dealIndex |
| 不可提前关闭 | A 在 deadline 前不可提取 |
| A 承担所有费用 | verifierFee + protocolFee 均从预算按 claim 扣除 |
| 按 claim 收协议费 | PROTOCOL_FEE 在每次 claim 时扣除 |
| B 零输入 | `claim()` 无参数 — 用户名从 TwitterRegistry 读取 |
| 最多 3 次失败 | `failCount[B] >= 3` → 在此合约中被封禁 |
| 成功仅一次 | `claimed[B] = true` → 不可再 claim |

---

## 8. 资金流向

### 8.1 Campaign 创建

```
grossAmount → budget（全额，无预收费用）
```

### 8.2 每次 Claim 成本

```
claimCost = rewardPerFollow + verifierFee + PROTOCOL_FEE
每次 claim() 从 budget 锁定 claimCost
remainingSlots = budget / claimCost
```

### 8.3 验证结果 → 资金分配

| 结果 | 奖励 | Verifier 费用 | 协议费 | 预算变化 |
|------|------|--------------|--------|---------|
| 通过 (result > 0) | → B | → Verifier | → FeeCollector | — |
| 失败 (result < 0) | → 预算 | → Verifier | → FeeCollector | +rewardPerFollow |
| 不确定 (result == 0) | → 预算 | → 预算 | → 预算 | +claimCost |
| Verifier 超时 | → 预算 | → 预算 | → 预算 | +claimCost |

### 8.4 Campaign 结束

```
deadline 到期 + pendingClaims == 0 后：
  budget → A（通过 withdrawRemaining()）
```

---

## 9. 验证清单

### 9.1 createDeal

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | 尚未初始化（仅调用一次） | AlreadyInitialized |
| 2 | `grossAmount >= claimCost`（至少可 claim 1 次） | InvalidParams |
| 3 | `rewardPerFollow > 0` | InvalidParams |
| 4 | `deadline > block.timestamp` | InvalidParams |
| 5 | `verifier != address(0)`，是合约 | VerifierNotContract |
| 6 | `target_username` 规范化后非空 | InvalidParams |
| 7 | `sigDeadline >= deadline` | SignatureExpired |
| 8 | Verifier spec 匹配 + EIP-712 签名有效 | InvalidVerifierSignature |
| 9 | `USDC.transferFrom(A, 合约, grossAmount)` | TransferFailed |

### 9.2 claim

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | Campaign 未关闭，未过 deadline | CampaignExpired |
| 2 | `budget >= claimCost` | BudgetExhausted |
| 3 | `!claimed[msg.sender]` | AlreadyClaimed |
| 4 | `failCount[msg.sender] < MAX_FAILURES` | MaxFailures |
| 5 | `TwitterRegistry.usernameOf[msg.sender]` 非空 | NotVerified |
| 6 | 无待处理的 claim | PendingClaim |
| 7 | 从预算锁定 claimCost，pendingClaims++ | — |

### 9.3 onVerificationResult

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | `msg.sender == verifier` | NotVerifier |
| 2 | Claim 状态为 VERIFYING | InvalidStatus |
| 3 | 根据 result 分配资金，更新计数器 | — |

### 9.4 withdrawRemaining

| # | 检查项 | 错误 |
|---|--------|------|
| 1 | `msg.sender == partyA` | NotPartyA |
| 2 | `block.timestamp > deadline` | NotExpired |
| 3 | `pendingClaims == 0` | PendingClaims |
| 4 | `budget > 0` | NoFunds |
| 5 | `!closed` | AlreadyClosed |
