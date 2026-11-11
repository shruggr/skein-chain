# The chain app (0.11.0)

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
| `proofs` | txid → `{block, depth, position, broadcast?}` | its block's header (a link) and its leaf; `broadcast`: the broadcast record its proof settled (a link); the merkle nodes are 64-byte `bitcoin-tx` blocks under the header's root (a BUMP is rebuilt by descent: `merkle.pathFor`) |
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
{kind: "broadcast", txid (hex), subject: <tx CID>, since: ms, path?: bytes, watchers: []}
```

`since` is its first broadcast (0.12.0: no `txStatus`, no `accepted` — a record
written before keeps them, ignored); `path` is a proof that came
before its header (tried again when headers arrive); `watchers` is empty
since 0.8.0 (the field is the SDK's record shape; nothing registers a
watcher: every status is a fact, below). Proven or rejected, the record goes
(proven, its `proofs` entry links it).

Status is computed from the records: **rejected** (a settlement record),
**proven** (its proof's block is on the best chain), else **unproven**. A
rejection walks the held transactions that spend it (the `spends` edges)
and rejects them too (`input-rejected`, `cause` the first); a proof rejects
every other held transaction spending one of the same outputs
(`double-spent`, 0.10.0: `cause` the proven winner). Nothing else rejects: a transaction the chain app cannot
prove stays known and unproven for as long as it is held, and the threads
resting on its fact keep resting. A proven transaction is never rejected.
A reorg that replaces the block a proof names turns the transaction back to
unproven — the fact `seen` with `reason: "reorged"` (0.10.0; was `reorged`) — and its broadcast is registered again,
and nothing is sent anywhere (0.7.1, David 2026-10-30: "I see no value in
rebroadcast, as the state should all be tied together and should heal when
updated proofs propagate" — before 0.7.1 it was broadcast again). The new
proof arrives as the first did: the host's status feed carries every
transaction submitted under its token, and a status new by its block hash
is routed to the instance as a proof event. A reorg is another proof for the same
transaction, a different block (shruggr/skein#112): proven again, it is the
fact `mined` again, with the new `height`.

The chain tracker's rules are the SDK's (`chain/src/chain.zig`): every
header must chain back to the network's genesis header; usable target,
proof of work, links; a heavier branch replaces ours from the fork point.
Not checked, by decision (#29 Q3): the difficulty-adjustment rule,
timestamps, versions.

### The header chain is the host's (shruggr/skein#156)

The header chain is **owned by the host, held once per host, and kept by the
host's kernel process** (skein `kernel-zig/src/host_chain.zig`, over the
SDK's `chain.host`): one record per host,

```
{kind: "host-chain", network, maps: {headers: <MST root>, heights: <MST root>}, tip: {height, hash}}
```

in the host's `host/chain` set, which every instance reads (the chain
exception, shruggr/skein#133). The host's network side (its headers feed,
`SKEIN_HEADERS_URL`) hands raw headers to the kernel process, which
validates and appends them as `Chain.add` always did (links, targets, proof
of work, the heavier branch replacing ours from the fork point).

**This app never copies a header.** Its state's `headers` and `heights`
name the host chain record's roots: the host sends a `chain` event,
`{kind: "chain", root: <host chain record>, height}`, in box `chain` once per
block, once when the instance is installed and once at each start; the app
points its state at that record (skein-sdk `State.pointAt`). The fork is the
highest height where this state's chain and the host's agree (walked back
from this state's tip; an empty state forks at 0). Headers of this state
above the fork that the host's chain replaced revert the proofs against
them, exactly as a heavier branch always did: those transactions are
unproven again (not broadcast again, 0.7.1). Proofs that waited for a header are
tried again. The result record says what happened: `chain: {root, height,
fork}`. A `header` event is refused (`BadEvent`). Every other map (`txs`,
`proofs`, `proofHeights`, `rejected`, `unproven`, `spent`, `broadcasts`) is
this instance's own, as before; every reader reads `chain/state` exactly as
before.

**Birth.** The image a skein is born from still carries the chain
(`chain/headers/<first>`, `chain/tip`: skein docs/BOOTSTRAP.md, "The image's
chain part"), as the host's bootstrap for a fresh host chain: a host whose
chain is empty imports it (the kernel's `chain-import`) before the new
instance's first event. The app never loads an image itself. Replay
resolves the same: the event is a log entry carrying the record's CID, and
the host chain's blocks are never deleted.

## Its interface

One box, `chain` (the app's name), taking the host's events (its `event`
row) and `{fn, args}` from the instance's own apps and the owner (shruggr/skein#79:
its rows from `$self` and `$owner`, not an open box); and `chain/status`
(written `"status"`: a manifest's box is relative to the app, shruggr/skein#128),
the status provider's messages.

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
envelope where the bytes were: `{form, beef: <pointer record CID>, subject?,
vout?}` (shruggr/skein#146; the pointer record is the BEEF alone) (a bad
BUMP: the message is a refusal entry and nothing runs). `ingest` reads the
bytes back with the SDK's `chain.record.wireOf` (the exact bytes) and
ingests them as below; bytes or hex still work from a caller no door
stands in front of.

**Ingest a BEEF** (V1, V2, Atomic, Outpoint or Subject; its subject the atomic, outpoint or subject txid, else its
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

**A status is the latest fact** (0.9.0, David 2026-11-09): a valid proof for a transaction makes it proven and emits `mined`, also when it was rejected before (skein-sdk 0.18.0: the `rejected` map no longer overrides a proof; the settlement record stays, read for its reason).

**Four statuses, one at intake** (0.10.0, David 2026-11-09; supersedes 0.8.0's words). Each status of a
transaction a step comes to is recorded (the state above) and emitted as the
fact `<app>/tx/<txid hex>` (skein 0.5.0's event index, under the app's own
name — `chain/tx/<txid>`; a listener's thread rests on the name, skein
0.5.4's `on(name)`, and every fact under it wakes it). None is final: each is
the latest thing known, and a later valid proof is `mined`.

| `status` | when | also |
|---|---|---|
| `pending` | at intake: held, its broadcast asked for; it stays so until a rejection or a proof (0.12.0) | |
| `seen` | 0.12.0: only a reorg turned it back to unproven (it was `mined`). No status from the network makes it (David 2026-11-11: an instance hears only rejected or mined; the broadcaster's other statuses stay in the host) | `reason: "reorged"` |
| `mined` | its proof, on the best chain (at intake for a transaction that arrives proven, a BEEF's ancestors included); again after a reorg, proven in another block | `height` |
| `rejected` | a rejecting status (REJECTED, INVALID, MALFORMED: the reason; 0.12.0: no DOUBLE_SPEND_ATTEMPTED, the broadcaster never produces it), a competing spend proven (`double-spent`), something it spends rejected (`input-rejected`) | `reason` (the settlement record's); `by`: the winner of a double spend, or the cascade's root (the settlement's `cause`, skein-sdk 0.19.0) |

**Every transaction gets a status at intake**: each one a step newly holds
(skein-sdk 0.19.0 `State.added`: an ingest's parents first) — `pending`, or
`mined` when it comes proven, or `rejected` when a proven held one already
spends what it spends. An `ingest` also emits its subject's status as it
stands when it was held before, so a listener that rests on the name before
its ingest hears it.

**Proof linkages** (0.11.0, David 2026-11-10: "the fact that the transaction has a proof is its
status"). When a merkle path is saved (its root the header's on our best chain), every transaction
it covers — each level-0 hash whose root, computed through the path, is that header's merkle root;
no duplicate slot; nothing above level 0 — is linked to the block, held or not, and raised once as

    <app>/proof/<txid hex>   {block: <block hash hex>, height, position}

(skein-sdk 0.21.0 `putProof`, the one writer of the linkage rows, lists exactly what it linked). The
same path again links nothing and raises nothing. A transaction taken in subscribes its fn `proof` to
its own `<app>/proof/<txid>` (beside `outputs` on `<app>/tx/<txid>`): covered already, its status at
intake is `mined` (read from the state) and it is never registered for broadcast; linked later, the
subscription step settles what the proof settles (double spends, its broadcast record) and raises
`<app>/tx/<txid>` `mined` with its height when the latest fact is not already that. Our own outgoing
BEEF carries a linked transaction proven (raw with its BUMP).

**Every dependency by subscription** (0.11.0, David 2026-11-10: "Everything is registered with
events. There shouldn't be any way you can't re-examine them."). Each wake re-reads the state.

| dependency | subscribed | fn | re-reads |
|---|---|---|---|
| a transaction's status on its proof | `<app>/proof/<txid>` (at intake) | `proof` | the linkage; settles its broadcast record, double spends, inputs' spent; raises `mined` |
| an output's state on its spender's status | `<app>/tx/<txid>` (at intake) | `outputs` | each output it spends: the live spender |
| a transaction on its parents | `<app>/tx/<parent>` for each input's transaction (at intake) | `parents` | every held child of that parent: `input-rejected` by the root when a parent is rejected; `revived` (pending, broadcast again) when none is |
| a transaction's parents on it (a proven child) | `<app>/tx/<txid>` (at intake) | `children` | each held parent: a proven descendant lifts any rejection of it (unproven, broadcast again — no linkage is invented; we hold no path for it) |
| a mined transaction on its block | `<app>/block/<hash>` (when its `mined` is raised) | `block` | every held transaction linked to that block: `seen`/`reorged`, or `mined` again |

`<app>/block/<hash>` `{height, active}` is raised when a block a linkage names leaves our best chain
(`active: false`) or comes back (`active: true`) — only for what changed in that step. A rejection rejects only its own transaction, and
never one with a proven descendant (a proven child proves its parents mined). A proof overrides a
rejection, also after a reorg: the settlement leaves `rejected` (its linkage keeps it, read for its
reason). A proof before its header is kept whatever the transaction's status (`parked`).
At intake a transaction is read against facts already raised (a past fact is never delivered to a
subscription made later): covered already → `mined`, settled; a parent rejected already →
`input-rejected`. Transactions held before 0.11.0 have none of these subscriptions: relaunch.

**Output states** (0.10.0, David 2026-11-09). Each output a held transaction
spends has a state, the fact `<app>/output/<txid hex>.<vout>`:

    {state: "spent" | "rolledBack", spentBy: <txid hex>}

The latest message under the name is the output's current state (as a
transaction's latest `chain/tx` fact is its status). It follows the status of
the transaction spending it, by subscription: when the app first holds a
transaction T it subscribes (skein 0.5.2 `on`) its function `outputs` to
`<app>/tx/<T>` — one subscription per transaction, kept — so every status fact
of T, the one at intake included (a subscription made in a step hears that
step's facts), steps `outputs`: each output T spends (coinbase inputs skipped)
is walked from the chain state — its live spender is a held spender that is
not rejected, a mined one first, else the first by txid — and its state is
`spent` by that spender, or `rolledBack` (`spentBy` the spender the latest
message named) when none is left; posted only when it differs from the latest
message (an output with no message yet and no live spender gets none). Nothing
is posted for transactions held before 0.10.0 (no backfill). Who follows an
output subscribes to its name (the wallet app); the app posts for every output.

**`ingest` as an in-VM call** (0.10.0, David 2026-11-09): from a program's
step, `call(<the chain app's program>, "ingest", {beef})` (`chain.ingest` the
same) takes the BEEF in as part of that step — the app's state advanced in its
own scope, each newly held transaction subscribed and given its status, each
left unproven broadcast (the event the host carries); nothing is awaited (the
host's proofs and statuses reach the app as for any transaction it holds:
box `chain`, `chain/status`). The answer (dag-cbor on stdout): the subject's
`{txid, status, height?, reason?, by?}` in the words above; a refusal is the
call's error (`ingest: <ErrorName>`, `args.beef: …`). A kernel call of `ingest`
is refused (`ingest writes: call it from a step`). The message form below stays
while senders use it.

The caller of `ingest` (the message's sender) is answered once, at its
address, in the box it wrote to, as an app answers (docs/APPS.md §4) — when
there is a status to answer at the ingest (proven, rejected), or an error:

```
{fn, request: <the request message's CID>, replyTo: <the same>, result: {txid, tx: <CID>, state, …}}
{fn, request, replyTo, error: {code, message}}
```

| state | result also carries |
|---|---|
| `proven` | `block` (the header's CID), `height` |
| `rejected` | `reason`, `settlement` (the settlement record's CID) |

An unproven transaction is not answered (0.12.0): its later statuses are the
facts. An answer goes out only when the address book reaches the caller;
either way it is in the log. Errors: `bad-request` (no `fn`), `unknown-fn`,
`bad-args`, `failed` (`ingest: InvalidBeef`, `RootMismatch`,
`UnknownHeader`, `ScriptFailed`, `MissingInput`, …; `not proven` for
`proof`).

**`status {txid}`** → `{txid, state: proven | unproven | rejected | unknown, tx?, block?, height?, broadcast?, reason?, settlement?}`.
**`proof {txid}`** → `{txid, tx, block, height, depth, position}`: the
header's CID, its height, and the leaf's place; the merkle nodes are in
the store under the header's merkle root.

The reads are also a kernel call or an in-VM `call` (`kind: "call"`, `fn`
`status` / `proof`, `arg` dag-cbor `{txid}`, the answer dag-cbor on stdout;
they write nothing). `ingest` is an in-VM call from a step (0.10.0, above);
a kernel call of it is refused: it writes.

**The host's events** (sender-less, self-validating; skein docs/MESSAGES.md):

- `{kind: "chain", root: <the host chain record>, height}` in box `chain` —
  the host's headers tracker: once per block, once at install and at each
  start (above);
- `{kind: "proof", subject: <tx CID>, txid, path, via?, …}` — the
  broadcaster's proof, or an overlay route's (`via`: its `-proof` gossip,
  checked against this instance's headers): to the thread awaiting the
  transaction, else box `chain`.

**The status provider's messages** (box `chain/status`, signed by the provider,
`subject` the transaction): `{kind: "status", txid, txStatus, …}` — to the
thread awaiting the transaction, else this app's `status` row. 0.12.0: only
a rejection (or a `merklePath`, a proof) changes anything; any other status
is recorded on the step's result and changes nothing. Statuses are optional:
without a provider a transaction is proven by its proof and rejected by a
competing proof.

The chain app is the only thing that emits the broadcast event. The
wallet and the overlay apps (shruggr/skein#79) neither broadcast nor take
headers, proofs or statuses: they send `ingest` and rest on its facts.

## Where it is going: a reference is a subscription

0.8.0 built the first point below: a status is a fact that every listener
resting on the transaction's name hears, for the life of the transaction
(no registration, no watcher, nothing that ends). The rest of the decided
direction (shruggr/skein#31, "Decided 2026-10-02 (night)") is not built yet:

- A registration lasts for the life of the transaction. Every change of its
  chain state (proven, rejected, reorged out, conflicted by a proven spend)
  goes to every registrant, which wakes and reads the chain state again.
- There is no unwind or replay as an action. Whether a judgement counts is
  a read of the chain state; a judgement is re-run when the chain state it
  depended on changes.
- A rejection by Arcade is not a state of the chain. A parent with no proof
  is a point of pausing until something changes.
- Fetching missing ancestors is not this app's: it is a separate monitor
  tool.

## The manifest

`etc/app.json` (shruggr/skein#143: routes, no senders):

```json
"programs": {"chain": "bin/chain.wasm"},
"config":   {"chain": {}},
"routes": [
  {"transport": "event", "address": "chain", "handler": "chain"},
  {"address": "chain", "filters": ["kernel.beef"], "handler": "chain"},
  {"address": "status", "handler": "chain"}
]
```

- the `event` route at `chain`: the host's events (the host chain's
  `chain` event, the broadcaster's proof) — specific wiring, never a message;
- the mailbox route at `chain`: the callers (the instance's own apps by the
  host's loopback — the wallet, the overlay apps — and root). Open: no
  role gates its functions; the filter `kernel.beef` decodes an ingest's
  BEEF at the kernel's door into its pointer record;
- the mailbox route at `status` (`chain/status`): the status provider's
  messages.

`config.chain` (read from the app record at every step; the genesis
defaults where it says nothing): `network` (`main` | `test` | `regtest`;
else `defaults.walletNetwork`, else `main`).

Its writes are heads under its name (skein's write-scope rule, #77):
`chain/state`. Wired at boot by a system tree instead (`bin/chain.wasm`
and its routes), its program is named `chain` and
the default scope for a program named `chain` (`chain: ["chain/"]`, skein `src/host/genesis.ts`) lets it write the same head.

## Install

```
skein-host install https://github.com/shruggr/skein-chain --instance <handle> --approve-all
```

The prompt reads the rows aloud: `row mailbox chain from event → chain`,
`row mailbox chain from $self → chain`, `row mailbox chain from $owner →
chain`, `row mailbox chain/status from $status → chain`.
