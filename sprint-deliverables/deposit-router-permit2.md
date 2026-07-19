# DepositRouter With Permit2

This is the recommended periphery design for one-click deposits after the
`depositFor` payer-model fix.

## Goal

Users should be able to deposit with a Permit2 signature without approving the
vault directly. The router may bind referrals and submit the deposit into the
vault, but it must not let an arbitrary caller choose a third-party payer.

## Safe Payer Model

Unsafe legacy model:

```solidity
vault.depositFor(amount, receiver, payer);
```

Safe current model:

```solidity
permit2 pulls user USDC to DepositRouter
DepositRouter approves vault
vault.depositFor(amount, user)
```

or:

```solidity
permit2 pulls user USDC to DepositRouter
DepositRouter approves vault
vault.deposit(amount, user)
```

Both are safe because, from the vault's point of view, `msg.sender` is the
router and the router is the token source.

## Mode A: Permit2 SignatureTransfer

Use this for one-time signed deposits.

Flow:

1. User signs a Permit2 `SignatureTransfer` permit for USDC and amount.
2. User calls `DepositRouter.depositWithPermit2Transfer`.
3. Router calls Permit2 to transfer USDC from user to router.
4. Router calls vault deposit entry with `receiver = user`.
5. Router optionally binds referral.

Properties:

- per-deposit signature
- no long-lived token allowance to the router
- good default for retail UX

## Mode B: Permit2 AllowanceTransfer

Use this for repeat deposits where the user has already granted Permit2
allowance.

Flow:

1. User signs or has an active Permit2 allowance for the router.
2. Router calls Permit2 `transferFrom`.
3. Router deposits into the vault for the user.
4. Router optionally binds referral.

Properties:

- cheaper repeat path after allowance is set
- expiry and nonce must be handled carefully
- useful for recurring or automated deposit UX

## Router Invariants

The production router should enforce:

- `amount > 0`
- `receiver == msg.sender` unless a deliberate delegated-deposit feature is
  designed and signed
- Permit2 token is exactly the vault asset
- Permit2 transfer recipient is the router itself
- vault call uses `depositFor(amount, receiver)` or `deposit(amount, receiver)`
- router never exposes a vault call with arbitrary `payer`
- referral binding happens after successful token pull/deposit or is otherwise
  made idempotent

## Core Compatibility

The core repo currently supports the safe router model:

- `ERC4626Module.depositFor(uint256 assets, address receiver)` uses
  `msg.sender` as payer.
- `deposit(uint256 assets, address receiver)` also pulls from `msg.sender`, so
  it is compatible with a router that already holds user funds.
- `test/sprint-test/DepositFor_UnauthorizedPayer_POC.t.sol` covers the old
  approval-theft bug and the positive router path.
- `test/mocks/MockDepositRouter.sol` is a core-boundary test double. It bypasses
  Permit2 but models the same custody shape: router receives tokens first, then
  deposits for the user.

## Minimal Production Sketch

```solidity
function depositWithPermit2Transfer(
    uint256 amount,
    address referrer,
    PermitTransferFrom calldata permit,
    SignatureTransferDetails calldata details,
    bytes calldata signature
) external returns (uint256 shares) {
    require(amount > 0, "amount=0");
    require(permit.permitted.token == address(asset), "bad-token");
    require(details.to == address(this), "bad-recipient");
    require(details.requestedAmount == amount, "bad-amount");

    permit2.permitTransferFrom(permit, details, msg.sender, signature);

    asset.forceApprove(address(vault), amount);
    shares = vault.depositFor(amount, msg.sender);

    if (referrer != address(0)) {
        referralBinding.bind(msg.sender, referrer);
    }
}
```

The exact Permit2 interfaces should come from Uniswap Permit2 in the periphery
repo. The important invariant is not the specific helper function name; it is
that the vault never receives a user-supplied payer address.
