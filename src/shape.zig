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

/// A watcher (a broadcast record's `watchers` entry): who to answer, in which box, about which request.
pub const Watcher = struct { to: []const u8, box: []const u8, request: []const u8 };

pub fn watcherOf(v: Value) ?Watcher {
    return .{ .to = v.getBytes("to") orelse return null, .box = v.getText("box") orelse return null, .request = v.getCid("request") orelse return null };
}

/// An answer to a watcher: who, which box, the `ingest` answer body.
pub const Answer = struct { to: []const u8, box: []const u8, body: Value };

/// Every state change of a watched transaction this step (`st.changes`): an `ingest` answer to each of
/// its watchers, at the request they watched by. A proof after a reorg is another change: the watchers
/// of the first proof (kept by the chain state, skein-sdk 0.7.1) are answered again, with the new
/// `block`. `via`: a proof that came by a route's wiring (an overlay's `-proof` gossip) — its watchers
/// are told, so they do not publish it again.
pub fn changeAnswers(a: Allocator, st: *State, via: ?[]const u8) ![]Answer {
    var out: std.ArrayList(Answer) = .empty;
    for (st.changes.items) |ch| for (ch.watchers) |wv| {
        const w = watcherOf(wv) orelse continue;
        var result = try txState(a, st, ch.txid, @tagName(ch.state), ch.detail);
        if (ch.state == .proven) if (via) |v| {
            result = .{ .map = try std.mem.concat(a, cbor.Entry, &.{ result.map, &.{.{ .key = "via", .value = .{ .text = v } }} }) };
        };
        try out.append(a, .{ .to = w.to, .box = w.box, .body = try answerBody(a, "ingest", w.request, .{ .ok = result }) });
    };
    return out.items;
}
