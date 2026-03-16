# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "web3>=7.0,<8",
#   "eth-abi>=5.0,<6",
#   "httpx>=0.27",
#   "python-dotenv>=1.0",
# ]
# ///

"""Wallet skill CLI entry point.

Usage:
  uv run scripts/run.py <command> [options]
  uv run scripts/run.py --help
  uv run scripts/run.py -c "<python code>"   (advanced escape hatch)

Commands:
  address              Show wallet address
  eth-balance          Native token balance
  balance              ERC20 token balance
  list-functions       List contract read/write functions
  call                 Read contract state (view/pure)
  invoke               Write to contract (sends tx)
  approve              ERC20 approve (skip if allowance sufficient)
  approve-and-invoke   Approve + contract call in one step
  sign-message         EIP-191 message signing
  sign-typed-data      EIP-712 typed data signing
  decode-logs          Parse transaction event logs
  decode-revert        Decode revert error data
  to-raw               Human amount -> raw integer
  fmt                  Raw integer -> human readable
"""

import sys, os, subprocess, json, argparse

DEPS = ["web3>=7.0,<8", "eth-abi>=5.0,<6", "httpx>=0.27", "python-dotenv>=1.0"]

def _ensure_deps():
    try:
        import web3, eth_abi, httpx, dotenv  # noqa: F401
    except ImportError:
        print("Installing wallet skill dependencies...", file=sys.stderr)
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "-q"] + DEPS,
            stdout=sys.stderr,
        )

scripts_dir = os.path.dirname(os.path.abspath(__file__))
if scripts_dir not in sys.path:
    sys.path.insert(0, scripts_dir)

_ensure_deps()

# --- -c escape hatch (check before argparse) ---
if len(sys.argv) >= 3 and sys.argv[1] == "-c":
    exec(sys.argv[2])
    sys.exit(0)

# --- CLI output helpers ---
def _out(data):
    """Print JSON to stdout."""
    print(json.dumps(data, ensure_ascii=False, indent=2) if isinstance(data, (dict, list)) else data)

def _error(error_type: str, detail: str, exit_code: int):
    """Print structured JSON error to stderr, then exit."""
    json.dump({"error": error_type, "detail": detail, "exit_code": exit_code},
              sys.stderr, ensure_ascii=False)
    sys.stderr.write("\n")
    sys.exit(exit_code)

# --- CLI subcommands ---

def cmd_address(_args):
    from wallet import address
    _out(address())

def cmd_eth_balance(args):
    from wallet import eth_balance
    _out(eth_balance(args.chain))

def cmd_balance(args):
    from erc20 import balance
    _out(balance(args.token, owner=args.owner, chain_id=args.chain))

def cmd_list_functions(args):
    from abi import list_functions
    _out(list_functions(args.contract))

def cmd_call(args):
    from abi import call
    parsed_args = json.loads(args.args) if args.args else None
    _out(call(args.contract, args.sig, parsed_args,
              chain_id=args.chain, from_address=getattr(args, 'from_addr', None)))

def cmd_invoke(args):
    from abi import invoke
    parsed_args = json.loads(args.args) if args.args else None
    if args.dry_run:
        from wallet import _estimate_gas
        _out(_estimate_gas(args.contract, args.sig, parsed_args,
                           chain_id=args.chain, value=args.value))
    else:
        _out(invoke(args.contract, args.sig, parsed_args,
                    chain_id=args.chain, value=args.value))

def cmd_approve(args):
    from erc20 import approve
    _out(approve(args.token, args.spender, args.amount, chain_id=args.chain))

def cmd_approve_and_invoke(args):
    from erc20 import approve_and_invoke
    parsed_args = json.loads(args.args) if args.args else None
    _out(approve_and_invoke(args.token, args.contract, args.amount,
                            args.sig, parsed_args, chain_id=args.chain, value=args.value))

def cmd_sign_message(args):
    from wallet import sign_message
    _out(sign_message(args.message))

def cmd_sign_typed_data(args):
    from wallet import sign_typed_data
    data = json.loads(args.data) if isinstance(args.data, str) else args.data
    _out(sign_typed_data(data))

def cmd_decode_logs(args):
    from decoder import decode_logs
    _out(decode_logs(args.tx_hash, args.contract, chain_id=args.chain))

def cmd_decode_revert(args):
    from decoder import decode_revert
    _out(decode_revert(args.data, contract_address=args.contract, chain_id=args.chain))

def cmd_to_raw(args):
    from wallet import to_raw
    _out(to_raw(args.amount, args.decimals))

def cmd_fmt(args):
    from wallet import fmt
    _out(fmt(args.raw, args.decimals, args.symbol))

def main():
    parser = argparse.ArgumentParser(
        description="Wallet skill — EVM wallet operations",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    # address
    sub.add_parser("address", help="Show wallet address")

    # eth-balance
    p = sub.add_parser("eth-balance", help="Native token balance")
    p.add_argument("--chain", type=int, default=10)

    # balance (erc20)
    p = sub.add_parser("balance", help="ERC20 token balance")
    p.add_argument("token", help="Token contract address")
    p.add_argument("--owner", help="Owner address (default: current wallet)")
    p.add_argument("--chain", type=int, default=10)

    # list-functions
    p = sub.add_parser("list-functions", help="List contract functions")
    p.add_argument("contract", help="Contract address or ABI file path")

    # call
    p = sub.add_parser("call", help="Read contract state (view/pure)")
    p.add_argument("contract", help="Contract address")
    p.add_argument("sig", help="Function signature, e.g. 'balanceOf(address)->(uint256)'")
    p.add_argument("--args", help="JSON array of arguments", default="[]")
    p.add_argument("--chain", type=int, default=10)
    p.add_argument("--from", dest="from_addr", help="Simulate msg.sender")

    # invoke
    p = sub.add_parser("invoke", help="Write to contract (sends tx)")
    p.add_argument("contract", help="Contract address")
    p.add_argument("sig", help="Function signature")
    p.add_argument("--args", help="JSON array of arguments", default="[]")
    p.add_argument("--chain", type=int, default=10)
    p.add_argument("--value", type=int, default=0, help="ETH value in wei")
    p.add_argument("--dry-run", action="store_true",
                   help="Estimate gas and show tx details without executing")

    # approve
    p = sub.add_parser("approve", help="ERC20 approve (skip if allowance sufficient)")
    p.add_argument("token", help="Token contract address")
    p.add_argument("spender", help="Spender address")
    p.add_argument("amount", help="Amount in raw units")
    p.add_argument("--chain", type=int, default=10)

    # approve-and-invoke
    p = sub.add_parser("approve-and-invoke", help="Approve + contract call in one step")
    p.add_argument("token", help="Token contract address")
    p.add_argument("contract", help="Contract to invoke")
    p.add_argument("amount", help="Approve amount in raw units")
    p.add_argument("sig", help="Function signature to invoke")
    p.add_argument("--args", help="JSON array of arguments", default="[]")
    p.add_argument("--chain", type=int, default=10)
    p.add_argument("--value", type=int, default=0)

    # sign-message
    p = sub.add_parser("sign-message", help="EIP-191 message signing")
    p.add_argument("message", help="Message to sign")

    # sign-typed-data
    p = sub.add_parser("sign-typed-data", help="EIP-712 typed data signing")
    p.add_argument("data", help="Typed data (JSON string or file path)")

    # decode-logs
    p = sub.add_parser("decode-logs", help="Parse transaction event logs")
    p.add_argument("tx_hash", help="Transaction hash")
    p.add_argument("contract", help="Contract address (for ABI)")
    p.add_argument("--chain", type=int, default=10)

    # decode-revert
    p = sub.add_parser("decode-revert", help="Decode revert error data")
    p.add_argument("data", help="Hex error data")
    p.add_argument("--contract", help="Contract address (for custom errors)")
    p.add_argument("--chain", type=int, default=10)

    # to-raw
    p = sub.add_parser("to-raw", help="Human amount -> raw integer")
    p.add_argument("amount", type=float, help="Human-readable amount")
    p.add_argument("--decimals", type=int, default=18)

    # fmt
    p = sub.add_parser("fmt", help="Raw integer -> human readable")
    p.add_argument("raw", type=int, help="Raw integer amount")
    p.add_argument("--decimals", type=int, default=18)
    p.add_argument("--symbol", default="", help="Token symbol")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    dispatch = {
        "address": cmd_address, "eth-balance": cmd_eth_balance,
        "balance": cmd_balance, "list-functions": cmd_list_functions,
        "call": cmd_call, "invoke": cmd_invoke,
        "approve": cmd_approve, "approve-and-invoke": cmd_approve_and_invoke,
        "sign-message": cmd_sign_message, "sign-typed-data": cmd_sign_typed_data,
        "decode-logs": cmd_decode_logs, "decode-revert": cmd_decode_revert,
        "to-raw": cmd_to_raw, "fmt": cmd_fmt,
    }

    try:
        dispatch[args.command](args)
    except FileNotFoundError:
        _error("ConfigError", ".env file not found. Run: cp .env.example .env", 4)
    except RuntimeError as e:
        if "revert" in str(e).lower():
            _error("ContractRevert", str(e), 2)
        _error("RuntimeError", str(e), 3)
    except ConnectionError as e:
        _error("NetworkError", str(e), 3)
    except TimeoutError as e:
        _error("NetworkError", f"Request timed out: {e}", 3)
    except Exception as e:
        _error("Error", str(e), 3)

if __name__ == "__main__":
    main()
