# Reactive Omni gap catcher

Entry for the Reactive Omni Buildathon (Every Second Counts). Work in progress.

## Day-1 probe

A bare origin event → Lasna `react()` → callback loop, timed end to end on the origin chain's own clock.

| Route | Delivered | p50 | p95 |
|---|---|---|---|
| Base Sepolia → Lasna → Base Sepolia | 20/20 | 1.6 s | 2.6 s |
| Unichain Sepolia → Lasna → Unichain Sepolia | 10/10 | 2.0 s | 2.0 s |

Reproduce: `forge build`, then `python scripts/probe_latency.py base 20` (needs `DEPLOYER_PRIVATE_KEY` and Foundry's `cast`). Raw rows are in `results/`.
