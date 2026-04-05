---
name: wallet-deno
description: >-
  多链 EVM 钱包。用于用户需要查询余额、与智能合约交互或签名消息时。
license: MIT
compatibility: 需要 Deno 2.x+ 和网络访问
metadata:
  author: synctxai
  version: "1.0"
---

## 加载时

```bash
W="deno run --allow-net --allow-env --allow-read --allow-write scripts/run.ts"

# 1. 检查钱包状态
$W check-wallet
# 如果状态为 "no_env" 或 "no_key":
$W generate-wallet

# 2. 显示地址
$W address

# 3. 查询余额
$W balance
```

## 命令参考

### 设置

| 命令 | 说明 |
|------|------|
| `check-wallet` | 检查钱包状态 (ok / no_env / no_key / invalid_key) |
| `generate-wallet` | 生成新私钥，写入 .env |
| `address` | 显示钱包地址 |

### 余额查询

```bash
$W balance                                   # 所有 4 条链: ETH + USDC
$W balance --chain 8453                      # 单条链: ETH + USDC
$W balance --token 0xTOKEN --chain 8453      # 指定链上的特定 ERC20
```

### 合约读取

函数签名格式：`name(inputTypes)->(outputTypes)`

- `balanceOf(address)->(uint256)` — 有返回值
- `createDeal(address,uint96,bytes32)` — 写操作，无返回
- `name()->(string)` — 无参数
- `approve(address,uint256)->(bool)` — bool 返回

```bash
$W read CONTRACT "balanceOf(address)->(uint256)" --args '["0xOwner"]' --chain 8453
$W read CONTRACT "name()->(string)"
```

当 view 函数依赖 `msg.sender` 时，使用 `--from 0xAddress`。

### 合约写入 (`send`)

所有写操作通过 `send` 命令执行，两种模式：

- **免 gas** (`--gasless gelato`)：通过 Gelato 7702 Turbo relay 执行。平台返回的合约信息中包含 `gasless` 字段，将其值传给 `--gasless`。
- **自付 gas**（不加 `--gasless`）：通过钱包直接发送，用户自付 gas。

当调用需要代币授权时，使用 `--approve TOKEN:AMOUNT`。免 gas 模式下，approve + 业务调用通过 EIP-7702 原子打包（任一回滚则全部回滚）。自付 gas 模式下为两笔独立交易。

```bash
# 免 gas
$W send CONTRACT "accept(uint256)" --args '["42"]' --gasless gelato

# 自付 gas
$W send CONTRACT "accept(uint256)" --args '["42"]'

# 免 gas + 代币授权（原子批量）
$W send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000 --gasless gelato

# 自付 gas + 代币授权（两笔独立交易）
$W send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000

# 预览而不提交
$W send CONTRACT "fn()" --dry-run

# 附带 ETH 值（少见，仅自付 gas 模式）
$W send CONTRACT "deposit()" --value 1000000000000000000
```

### 签名

```bash
$W sign "hello world"                                    # EIP-191
$W sign-typed '{"domain":{...},"types":{...},...}'       # EIP-712
```

### ABI 发现与解码

```bash
$W list-functions CONTRACT --chain 8453                  # 列出读/写函数
$W decode-logs TX_HASH CONTRACT --chain 8453             # 解码事件日志
$W decode-revert HEX_DATA --contract 0x... --chain 8453  # 解码 revert 原因
```

### 工具命令

```bash
$W to-raw 1.5 --decimals 6          # → 1500000
$W fmt 1500000 --decimals 6 --symbol USDC  # → "1.5 USDC"
$W relay-status TASK_ID              # 查询 relay 任务状态
```

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
2. 读操作直接通过 RPC 执行。**写操作根据 `--gasless` 参数决定：指定 `--gasless gelato` 时走 Gelato relay 免 gas，否则直接发送（自付 gas）**。根据平台返回的合约 `gasless` 字段判断。
3. 所有参数必须是真实值 — 不得伪造地址、金额或签名。
4. 如缺少必需参数，向用户询问。
5. 出错时，阅读对应脚本源码进行排查。
6. 使用用户的语言回复。
