# Morpheus BuildersV4 — Post-Deposit Lock Rewrite PoC (C-1)

Fork-only Foundry proof of concept for a Morpheus bug bounty finding against
**BuildersV4** on Base (`0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`).

**Finding:** `editSubnet` lets a subnet admin raise `withdrawLockPeriodAfterDeposit`
*after* users have deposited — `_validateSubnet` enforces only the 7-day minimum,
with no upper bound and no time gate — and `withdraw()` checks the lock against the
**current** subnet storage value rather than a per-user snapshot from deposit time.
Setting the lock to `type(uint128).max` after a victim deposits therefore locks the
victim's principal permanently (a lock, not a theft: nobody can withdraw it).
Test 1 demonstrates the attack end-to-end; Test 2 is the control (no edit → the
victim withdraws in full after 7 days). See `test-output.txt` for a recorded run.

## Run

```bash
BASE_RPC_URL=https://base-rpc.publicnode.com forge test
```

(any Base mainnet RPC with archive access at the pinned block works).
The fork is pinned to **Base block 58522987** in `setUp()` via
`vm.createSelectFork(vm.envString("BASE_RPC_URL"), 58522987)`.

## Safety

This is a **fork-only** PoC: it reads and simulates against a local fork of Base
mainnet state and must **never** be run against live mainnet. No real funds,
accounts, or subnets are touched.
