from abi import call, invoke
from wallet import address, fmt

def balance(token: str, owner: str | None = None, *, chain_id: int = 10) -> dict:
    if owner is None:
        owner = address()
    raw = call(token, "balanceOf(address)->(uint256)", [owner], chain_id=chain_id)
    decimals = call(token, "decimals()->(uint8)", [], chain_id=chain_id)
    symbol = call(token, "symbol()->(string)", [], chain_id=chain_id)
    return {"raw": str(raw), "formatted": fmt(raw, decimals, symbol),
            "symbol": symbol, "decimals": decimals}

def approve(token: str, spender: str, amount: str | int, *, chain_id: int = 10) -> dict | None:
    owner = address()
    allowance = call(token, "allowance(address,address)->(uint256)", [owner, spender], chain_id=chain_id)
    if int(allowance) >= int(amount):
        return None
    return invoke(token, "approve(address,uint256)", [spender, str(amount)], chain_id=chain_id)

def approve_and_invoke(
    token: str, contract: str, amount: str | int,
    sig: str, args: list[str] | None = None,
    *, chain_id: int = 10, value: int = 0
) -> dict:
    approve(token, contract, amount, chain_id=chain_id)
    return invoke(contract, sig, args, chain_id=chain_id, value=value)
