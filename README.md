# Morpheus H-001 PoC: self-referral dilutes other stakers' MOR rewards

Foundry proof of concept for a Low-severity finding in the Morpheus
DepositPool (stETH) on Ethereum mainnet.

A staker who names their own address as referrer earns an extra 23.72 MOR
(about $16.54) over 15 days per 100 stETH staked, taken from other stakers'
share of the fixed daily emission.

## Run it

```sh
forge test
```

That is the whole setup. The tests fork Ethereum mainnet at block 26430188
through the public RPC in `foundry.toml` (no API key needed).

## What the tests prove

- `testSelfReferralDilution`: two accounts stake 100 stETH each for 15 days.
  The self-referrer ends with 171.95 MOR (149.71 user + 22.23 referrer)
  vs 148.23 MOR for the identical honest stake. Difference: 23.72 MOR.
- `testReferrerClaimExecutes`: the referrer leg actually pays out on the fork
  (22.47 MOR in the single-staker variant), after the 14 day claim lock and
  the 0.5 ETH LayerZero fee.

## Target

DepositPool (stETH) `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790` on Ethereum
mainnet, block 26430188. No privileged role, no special state. Fork only,
nothing here touches mainnet.

## Suggested fix

Reject `referrer_ == user_` in `_stake` (and in
`manageUsersInPrivateRewardPool`), and clear referrer data on existing
self-referrals.
