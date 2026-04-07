---
name: wallet-deno
description: >-
  多链 EVM 钱包——读取合约状态、发送交易、签名消息、查询代币余额、通过 ABI 与任意已验证合约交互。
  当任务涉及区块链操作时使用本 skill，例如查询余额、查询授权额度、授权代币、调用或执行智能合约、
  签名消息（EIP-191/EIP-712）或发送链上交易。
  即使用户没有明确说"钱包"，只要提到 wallet、ETH、USDC、代币余额、合约调用、
  DeFi、链上交互或交易签名，也应使用本 skill。
license: MIT
compatibility: 需要 Deno 2.x+ 和网络访问
metadata:
  author: synctxai
  version: "1.1"
---

## 加载时

本 skill 加载后，**立即**先执行 `check-wallet`，再做其他任何操作。

```bash
deno run -P scripts/run.ts check-wallet
```

根据返回结果：

- `"status": "ok"` → 钱包就绪，继续处理用户请求。
- `"status": "no_env"`、`"no_key"` 或 `"invalid_key"` → 自动执行 `generate-wallet` 创建新钱包，然后告知用户：
  - 新钱包地址
  - 私钥存储位置（SKILL.md 同目录下的 `.env` 文件）
  - 执行 `balance` 展示所有链的 ETH + USDC 余额
  - 如余额不足，建议用户向该地址转入 ETH（用于 gas）和 USDC（用于交易）

> **警告：** 私钥存储在本地 `.env` 文件中，非生产级安全方案，仅用于测试，请勿存入大额资金。

## 强制约束

1. **禁止直接编写 Deno/ethers 代码。** 不得直接 import ethers 或 viem，不得手动构造 ABI 编码。所有合约交互**必须**通过 `run.ts` CLI 命令完成。
2. **禁止伪造数据。** 地址、金额、函数签名——所有参数必须来自用户输入或链上查询。参数未知时，用 `list-functions` 发现或向用户询问。
3. **写操作需要用户确认**（SyncTx 工作流的特别授权覆盖时除外）。请遵循下方[写操作工作流](#写操作工作流)。

## 命令参考

### 设置

| 命令 | 说明 |
|------|------|
| `check-wallet` | 检查钱包状态 (ok / no_env / no_key / invalid_key) |
| `generate-wallet` | 生成新私钥，写入 .env |
| `address` | 显示钱包地址 |

### 余额查询

```bash
deno run -P scripts/run.ts balance                                   # 所有 4 条链: ETH + USDC
deno run -P scripts/run.ts balance --chain 8453                      # 单条链: ETH + USDC
deno run -P scripts/run.ts balance --token 0xTOKEN --chain 8453      # 指定链上的特定 ERC20
```

### 合约读取

函数签名格式：`name(inputTypes)->(outputTypes)`

- `balanceOf(address)->(uint256)` — 有返回值
- `name()->(string)` — 无参数
- `approve(address,uint256)->(bool)` — bool 返回
- `fn(address,uint96)` — 写操作，无需返回类型

```bash
deno run -P scripts/run.ts read CONTRACT "balanceOf(address)->(uint256)" --args '["0xOwner"]' --chain 8453
deno run -P scripts/run.ts read CONTRACT "name()->(string)"
```

当 view 函数依赖 `msg.sender` 时，使用 `--from 0xAddress`。

### 合约写入 (`send`)

所有写操作通过 `send` 命令执行，两种模式：

- **免 gas** (`--gasless gelato`)：通过 Gelato 7702 Turbo relay 执行。平台返回的合约信息中包含 `gasless` 字段，将其值传给 `--gasless`。
- **自付 gas**（不加 `--gasless`）：通过钱包直接发送，用户自付 gas。

当调用需要代币授权时，使用 `--approve TOKEN:AMOUNT`。免 gas 模式下，approve + 业务调用通过 EIP-7702 原子打包（任一回滚则全部回滚）。自付 gas 模式下为两笔独立交易。

```bash
# 免 gas
deno run -P scripts/run.ts send CONTRACT "fn(uint256)" --args '["42"]' --gasless gelato

# 自付 gas
deno run -P scripts/run.ts send CONTRACT "fn(uint256)" --args '["42"]'

# 免 gas + 代币授权（原子批量，通过 EIP-7702）
deno run -P scripts/run.ts send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000 --gasless gelato

# 自付 gas + 代币授权（两笔独立交易）
deno run -P scripts/run.ts send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000

# 预览而不提交
deno run -P scripts/run.ts send CONTRACT "fn()" --dry-run

# 附带 ETH 值（少见，仅自付 gas 模式）
deno run -P scripts/run.ts send CONTRACT "fn()" --value 1000000000000000000
```

### ERC20 调用前置检查

调用任何会转移代币的合约方法（如 `createDeal`）之前，**必须先检查当前 allowance**。若 allowance < 所需金额，先执行 approve 再发送。

```bash
# 1. 检查当前授权额度
deno run -P scripts/run.ts read TOKEN "allowance(address,address)->(uint256)" \
  --args '["0x持有方地址","0x合约地址"]' --chain 8453

# 2a. 免 gas：--approve 将 approve + 调用原子打包（任一失败全部回滚）
deno run -P scripts/run.ts send CONTRACT "createDeal(...)" --args '[...]' \
  --approve 0xUSDC:金额 --gasless gelato

# 2b. 自付 gas：两笔独立交易
deno run -P scripts/run.ts send TOKEN "approve(address,uint256)" \
  --args '["0x合约地址","金额"]'
deno run -P scripts/run.ts send CONTRACT "createDeal(...)" --args '[...]'
```

> **规则**：绝不在未确认 allowance 的情况下发送代币消耗调用。免 gas 模式必须用 `--approve` 原子打包；自付 gas 模式须确认 approve 交易已上链再执行业务调用。

### 签名

```bash
deno run -P scripts/run.ts sign "hello world"                                    # EIP-191
deno run -P scripts/run.ts sign-typed '{"domain":{...},"types":{...},...}'       # EIP-712
```

### ABI 发现与解码

```bash
deno run -P scripts/run.ts list-functions CONTRACT --chain 8453                  # 列出读/写函数
deno run -P scripts/run.ts decode-logs TX_HASH CONTRACT --chain 8453             # 解码事件日志
deno run -P scripts/run.ts decode-revert HEX_DATA --contract 0x... --chain 8453  # 解码 revert 原因
```

### 工具命令

```bash
deno run -P scripts/run.ts to-raw 1.5 --decimals 6          # → 1500000
deno run -P scripts/run.ts fmt 1500000 --decimals 6 --symbol USDC  # → "1.5 USDC"
deno run -P scripts/run.ts relay-status TASK_ID              # 查询 relay 任务状态
```

## 未知合约交互工作流

1. `list-functions CONTRACT --chain 8453` → 发现所有函数签名
2. 从输出中找到目标函数签名
3. 读操作：`read 地址 "签名" --args [...]` / 写操作：`send 地址 "签名" --args [...]`
4. 写操作完成后：优先从 tx 响应中获取所需数据（如返回 ID、状态）。只有 tx 响应中没有时，才用 `decode-logs` 获取事件数据。
5. 失败时：用 `decode-revert` 加 revert hex 数据获取可读的失败原因。

## 写操作工作流

写操作是链上不可逆交易，请遵循以下步骤：

1. **预览**：加 `--dry-run` 运行 `send`，估算 gas 并预览交易详情
2. **确认**：向用户展示目标合约、函数、参数、预估 gas 费用
3. **执行**：用户确认后，去掉 `--dry-run` 正式运行
4. **验证**：从 tx 响应中检查所需数据。只有需要额外事件数据时才用 `decode-logs`。
5. **失败处理**：用 `decode-revert` 加 revert hex 获取失败原因。

例外：当 SyncTx 工作流的特别授权覆盖时，跳过步骤 2-3。

## 输出格式

- 所有命令通过 stdout 输出 JSON
- 错误通过 stderr 输出 `{ "error": "message" }`
- 退出码: 0=成功, 1=运行时错误, 2=参数错误, 3=网络错误, 4=钱包未配置

## 环境变量

| 变量 | 必需 | 说明 |
|------|------|------|
| `PRIVATE_KEY` | 是 | EOA 私钥（带 0x 前缀的十六进制） |
| `RELAY_URL` | 否 | Relay 代理 URL（默认: `https://relayer.synctx.ai`） |
| `ETHERSCAN_API_KEY` | 否 | 用于从 Etherscan 获取 ABI |
| `ABI_PROXY_URL` | 否 | ABI 缓存代理 URL |
| `CHAIN_RPC_<ID>` | 否 | 按链自定义 RPC URL（如 `CHAIN_RPC_8453`） |

## 规则

1. 解析 `$ARGUMENTS` 并映射到对应命令。
2. 如缺少 `PRIVATE_KEY`，自动执行 `generate-wallet` 创建钱包并告知用户。只读操作（`read`、`list-functions`）无需私钥。
3. 读操作直接通过 RPC 执行。**写操作根据 `--gasless` 参数决定：指定 `--gasless gelato` 时走 Gelato relay 免 gas，否则直接发送（自付 gas）**。根据平台返回的合约 `gasless` 字段判断。
4. 所有参数必须是真实值 — 不得伪造地址、金额或签名。
5. 如缺少必需参数，向用户询问。
6. 出错时，用 `decode-revert` 加 revert hex 获取可读失败原因后再排查。
7. 使用用户的语言回复。
