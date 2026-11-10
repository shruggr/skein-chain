# skein-chain

The chain app for a [skein](https://github.com/shruggr/skein): the one
writer of an instance's chain state (headers, transactions, proofs, spends,
settlement, broadcasts) under the head `chain/state`, which every other app
reads by CID. It is the only thing on an instance that broadcasts. Version
**0.7.1**.

## What it is

One program, `bin/chain.wasm`, over the SDK's `chain` module (the records
live in `chain/src/state.zig` there; this repo is the VM glue and the
manifest). Its interface is `chain/1` on box `chain`:

| fn | args | writes | answered |
|---|---|---|---|
| `ingest` | `{beef}` | yes | a message (proven in: answered at once; unproven in: recorded, broadcast) or, 0.10.0, an in-VM call from a program's step (answered `{txid, status, height?, reason?, by?}`: the step's own write) |
| `status` | `{txid}` | no | at once: `{txid, state, tx?, block?, height?, txStatus?, broadcast?, reason?, settlement?}` (CIDs) |
| `proof` | `{txid}` | no | at once: `{txid, tx, block, height, depth, position}` |

Its routes (`etc/app.json`, shruggr/skein#143):

| transport | box | filters | carries |
|---|---|---|---|
| `event` | `chain` | — | the host's events: `chain` (the host chain's record, once per block, at install and at each start), a proof from the broadcaster. Events only, never a message |
| `mailbox` | `chain` | `kernel.beef` | calls from anyone the kernel admits: the instance's own apps (the wallet, overlays) and root. Open (no role gates `ingest`, `status`, `proof`); `kernel.beef` hands `ingest` the BEEF's pointer record |
| `mailbox` | `chain/status` (written `"status"`, shruggr/skein#128) | — | the status provider's messages |

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

- **The host chain** (shruggr/skein#156): the host keeps the header chain
  once, in its kernel process (fed by its `SKEIN_HEADERS_URL`; a fresh host
  bootstraps it from the image's `chain/headers`), and sends this app a
  `chain` event naming its record; the app's state points at it, never
  copies it (docs/CHAIN.md, "The header chain is the host's"). Without it
  the app proves nothing: there is nothing to check a BUMP against.
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
plus the same three routes; the program named `chain`
writes `chain/…` (skein `docs/BOOTSTRAP.md`).

## Build and test

Zig 0.16.0 (`mise.toml`).

```
zig build          # zig-out/bin/chain.wasm
zig build bin      # the same into bin/chain.wasm (commit it; the build is reproducible)
zig build test     # src/shape.zig natively, over a chain state in memory
```

With a local SDK checkout: `zig build --fork=../skein-sdk`. The flow through
a kernel (install, ingest, broadcast, statuses, proofs, the answers, at boot
too, replay) is skein's `kernel-zig/equiv/chain.ts`, which installs this repo
at a pinned commit.

| file | what |
|---|---|
| `bin/chain.wasm` | the program (wasm32-wasi) |
| `etc/app.json` | the manifest |
| `src/main.zig` | the steps: messages, events, statuses, the awaiting thread, the `outputs` subscription; the reads and `ingest` as a call |
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
| this app | 0.11.0 (tag `v0.11.0`) |
| skein-sdk | 0.21.0 (commit c08e74d on branch `proof-events`, until tagged), by tag URL and hash in `build.zig.zon` (module `chain`; bsvz comes through it) |
| skein | 0.5.4 or later (the event index, 0.5.0: the facts; a thread resting on a name, 0.5.4: the listeners); skein's equivs pin this repo by commit |

0.11.0 (David 2026-11-10; skein-sdk 0.21.0): a saved merkle path links EVERY transaction it covers (skein-sdk's one writer, `putProof`: each level-0 hash whose root is the header's, held or not, its own offset), and each linkage is the fact `chain/proof/<txid>` `{block, height, position}`, raised once. A transaction taken in subscribes its fn `proof` to its own `chain/proof/<txid>` beside `outputs`; covered already at intake, it is `mined` at once (its status read from the state) and never broadcast; linked later, the subscription step settles what the proof settles (skein-sdk `settleProven`: double spends, its broadcast record) and raises `chain/tx/<txid>` `mined` with its height when the latest fact is not already that. Every other dependency the same way, each re-read from the state on every wake: a transaction subscribes `parents` to each of its parents' `chain/tx` (a parent rejected → `rejected` `input-rejected` by the root; no parent rejected any more → `revived`: pending, broadcast again; the fact steps its own children in turn — the walk at the source goes); and `children` to its own `chain/tx`, so a proven child lifts its parents' rejections (unproven, broadcast again); a mined transaction subscribes `block` to `chain/block/<hash>` `{height, active}`, raised when a block a linkage names leaves our best chain or comes back (`seen` reason `reorged`, or `mined` again — the inline reorg walk goes). A rejection never stands for a transaction with a proven descendant; a proof overrides a rejection, also after a reorg; a proof before its header is kept whatever the status. Release notes: a FRESH HOME is required — a chain state from before is refused when opened ("chain state from before 0.11.0: relaunch on a fresh home"), and transactions held before have none of these subscriptions; a revived parent (its rejection lifted because a child is proven) stays unproven with a registered broadcast until its own proof arrives; a parked path for a fork block is dropped if a different branch's header arrives at that height (the proof must come again).
0.10.0 (David 2026-11-09; skein-sdk v0.19.0): four statuses — `pending` (at intake: held, broadcast asked for, no answer yet), `seen` (was `accepted`; after a reorg `seen` with `reason: "reorged"`, no `reorged` word), `mined` (`height`), `rejected` (`reason`; `by` the winner of a double spend, or the root of an `input-rejected` cascade) — and every transaction gets one at intake (`mined` when it comes proven, BEEF ancestors included). Output states: `chain/output/<txid>.<vout>` `{state: spent | rolledBack, spentBy}`, the latest message the output's current state; wired by subscription — the app subscribes its fn `outputs` to `chain/tx/<T>` when it first holds T, and every status fact of T walks the outputs T spends from the chain state (the live spender: held, not rejected, a mined one first) and posts what differs from the latest message (an output with no message and no live spender gets none; coinbase inputs skipped; no backfill). `ingest` as an in-VM call (the app writes its state, subscribes, emits the statuses and the broadcast in the caller's step; nothing awaited); a kernel call of it is refused. The message form stays for the senders that still use it. Contract: agent-env plans/research/chain-contract-2026-11-09.md.
0.9.0: a status is a transaction's latest fact (David 2026-11-09): a valid proof makes it `mined` also after a rejection — the proof event or a BEEF carrying it proves it, the fact `mined` with its height is emitted (no broadcast record left to settle: no watchers), its inputs' spends are counted again; the settlement record stays, read for its reason (skein-sdk v0.18.0). 0.8.0: every status of a transaction is a fact (David 2026-11-09): recorded, and emitted as `<app>/tx/<txid>` `{status: accepted | mined (height) | rejected | reorged}` (skein 0.5.0's event index; a listener rests on the name, skein 0.5.4); an ingest emits its subject's status as it stands; the watchers list goes (`ingest` no longer registers its caller: it is answered once, at the ingest, when there is a status or an error); the proof event's `via` is kept on the result record only; skein-sdk v0.17.2. 0.7.1: a reorg broadcasts nothing (the settled overlay sync design, David 2026-10-30): the transactions it turns back to unproven are not broadcast again nor awaited by the step; the new proof arrives as the first did, through the host's status feed (a new block hash is a new status, routed as a proof event), and is answered to every watcher. 0.7.0: the header chain is the host's (shruggr/skein#156): the event `chain {root, height}` points the state's `headers` and `heights` at the host chain record (skein-sdk v0.12.0 `State.pointAt`; a reorg the host took reverts the proofs above the fork); a `header` event is refused; the first step no longer loads the image's chain (the host bootstraps its own chain from it), and the result record has `chain: {root, height, fork}`, no `image`. 0.6.1: `ingest` sorts a BEEF that came out of order (a child before its parent: ts-sdk's writer puts a proven child before its proven parent) parents-first and verifies it, instead of refusing `NotParentsFirst` (skein-sdk v0.11.1; David Case, 2026-10-22); SPV is as strict as before. 0.6.0: `ingest {beef}` takes the envelope the kernel's door writes beside the pointer record (`{form, beef, subject?, vout?}`, shruggr/skein#146), read back with skein-sdk v0.11.0 `chain.record.wireOf`; a Subject BEEF (BRC-233) ingests like the other forms. 0.5.0: routes, no senders (shruggr/skein#143; skein-sdk v0.9.0). 0.4.0: the first step on an instance whose tree carries a header chain (`chain/headers`, the image's: shruggr/skein#132) loads it into the empty state — the whole chain from genesis, verified (skein-sdk v0.8.0 `chain.image`); the result record's `image: {headers, tip}`. 0.3.2: a proof after a reorg is answered to the same watchers as the first, with its `block` (#2; skein-sdk v0.7.1 keeps a proven transaction's watchers; the app uses only the SDK's `chain` module, so 0.7.0's `sk` changes — intentions, `authfetch`, no `provider(role)` — touch nothing here). 0.3.1: the status provider's box is `chain/status` (the manifest still writes `"status"`; skein resolves a box under the app's name, shruggr/skein#128). 0.3.0: `ingest {beef: <cid>}` takes the BEEF as its pointer record, and the `$self`/`$owner` rows name `filter: "beef"` (shruggr/skein#121); no abandonment: the app never rejects on its own clock (#1). 0.2.0 split the open `chain` box into the `event`, `$self` and `$owner` rows
(shruggr/skein#79); 0.1.0 was the first release (shruggr/skein#78).

## Contributing

Work is tracked in shruggr/skein; start at issue
[#31](https://github.com/shruggr/skein/issues/31). MIT, as skein.
