# XFollowDealContract Design Document

> 1-to-many campaign model: A deposits a budget, any TwitterRegistry-verified user can follow and claim a fixed reward. Fully automated, no negotiation needed.

---

## 1. Overview

XFollowDealContract is a concrete DealContract implementation for the **"A pays a fixed reward per follow to a specified account on X"** campaign scenario.

- **Inheritance:** `IDeal → DealBase → XFollowDealContract`
- **Model:** 1-to-many — A creates a campaign, any number of Bs can claim
- **Verification system:** Multi-claim, single verifier per campaign, requiring `XFollowVerifierSpec`
- **Payment token:** USDC
- **Tags:** `["x", "follow"]`
- **Identity:** `TwitterRegistry` binding is mandatory — contract reads `usernameOf[msg.sender]` on-chain, reverts if unbound
- **Verification semantics:** Verifier checks whether the follow relationship exists at verification time. Identity is guaranteed by TwitterRegistry (wallet ↔ username), eliminating impersonation risk
- **Off-chain verification:** Dual-provider parallel check via twitterapi.io (`check_follow_relationship`) + twitter-api45 (`checkfollow.php`)
- **End conditions:** Budget exhausted OR deadline reached — A cannot close early
- **Unified deadline:** Campaign deadline is used as both the verifier signature expiry and the campaign end time

---

## 2. Core Data Structures

### 2.1 Deal (Campaign)

```solidity
struct Deal {
    // Slot 1
    address partyA;              // 20 bytes — campaign creator
    uint48  deadline;            // 6 bytes  — campaign end time = signature deadline
    uint8   status;              // 1 byte   — OPEN / CLOSED
    // Slot 2
    address verifier;            // 20 bytes — verifier contract address
    uint96  rewardPerFollow;     // 12 bytes — fixed USDC reward per follow
    // Slot 3
    uint96  budget;              // 12 bytes — remaining unlocked USDC budget
    uint96  verifierFee;         // 12 bytes — fee per verification (paid from budget)
    uint32  pendingClaims;       // 4 bytes  — claims awaiting verification
    uint32  completedClaims;     // 4 bytes  — successfully verified claims
    // Dynamic
    string  target_username;     // canonicalized: no @, lowercase
    bytes   verifierSignature;   // EIP-712 signature (deadline = deal.deadline)
}
```

### 2.2 Claim

```solidity
struct Claim {
    // Slot 1
    address claimer;             // 20 bytes — B's address
    uint48  timestamp;           // 6 bytes  — claim creation time
    uint8   status;              // 1 byte   — VERIFYING / COMPLETED / REJECTED
    // Dynamic
    string  follower_username;   // read from TwitterRegistry at claim time (B provides nothing)
}
```

### 2.3 Mappings

```solidity
mapping(uint256 => Deal) deals;
mapping(uint256 => mapping(uint256 => Claim)) claims;
mapping(uint256 => mapping(address => bool)) hasClaimed;   // prevent double-claiming
mapping(uint256 => mapping(address => uint8)) failCount;   // track failures per address
mapping(uint256 => uint256) nextClaimIndex;
```

---

## 3. Function Reference

### 3.1 XFollowDealContract Functions

| Method | Parameters | Caller | Description |
|--------|------------|--------|-------------|
| `createDeal(...)` | `uint96 grossAmount, address verifier, uint96 verifierFee, uint96 rewardPerFollow, bytes sig, string target_username, uint48 deadline` | A | Create campaign. Deposit `grossAmount` USDC (= protocolFee + budget). `deadline` serves as both campaign end time and verifier signature expiry |
| `claim(dealIndex)` | `uint256 dealIndex` | Any B | B calls with only `dealIndex`. Contract reads `TwitterRegistry.usernameOf[msg.sender]` — reverts `NotVerified` if unbound. Locks (rewardPerFollow + verifierFee) from budget. Emits VerificationRequested |
| `onVerificationResult(...)` | `uint256 dealIndex, uint256 claimIndex, int8 result, string reason` | Verifier | result>0 → pay B, completedClaims++; result<0 → reward to budget, mark failure on B; result==0 → all to budget |
| `withdrawRemaining(dealIndex)` | `uint256 dealIndex` | A | After deadline + pendingClaims==0, A withdraws remaining budget. Deal → CLOSED |
| `resetClaim(dealIndex, claimIndex)` | `uint256 dealIndex, uint256 claimIndex` | Anyone | After VERIFICATION_TIMEOUT, reset timed-out claim. Reward + fee return to budget |

### 3.2 Query Functions

| Method | Return | Description |
|--------|--------|-------------|
| `dealStatus(dealIndex)` | `uint8` | Derived status: OPEN / EXHAUSTED / EXPIRED / CLOSED / NOT_FOUND |
| `dealInfo(dealIndex)` | `(address partyA, string target, uint96 reward, uint96 budget, uint48 deadline, uint32 completed, uint32 pending)` | Campaign details for UI |
| `claimInfo(dealIndex, claimIndex)` | `(address claimer, string username, uint8 status)` | Individual claim details |
| `canClaim(dealIndex, addr)` | `bool` | Whether addr can claim (has TwitterRegistry binding, not already claimed, budget available, not expired) |
| `failures(dealIndex, addr)` | `uint8` | Number of failed claims for this address in this campaign |

### 3.3 Inherited from DealBase / IDeal

| Method | Description |
|--------|-------------|
| `name()` | Returns `"X Follow Deal"` |
| `description()` | Campaign description |
| `tags()` | `["x", "follow"]` |
| `version()` | `"2.0"` |
| `instruction()` | Markdown operation guide |
| `requiredSpecs()` | `[XFollowVerifierSpec]` |
| `verificationParams(dealIndex, claimIndex)` | Returns verifier + specParams for a specific claim |

---

## 4. Verification System

### 4.1 Contract Structure

```
VerifierSpec ← XFollowVerifierSpec (business specification)
IVerifier ← VerifierBase ← XFollowVerifier (instance)
XFollowVerifier.spec() → XFollowVerifierSpec
```

### 4.2 EIP-712 Signature (per-campaign, unified deadline)

TYPEHASH:
```
Verify(string targetUsername,uint256 fee,uint256 deadline)
```

The verifier signs once per campaign. `deadline` = campaign deadline, serving double duty:
- Verifier commitment expiry (standard EIP-712 deadline)
- Campaign end time (no new claims after this time)

### 4.3 specParams (per-claim)

```solidity
specParams = abi.encode(
    string follower_username,  // read from TwitterRegistry.usernameOf[claimer] at claim time
    string target_username     // campaign target (from deal)
)
```

B does not provide any username — the contract reads it from TwitterRegistry on-chain.

### 4.4 Off-chain Verification Flow

```
Verifier Service receives notify_verify (with claimIndex as verificationIndex)
  │
  ├── 0. Read on-chain claim status — only proceed if VERIFYING
  ├── 1. Read verificationParams(dealIndex, claimIndex) → decode specParams
  ├── 2. Parallel API calls:
  │     ├── twitterapi.io: check_follow_relationship
  │     └── twitter-api45: checkfollow.php
  ├── 3. Merge logic:
  │     ├── ANY confirms follow → result = 1 (pass)
  │     ├── Both deny → retry once after 5s → result = -1 or 1
  │     └── Both error → result = 0 (inconclusive)
  └── 4. reportResult(dealContract, dealIndex, claimIndex, result, reason, expectedFee)
```

---

## 5. Transaction Flow

```mermaid
sequenceDiagram
    participant A as Campaign Creator (A)
    participant P as SyncTx (MCP)
    participant B as Follower (B)
    participant D as DealContract
    participant V as Verifier
    participant R as TwitterRegistry

    Note over A,V: Setup Phase (once per campaign)

    A->>P: 🟣 request_sign(verifier_address, {target_username}, deadline)
    P-->>V: async message
    V->>P: reply {accepted, fee, sig}
    P-->>A: async message

    Note over A: 🟢 USDC.approve(DealContract, grossAmount)
    A->>D: 🟢 createDeal(grossAmount, verifier, verifierFee,<br/>rewardPerFollow, sig, target_username, deadline) → dealIndex
    Note over D: Verify sig with deadline = campaign deadline<br/>protocolFee → FeeCollector<br/>🔵 DealCreated · DealStateChanged(OPEN)
    A->>P: 🟣 report_transaction(tx_hash, chain_id)

    Note over B,D: Claim Phase (repeatable, zero input from B)

    Note over B: 1. Bind Twitter via TwitterRegistry (if not already)
    Note over B: 2. Follow target_username on X
    B->>D: 🟡 canClaim(dealIndex, B.address) → true
    B->>D: 🟢 claim(dealIndex)
    Note over D: Read R.usernameOf[B] → revert if empty<br/>Lock (reward + verifierFee) from budget<br/>🔵 VerificationRequested(dealIndex, claimIndex, verifier)
    B->>P: 🟣 report_transaction + notify_verifier
    P-->>V: async message

    V->>D: 🟡 verificationParams(dealIndex, claimIndex)
    Note over V: Dual-provider follow check

    V->>D: 🟢 reportResult(dealContract, dealIndex, claimIndex, result, reason, expectedFee)

    alt result > 0 — following confirmed
        Note over D: reward → B, fee → verifier<br/>completedClaims++
    else result < 0 — not following
        Note over D: reward → budget, fee → verifier<br/>failCount[B]++
    else result == 0 — inconclusive
        Note over D: reward + fee → budget
    end

    Note over A,D: Withdrawal Phase (after deadline)

    A->>D: 🟢 withdrawRemaining(dealIndex)
    Note over D: Remaining budget → A<br/>Deal → CLOSED
```

---

## 6. State Machine

### 6.1 Deal Status

| Code | Status | Meaning |
|------|--------|---------|
| 0 | OPEN | Accepting claims (budget ≥ rewardPerFollow + verifierFee, not past deadline) |
| 1 | EXHAUSTED | Budget < rewardPerFollow + verifierFee (may recover if claims are rejected) |
| 2 | EXPIRED | Past deadline, pending claims may still resolve, A cannot withdraw yet |
| 3 | CLOSED | A has withdrawn remaining budget, all claims resolved |
| 255 | NOT_FOUND | Deal does not exist |

> EXHAUSTED and EXPIRED are derived at runtime (not stored). Stored status is only OPEN or CLOSED.

### 6.2 Claim Status

| Code | Status | Meaning |
|------|--------|---------|
| 0 | VERIFYING | Awaiting verifier response |
| 1 | COMPLETED | Follow verified, B paid |
| 2 | REJECTED | Follow not detected, reward returned to budget, failure recorded |
| 3 | TIMED_OUT | Verifier timed out, reward + fee returned to budget |

### 6.3 State Transition Diagram

```mermaid
flowchart TD
    OPEN["0 OPEN<br/>Accepting claims"]
    EXHAUSTED["1 EXHAUSTED<br/>Budget insufficient<br/>(may recover on rejection)"]
    EXPIRED["2 EXPIRED<br/>Past deadline<br/>pending claims resolving"]
    CLOSED["3 CLOSED ✅<br/>A withdrew remaining"]

    OPEN -->|"budget < cost per claim"| EXHAUSTED
    OPEN -->|"block.timestamp > deadline"| EXPIRED
    EXHAUSTED -->|"claim rejected → budget recovered"| OPEN
    EXHAUSTED -->|"block.timestamp > deadline"| EXPIRED
    EXPIRED -->|"A: withdrawRemaining()<br/>(pendingClaims == 0)"| CLOSED

    subgraph "Per-Claim Lifecycle"
        VERIFYING["VERIFYING<br/>Awaiting verifier"]
        COMPLETED["COMPLETED ✅<br/>B paid"]
        REJECTED["REJECTED ❌<br/>Reward returned<br/>failCount[B]++"]
        CLAIM_TIMEOUT["TIMED_OUT ⏰<br/>All returned"]

        VERIFYING -->|"result > 0"| COMPLETED
        VERIFYING -->|"result < 0"| REJECTED
        VERIFYING -->|"result == 0"| REJECTED
        VERIFYING -->|"VERIFICATION_TIMEOUT"| CLAIM_TIMEOUT
    end
```

---

## 7. Timeouts and Abnormal Paths

### 7.1 Timeout Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `VERIFICATION_TIMEOUT` | 30 minutes | Per-claim verifier response time limit |

No STAGE_TIMEOUT or SETTLING_TIMEOUT — the campaign model has no negotiation phases.

### 7.2 Verifier Timeout on a Claim

```mermaid
sequenceDiagram
    participant X as Anyone
    participant D as DealContract

    Note over X,D: Claim in VERIFYING state,<br/>verifier did not respond within VERIFICATION_TIMEOUT
    X->>D: 🟢 resetClaim(dealIndex, claimIndex)
    Note over D: reward + verifierFee → budget<br/>pendingClaims -= 1<br/>claim status → TIMED_OUT
```

> Anyone can call resetClaim after timeout — no permissions needed.

### 7.3 Campaign Expires with Remaining Budget

```mermaid
sequenceDiagram
    participant A as Campaign Creator
    participant D as DealContract

    Note over A,D: Past deadline, pendingClaims == 0
    A->>D: 🟢 withdrawRemaining(dealIndex)
    Note over D: Remaining budget → A<br/>🔵 DealPhaseChanged(dealIndex, 5)<br/>🔵 DealStateChanged(dealIndex, CLOSED)
```

### 7.4 Campaign Expires with Pending Claims

```mermaid
sequenceDiagram
    participant A as Campaign Creator
    participant V as Verifier
    participant D as DealContract

    Note over A,D: Past deadline, pendingClaims > 0

    alt Verifier responds in time
        V->>D: 🟢 reportResult(...)
        Note over D: Claim resolved normally
    else Verifier times out
        A->>D: 🟢 resetClaim(dealIndex, claimIndex)
        Note over D: Reward + fee returned to budget
    end

    Note over A: Once pendingClaims == 0:
    A->>D: 🟢 withdrawRemaining(dealIndex)
```

### 7.5 Budget Exhausted → Recovery on Rejection

When a claim is rejected (result < 0), `rewardPerFollow` returns to the budget. This may re-open the campaign for new claims:

```
EXHAUSTED → claim rejected → budget += rewardPerFollow → OPEN (if budget ≥ cost per claim)
```

### 7.6 Design Principles

| Principle | Implementation |
|-----------|----------------|
| No early close | A cannot withdraw before deadline — committed budget |
| No negotiation | Fixed reward, self-service claim |
| A pays all fees | verifierFee deducted from budget, not from B |
| B provides nothing | B calls `claim(dealIndex)` only — username read from TwitterRegistry on-chain |
| Failure tracking | Failed claims increment `failCount[dealIndex][B]` — visible via `failures()` |
| Identity required | TwitterRegistry binding mandatory — `claim()` reverts if unbound |
| One claim per user | `hasClaimed` mapping prevents double claims |
| Unified deadline | Campaign deadline = verifier signature deadline — one parameter, no mismatch |

---

## 8. Fund Flow

### 8.1 Campaign Creation

```
A approves and deposits grossAmount:
  grossAmount = protocolFee + budget
  protocolFee → FeeCollector (non-refundable)
  budget → contract escrow
```

### 8.2 Per-Claim Cost (from budget)

```
Each claim locks: rewardPerFollow + verifierFee
Remaining claimable follows = budget / (rewardPerFollow + verifierFee)
```

### 8.3 Verification Result → Fund Distribution

| Result | Reward (rewardPerFollow) | Verifier Fee | Budget Change | B Record |
|--------|--------------------------|--------------|---------------|----------|
| Pass (result > 0) | → B | → Verifier | — | completedClaims++ |
| Fail (result < 0) | → budget | → Verifier | +rewardPerFollow | failCount[B]++ |
| Inconclusive (result == 0) | → budget | → budget | +rewardPerFollow + verifierFee | — |
| Verifier timeout | → budget | → budget | +rewardPerFollow + verifierFee | — |

### 8.4 Campaign End

```
After deadline + all claims resolved:
  remaining budget → A via withdrawRemaining()
```

---

## 9. Validation Checklist

### 9.1 createDeal Validations

| # | Check | Error |
|---|-------|-------|
| 1 | `grossAmount > protocolFee` | InvalidParams |
| 2 | `budget >= rewardPerFollow + verifierFee` (at least 1 claim possible) | InvalidParams |
| 3 | `rewardPerFollow > 0` | InvalidParams |
| 4 | `deadline > block.timestamp` | InvalidParams |
| 5 | `verifier != address(0)`, is contract | VerifierNotContract |
| 6 | `target_username` non-empty after canonicalization | InvalidParams |
| 7 | Verifier spec match + EIP-712 signature valid (deadline = campaign deadline) | InvalidVerifierSignature |
| 8 | `USDC.transferFrom(A, contract, grossAmount)` | TransferFailed |

### 9.2 claim Validations

| # | Check | Error |
|---|-------|-------|
| 1 | Deal status is OPEN (stored) | InvalidStatus |
| 2 | `block.timestamp <= deadline` | DealExpired |
| 3 | `budget >= rewardPerFollow + verifierFee` | BudgetExhausted |
| 4 | `!hasClaimed[dealIndex][msg.sender]` | AlreadyClaimed |
| 5 | `TwitterRegistry.usernameOf[msg.sender]` is non-empty | NotVerified |
| 6 | Lock (rewardPerFollow + verifierFee) from budget | — |

### 9.3 onVerificationResult Validations

| # | Check | Error |
|---|-------|-------|
| 1 | `msg.sender == deal.verifier` | NotVerifier |
| 2 | Claim status is VERIFYING | InvalidStatus |
| 3 | Distribute funds based on result; if result<0, increment failCount | — |

### 9.4 withdrawRemaining Validations

| # | Check | Error |
|---|-------|-------|
| 1 | `msg.sender == deal.partyA` | NotPartyA |
| 2 | `block.timestamp > deal.deadline` | NotExpired |
| 3 | `deal.pendingClaims == 0` | PendingClaims |
| 4 | `deal.budget > 0` | NoFunds |

### 9.5 Verifier Service Pre-flight Checks

| # | Check | Action |
|---|-------|--------|
| 1 | Claim status is VERIFYING | Skip if not |
| 2 | Verifier address matches self | Skip if not |
| 3 | On-chain fee > 0 | Skip if not |
