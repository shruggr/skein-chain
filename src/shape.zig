//! The chain app's pure parts, tested natively (test.zig): its configuration
//! (from its app record, else the genesis defaults), the functions it takes
//! and their arguments, and the shapes of its answers.
const std = @import("std");
const c = @import("chain");

const cbor = c.cbor;
const Value = cbor.Value;
const State = c.state.State;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// What the app runs with.
pub const Config = struct {
    /// The app's name: its box, and the prefix of its heads (`<app>/app`, `<app>/state`).
    app: []const u8 = "chain",
    network: c.chain.Network = .main,

    pub fn stateHead(self: Config, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}/state", .{self.app});
    }
};

/// The configuration: `config.chain` of the app record (`network`: "main" | "test" | "regtest")
/// where it says, else the genesis default `walletNetwork`, else mainnet. `app`: the name the program record names (null:
/// a genesis-wired program — "chain").
pub fn configOf(app: ?[]const u8, record: ?Value, defaults: ?Value) !Config {
    var conf = Config{};
    if (app) |n| conf.app = n;
    if (defaults) |d| {
        if (d.getText("walletNetwork")) |n| conf.network = c.chain.Network.parse(n) orelse return error.BadConfig;
    }
    const ch = if (record) |r| (if (r.get("config")) |x| x.get("chain") else null) else null;
    if (ch) |x| {
        if (x != .map) return error.BadConfig;
        if (x.get("network")) |n| conf.network = c.chain.Network.parse(if (n == .text) n.text else return error.BadConfig) orelse return error.BadConfig;
    }
    return conf;
}

/// The functions the app takes in its box (`{fn, args}`), by name; `chain.<fn>` (docs/APPS.md §4's
/// dotted form, the interface `chain/1`) is the same function.
pub const Fn = enum {
    ingest,
    status,
    proof,

    pub fn parse(name: []const u8) ?Fn {
        const bare = if (std.mem.startsWith(u8, name, "chain.")) name["chain.".len..] else name;
        return std.meta.stringToEnum(Fn, bare);
    }
    /// `ingest` writes; the reads answer from the state as it stands.
    pub fn writes(f: Fn) bool {
        return f == .ingest;
    }
};

pub const Failure = struct { code: []const u8, message: []const u8 };

/// A txid argument: 64 hex digits (display order) → internal order.
pub fn txidArg(args: Value) !?[32]u8 {
    const t = args.getText("txid") orelse return null;
    return c.header.fromHex(t) catch null;
}

/// A BEEF argument: bytes, or hex text.
pub fn beefArg(a: Allocator, args: Value) !?[]const u8 {
    const v = args.get("beef") orelse return null;
    return switch (v) {
        .bytes => |b| b,
        .text => |t| blk: {
            if (t.len % 2 != 0) break :blk null;
            const out = try a.alloc(u8, t.len / 2);
            _ = std.fmt.hexToBytes(out, t) catch break :blk null;
            break :blk out;
        },
        else => null,
    };
}

fn txidText(a: Allocator, txid: [32]u8) !Value {
    return .{ .text = try a.dupe(u8, &c.header.toHex(txid)) };
}

fn txCid(a: Allocator, txid: [32]u8) !Value {
    return .{ .cid = try a.dupe(u8, &c.store.hashCid(.tx, txid)) };
}

/// What a caller is told about a transaction: `{txid, tx, state, …}` — CIDs, not data.
///   proven    block (its header's CID), height
///   accepted  txStatus (the status that accepted it)
///   rejected  reason, settlement (the settlement record's CID)
///   unproven  broadcast (the registered broadcast record's CID), txStatus   (a read only)
///   unknown   (a read only: not held)
pub fn txState(a: Allocator, st: *State, txid: [32]u8, as: ?[]const u8, detail: []const u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.append(a, .{ .key = "txid", .value = try txidText(a, txid) });
    if (!(try st.holds(txid))) {
        try es.append(a, .{ .key = "state", .value = .{ .text = "unknown" } });
        return .{ .map = es.items };
    }
    try es.append(a, .{ .key = "tx", .value = try txCid(a, txid) });
    const status = try st.status(txid);
    const name = as orelse @tagName(status);
    try es.append(a, .{ .key = "state", .value = .{ .text = name } });
    switch (status) {
        .proven => {
            const r = (try st.proofRecord(txid)).?;
            try es.append(a, .{ .key = "block", .value = .{ .cid = r.block } });
            if (try st.chain().heightOf(c.store.bitcoinHash(r.block).?)) |h| try es.append(a, .{ .key = "height", .value = .{ .uint = h } });
        },
        .rejected => {
            const sc = (try st.settlementCid(txid)).?;
            try es.append(a, .{ .key = "settlement", .value = .{ .cid = sc } });
            try es.append(a, .{ .key = "reason", .value = .{ .text = (try st.record(sc)).getText("reason") orelse "" } });
        },
        .unproven => {
            if (try st.broadcastCid(txid)) |bc| {
                try es.append(a, .{ .key = "broadcast", .value = .{ .cid = bc } });
                const r = try st.record(bc);
                const ts = if (detail.len > 0) detail else r.getText("txStatus") orelse "";
                if (ts.len > 0) try es.append(a, .{ .key = "txStatus", .value = .{ .text = ts } });
            }
        },
    }
    return .{ .map = es.items };
}

/// `proof {txid}`: where the proof is — the header's CID, its height, the leaf's depth and position
/// (the merkle nodes are under the header's merkle root: skein-sdk chain `merkle.pathFor`).
pub fn proofOf(a: Allocator, st: *State, txid: [32]u8) !?Value {
    if ((try st.status(txid)) != .proven) return null;
    const r = (try st.proofRecord(txid)).?;
    const h = (try st.chain().heightOf(c.store.bitcoinHash(r.block).?)).?;
    return .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "txid", .value = try txidText(a, txid) },
        .{ .key = "tx", .value = try txCid(a, txid) },
        .{ .key = "block", .value = .{ .cid = r.block } },
        .{ .key = "height", .value = .{ .uint = h } },
        .{ .key = "depth", .value = .{ .uint = r.pos.depth } },
        .{ .key = "position", .value = .{ .uint = r.pos.offset } },
    }) };
}

/// An answer to a call by message (docs/APPS.md §4): `{fn, request, replyTo, result}` or `{…, error}`.
pub fn answerBody(a: Allocator, func: []const u8, request: []const u8, outcome: union(enum) { ok: Value, err: Failure }) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "fn", .value = .{ .text = func } },
        .{ .key = "request", .value = .{ .cid = request } },
        .{ .key = "replyTo", .value = .{ .cid = request } },
    });
    switch (outcome) {
        .ok => |v| try es.append(a, .{ .key = "result", .value = v }),
        .err => |f| try es.append(a, .{ .key = "error", .value = .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "code", .value = .{ .text = f.code } },
            .{ .key = "message", .value = .{ .text = f.message } },
        }) } }),
    }
    return .{ .map = es.items };
}

/// The fact name of a transaction's status: `<app>/tx/<txid hex>`.
pub fn txName(a: Allocator, app: []const u8, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/tx/{s}", .{ app, &c.header.toHex(txid) });
}

/// The fact name of an output's state (0.10.0): `<app>/output/<txid hex>.<vout>`.
pub fn outputName(a: Allocator, app: []const u8, txid: [32]u8, vout: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/output/{s}.{d}", .{ app, &c.header.toHex(txid), vout });
}

/// A transaction's status as a fact (0.10.0, David 2026-11-09): the emit `{event: "<app>/tx/<txid
/// hex>", status, height?, reason?, by?}` — `status` one of four: "pending" (held, its broadcast
/// asked for, no answer yet), "seen" (the network has it; after a reorg with `reason` "reorged"),
/// "mined" (with `height`, its block's on our best chain), "rejected" (with `reason`; `by` the
/// winner of a double spend, or the cascade's root for "input-rejected"). None is final.
pub fn statusEvent(a: Allocator, app: []const u8, txid: [32]u8, status: []const u8, height: ?u64, reason: ?[]const u8, by: ?[32]u8) !Value {
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.appendSlice(a, &.{
        .{ .key = "event", .value = .{ .text = try txName(a, app, txid) } },
        .{ .key = "status", .value = .{ .text = status } },
    });
    if (height) |h| try es.append(a, .{ .key = "height", .value = .{ .uint = h } });
    if (reason) |r| try es.append(a, .{ .key = "reason", .value = .{ .text = r } });
    if (by) |b| try es.append(a, .{ .key = "by", .value = try txidText(a, b) });
    return .{ .map = es.items };
}

/// The height of a proven transaction's block on our best chain (null: not proven).
fn minedHeight(st: *State, txid: [32]u8) !?u64 {
    if ((try st.status(txid)) != .proven) return null;
    const r = (try st.proofRecord(txid)) orelse return null;
    const h = (try st.chain().heightOf(c.store.bitcoinHash(r.block) orelse return null)) orelse return null;
    return h;
}

/// A held transaction's status as it stands, in the four words: proven "mined"; rejected
/// "rejected" (its settlement's reason and cause); unproven "seen" once a status accepted it, else
/// "pending".
pub fn statusNow(a: Allocator, st: *State, app: []const u8, txid: [32]u8) !Value {
    return switch (try st.status(txid)) {
        .proven => statusEvent(a, app, txid, "mined", try minedHeight(st, txid), null, null),
        .rejected => blk: {
            const r = (try st.rejectionOf(txid)) orelse break :blk statusEvent(a, app, txid, "rejected", null, "rejected", null);
            break :blk statusEvent(a, app, txid, "rejected", null, r.reason, r.by);
        },
        .unproven => blk: {
            const seen = if (try st.broadcastRecord(txid)) |r| r.getBool("accepted") orelse false else false;
            break :blk statusEvent(a, app, txid, if (seen) "seen" else "pending", null, null, null);
        },
    };
}

/// Every status this step came to, as facts, in order (0.10.0):
///   - each transaction a reorg turned back to unproven (`st.reverted`): "seen", reason "reorged";
///   - each state change of a transaction with a registered broadcast (`st.changes`): "seen" (was
///     "accepted"), "mined" with its height, "rejected" with its reason and cause;
///   - each transaction this step newly held (`st.added`, skein-sdk 0.19.0): its status at intake
///     ("pending", "mined", "rejected", "seen") — every transaction gets one;
///   - an ingest's subject: its status as it stands, also when it was held before.
/// A transaction's same status twice in one step is one fact.
pub fn statusEvents(a: Allocator, st: *State, app: []const u8, ingested: ?[32]u8) ![]Value {
    const Said = struct { txid: [32]u8, status: []const u8 };
    var said: std.ArrayList(Said) = .empty;
    var out: std.ArrayList(Value) = .empty;
    const add = struct {
        fn f(al: Allocator, ss: *std.ArrayList(Said), o: *std.ArrayList(Value), txid: [32]u8, ev: Value) !void {
            const status = ev.getText("status").?;
            for (ss.items) |x| if (eql(u8, &x.txid, &txid) and eql(u8, x.status, status)) return;
            try ss.append(al, .{ .txid = txid, .status = status });
            try o.append(al, ev);
        }
    }.f;
    for (st.reverted.items) |t| try add(a, &said, &out, t, try statusEvent(a, app, t, "seen", null, "reorged", null));
    for (st.changes.items) |ch| try add(a, &said, &out, ch.txid, switch (ch.state) {
        .accepted => try statusEvent(a, app, ch.txid, "seen", null, null, null),
        .proven => try statusEvent(a, app, ch.txid, "mined", try minedHeight(st, ch.txid), null, null),
        .rejected => try statusEvent(a, app, ch.txid, "rejected", null, ch.detail, ch.by),
    });
    for (st.added.items) |t| try add(a, &said, &out, t, try statusNow(a, st, app, t));
    if (ingested) |t| if (try st.holds(t)) try add(a, &said, &out, t, try statusNow(a, st, app, t));
    return out.items;
}

/// The fact name of a transaction's linkage to where its proof is (0.11.0): `<app>/proof/<txid hex>`.
pub fn proofName(a: Allocator, app: []const u8, txid: [32]u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/proof/{s}", .{ app, &c.header.toHex(txid) });
}

/// The linkages this step established (0.11.0, David 2026-11-10), as facts: for each transaction
/// a saved merkle path newly linked to its block — held or not (skein-sdk 0.21.0 `State.linked`, the
/// one writer's list) — `{event: "<app>/proof/<txid>", block: <block hash hex>, height, position}`.
pub fn proofEvents(a: Allocator, st: *State, app: []const u8) ![]Value {
    const out = try a.alloc(Value, st.linked.items.len);
    for (st.linked.items, out) |l, *v| v.* = .{ .map = try a.dupe(cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = try proofName(a, app, l.txid) } },
        .{ .key = "block", .value = try txidText(a, l.block) },
        .{ .key = "height", .value = .{ .uint = l.height } },
        .{ .key = "position", .value = .{ .uint = l.position } },
    }) };
    return out;
}

/// A held transaction's `<app>/proof/<t>` subscription step (0.11.0): what its linkage settles in
/// the state (skein-sdk `settleProven`: double spends, its inputs' spent, its broadcast record), as
/// facts — every other transaction's status the settling changed, and `t`'s own `mined` with its
/// height when the state says it is proven and the latest `<app>/tx/<t>` fact is not already that.
pub fn provenFacts(a: Allocator, st: *State, app: []const u8, t: [32]u8, latest: Latest) ![]Value {
    try st.settleProven(t);
    var out: std.ArrayList(Value) = .empty;
    for (try statusEvents(a, st, app, null)) |e| {
        if (eql(u8, e.getText("event").?, try txName(a, app, t))) continue;
        try out.append(a, e);
    }
    if ((try st.holds(t)) and (try st.status(t)) == .proven) {
        const now = try statusNow(a, st, app, t);
        const last = try latest.of(a, try txName(a, app, t));
        const same = if (last) |l| eql(u8, l.getText("status") orelse "", "mined") and l.getUint("height") == now.getUint("height") else false;
        if (!same) try out.append(a, now);
    }
    return out.items;
}

/// What a transaction's answer to an in-VM `ingest` call is (0.10.0): its status in the four
/// words, as the fact says it — `{txid, status, height?, reason?, by?}`.
pub fn ingestAnswer(a: Allocator, st: *State, app: []const u8, txid: [32]u8) !Value {
    const ev = try statusNow(a, st, app, txid);
    var es: std.ArrayList(cbor.Entry) = .empty;
    try es.append(a, .{ .key = "txid", .value = try txidText(a, txid) });
    for (ev.map) |e| if (!eql(u8, e.key, "event")) try es.append(a, e);
    return .{ .map = es.items };
}

/// The latest record under a fact's name (the event index's `latest`), or null: in the VM the
/// `events` import; in tests a stand-in.
pub const Latest = struct {
    ptr: *anyopaque,
    f: *const fn (ptr: *anyopaque, a: Allocator, name: []const u8) anyerror!?Value,
    pub fn of(self: Latest, a: Allocator, name: []const u8) !?Value {
        return self.f(self.ptr, a, name);
    }
};

/// The spender an output's state names now, from the chain state (0.10.0): of the held
/// transactions spending it that are not rejected, the mined one, else the first (lowest txid);
/// null when none.
pub fn liveSpender(st: *State, txid: [32]u8, vout: u32) !?[32]u8 {
    var first: ?[32]u8 = null;
    for (try st.spendersOf(c.store.outpointKey(txid, vout))) |sp| switch (try st.status(sp)) {
        .rejected => {},
        .proven => return sp,
        .unproven => if (first == null) {
            first = sp;
        },
    };
    return first;
}

/// The output-state facts a status change of `t` calls for (0.10.0, David 2026-11-09): each output
/// `t` spends (coinbase inputs skipped) walked from the chain state — "spent" by its live spender
/// (`liveSpender`), else "rolledBack" (`spentBy` the spender the latest message named) — posted
/// only when it differs from the latest message under `<app>/output/<txid>.<vout>`; an output with
/// no message yet and no live spender gets none. `{event, state, spentBy}`.
pub fn outputEvents(a: Allocator, st: *State, app: []const u8, t: [32]u8, latest: Latest) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    const raw = (try st.txRaw(t)) orelse return out.items;
    const tx = try c.bsvz.transaction.Transaction.parse(a, raw);
    var names: std.ArrayList([]const u8) = .empty;
    each: for (tx.inputs) |in| {
        const prev = in.previous_outpoint;
        if (prev.index == 0xffffffff and std.mem.allEqual(u8, &prev.txid.bytes, 0)) continue;
        const name = try outputName(a, app, prev.txid.bytes, prev.index);
        for (names.items) |n| if (eql(u8, n, name)) continue :each;
        try names.append(a, name);
        const last = try latest.of(a, name);
        const last_state = if (last) |l| l.getText("state") else null;
        const last_by = if (last) |l| l.getText("spentBy") else null;
        var state: []const u8 = undefined;
        var by: [32]u8 = undefined;
        if (try liveSpender(st, prev.txid.bytes, prev.index)) |s| {
            state = "spent";
            by = s;
            if (last_state != null and eql(u8, last_state.?, "spent") and last_by != null and eql(u8, last_by.?, &c.header.toHex(s))) continue;
        } else {
            const lb = last_by orelse continue;
            if (last_state != null and eql(u8, last_state.?, "rolledBack")) continue;
            state = "rolledBack";
            by = c.header.fromHex(lb) catch continue;
        }
        try out.append(a, .{ .map = try a.dupe(cbor.Entry, &.{
            .{ .key = "event", .value = .{ .text = name } },
            .{ .key = "state", .value = .{ .text = state } },
            .{ .key = "spentBy", .value = try txidText(a, by) },
        }) });
    }
    return out.items;
}
