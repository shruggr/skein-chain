# skein-chain

The chain module for [skein](https://github.com/shruggr/skein): the one
writer of an instance's chain state — headers, transactions, proofs,
spends, settlement, broadcasts — under the head `chain/state`, which
everyone else reads by CID. shruggr/skein#78. The contract is
[docs/CHAIN.md](docs/CHAIN.md).

```
{fn: "ingest", args: {beef}}   proven: recorded, answered at once
                               unproven: recorded, broadcast, answered on each state change
                               (accepted, proven, rejected) at the caller's address
{fn: "status", args: {txid}}   its state: CIDs (tx, block, settlement, broadcast)
{fn: "proof",  args: {txid}}   where its proof is: block, height, depth, position
```

from the instance's own apps (`$self`: the wallet, the overlay apps) and
the owner; and the host's events (headers, the broadcaster's proofs: the
`event` row) and the status provider's messages.

## Layout

```
bin/chain.wasm     the program (wasm32-wasi; committed, reproducible: `zig build bin`)
etc/app.json       the manifest (skein docs/APPS.md §2, the #77 shape)
src/main.zig       the steps: messages, events, statuses, the awaiting thread; the reads as a call
src/shape.zig      configuration, functions, answer shapes (pure; test.zig)
src/vm.zig         the `skein` imports over the SDK chain library's values
docs/CHAIN.md      the contract
```

The chain state itself — its records, ingest, SPV, settlement, the
registered broadcasts — is the SDK's chain library (shruggr/skein-sdk,
module `chain`, ≥ 0.4.0, `chain/src/state.zig`), a URL+hash dependency in
`build.zig.zon`; bsvz comes through it.

## Build

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/chain.wasm
zig build bin      # the same into bin/chain.wasm (commit it)
zig build test     # src/shape.zig natively
```

With a sibling SDK checkout: `zig build --fork=../skein-sdk`. The flow
through a kernel (ingest, broadcast, statuses, proofs, the answers, at
install and at boot, replay) is skein's `kernel-zig/equiv/chain.ts`, which
installs this repo at a pinned commit.

## Install

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle> --approve-all
```

MIT, as skein.
