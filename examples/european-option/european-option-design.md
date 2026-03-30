# EuropeanOptionDealContract Design

> V1 把欧式期权拆成 SyncTx 当前标准真正能稳定承载的最小原语：`pairwise explicit-consent deal + settlement-price verifier`。
> 公开报价、series 市场层、自动做市曲线属于上层市场组件，不和核心 DealContract 混在一起实现。

---

## 1. V1 目标

V1 只解决三件事：

1. 如何让 `holder` 和 `writer` 达成一笔标准欧式期权交易
2. 到期时如何把“结算价格”安全带回链上
3. 如何在价格验证失败时避免资金永久锁死

V1 不解决：

- 公开 series 市场
- 自动做市层
- margin / liquidation
- 二级转让

---

## 2. 为什么需要“价格 side-channel verifier”

SyncTx 当前的 `onVerificationResult` 只支持：

```solidity
onVerificationResult(uint256 dealIndex, uint256 verificationIndex, int8 result, string reason)
```

这意味着 verifier 结果天然适合：

- Boolean：通过 / 不通过
- Score：1 到 127 的打分

但期权结算需要的是：

- 一个真实的数值结算价 `settlementPrice`

因此 V1 的解法不是去改协议基类，而是引入一个专门的 `SettlementPriceVerifier`：

- `result > 0`：表示“价格已可用”
- `result == 0`：表示“不确定”
- `result < 0`：表示“验证失败”
- 真正的 `settlementPrice` 存在 verifier 合约里
- DealContract 在 `onVerificationResult` 中回读 `settlementPriceOf(...)`

这就是本文实现的 `VerifierSpec + Verifier + DealContract` 组合的核心原因。

---

## 3. 交易流程

### 3.1 场外达成条款

Holder 和 Writer 先在链下达成期权条款：

- `optionType`: `PUT` or `CALL`
- `underlying`
- `quantity`
- `strike`
- `premium`
- `expiry`
- `settlementWindow`
- `verifier`
- `verifierFee`

### 3.2 获取 Verifier 签名

Holder 向 `SettlementPriceVerifier` 请求一个 EIP-712 签名，证明 verifier 同意为下列结算条件服务：

- `underlying`
- `quoteToken`
- `expiry`
- `settlementWindow`
- `fee`
- `deadline`

### 3.3 Holder 创建 deal

Holder 先把 `premium` 转进合约，然后调用：

```text
createDeal(...)
```

创建后 deal 进入 `WaitingAccept`。

### 3.4 Writer 接受 deal

Writer 调用：

```text
accept(dealIndex)
```

并按 option type 锁抵押：

- `PUT`：锁 `USDC`
- `CALL`：锁 `underlying`

接受后 deal 进入 `Active`。

### 3.5 到期后请求价格验证

到期后，任一参与方都可以调用：

```text
requestVerification(dealIndex, 0)
```

并预付 `verifierFee`。

### 3.6 Verifier 回报结果

链下 verifier 读取 `verificationParams`，按 `(underlying, quoteToken, expiry, settlementWindow)` 获取结算价格，然后：

- 若价格明确：调用 `reportSettlementPrice(...)`
- 若无法确认：调用 `reportInconclusive(...)`
- 若验证失败：调用 `reportFailure(...)`

### 3.7 自动结算或进入 Settling

若价格明确，则 deal 自动结算：

- `PUT`：买方获得 `USDC payoff`
- `CALL`：买方获得 `underlying-equivalent payout`

若不明确，则进入 `Settling`，双方可手动协商 collateral 的分配。

### 3.8 超时退出

若 verifier 超时，任何一方都可 `resetVerification` 并进入 `Settling`。

若 `Settling` 再次超时，则执行 `unwind`：

- premium 退回 holder
- collateral 退回 writer

这不是理想金融语义，但好于永久锁死。

---

## 4. 需要什么样的 Verifier

V1 需要的不是“判断真假”的 verifier，而是“把数值价格安全带回链上”的 verifier。

因此它必须具备三种能力：

1. 能对 `(underlying, quoteToken, expiry, settlementWindow, fee, deadline)` 做 EIP-712 签名
2. 能在到期时产生一个单值 `settlementPrice`
3. 能把这个价格写进链上，并回调 DealContract

这对应三个组件：

- `SettlementPriceVerifierSpec.sol`
- `SettlementPriceVerifier.sol`
- `EuropeanOptionDealContract.sol`

---

## 5. Spec 的职责

`SettlementPriceVerifierSpec` 只做一件事：

> 验证某个 verifier 是否真的同意为指定结算条款服务。

它不负责：

- 返回价格
- 存价格
- 执行结算

它只负责恢复签名者地址，并让 DealContract 在 `createDeal` 时比对：

```text
recovered == verifier.signer()
```

---

## 6. DealContract 的职责

`EuropeanOptionDealContract` 只负责：

- 托管 premium 和 collateral
- 维护 deal 状态机
- 触发验证
- 在 verifier 给出价格后计算 payoff
- 执行资产划转

它不负责：

- 公开 market / series / curve
- 生成 oracle 数据
- 处理清算体系

---

## 7. 核心资产语义

V1 采用 asymmetrical collateral model：

- `PUT`：`USDC collateral -> USDC payout`
- `CALL`：`underlying collateral -> underlying-equivalent payout`

这样可以在没有 margin/liquidation 的前提下同时支持：

- `PUT`
- `CALL`

但代价是：

- `CALL` 不是严格意义上的“统一 USDC cash payout”
- 它是 `standard payoff + underlying-equivalent settlement`

---

## 8. 为什么 V1 不直接实现 public series

因为当前 SyncTx 核心标准是：

- `DealContract`
- `VerifierSpec`
- `Verifier`

如果一开始就在同一合约里塞入：

- maker vault
- public offers
- param curve
- deal settlement
- testing/final

那就会把“市场层”和“结算层”强耦合，难以验证真正的协议边界。

V1 更正确的路线是：

1. 先把期权结算原语落地
2. 再在其上做 series / quoting / vault 层

---

## 9. 实现清单

本目录实现：

- `SettlementPriceVerifierSpec.sol`
- `SettlementPriceVerifier.sol`
- `EuropeanOptionDealContract.sol`

它们共同构成一个可运行的欧式期权核心交易流示例。

