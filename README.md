# skein-chain

The chain app for a [skein](https://github.com/shruggr/skein): the one
writer of an instance's chain state (headers, transactions, proofs, spends,
settlement, broadcasts) under the head `chain/state`, which every other app
reads by CID. It is the only thing on an instance that broadcasts. Version
**0.2.0**.

## What it is

One program, `bin/chain.wasm`, over the SDK's `chain` module (the records
live in `chain/src/state.zig` there; this repo is the VM glue and the
manifest). Its interface is `chain/1` on box `chain`:

| fn | args | writes | answered |
|---|---|---|---|
| `ingest` | `{beef}` | yes | proven in: at once. Unproven in: recorded, broadcast, then once per state change: `accepted`, then `proven` or `rejected` |
| `status` | `{txid}` | no | at once: `{txid, state, tx?, block?, height?, txStatus?, broadcast?, reason?, settlement?}` (CIDs) |
| `proof` | `{txid}` | no | at once: `{txid, tx, block, height, depth, position}` |

Its dispatch rows (`etc/app.json`):

| box | sender | carries |
|---|---|---|
| `chain` | `event` | the host's events: a header from a feed, a proof from the broadcaster. Events only, never a message |
| `chain` | `$self` | calls from the instance's own apps (the wallet, overlays), by the host's loopback |
| `chain` | `$owner` | calls from the owner |
| `status` | `$status` | the status provider's messages; `optional`: left out on a host with no status provider |

Calls hand back CIDs, not data. The wallet and the overlay apps never
broadcast and never take headers, proofs or statuses: they send `ingest` to
the instance itself and await the answers.

**What is built and where it goes.** Today an ingest's caller is answered
until the transaction is `proven` or `rejected`, and then the registration
ends. The decided direction (shruggr/skein#31, "Decided 2026-10-02
(night)") is that a reference to a transaction is a subscription for the
life of the transaction: every registration is kept, and every change of
its chain state (accepted, proven, reorged out, conflicted by a proven
spend) reaches every registrant, which reads the chain state again. That is
not built yet.

## Use it

Install it into an instance, before anything that requires `chain/1`:

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle>
```

The install reads the rows aloud and asks; `--approve-all` skips the
question.

What the host must provide:

- **A headers feed** (the host's `SKEIN_HEADERS_URL`). Without headers the
  app proves nothing: there is nothing to check a BUMP against.
- **A broadcaster** (the host's `SKEIN_ARC_URL`, its `status` provider).
  Without one, an unproven transaction is not broadcast and its status is
  not followed. An install on a host with no status provider leaves the
  `$status` row out and says so in the install prompt.

Arcade is one channel, not the only one. A transaction handed to someone
else (a payment) is broadcast by them and held here as spent but unproven;
its proof may arrive later in a BEEF someone sends. An unproven transaction
only has to resolve when it is referenced again.

Then, from a program of the same instance (Zig, over the SDK):

```zig
// me: the instance's own key (the step input's `self.identity`).
// body: {fn: "ingest", args: {beef}}. Sent to the instance itself, box "chain"; the thread rests on the message.
const id = try sk.emit(a, me, "chain", body, null);
try sk.awaitRecord(id);
```

Each answer is a message `{fn, request, replyTo, result: {txid, tx, state,
…}}` (or `{…, error: {code, message}}`) that steps the awaiting thread.
Readers that only need state read `head("chain/state")` and walk it with the
SDK's `chain.state`.

Configuration is `config.chain` in the manifest: `network` (`main`, `test`,
`regtest`). Where it says nothing, the genesis default `walletNetwork`
applies, else `main`. The chain app never rejects a transaction on a clock
of its own: one it cannot prove stays unproven for as long as it is held.

An instance can also wire it at boot from a system tree: `bin/chain.wasm`
plus the same four rows in `etc/dispatch.json`; the program named `chain`
writes `chain/…` (skein `docs/BOOTSTRAP.md`).

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/chain.wasm
zig build bin      # the same into bin/chain.wasm (commit it; the build is reproducible)
zig build test     # src/shape.zig natively
```

With a local SDK checkout: `zig build --fork=../skein-sdk`. The flow through
a kernel (install, ingest, broadcast, statuses, proofs, the answers, at boot
too, replay) is skein's `kernel-zig/equiv/chain.ts`, which installs this repo
at a pinned commit.

| file | what |
|---|---|
| `bin/chain.wasm` | the program (wasm32-wasi) |
| `etc/app.json` | the manifest |
| `src/main.zig` | the steps: messages, events, statuses, the awaiting thread; the reads as a call |
| `src/shape.zig` | configuration, functions, answer shapes (pure) |
| `src/vm.zig` | the `skein` imports over the SDK chain library's values |

## Docs

| what | where |
|---|---|
| the contract: state, maps, ingest, answers, events | [docs/CHAIN.md](docs/CHAIN.md) |
| broadcast out, proofs and statuses in | skein `docs/MESSAGES.md` |
| apps, manifests, install | skein `docs/APPS.md` |

## Versions

| | |
|---|---|
| this app | 0.2.0 (tag `v0.2.0`) |
| skein-sdk | v0.4.0, by tag tarball and hash in `build.zig.zon` (module `chain`; bsvz comes through it) |
| skein | log format 8; skein's equivs pin this repo by commit |

0.2.0 split the open `chain` box into the `event`, `$self` and `$owner` rows
(shruggr/skein#79); 0.1.0 was the first release (shruggr/skein#78).

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
