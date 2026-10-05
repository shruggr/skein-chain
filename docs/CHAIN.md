# The chain app (0.2.0)

shruggr/skein#78 (decided 2026-10-01, the tracker issue #31: "the chain is
its own head, owned by a chain module"). **The chain state is global to an
instance**: anyone who references a transaction needs to be able to verify
its chain state. It lives under the chain app's heads, `chain/…`, and the
chain app is its **one writer**: headers, transactions, proofs, spends,
settlement, broadcasts. The wallet and each overlay keep their own records
under their own names and **read** the chain state by CID (`head("chain/state")`,
then `get`); a reader that needs a pointer it does not hold calls the chain
app, and the call hands back CIDs, not data.

What this repo is: the app — `bin/chain.wasm` (Zig 0.16.0, wasm32-wasi)
and `etc/app.json` — over the chain library of shruggr/skein-sdk (module
`chain`, ≥ 0.4.0: `chain/src/state.zig` holds the records; this program is
the VM glue). The skein side (the kernel, the host, the install, the
dispatch table) is shruggr/skein: docs/APPS.md, docs/MESSAGES.md
("Broadcast out, proofs and statuses in"), and the end-to-end case
`kernel-zig/equiv/chain.ts`.

## Its state

The head `chain/state` (`<app>/state`; the app record is `chain/app`):

```
{kind: "chain-state", network: "main" | "test" | "regtest", maps: {<name>: <MST root> | null}}
```

| map | key → value | |
|---|---|---|
| `headers` | height (u32 BE) → header (`bitcoin-block` link) | the best chain, anchored at the network's genesis header |
| `heights` | block hash → height | the best chain, backwards |
| `txs` | txid → transaction (`bitcoin-tx` link) | every transaction ingested; each kept, so its inputs are the kernel's `spends` edges (#42) |
| `proofs` | txid → `{block, depth, position}` | its block's header (a link) and its leaf; the merkle nodes are 64-byte `bitcoin-tx` blocks under the header's root (a BUMP is rebuilt by descent: `merkle.pathFor`) |
| `proofHeights` | height ‖ txid → null | what a reorg reverts |
| `rejected` | txid → settlement record | `{kind: "settlement", txid, status: "rejected", reason, at, cause?}` |
| `unproven` | txid → null | derived: held, neither proven on the best chain nor rejected |
| `spent` | txid ‖ vout → spending txid | derived: the first held spender that is not rejected |
| `broadcasts` | txid → broadcast record | the broadcast each unproven transaction has registered |

Keys are bytes ordered bytewise (the kernel's Merkle search trees, the
SDK's `mst`); txids and block hashes in internal byte order.

**Every unproven transaction at rest has a registered broadcast**: a
transaction is in `unproven` only while `broadcasts` holds its record:

```
{kind: "broadcast", txid (hex), subject: <tx CID>, since: ms, txStatus,
 accepted?: true, path?: bytes, watchers: [{to: bytes(33), box, request: <message CID>}]}
```

`since` is its first broadcast; `accepted` is set by
the first status that is not a rejection; `path` is a proof that came
before its header (tried again when headers arrive); `watchers` are the
callers answered on each state change. Proven or rejected, the record goes.

Status is computed from the records: **rejected** (a settlement record),
**proven** (its proof's block is on the best chain), else **unproven**. A
rejection walks the held transactions that spend it (the `spends` edges)
and rejects them too (`input-rejected`, `cause` the first); a proof rejects
every other held transaction spending one of the same outputs
(`double-spent`). Nothing else rejects: a transaction the chain app cannot
prove stays known and unproven for as long as it is held, and the threads
of its watchers keep waiting. A proven transaction is never rejected.
A reorg that replaces the block a proof names turns the transaction back to
unproven: its broadcast is registered again and it is broadcast again.

The chain tracker's rules are the SDK's (`chain/src/chain.zig`): every
header must chain back to the network's genesis header; usable target,
proof of work, links; a heavier branch replaces ours from the fork point.
Not checked, by decision (#29 Q3): the difficulty-adjustment rule,
timestamps, versions.

## Its interface

One box, `chain` (the app's name), taking the host's events (its `event`
row) and `{fn, args}` from the instance's own apps and the owner (shruggr/skein#79:
its rows from `$self` and `$owner`, not an open box); and `status`, the
status provider's messages.

| fn | args | writes | answers |
|---|---|---|---|
| `ingest` | `{beef}`: a BEEF pointer record's CID (skein #121), or bytes, or hex | yes | proven in: at once; unproven in: on each state change |
| `status` | `{txid}` (hex, display order) | no | at once |
| `proof` | `{txid}` | no | at once |

`chain.ingest`, `chain.status`, `chain.proof` (docs/APPS.md §4's dotted
form; the interface is `chain/1`) are the same functions; the answer
echoes `fn` as sent.

**A BEEF comes in as its pointer record** (shruggr/skein#121). The rows
that take callers' messages (`chain` from `$self` and from `$owner`) name
`filter: "beef"`: the kernel's door, before the message's entry is
written, decodes every BEEF in its body's fields, stores each transaction
once as its `bitcoin-tx` block and each BUMP as the raw block of its bytes,
checks every BUMP against the headers in `chain/state`, and puts the
pointer record's CID where the bytes were (a bad BUMP: the message is a
refusal entry and nothing runs). `ingest` reads the BEEF back with the
SDK's `chain.record.beefOf` (the exact bytes) and ingests it as below; bytes
or hex still work from a caller no door stands in front of.

**Ingest a BEEF** (V1, V2, Atomic or Outpoint; its subject the atomic or outpoint txid, else its
last transaction). SPV against this instance's chain: every BUMP's root is
the header's merkle root at its height (an unknown height fails the
ingest — feed the headers first); every transaction is in its BUMP, or
has every input's source earlier in the BEEF or held, each input's script
verified; a txid-only entry must be held. Then every transaction it
carries is recorded, every proof it carries put; a transaction spending an
output a proven held one spends is rejected at once (`double-spent`); each
one left unproven registers its broadcast and is **broadcast** — the
event `{event: "broadcast", tx: <its CID>, beef: <its Atomic BEEF>}`
(skein docs/MESSAGES.md), which the host carries to its network — and the
thread rests awaiting them, with no deadline; after each step it rests
again on those still unproven.

The caller (the message's sender) is answered at its address, in the box
it wrote to, as an app answers (docs/APPS.md §4). A caller that is the
instance itself — the wallet, an overlay — is answered by the same loopback
it wrote by (shruggr/skein#79), and the answer steps the thread awaiting its
`ingest` message:

```
{fn, request: <the request message's CID>, replyTo: <the same>, result: {txid, tx: <CID>, state, …}}
{fn, request, replyTo, error: {code, message}}
```

| state | when | result also carries |
|---|---|---|
| `proven` | at once, for a transaction that arrives proven (or is proven already); later, when its proof arrives | `block` (the header's CID), `height`; `via` when the proof event came by a route's wiring (an overlay's `-proof` gossip: the watcher does not publish it again) |
| `accepted` | the first status from the status provider that is not a rejection (RECEIVED, SEEN_ON_NETWORK, …); at once for a second ingest of a transaction already accepted | `txStatus`, `broadcast` (the broadcast record's CID) |
| `rejected` | a rejecting status (REJECTED, DOUBLE_SPEND_ATTEMPTED, INVALID, MALFORMED), a competing spend proven, something it spends rejected; at once if it is rejected already | `reason`, `settlement` (the settlement record's CID) |

So an unproven transaction's caller gets several answers to one request,
`accepted` then `proven` (or `rejected`), each a message with the same
`replyTo`. A second ingest of a pending transaction adds its caller as
another watcher. An answer goes out only when the address book reaches
the caller; either way it is in the log. Errors: `bad-request` (no `fn`),
`unknown-fn`, `bad-args`, `failed` (`ingest: InvalidBeef`, `RootMismatch`,
`UnknownHeader`, `ScriptFailed`, `MissingInput`, …; `not proven` for
`proof`).

**`status {txid}`** → `{txid, state: proven | unproven | rejected | unknown, tx?, block?, height?, txStatus?, broadcast?, reason?, settlement?}`.
**`proof {txid}`** → `{txid, tx, block, height, depth, position}`: the
header's CID, its height, and the leaf's place; the merkle nodes are in
the store under the header's merkle root.

The reads are also a kernel call or an in-VM `call` (`kind: "call"`, `fn`
`status` / `proof`, `arg` dag-cbor `{txid}`, the answer dag-cbor on stdout;
they write nothing). `ingest` is refused there (`IngestIsAMessage`): its
answers come later, at an address.

**The host's events** (sender-less, self-validating; skein docs/MESSAGES.md):

- `{kind: "header", raw}` or `{kind: "header", raws: [...]}` (a run, parents
  first) in box `chain` — the host's header feeds (their default box is
  `chain`);
- `{kind: "proof", subject: <tx CID>, txid, path, via?, …}` — the
  broadcaster's proof, or an overlay route's (`via`: its `-proof` gossip,
  checked against this instance's headers): to the thread awaiting the
  transaction, else box `chain`.

**The status provider's messages** (box `status`, signed by the provider,
`subject` the transaction): `{kind: "status", txid, txStatus, …}` — to the
thread awaiting the transaction, else this app's `status` row. Statuses
are optional: without a provider a transaction is proven by its proof,
rejected by a competing proof, and never `accepted`.

The chain app is the only thing that emits the broadcast event. The
wallet and the overlay apps (shruggr/skein#79) neither broadcast nor take
headers, proofs or statuses: they send `ingest` and wait on the answers.

## Where it is going: a reference is a subscription

What is built above is a one-shot answer set: a watcher is answered until
its transaction is `proven` or `rejected`, and its registration ends there
(the broadcast record goes with it). The decided direction (shruggr/skein#31,
"Decided 2026-10-02 (night)") changes that, and is not built yet:

- A registration lasts for the life of the transaction. Every change of its
  chain state (accepted, proven, reorged out, conflicted by a proven spend)
  goes to every registrant, which wakes and reads the chain state again.
- There is no unwind or replay as an action. Whether a judgement counts is
  a read of the chain state; a judgement is re-run when the chain state it
  depended on changes.
- A rejection by Arcade is not a state of the chain. A parent with no proof
  is a point of pausing until something changes.
- Fetching missing ancestors is not this app's: it is a separate monitor
  tool.

## The manifest

`etc/app.json` (the #77 shape):

```json
"programs": {"chain": "bin/chain.wasm"},
"config":   {"chain": {}},
"dispatch": [
  {"address": "chain",  "sender": "event",   "program": "chain"},
  {"address": "chain",  "sender": "$self",   "program": "chain"},
  {"address": "chain",  "sender": "$owner",  "program": "chain"},
  {"address": "status", "sender": "$status", "program": "chain", "optional": true}
]
```

- the `chain` row from `event`: the host's events (a feed's header, the
  broadcaster's proof) — specific wiring, never a message (skein's dispatch
  sender `event`, #79);
- the `chain` rows from `$self` (the instance's own apps, by the host's
  loopback: the wallet, the overlay apps — any program of the instance
  emits as the instance) and `$owner`: the callers;
- the `status` row from the instance's status provider; `optional`: left
  out by the install on a host with none (skein's install, #78).

`config.chain` (read from the app record at every step; the genesis
defaults where it says nothing): `network` (`main` | `test` | `regtest`;
else `defaults.walletNetwork`, else `main`).

Its writes are heads under its name (skein's write-scope rule, #77):
`chain/state`. Wired at boot by a system tree instead (`bin/chain.wasm`
and the rows in `etc/dispatch.json`), its program is named `chain` and
the default scope for a program named `chain` (`chain: ["chain/"]`, skein `src/host/genesis.ts`) lets it write the same head.

## Install

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle> --approve-all
```

The prompt reads the rows aloud: `row mailbox chain from event → chain`,
`row mailbox chain from $self → chain`, `row mailbox chain from $owner →
chain`, `row mailbox status from $status → chain`.
