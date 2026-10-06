//! chain: the chain module (shruggr/skein#78), the one writer of the
//! instance's chain state — headers, transactions, proofs, spends,
//! settlement, broadcasts — under the head `<app>/state` (skein-sdk
//! `chain.state`; docs/CHAIN.md). Everyone else reads it by CID.
//!
//! Stepped on:
//!
//!   box `chain`, a message {fn, args}     from a caller the rows admit (#79: the instance's own apps, `$self`, and the owner):
//!       ingest {beef}     record a BEEF: the pointer record's CID the kernel's door wrote (skein #121), or bytes. Proven (its BUMPs verify against our headers): answered at
//!                         once. Unproven: recorded, broadcast (the event the host carries to its
//!                         network), and the caller answered on each state change — accepted (the
//!                         first status that is not a rejection), proven, rejected — at its
//!                         address: {fn, request, replyTo, result: {txid, tx, state, …}}, one answer
//!                         per change. Every unproven transaction at rest has a registered broadcast.
//!       status {txid}     the transaction's state (CIDs: tx, block, settlement, broadcast)
//!       proof {txid}      where its proof is: the header's CID, height, depth, position
//!   box `chain`, an event (no sender)    the host's wiring: `header` ({raw} or {raws}, a run, parents
//!                                        first) from its feeds; `proof` ({subject, txid, path, …}) from
//!                                        its broadcaster, for a transaction no thread awaits
//!   box `chain/status`, a message        a status provider's ({kind: "status", txid, txStatus, …},
//!                                        about its subject), for a transaction no thread awaits
//!   a thread resting after a broadcast   its transactions' proofs (input `event`), statuses (input
//!                                        `message`); it has no deadline of its own
//!
//! Called (`kind: "call"`, an in-VM or kernel call): `status` and `proof`, the
//! same answers as dag-cbor on stdout; they write nothing.
//!
//! The first step on an instance whose tree (the head `main`: an image's,
//! shruggr/skein#132) carries a header chain starts from it: every header
//! from genesis to the image's tip, loaded into the empty state before the
//! step's own work (skein-sdk `chain.image`); the tip events continue from there.
//!
//! Every step keeps a result record and prints its CID:
//!   {kind: "chain-result", op, image?: {headers, tip}, fn?, txid?, status?, error?, answered, broadcast, awaited?, state}
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
    /// Transactions this step registered (an ingest, a reorg): broadcast and awaited.
    to_broadcast: std.ArrayList([32]u8) = .empty,
    /// Transactions this thread rests on after the step.
    awaited: std.ArrayList([32]u8) = .empty,
    writes: bool = true,
    /// A proof event's `via` (it came by a route's wiring, not the host's broadcaster).
    via: ?[]const u8 = null,

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
    // shruggr/skein#132: the first step on an instance whose tree carries a header chain
    // (`chain/headers`, the image's) starts from it — the whole chain from genesis.
    const from_image = if (state == null) try loadImage(&p) else false;
    const args = in.get("args") orelse return error.BadInput;
    var op: []const u8 = "event";

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

    // A reorg this step turned proven transactions back to unproven: registered again, broadcast again.
    for (p.st.reverted.items) |t| if (!contains(p.to_broadcast.items, t)) try p.to_broadcast.append(a, t);
    // Every state change of a watched transaction: an answer to each watcher (a proof after a reorg: again).
    for (try shape.changeAnswers(a, &p.st, p.via)) |x| try p.answer(x.to, x.box, x.body);

    var new_state: ?[]const u8 = state;
    if (p.writes or from_image) {
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

/// An empty chain state filled from the header chain the instance's tree
/// carries (skein-sdk `chain.image`: the head `main`, the tree its genesis
/// named — the image's, so a replay loads the same): whether there was one.
fn loadImage(p: *Step) !bool {
    const root = (try vm.head(p.a, "main")) orelse return false;
    if (root.len < 2 or root[1] != 0x78) return false; // not a git tree
    const got = (try c.image.load(&p.st, root)) orelse return false;
    try p.field("image", .{ .map = try p.a.dupe(cbor.Entry, &.{
        .{ .key = "headers", .value = .{ .uint = got.headers } },
        .{ .key = "tip", .value = .{ .uint = got.tip } },
    }) });
    return true;
}

/// A `header` or `proof` event (the host's feeds and broadcaster).
fn onEvent(p: *Step, ev: Value) !void {
    const a = p.a;
    const kind = ev.getText("kind") orelse return error.BadEvent;
    try p.field("event", .{ .text = kind });
    if (eql(u8, kind, "header")) {
        var raws: std.ArrayList([]const u8) = .empty;
        if (ev.getArray("raws")) |rs| {
            for (rs) |r| try raws.append(a, if (r == .bytes) r.bytes else return error.BadEvent);
        } else try raws.append(a, ev.getBytes("raw") orelse return error.BadEvent);
        const res = try p.st.addHeaders(raws.items);
        try p.field("added", .{ .uint = res.added });
        try p.field("tip", .{ .uint = res.tip });
        if (res.replaced > 0) try p.field("replaced", .{ .uint = res.replaced });
    } else if (eql(u8, kind, "proof")) {
        const txid = if (ev.getCid("subject")) |s| c.store.bitcoinHash(s) orelse return error.BadEvent else c.header.fromHex(ev.getText("txid") orelse return error.BadEvent) catch return error.BadEvent;
        try p.field("txid", try p.hex(txid));
        p.via = ev.getText("via");
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
    const outcome = callOf(p, name, fargs, sender, box, message) catch |e| Outcome{ .err = .{ .code = "failed", .message = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ @errorName(e), if (vm.lastError().len > 0) ": " else "", vm.lastError() }) } };
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

fn callOf(p: *Step, name: []const u8, fargs: Value, sender: ?[]const u8, box: []const u8, message: []const u8) !Outcome {
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
            // shruggr/skein#121: a BEEF comes in as the pointer record the kernel's door wrote (its CID; the
            // transactions and BUMPs are blocks in the store), or as bytes / hex from a caller with no door.
            const beef = if (fargs.getCid("beef")) |rc|
                c.record.beefOf(a, vm.store(), rc) catch |e| return .{ .err = .{ .code = "bad-args", .message = try std.fmt.allocPrint(a, "args.beef: not a BEEF pointer record held here ({s})", .{@errorName(e)}) } }
            else
                (try shape.beefArg(a, fargs)) orelse return .{ .err = .{ .code = "bad-args", .message = "args.beef: want a BEEF pointer record's CID, or a BEEF (bytes, or hex)" } };
            const got = p.st.ingest(beef) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => return .{ .err = .{ .code = "failed", .message = try std.fmt.allocPrint(a, "ingest: {s}", .{@errorName(e)}) } },
            };
            try p.field("txid", try p.hex(got.txid));
            try p.field("status", .{ .text = @tagName(got.status) });
            for (got.registered) |t| try p.to_broadcast.append(a, t);
            switch (got.status) {
                // Proven or rejected in: answered at once.
                .proven, .rejected => return .{ .ok = try shape.txState(a, &p.st, got.txid, null, "") },
                .unproven => {
                    // Answered on each state change from now on; at once if it is accepted already.
                    if (sender) |s| try p.st.watch(got.txid, s, box, message);
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
    if (f.writes()) return error.IngestIsAMessage; // its answers come later, at the caller's address
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
