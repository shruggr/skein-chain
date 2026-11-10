//! chain: the chain module (shruggr/skein#78), the one writer of the
//! instance's chain state — headers, transactions, proofs, spends,
//! settlement, broadcasts — under the head `<app>/state` (skein-sdk
//! `chain.state`; docs/CHAIN.md). Everyone else reads it by CID.
//!
//! Stepped on:
//!
//!   box `chain`, a message {fn, args}     from a caller the kernel admits (skein#143: an open route, filter kernel.beef — the instance's own apps, root):
//!       ingest {beef}     record a BEEF: the envelope the kernel's door wrote (skein #121, #146), or bytes. Proven (its BUMPs verify against our headers): answered at
//!                         once. Unproven: recorded and broadcast (the event the host carries to its
//!                         network); answered at once only when it is accepted already. 0.8.0: no
//!                         watchers — every status of a transaction (below) is a fact.
//!       status {txid}     the transaction's state (CIDs: tx, block, settlement, broadcast)
//!       proof {txid}      where its proof is: the header's CID, height, depth, position
//!   box `chain`, an event (no sender)    the host's wiring: `chain` ({root, height}: the host chain's
//!                                        record, shruggr/skein#156 — sent once per block, and once at
//!                                        install and at each start) from its headers tracker; `proof`
//!                                        ({subject, txid, path, …}) from its broadcaster, for a
//!                                        transaction no thread awaits. A `header` event is refused
//!                                        (BadEvent): the header chain is the host's
//!   box `chain/status`, a message        a status provider's ({kind: "status", txid, txStatus, …},
//!                                        about its subject), for a transaction no thread awaits
//!   a thread resting after a broadcast   its transactions' proofs (input `event`), statuses (input
//!                                        `message`); it has no deadline of its own
//!
//! Called (`kind: "call"`, an in-VM or kernel call): `status` and `proof`, the
//! same answers as dag-cbor on stdout; they write nothing. `ingest` (0.10.0): an in-VM call from a
//! step only (it writes in that step); a kernel call of it is refused.
//!
//! The header chain is the host's (shruggr/skein#156): kept once per host by
//! its kernel process, in the `host/chain` set every instance reads. A `chain`
//! event points this state's `headers` and `heights` at the host chain
//! record's (skein-sdk `State.pointAt`): no copy; a reorg the host chain took
//! reverts the proofs above the fork, as a heavier branch always did.
//!
//! Every status of a transaction a step comes to is recorded (the state) and emitted as the fact
//! `<app>/tx/<txid>` (skein 0.5.0's event index; listeners rest on the name, skein 0.5.4), in four
//! words (0.10.0, David 2026-11-09): `pending` (at intake: held, broadcast asked for, no answer yet),
//! `seen` (the network has it; after a reorg with `reason: "reorged"`), `mined` (`height`),
//! `rejected` (`reason`; `by` the winner of a double spend or the root of an input-rejected
//! cascade). EVERY transaction gets one at intake (skein-sdk 0.19.0 `added`), and an ingest
//! emits its subject's status as it stands. None is final: a later proof is `mined`.
//!
//! Output states (0.10.0): when the app first holds a transaction T it subscribes its fn
//! `outputs` to `<app>/tx/<T>`; each status fact of T steps it — the outputs T spends walked
//! from the chain state, each posted as `<app>/output/<txid>.<vout>` {state: spent |
//! rolledBack, spentBy} when it differs from the latest one (shape.outputEvents).
//!
//! `ingest` is also an in-VM call (0.10.0): from a program's step, the app writes, subscribes,
//! emits the statuses and the broadcast in that step (`ingestCall`).
//!
//! Every step keeps a result record and prints its CID:
//!   {kind: "chain-result", op, chain?: {root, height, fork}, fn?, txid?, status?, error?, facts?: [{event, status}], answered, broadcast, awaited?, state}
//!   {kind: "chain-result", op: "outputs", txid, posted}   (a status fact's subscription step; the output facts not listed)
const std = @import("std");
const c = @import("chain");
const vm = @import("vm.zig");
const shape = @import("shape.zig");

const cbor = c.cbor;
const Value = cbor.Value;
const State = c.state.State;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub fn main() u8 {
    return vm.main("chain", run);
}

/// The app's name (its program record's `app`; none: a genesis-wired program, "chain") and record.
fn configure(a: Allocator, in: Value) !shape.Config {
    const s = vm.store();
    var app: ?[]const u8 = null;
    if (in.getCid("thread")) |t| if ((try s.getValue(a, t)).getCid("program")) |p| {
        app = (try s.getValue(a, p)).getText("app");
    };
    var record: ?Value = null;
    if (app) |n| if (try vm.head(a, try std.fmt.allocPrint(a, "{s}/app", .{n}))) |root| {
        const r = try s.getValue(a, root);
        if (eql(u8, r.getText("kind") orelse "", "app")) record = r;
    };
    return shape.configOf(app, record, in.get("defaults"));
}

const Step = struct {
    a: Allocator,
    conf: shape.Config,
    st: State,
    fields: std.ArrayList(cbor.Entry) = .empty,
    /// Answers to send: (to, box, body).
    answers: std.ArrayList(struct { []const u8, []const u8, Value }) = .empty,
    /// Transactions this step registered (an ingest): broadcast and awaited.
    to_broadcast: std.ArrayList([32]u8) = .empty,
    /// Transactions this thread rests on after the step.
    awaited: std.ArrayList([32]u8) = .empty,
    writes: bool = true,
    /// A proof event's `via` (it came by a route's wiring, not the host's broadcaster): on the result record.
    via: ?[]const u8 = null,
    /// The transaction an ingest came to (0.8.0): its status at the ingest is a fact too.
    ingested: ?[32]u8 = null,

    fn field(self: *Step, key: []const u8, v: Value) !void {
        try self.fields.append(self.a, .{ .key = key, .value = v });
    }
    fn hex(self: *Step, txid: [32]u8) !Value {
        return .{ .text = try self.a.dupe(u8, &c.header.toHex(txid)) };
    }
    fn answer(self: *Step, to: []const u8, box: []const u8, body: Value) !void {
        try self.answers.append(self.a, .{ to, box, body });
    }
};

fn run(a: Allocator) anyerror!void {
    const in = try vm.input(a);
    if (eql(u8, in.getText("kind") orelse "", "call")) return onCall(a, in);
    const conf = try configure(a, in);
    const s = vm.store();
    const head_name = try conf.stateHead(a);
    const state = try vm.head(a, head_name);
    var p = Step{ .a = a, .conf = conf, .st = try State.load(a, s, state, conf.network) };
    p.st.now = @intCast(in.getUint("at") orelse return error.BadInput);
    const args = in.get("args") orelse return error.BadInput;
    var op: []const u8 = "event";

    // 0.10.0: a status fact of a transaction we hold steps the subscription made when it was taken in.
    if (eql(u8, args.getText("fn") orelse "", OUTPUTS_FN) and args.getCid("event") != null) return onOutputs(a, &p, args);

    const woke = in.getBool("woke") orelse false;
    if (in.get("event") != null or in.get("message") != null or woke) {
        // A thread resting after a broadcast: what it awaits, from the result its last step kept.
        op = "callback";
        const prior = try awaitedFromTip(a, in);
        if (in.get("event")) |e| {
            const ev = try s.getValue(a, e.getCid("event") orelse return error.BadInput);
            try onEvent(&p, ev);
        } else if (in.get("message")) |m| {
            const body = try s.getValue(a, m.getCid("body") orelse return error.BadInput);
            const subject = m.getCid("subject") orelse return error.BadInput;
            try onStatus(&p, c.store.bitcoinHash(subject) orelse return error.BadInput, body);
        } else {
            // A thread resting with a deadline set before abandonment was removed (skein-chain#1): it rests again.
            try p.field("woke", .{ .boolean = true });
        }
        for (prior) |t| if ((try p.st.broadcastRecord(t)) != null) try p.awaited.append(a, t);
    } else if (args.getCid("event")) |ec| {
        try onEvent(&p, try s.getValue(a, ec));
    } else if (eql(u8, args.getText("box") orelse "", "chain/status") and args.getCid("body") != null) {
        op = "status";
        const body = try s.getValue(a, args.getCid("body").?);
        const txid = c.header.fromHex(body.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        try onStatus(&p, txid, body);
    } else if (args.getCid("body")) |bc| {
        op = "call";
        try onMessage(&p, args, try s.getValue(a, bc));
    } else return error.BadInput;

    // 0.8.0 (David 2026-11-09): every status of a transaction this step came to — accepted, rejected,
    // mined (with its height), reorged — is recorded (the state) and emitted as the fact
    // `<app>/tx/<txid>` {status, height?}; no watchers. A reorg this step turned proven transactions
    // back to unproven is broadcast nowhere (0.7.1): the fact `reorged`; the new proof arrives as the
    // first did, through the host's status feed, and is the fact `mined` again.
    // 0.10.0: each transaction newly held is tied to its outputs' states: its status fact steps
    // `outputs` (subscribed here; a subscription made in this step hears this step's facts too).
    try subscribeAdded(a, &p.st, conf.app);
    const facts = try shape.statusEvents(a, &p.st, conf.app, p.ingested);
    for (facts) |e| _ = try vm.emitEvent(a, e);
    if (facts.len > 0) {
        const names = try a.alloc(Value, facts.len);
        for (facts, names) |e, *nm| nm.* = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = e.get("event").? },
            .{ .key = "status", .value = e.get("status").? },
        }) };
        try p.field("facts", .{ .array = names });
    }

    var new_state: ?[]const u8 = state;
    if (p.writes) {
        new_state = try p.st.save();
        if (state == null or !eql(u8, state.?, new_state.?)) try vm.advance(head_name, new_state.?);
    }
    // Broadcast (the event the host carries) and await: what this step registered, and what it already awaited.
    for (p.to_broadcast.items) |t| {
        try vm.broadcast(a, t, (try p.st.beefOf(t)).?);
        if (!contains(p.awaited.items, t)) try p.awaited.append(a, t);
    }
    var sent: u64 = 0;
    const me = if (in.get("self")) |sf| sf.getBytes("identity") else null;
    for (p.answers.items) |x| if (try vm.reachable(a, x[0], me)) {
        _ = try vm.send(a, x[0], x[1], x[2]);
        sent += 1;
    };
    if (p.awaited.items.len > 0) {
        const hexes = try a.alloc(Value, p.awaited.items.len);
        for (p.awaited.items, hexes) |t, *h| {
            try vm.awaitRecord(&c.store.hashCid(.tx, t));
            h.* = try p.hex(t);
        }
        try p.field("awaited", .{ .array = hexes });
    }
    var out: std.ArrayList(cbor.Entry) = .empty;
    try out.appendSlice(a, &.{
        .{ .key = "kind", .value = .{ .text = "chain-result" } },
        .{ .key = "op", .value = .{ .text = op } },
    });
    try out.appendSlice(a, p.fields.items);
    try out.appendSlice(a, &.{
        .{ .key = "answered", .value = .{ .uint = p.answers.items.len } },
        .{ .key = "sent", .value = .{ .uint = sent } },
        .{ .key = "broadcast", .value = .{ .uint = p.to_broadcast.items.len } },
        .{ .key = "state", .value = if (new_state) |ns| .{ .cid = ns } else .null },
    });
    _ = try vm.finish(a, .{ .map = out.items });
}

/// The function the app subscribes, per transaction taken in, to its status fact `<app>/tx/<txid>`.
const OUTPUTS_FN = "outputs";

/// 0.10.0: every transaction this step newly held — its status fact steps `outputs`.
fn subscribeAdded(a: Allocator, st: *State, app: []const u8) !void {
    for (st.added.items) |t| try vm.on(try shape.txName(a, app, t), OUTPUTS_FN);
}

/// 0.10.0 (David 2026-11-09): a status fact of a transaction `t` — its subscription's step. Each output
/// `t` spends is walked from the chain state and its state posted as `<app>/output/<txid>.<vout>`
/// when it differs from the latest one (shape.outputEvents). Writes no state.
fn onOutputs(a: Allocator, p: *Step, args: Value) !void {
    const name = args.getText("box") orelse return error.BadInput;
    const t = c.header.fromHex(name[(std.mem.lastIndexOfScalar(u8, name, '/') orelse return error.BadInput) + 1 ..]) catch return error.BadInput;
    var dummy: u8 = 0;
    const latest = shape.Latest{ .ptr = &dummy, .f = struct {
        fn f(_: *anyopaque, al: Allocator, n: []const u8) anyerror!?Value {
            return vm.latestEvent(al, n);
        }
    }.f };
    const events = try shape.outputEvents(a, &p.st, p.conf.app, t, latest);
    for (events) |e| _ = try vm.emitEvent(a, e);
    _ = try vm.finish(a, .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "kind", .value = .{ .text = "chain-result" } },
        .{ .key = "op", .value = .{ .text = OUTPUTS_FN } },
        .{ .key = "txid", .value = try p.hex(t) },
        .{ .key = "posted", .value = .{ .uint = events.len } },
    }) });
}

/// A `chain` or `proof` event (the host's headers tracker and broadcaster).
fn onEvent(p: *Step, ev: Value) !void {
    const kind = ev.getText("kind") orelse return error.BadEvent;
    try p.field("event", .{ .text = kind });
    if (eql(u8, kind, "chain")) {
        // shruggr/skein#156: the host chain's record (read through the host/chain exception, #133).
        const root = ev.getCid("root") orelse return error.BadEvent;
        const got = try p.st.pointAt(root);
        try p.field("chain", .{ .map = try p.a.dupe(cbor.Entry, &.{
            .{ .key = "root", .value = .{ .cid = root } },
            .{ .key = "height", .value = .{ .uint = got.height } },
            .{ .key = "fork", .value = .{ .uint = got.fork } },
        }) });
    } else if (eql(u8, kind, "proof")) {
        const txid = if (ev.getCid("subject")) |s| c.store.bitcoinHash(s) orelse return error.BadEvent else c.header.fromHex(ev.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        try p.field("txid", try p.hex(txid));
        p.via = ev.getText("via");
        if (p.via) |v| try p.field("via", .{ .text = v });
        const outcome = p.st.applyStatus(txid, "MINED", ev.getBytes("path") orelse return error.BadEvent) catch |e| switch (e) {
            error.UnknownTransaction => {
                try p.field("outcome", .{ .text = "unknown" });
                return;
            },
            error.RootMismatch, error.BadProof => {
                try p.field("outcome", .{ .text = @errorName(e) });
                return;
            },
            else => return e,
        };
        try p.field("outcome", .{ .text = @tagName(outcome) });
    } else return error.BadEvent;
}

/// A status provider's status about a transaction.
fn onStatus(p: *Step, txid: [32]u8, body: Value) !void {
    try p.field("txid", try p.hex(txid));
    const ts = body.getText("txStatus") orelse "";
    try p.field("txStatus", .{ .text = ts });
    const outcome = p.st.applyStatus(txid, ts, body.getBytes("merklePath")) catch |e| switch (e) {
        error.UnknownTransaction => {
            try p.field("outcome", .{ .text = "unknown" });
            return;
        },
        error.RootMismatch, error.BadProof => {
            try p.field("outcome", .{ .text = @errorName(e) });
            return;
        },
        else => return e,
    };
    try p.field("outcome", .{ .text = @tagName(outcome) });
}

/// A message in the app's box: {fn, args}.
fn onMessage(p: *Step, args: Value, body: Value) !void {
    const a = p.a;
    const message = args.getCid("message") orelse return error.BadInput;
    const box = args.getText("box") orelse p.conf.app;
    const sender = args.getBytes("sender");
    const name = body.getText("fn") orelse "";
    try p.field("fn", .{ .text = name });
    const fargs = body.get("args") orelse Value{ .map = &.{} };
    const outcome = callOf(p, name, fargs) catch |e| Outcome{ .err = .{ .code = "failed", .message = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ @errorName(e), if (vm.lastError().len > 0) ": " else "", vm.lastError() }) } };
    switch (outcome) {
        .none => {},
        .ok => |v| if (sender) |s| try p.answer(s, box, try shape.answerBody(a, name, message, .{ .ok = v })),
        .err => |f| {
            try p.field("error", .{ .text = f.message });
            if (sender) |s| try p.answer(s, box, try shape.answerBody(a, name, message, .{ .err = f }));
        },
    }
}

const Outcome = union(enum) { none, ok: Value, err: shape.Failure };

fn callOf(p: *Step, name: []const u8, fargs: Value) !Outcome {
    const a = p.a;
    const f = shape.Fn.parse(name) orelse {
        p.writes = false;
        return .{ .err = .{ .code = if (name.len == 0) "bad-request" else "unknown-fn", .message = if (name.len == 0) "not a call: want {fn, args}" else try std.fmt.allocPrint(a, "{s}: the chain app takes ingest, status, proof", .{name}) } };
    };
    if (fargs != .map) return .{ .err = .{ .code = "bad-args", .message = "args: want a map" } };
    if (!f.writes()) p.writes = false;
    switch (f) {
        .status, .proof => {
            const txid = (try shape.txidArg(fargs)) orelse return .{ .err = .{ .code = "bad-args", .message = "args.txid: want 64 hex digits" } };
            try p.field("txid", try p.hex(txid));
            if (f == .status) return .{ .ok = try shape.txState(a, &p.st, txid, null, "") };
            return if (try shape.proofOf(a, &p.st, txid)) |v| .{ .ok = v } else .{ .err = .{ .code = "failed", .message = "not proven" } };
        },
        .ingest => {
            // shruggr/skein#121, #146: a BEEF comes in as the envelope the kernel's door wrote ({form, beef:
            // <pointer record CID>, subject?, vout?}; the transactions and BUMPs are blocks in the store), or
            // as bytes / hex from a caller with no door.
            const beef = if (fargs.get("beef")) |env| if (env == .map)
                c.record.wireOf(a, vm.store(), env) catch |e| return .{ .err = .{ .code = "bad-args", .message = try std.fmt.allocPrint(a, "args.beef: not a BEEF envelope over a pointer record held here ({s})", .{@errorName(e)}) } }
            else
                (try shape.beefArg(a, fargs)) orelse return .{ .err = .{ .code = "bad-args", .message = "args.beef: want a BEEF envelope, or a BEEF (bytes, or hex)" } }
            else
                return .{ .err = .{ .code = "bad-args", .message = "args.beef: want a BEEF envelope, or a BEEF (bytes, or hex)" } };
            const got = p.st.ingest(beef) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return .{ .err = .{ .code = "failed", .message = try std.fmt.allocPrint(a, "ingest: {s}", .{@errorName(e)}) } },
            };
            try p.field("txid", try p.hex(got.txid));
            try p.field("status", .{ .text = @tagName(got.status) });
            for (got.registered) |t| try p.to_broadcast.append(a, t);
            // 0.8.0: no watchers. Its status at the ingest is a fact (`<app>/tx/<txid>`, statusEvents), as
            // every later one is; the caller is answered once, here, when there is a status to answer.
            p.ingested = got.txid;
            switch (got.status) {
                // Proven or rejected in: answered at once.
                .proven, .rejected => return .{ .ok = try shape.txState(a, &p.st, got.txid, null, "") },
                .unproven => {
                    const r = (try p.st.broadcastRecord(got.txid)).?;
                    if (r.getBool("accepted") orelse false) return .{ .ok = try shape.txState(a, &p.st, got.txid, "accepted", "") };
                    return .none;
                },
            }
        },
    }
}

/// A kernel or in-VM call: `status` / `proof` {txid} → dag-cbor. Reads only.
fn onCall(a: Allocator, in: Value) !void {
    const name = in.getText("fn") orelse "";
    const f = shape.Fn.parse(name) orelse return error.UnknownFn;
    if (f == .ingest) return ingestCall(a, in);
    const arg = try cbor.decode(a, in.getBytes("arg") orelse return error.BadInput);
    const txid = (try shape.txidArg(arg)) orelse return error.BadArgs;
    // The state head of the app named "chain" (a call names no program; the name is the app's identity).
    const conf = shape.Config{};
    const s = vm.store();
    const state = try vm.head(a, try conf.stateHead(a));
    const network = if (state) |sc| c.chain.Network.parse((try s.getValue(a, sc)).getText("network") orelse "") orelse .main else .main;
    var st = try State.load(a, s, state, network);
    if (f == .status) return vm.answer(a, try shape.txState(a, &st, txid, null, ""));
    return vm.answer(a, (try shape.proofOf(a, &st, txid)) orelse .null);
}

/// `ingest {beef}` as an in-VM call (0.10.0, David 2026-11-09): from a program's step, the chain app
/// takes the BEEF in as part of that step — every transaction recorded and its state advanced (in
/// the chain app's own scope), each newly held one subscribed (`outputs`) and given its status
/// fact, each left unproven broadcast (the event the host carries). Nothing is awaited: the host's
/// proofs and statuses reach the chain app as they do any transaction it holds (box `chain`,
/// `chain/status`). Answers the subject's status in the four words (shape.ingestAnswer). A kernel
/// call (no step) is refused: it writes.
fn ingestCall(a: Allocator, in: Value) !void {
    const step = in.get("step") orelse return vm.refuse("ingest writes: call it from a step");
    const s = vm.store();
    // The app named "chain" (a call names no program; the name is the app's identity), its record's config.
    var record: ?Value = null;
    if (try vm.head(a, "chain/app")) |root| {
        const r = try s.getValue(a, root);
        if (eql(u8, r.getText("kind") orelse "", "app")) record = r;
    }
    const conf = try shape.configOf("chain", record, in.get("defaults"));
    const head_name = try conf.stateHead(a);
    const state = try vm.head(a, head_name);
    var st = try State.load(a, s, state, conf.network);
    st.now = @intCast(step.getUint("at") orelse in.getUint("now") orelse return error.BadInput);
    const arg = try cbor.decode(a, in.getBytes("arg") orelse return error.BadInput);
    if (arg != .map) return vm.refuse("args: want a map");
    const beef = if (arg.get("beef")) |env| if (env == .map)
        c.record.wireOf(a, s, env) catch |e| return vm.refuse(try std.fmt.allocPrint(a, "args.beef: not a BEEF envelope over a pointer record held here ({s})", .{@errorName(e)}))
    else
        (try shape.beefArg(a, arg)) orelse return vm.refuse("args.beef: want a BEEF envelope, or a BEEF (bytes, or hex)")
    else
        return vm.refuse("args.beef: want a BEEF envelope, or a BEEF (bytes, or hex)");
    const got = st.ingest(beef) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return vm.refuse(try std.fmt.allocPrint(a, "ingest: {s}", .{@errorName(e)})),
    };
    try subscribeAdded(a, &st, conf.app);
    for (try shape.statusEvents(a, &st, conf.app, got.txid)) |e| _ = try vm.emitEvent(a, e);
    const new_state = try st.save();
    if (state == null or !eql(u8, state.?, new_state)) try vm.advance(head_name, new_state);
    for (got.registered) |t| try vm.broadcast(a, t, (try st.beefOf(t)).?);
    return vm.answer(a, try shape.ingestAnswer(a, &st, conf.app, got.txid));
}

/// The transactions the thread awaits: the result its last step kept (`awaited`).
fn awaitedFromTip(a: Allocator, in: Value) ![][32]u8 {
    const s = vm.store();
    var out: std.ArrayList([32]u8) = .empty;
    const tip = try s.getValue(a, in.getCid("tip") orelse return out.items);
    const kept = tip.getArray("kept") orelse return out.items;
    if (kept.len == 0 or kept[kept.len - 1] != .cid) return out.items;
    const res = try s.getValue(a, kept[kept.len - 1].cid);
    for (res.getArray("awaited") orelse &.{}) |x| if (x == .text) try out.append(a, try c.header.fromHex(x.text));
    return out.items;
}

fn contains(xs: []const [32]u8, t: [32]u8) bool {
    for (xs) |x| if (eql(u8, &x, &t)) return true;
    return false;
}
