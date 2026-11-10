//! The chain app's pure parts (src/shape.zig), natively: its configuration,
//! its functions, and the shapes of its answers over a chain state in memory
//! (0.8.0: every status a fact `chain/tx/<txid>`, a reorg's too).
//! The flow through a kernel (ingest, broadcast, statuses, proofs, the
//! answers, replay) is skein's kernel-zig/equiv/chain.ts.
const std = @import("std");
const c = @import("chain");
const shape = @import("src/shape.zig");

const cbor = c.cbor;
const Value = cbor.Value;

fn map(a: std.mem.Allocator, es: []const cbor.Entry) !Value {
    return .{ .map = try a.dupe(cbor.Entry, es) };
}

test "configuration: the app record's config.chain, else the genesis defaults, else mainnet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var conf = try shape.configOf(null, null, null);
    try std.testing.expectEqualStrings("chain", conf.app);
    try std.testing.expectEqual(c.chain.Network.main, conf.network);
    try std.testing.expectEqualStrings("chain/state", try conf.stateHead(a));
    const defaults = try map(a, &.{.{ .key = "walletNetwork", .value = .{ .text = "regtest" } }});
    conf = try shape.configOf("chain", null, defaults);
    try std.testing.expectEqual(c.chain.Network.regtest, conf.network);
    const record = try map(a, &.{.{ .key = "config", .value = try map(a, &.{.{ .key = "chain", .value = try map(a, &.{.{ .key = "network", .value = .{ .text = "test" } }}) }}) }});
    conf = try shape.configOf("mychain", record, defaults);
    try std.testing.expectEqual(c.chain.Network.@"test", conf.network);
    try std.testing.expectEqualStrings("mychain/state", try conf.stateHead(a));
    const bad = try map(a, &.{.{ .key = "config", .value = try map(a, &.{.{ .key = "chain", .value = try map(a, &.{.{ .key = "network", .value = .{ .text = "moon" } }}) }}) }});
    try std.testing.expectError(error.BadConfig, shape.configOf("chain", bad, null));
}

test "functions: bare or dotted; only ingest writes" {
    try std.testing.expectEqual(shape.Fn.ingest, shape.Fn.parse("ingest").?);
    try std.testing.expectEqual(shape.Fn.status, shape.Fn.parse("chain.status").?);
    try std.testing.expect(shape.Fn.parse("chain.nope") == null);
    try std.testing.expect(shape.Fn.ingest.writes() and !shape.Fn.proof.writes());
}

test "answers: {fn, request, replyTo, result | error}; an unknown transaction's state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req: [36]u8 = .{ 0x01, 0x71, 0x12, 0x20 } ++ .{7} ** 32;
    const ok = try shape.answerBody(a, "ingest", &req, .{ .ok = .null });
    try std.testing.expectEqualStrings("ingest", ok.getText("fn").?);
    try std.testing.expectEqualSlices(u8, &req, ok.getCid("replyTo").?);
    try std.testing.expectEqualSlices(u8, &req, ok.getCid("request").?);
    const err = try shape.answerBody(a, "status", &req, .{ .err = .{ .code = "bad-args", .message = "no" } });
    try std.testing.expectEqualStrings("bad-args", err.get("error").?.getText("code").?);

    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    const v = try shape.txState(a, &st, .{9} ** 32, null, "");
    try std.testing.expectEqualStrings("unknown", v.getText("state").?);
    try std.testing.expect(try shape.proofOf(a, &st, .{9} ** 32) == null);
    const args = try map(a, &.{ .{ .key = "txid", .value = .{ .text = "ab" ** 32 } }, .{ .key = "beef", .value = .{ .text = "0102" } } });
    try std.testing.expect((try shape.txidArg(args)) != null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, (try shape.beefArg(a, args)).?);
}

// ------------------------------------------------------------ the facts: every status, a reorg's too

fn mine(prev: [32]u8, merkle_root: [32]u8, time: u32) [80]u8 {
    var h = c.header.Header{ .version = 1, .prev_hash = prev, .merkle_root = merkle_root, .time = time, .bits = 0x207fffff, .nonce = 0 };
    while (true) : (h.nonce += 1) {
        const raw = h.serialize();
        if (c.header.powOk(&raw)) return raw;
    }
}

/// A BUMP for a block holding one transaction: its root is the txid.
fn soloPath(a: std.mem.Allocator, height: u32, txid: [32]u8) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, &.{ 0xfd, 0, 0, 0x01, 0x01, 0x00, 0x02 });
    std.mem.writeInt(u16, path.items[1..3], @intCast(height), .little);
    try path.appendSlice(a, &txid);
    return path.items;
}

const Tx = struct { tx: c.bsvz.transaction.Transaction, raw: []const u8, txid: [32]u8 };
const priv: [32]u8 = .{0x11} ** 32;

fn p2pkh() ![25]u8 {
    const pk = (try (try c.bsvz.primitives.ec.PrivateKey.fromBytes(priv)).publicKey()).toCompressedSec1();
    var s: [25]u8 = undefined;
    s[0..3].* = .{ 0x76, 0xa9, 0x14 };
    s[3..23].* = c.bsvz.crypto.hash.hash160(&pk).bytes;
    s[23..25].* = .{ 0x88, 0xac };
    return s;
}

/// The funding: one input from nowhere, one P2PKH output of 10 000 to our key.
fn funding(a: std.mem.Allocator) !Tx {
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, &.{ 1, 0, 0, 0, 1 });
    try raw.appendSlice(a, &([_]u8{0x72} ** 32));
    try raw.appendSlice(a, &.{ 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, 1 });
    var sats: [8]u8 = undefined;
    std.mem.writeInt(u64, &sats, 10_000, .little);
    try raw.appendSlice(a, &sats);
    try raw.append(a, 25);
    try raw.appendSlice(a, &(try p2pkh()));
    try raw.appendSlice(a, &.{ 0, 0, 0, 0 });
    return .{ .tx = try c.bsvz.transaction.Transaction.parse(a, raw.items), .raw = raw.items, .txid = c.beef.txidOf(raw.items) };
}

/// The funding's output spent to our key again (signed P2PKH).
fn spend(a: std.mem.Allocator, src: *const c.bsvz.transaction.Transaction) !Tx {
    const bsvz = c.bsvz;
    var b = bsvz.transaction.Builder.init(a);
    try b.addInputFromTx(src, 0);
    try b.addOutput(.{ .satoshis = 9_000, .locking_script = bsvz.script.Script.init(try a.dupe(u8, &(try p2pkh()))) });
    var tx = try b.build();
    const key = try bsvz.crypto.PrivateKey.fromBytes(priv);
    const prev = src.outputs[0];
    const u = try bsvz.transaction.templates.p2pkh_spend.signAndBuildUnlockingScript(a, &tx, 0, prev.locking_script, prev.satoshis, key, bsvz.transaction.templates.p2pkh_spend.default_scope);
    @constCast(tx.inputs)[0].unlocking_script = u;
    const raw = try tx.serialize(a);
    return .{ .tx = tx, .raw = raw, .txid = c.beef.txidOf(raw) };
}

fn expectFact(e: Value, txid: [32]u8, status: []const u8, height: ?u64) !void {
    var name: [64 + 9]u8 = undefined;
    _ = try std.fmt.bufPrint(&name, "chain/tx/{s}", .{&c.header.toHex(txid)});
    try std.testing.expectEqualStrings(&name, e.getText("event").?);
    try std.testing.expectEqualStrings(status, e.getText("status").?);
    try std.testing.expectEqual(height, e.getUint("height"));
}

/// The fact about `txid` among `facts` (exactly one).
fn factOf(facts: []const Value, txid: [32]u8) !Value {
    var name: [64 + 9]u8 = undefined;
    _ = try std.fmt.bufPrint(&name, "chain/tx/{s}", .{&c.header.toHex(txid)});
    var found: ?Value = null;
    for (facts) |f| if (std.mem.eql(u8, f.getText("event").?, &name)) {
        try std.testing.expect(found == null);
        found = f;
    };
    return found orelse error.NoFact;
}

test "every status a fact (0.10.0): pending at intake (its proven parent mined), seen, mined at 2, seen+reorged, mined at 4 — chain/tx/<txid> each time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;

    // Height 1 holds the funding; the child comes in unproven over it.
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    var st = try State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&h1});
    const child = try spend(a, &fund.tx);
    var bumps = [_]c.bsvz.spv.MerklePath{try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund.txid))};
    var entries = [_]c.beef.Entry{
        .{ .txid = fund.txid, .format = .raw_with_bump, .bump = 0, .raw = fund.raw, .tx = fund.tx },
        .{ .txid = child.txid, .format = .raw, .raw = child.raw, .tx = child.tx },
    };
    const beef = try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = child.txid, .bumps = &bumps, .entries = &entries });
    _ = try st.ingest(beef);
    // 0.10.0: every transaction gets a status at intake — the funding (proven in) `mined` at 1, the
    // child (only broadcast) `pending`.
    const intake = try shape.statusEvents(a, &st, "chain", child.txid);
    try std.testing.expectEqual(@as(usize, 2), intake.len);
    try expectFact(intake[0], fund.txid, "mined", 1);
    try expectFact(intake[1], child.txid, "pending", null);
    const ingested = try st.save();

    // A status accepts it.
    var st1 = try State.load(a, ms.store(), ingested, .regtest);
    try std.testing.expectEqual(State.Outcome.accepted, try st1.applyStatus(child.txid, "SEEN_ON_NETWORK", null));
    var facts = try shape.statusEvents(a, &st1, "chain", null);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try expectFact(facts[0], child.txid, "seen", null);
    // Ingested again, accepted already: its status as it stands, once.
    _ = try st1.ingest(beef);
    facts = try shape.statusEvents(a, &st1, "chain", child.txid);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    const accepted = try st1.save();

    // Proven at height 2.
    var st2 = try State.load(a, ms.store(), accepted, .regtest);
    const h2 = mine(c.header.hash(&h1), child.txid, 1_700_001_200);
    _ = try st2.addHeaders(&.{&h2});
    try std.testing.expectEqual(State.Outcome.proven, try st2.applyStatus(child.txid, "MINED", try soloPath(a, 2, child.txid)));
    facts = try shape.statusEvents(a, &st2, "mychain", null);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try std.testing.expect(std.mem.startsWith(u8, facts[0].getText("event").?, "mychain/tx/"));
    try std.testing.expectEqual(@as(?u64, 2), facts[0].getUint("height"));
    facts = try shape.statusEvents(a, &st2, "chain", null);
    try expectFact(facts[0], child.txid, "mined", 2);
    const proven = try st2.save();

    // A heavier branch without it: reorged (no broadcast, no other fact).
    var st3 = try State.load(a, ms.store(), proven, .regtest);
    const alt2 = mine(c.header.hash(&h1), .{3} ** 32, 1_700_001_201);
    const alt3 = mine(c.header.hash(&alt2), .{4} ** 32, 1_700_001_202);
    _ = try st3.addHeaders(&.{ &alt2, &alt3 });
    facts = try shape.statusEvents(a, &st3, "chain", null);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try expectFact(facts[0], child.txid, "seen", null);
    try std.testing.expectEqualStrings("reorged", facts[0].getText("reason").?);
    const reverted = try st3.save();

    // Proven again at height 4, another block: mined again, with its height.
    var st4 = try State.load(a, ms.store(), reverted, .regtest);
    const alt4 = mine(c.header.hash(&alt3), child.txid, 1_700_001_203);
    _ = try st4.addHeaders(&.{&alt4});
    try std.testing.expectEqual(State.Outcome.proven, try st4.applyStatus(child.txid, "MINED", try soloPath(a, 4, child.txid)));
    facts = try shape.statusEvents(a, &st4, "chain", null);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try expectFact(facts[0], child.txid, "mined", 4);
    // Ingested again, proven: `mined` as it stands.
    _ = try st4.ingest(beef);
    facts = try shape.statusEvents(a, &st4, "chain", child.txid);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
}

test "rejected (0.10.0): a network rejection is the fact `rejected` with its reason, no cause, once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    var st = try State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&h1});
    const child = try spend(a, &fund.tx);
    var bumps = [_]c.bsvz.spv.MerklePath{try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund.txid))};
    var entries = [_]c.beef.Entry{
        .{ .txid = fund.txid, .format = .raw_with_bump, .bump = 0, .raw = fund.raw, .tx = fund.tx },
        .{ .txid = child.txid, .format = .raw, .raw = child.raw, .tx = child.tx },
    };
    const beef = try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = child.txid, .bumps = &bumps, .entries = &entries });
    _ = try st.ingest(beef);
    try std.testing.expectEqual(State.Outcome.rejected, try st.applyStatus(child.txid, "DOUBLE_SPEND_ATTEMPTED", null));
    const facts = try shape.statusEvents(a, &st, "chain", child.txid);
    try std.testing.expectEqual(@as(usize, 2), facts.len); // the funding's intake `mined`, the child once
    const f = try factOf(facts, child.txid);
    try expectFact(f, child.txid, "rejected", null);
    try std.testing.expectEqualStrings("DOUBLE_SPEND_ATTEMPTED", f.getText("reason").?);
    try std.testing.expect(f.get("by") == null);
}

test "a proof after a rejection (0.9.0, skein-sdk 0.18.0): the latest fact — `mined` with its height; the rejection's reason kept in state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    var st = try State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&h1});
    const child = try spend(a, &fund.tx);
    var bumps = [_]c.bsvz.spv.MerklePath{try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund.txid))};
    var entries = [_]c.beef.Entry{
        .{ .txid = fund.txid, .format = .raw_with_bump, .bump = 0, .raw = fund.raw, .tx = fund.tx },
        .{ .txid = child.txid, .format = .raw, .raw = child.raw, .tx = child.tx },
    };
    const beef = try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = child.txid, .bumps = &bumps, .entries = &entries });
    _ = try st.ingest(beef);
    try std.testing.expectEqual(State.Outcome.rejected, try st.applyStatus(child.txid, "DOUBLE_SPEND_ATTEMPTED", null));
    const rejected = try st.save();

    var st2 = try State.load(a, ms.store(), rejected, .regtest);
    const h2 = mine(c.header.hash(&h1), child.txid, 1_700_001_200);
    _ = try st2.addHeaders(&.{&h2});
    try std.testing.expectEqual(State.Outcome.proven, try st2.applyStatus(child.txid, "MINED", try soloPath(a, 2, child.txid)));
    const facts = try shape.statusEvents(a, &st2, "chain", null);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try expectFact(facts[0], child.txid, "mined", 2);
    try std.testing.expectEqualStrings("DOUBLE_SPEND_ATTEMPTED", (try st2.record((try st2.settlementCid(child.txid)).?)).getText("reason").?);
}

// ------------------------------------------------------------ 0.10.0: output states, by subscription

/// The event index as the handler reads it: the latest record per name (a stand-in for `events`).
const Index = struct {
    latest: std.StringHashMap(Value),
    posts: usize = 0,
    fn reader(self: *Index) shape.Latest {
        return .{ .ptr = self, .f = struct {
            fn f(p: *anyopaque, _: std.mem.Allocator, name: []const u8) anyerror!?Value {
                const ix: *Index = @ptrCast(@alignCast(p));
                return ix.latest.get(name);
            }
        }.f };
    }
    /// The handler of every status fact a step emitted (each a step of its own: its posts land before the next).
    fn deliver(self: *Index, a: std.mem.Allocator, st: *c.state.State, facts: []const Value) !void {
        for (facts) |f| {
            const name = f.getText("event").?;
            const t = try c.header.fromHex(name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..]);
            for (try shape.outputEvents(a, st, "chain", t, self.reader())) |e| {
                try self.latest.put(e.getText("event").?, e);
                self.posts += 1;
            }
        }
    }
    fn state(self: *Index, a: std.mem.Allocator, txid: [32]u8, vout: u32) !?Value {
        return self.latest.get(try shape.outputName(a, "chain", txid, vout));
    }
};

fn expectOutput(v: ?Value, state: []const u8, by: [32]u8) !void {
    try std.testing.expectEqualStrings(state, v.?.getText("state").?);
    try std.testing.expectEqualStrings(&c.header.toHex(by), v.?.getText("spentBy").?);
}

/// A second spend of the funding's output (another amount: another txid).
fn spendOther(a: std.mem.Allocator, src: *const c.bsvz.transaction.Transaction) !Tx {
    const bsvz = c.bsvz;
    var b = bsvz.transaction.Builder.init(a);
    try b.addInputFromTx(src, 0);
    try b.addOutput(.{ .satoshis = 8_000, .locking_script = bsvz.script.Script.init(try a.dupe(u8, &(try p2pkh()))) });
    var tx = try b.build();
    const key = try bsvz.crypto.PrivateKey.fromBytes(priv);
    const prev = src.outputs[0];
    const u = try bsvz.transaction.templates.p2pkh_spend.signAndBuildUnlockingScript(a, &tx, 0, prev.locking_script, prev.satoshis, key, bsvz.transaction.templates.p2pkh_spend.default_scope);
    @constCast(tx.inputs)[0].unlocking_script = u;
    const raw = try tx.serialize(a);
    return .{ .tx = tx, .raw = raw, .txid = c.beef.txidOf(raw) };
}

fn beefOver(a: std.mem.Allocator, fund: Tx, proven: ?Tx, proven_h: u32, rest: []const Tx) ![]const u8 {
    var bumps: std.ArrayList(c.bsvz.spv.MerklePath) = .empty;
    var entries: std.ArrayList(c.beef.Entry) = .empty;
    try bumps.append(a, try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, fund.txid)));
    try entries.append(a, .{ .txid = fund.txid, .format = .raw_with_bump, .bump = 0, .raw = fund.raw, .tx = fund.tx });
    if (proven) |p| {
        try bumps.append(a, try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, proven_h, p.txid)));
        try entries.append(a, .{ .txid = p.txid, .format = .raw_with_bump, .bump = 1, .raw = p.raw, .tx = p.tx });
    }
    for (rest) |t| try entries.append(a, .{ .txid = t.txid, .format = .raw, .raw = t.raw, .tx = t.tx });
    return c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = entries.items[entries.items.len - 1].txid, .bumps = bumps.items, .entries = entries.items });
}

test "two spenders (0.10.0): A taken in (spent by A); a proven B — A rejected double-spent by B, the output spent by B; again, nothing posted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    var ix = Index{ .latest = std.StringHashMap(Value).init(a) };

    // Step 1: A comes in unproven over the funding.
    var st = try State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&h1});
    const ta = try spend(a, &fund.tx);
    const g = try st.ingest(try beefOver(a, fund, null, 0, &.{ta}));
    try std.testing.expectEqual(@as(usize, 2), st.added.items.len); // the funding and A: each subscribed
    try ix.deliver(a, &st, try shape.statusEvents(a, &st, "chain", g.txid));
    try expectOutput(try ix.state(a, fund.txid, 0), "spent", ta.txid);
    const s1 = try st.save();

    // Step 2: B, spending the same output, comes in proven at 2.
    var st2 = try State.load(a, ms.store(), s1, .regtest);
    const tb = try spendOther(a, &fund.tx);
    _ = try st2.addHeaders(&.{&mine(c.header.hash(&h1), tb.txid, 1_700_001_200)});
    const g2 = try st2.ingest(try beefOver(a, fund, tb, 2, &.{}));
    const facts = try shape.statusEvents(a, &st2, "chain", g2.txid);
    const fa = try factOf(facts, ta.txid);
    try expectFact(fa, ta.txid, "rejected", null);
    try std.testing.expectEqualStrings("double-spent", fa.getText("reason").?);
    try std.testing.expectEqualStrings(&c.header.toHex(tb.txid), fa.getText("by").?);
    try expectFact(try factOf(facts, tb.txid), tb.txid, "mined", 2);
    const before = ix.posts;
    try ix.deliver(a, &st2, facts);
    try expectOutput(try ix.state(a, fund.txid, 0), "spent", tb.txid);
    try std.testing.expectEqual(before + 1, ix.posts); // one post: A's handler; B's finds it said
    // The same facts again (any order): nothing more to post.
    const rev = try a.dupe(Value, facts);
    std.mem.reverse(Value, rev);
    try ix.deliver(a, &st2, rev);
    try std.testing.expectEqual(before + 1, ix.posts);

    // The other order from step 1's index: B's handler first, then A's — the same end state.
    var ix2 = Index{ .latest = std.StringHashMap(Value).init(a) };
    try ix2.latest.put(try shape.outputName(a, "chain", fund.txid, 0), .{ .map = try a.dupe(c.cbor.Entry, &.{
        .{ .key = "event", .value = .{ .text = try shape.outputName(a, "chain", fund.txid, 0) } },
        .{ .key = "state", .value = .{ .text = "spent" } },
        .{ .key = "spentBy", .value = .{ .text = try a.dupe(u8, &c.header.toHex(ta.txid)) } },
    }) });
    try ix2.deliver(a, &st2, rev);
    try expectOutput(try ix2.state(a, fund.txid, 0), "spent", tb.txid);
}

test "rolled back (0.10.0): the only spender rejected by the network — the output rolled back (by it), once; a later proof of it — spent again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    var ix = Index{ .latest = std.StringHashMap(Value).init(a) };
    var st = try State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&h1});
    const ta = try spend(a, &fund.tx);
    const g = try st.ingest(try beefOver(a, fund, null, 0, &.{ta}));
    try ix.deliver(a, &st, try shape.statusEvents(a, &st, "chain", g.txid));
    const s1 = try st.save();

    var st2 = try State.load(a, ms.store(), s1, .regtest);
    _ = try st2.applyStatus(ta.txid, "REJECTED", null);
    const facts = try shape.statusEvents(a, &st2, "chain", null);
    try ix.deliver(a, &st2, facts);
    try expectOutput(try ix.state(a, fund.txid, 0), "rolledBack", ta.txid);
    const n = ix.posts;
    try ix.deliver(a, &st2, facts);
    try std.testing.expectEqual(n, ix.posts);
    const s2 = try st2.save();

    // Mined after all (a proof is the latest fact): spent by it again.
    var st3 = try State.load(a, ms.store(), s2, .regtest);
    _ = try st3.addHeaders(&.{&mine(c.header.hash(&h1), ta.txid, 1_700_001_200)});
    _ = try st3.applyStatus(ta.txid, "MINED", try soloPath(a, 2, ta.txid));
    try ix.deliver(a, &st3, try shape.statusEvents(a, &st3, "chain", null));
    try expectOutput(try ix.state(a, fund.txid, 0), "spent", ta.txid);
}

test "outputs (0.10.0): a coinbase input posts nothing; an output with no message and no live spender posts nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    // A coinbase: one input, txid zero, vout 0xffffffff (putTx does not verify).
    var raw: std.ArrayList(u8) = .empty;
    try raw.appendSlice(a, &.{ 1, 0, 0, 0, 1 });
    try raw.appendSlice(a, &([_]u8{0} ** 32));
    try raw.appendSlice(a, &.{ 0xff, 0xff, 0xff, 0xff, 1, 0x51, 0xff, 0xff, 0xff, 0xff, 1 });
    try raw.appendSlice(a, &.{ 0x10, 0x27, 0, 0, 0, 0, 0, 0, 1, 0x51, 0, 0, 0, 0 });
    const cb = c.beef.txidOf(raw.items);
    _ = try st.putTx(cb, raw.items);
    var ix = Index{ .latest = std.StringHashMap(Value).init(a) };
    try std.testing.expectEqual(@as(usize, 0), (try shape.outputEvents(a, &st, "chain", cb, ix.reader())).len);
    // Not held: nothing.
    try std.testing.expectEqual(@as(usize, 0), (try shape.outputEvents(a, &st, "chain", .{7} ** 32, ix.reader())).len);
}

test "ingest answer (0.10.0): {txid, status, height?, reason?, by?} in the four words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const fund = try funding(a);
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    _ = try st.addHeaders(&.{&mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600)});
    const ta = try spend(a, &fund.tx);
    const g = try st.ingest(try beefOver(a, fund, null, 0, &.{ta}));
    const ans = try shape.ingestAnswer(a, &st, "chain", g.txid);
    try std.testing.expectEqualStrings(&c.header.toHex(ta.txid), ans.getText("txid").?);
    try std.testing.expectEqualStrings("pending", ans.getText("status").?);
    try std.testing.expect(ans.get("event") == null);
    const af = try shape.ingestAnswer(a, &st, "chain", fund.txid);
    try std.testing.expectEqualStrings("mined", af.getText("status").?);
    try std.testing.expectEqual(@as(?u64, 1), af.getUint("height"));
}

// ------------------------------------------------------------ 0.11.0: linkage facts; status by subscription

fn pairBytes(a: std.mem.Allocator, height: u32, left: [32]u8, right: [32]u8) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, &.{ 0xfd, 0, 0, 0x01, 0x02, 0x00, 0x02 });
    std.mem.writeInt(u16, path.items[1..3], @intCast(height), .little);
    try path.appendSlice(a, &left);
    try path.appendSlice(a, &.{ 0x01, 0x00 }); // the right leaf unflagged: a sibling hash
    try path.appendSlice(a, &right);
    return path.items;
}

const Live = struct { fund: Tx, p: Tx, x: Tx, cc: Tx, h1: [80]u8, h2: [80]u8 };

/// The funding at 1; P spends it and X spends P, both mined in block 2 (P at 0, X at 1); C spends X, unmined.
fn liveWorld(a: std.mem.Allocator, st: *c.state.State) !Live {
    const fund = try funding(a);
    const h1 = mine(c.header.hash(&c.chain.Network.regtest.genesis()), fund.txid, 1_700_000_600);
    const p = try spend(a, &fund.tx);
    const x = try spend(a, &p.tx);
    const cc = try spend(a, &x.tx);
    const h2 = mine(c.header.hash(&h1), c.store.dblSha256(&(p.txid ++ x.txid)), 1_700_001_200);
    _ = try st.addHeaders(&.{ &h1, &h2 });
    return .{ .fund = fund, .p = p, .x = x, .cc = cc, .h1 = h1, .h2 = h2 };
}

fn factFor(facts: []const Value, name_prefix: []const u8, txid: [32]u8) ?Value {
    for (facts) |f| {
        const n = f.getText("event").?;
        if (std.mem.startsWith(u8, n, name_prefix) and std.mem.endsWith(u8, n, &c.header.toHex(txid))) return f;
    }
    return null;
}

test "0.11.0 the live sequence: P's path saved — chain/proof for P and X (X unflagged, unheld); X arrives bare with child C — X's first fact mined at 2, never broadcast; C pending, its bundle has X proven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    const z = try liveWorld(a, &st);
    var bumps = [_]c.bsvz.spv.MerklePath{ try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, z.fund.txid)), try c.bsvz.spv.MerklePath.parse(a, try pairBytes(a, 2, z.p.txid, z.x.txid)) };
    var e1 = [_]c.beef.Entry{
        .{ .txid = z.fund.txid, .format = .raw_with_bump, .bump = 0, .raw = z.fund.raw, .tx = z.fund.tx },
        .{ .txid = z.p.txid, .format = .raw_with_bump, .bump = 1, .raw = z.p.raw, .tx = z.p.tx },
    };
    _ = try st.ingest(try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = z.p.txid, .bumps = &bumps, .entries = &e1 }));
    const proofs = try shape.proofEvents(a, &st, "chain");
    try std.testing.expectEqual(@as(usize, 3), proofs.len); // the funding, P, X
    const px = factFor(proofs, "chain/proof/", z.x.txid).?;
    try std.testing.expectEqual(@as(?u64, 2), px.getUint("height"));
    try std.testing.expectEqual(@as(?u64, 1), px.getUint("position"));
    try std.testing.expectEqualStrings(&c.header.toHex(c.header.hash(&z.h2)), px.getText("block").?);
    const s1 = try st.save();

    var st2 = try c.state.State.load(a, ms.store(), s1, .regtest);
    var e2 = [_]c.beef.Entry{
        .{ .txid = z.p.txid, .format = .txid_only },
        .{ .txid = z.x.txid, .format = .raw, .raw = z.x.raw, .tx = z.x.tx },
        .{ .txid = z.cc.txid, .format = .raw, .raw = z.cc.raw, .tx = z.cc.tx },
    };
    const g = try st2.ingest(try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = z.cc.txid, .bumps = &.{}, .entries = &e2 }));
    try std.testing.expectEqual(@as(usize, 0), (try shape.proofEvents(a, &st2, "chain")).len); // nothing new linked
    const facts = try shape.statusEvents(a, &st2, "chain", g.txid);
    try expectFact(factFor(facts, "chain/tx/", z.x.txid).?, z.x.txid, "mined", 2);
    try expectFact(factFor(facts, "chain/tx/", z.cc.txid).?, z.cc.txid, "pending", null);
    try std.testing.expectEqual(@as(usize, 1), g.registered.len); // C only: X is never broadcast
    try std.testing.expectEqualSlices(u8, &z.cc.txid, &g.registered[0]);
    const out = try c.beef.parse(a, (try st2.beefOf(z.cc.txid)).?);
    for (out.entries) |e| if (std.mem.eql(u8, &e.txid, &z.x.txid)) try std.testing.expectEqual(c.beef.Format.raw_with_bump, e.format);
}

test "0.11.0 a proof after the transaction: X held pending, P's path arrives — chain/proof/X; X's subscription step raises mined at 2 once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    const z = try liveWorld(a, &st);
    var bumps = [_]c.bsvz.spv.MerklePath{try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, z.fund.txid))};
    var e1 = [_]c.beef.Entry{
        .{ .txid = z.fund.txid, .format = .raw_with_bump, .bump = 0, .raw = z.fund.raw, .tx = z.fund.tx },
        .{ .txid = z.p.txid, .format = .raw, .raw = z.p.raw, .tx = z.p.tx },
        .{ .txid = z.x.txid, .format = .raw, .raw = z.x.raw, .tx = z.x.tx },
    };
    _ = try st.ingest(try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = z.x.txid, .bumps = &bumps, .entries = &e1 }));
    var ix = Index{ .latest = std.StringHashMap(Value).init(a) };
    for (try shape.statusEvents(a, &st, "chain", z.x.txid)) |f| try ix.latest.put(f.getText("event").?, f);
    try std.testing.expectEqualStrings("pending", ix.latest.get(try shape.txName(a, "chain", z.x.txid)).?.getText("status").?);
    const s1 = try st.save();

    // The broadcaster's proof of P: its path covers X.
    var st2 = try c.state.State.load(a, ms.store(), s1, .regtest);
    _ = try st2.applyStatus(z.p.txid, "MINED", try pairBytes(a, 2, z.p.txid, z.x.txid));
    const proofs = try shape.proofEvents(a, &st2, "chain");
    try std.testing.expect(factFor(proofs, "chain/proof/", z.x.txid) != null);
    const step_facts = try shape.statusEvents(a, &st2, "chain", null);
    try expectFact(factFor(step_facts, "chain/tx/", z.p.txid).?, z.p.txid, "mined", 2);
    try std.testing.expect(factFor(step_facts, "chain/tx/", z.x.txid) == null); // X's comes by its subscription
    for (step_facts) |f| try ix.latest.put(f.getText("event").?, f);
    const s2 = try st2.save();

    // X's `proof` subscription step.
    var st3 = try c.state.State.load(a, ms.store(), s2, .regtest);
    const pf = try shape.provenFacts(a, &st3, "chain", z.x.txid, ix.reader());
    try std.testing.expectEqual(@as(usize, 1), pf.len);
    try expectFact(pf[0], z.x.txid, "mined", 2);
    try std.testing.expect((try st3.broadcastRecord(z.x.txid)) == null);
    try ix.latest.put(pf[0].getText("event").?, pf[0]);
    // Woken again (the same linkage): nothing new.
    try std.testing.expectEqual(@as(usize, 0), (try shape.provenFacts(a, &st3, "chain", z.x.txid, ix.reader())).len);
    // Its output follows from that fact: P.0 spent by X.
    var out_ix = Index{ .latest = std.StringHashMap(Value).init(a) };
    try out_ix.deliver(a, &st3, pf);
    try expectOutput(try out_ix.state(a, z.p.txid, 0), "spent", z.x.txid);
}

test "0.11.0 held rejected, then a path covering it: the subscription step raises mined (a proof overrides a rejection)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    var st = try c.state.State.load(a, ms.store(), null, .regtest);
    const z = try liveWorld(a, &st);
    var bumps = [_]c.bsvz.spv.MerklePath{try c.bsvz.spv.MerklePath.parse(a, try soloPath(a, 1, z.fund.txid))};
    var e1 = [_]c.beef.Entry{
        .{ .txid = z.fund.txid, .format = .raw_with_bump, .bump = 0, .raw = z.fund.raw, .tx = z.fund.tx },
        .{ .txid = z.p.txid, .format = .raw, .raw = z.p.raw, .tx = z.p.tx },
        .{ .txid = z.x.txid, .format = .raw, .raw = z.x.raw, .tx = z.x.tx },
    };
    _ = try st.ingest(try c.beef.serialize(a, .{ .version = c.beef.V2, .atomic = z.x.txid, .bumps = &bumps, .entries = &e1 }));
    _ = try st.applyStatus(z.x.txid, "REJECTED", null);
    var ix = Index{ .latest = std.StringHashMap(Value).init(a) };
    try ix.latest.put(try shape.txName(a, "chain", z.x.txid), try shape.statusNow(a, &st, "chain", z.x.txid));
    const s1 = try st.save();

    var st2 = try c.state.State.load(a, ms.store(), s1, .regtest);
    _ = try st2.applyStatus(z.p.txid, "MINED", try pairBytes(a, 2, z.p.txid, z.x.txid));
    const s2 = try st2.save();
    var st3 = try c.state.State.load(a, ms.store(), s2, .regtest);
    const pf = try shape.provenFacts(a, &st3, "chain", z.x.txid, ix.reader());
    try std.testing.expectEqual(@as(usize, 1), pf.len);
    try expectFact(pf[0], z.x.txid, "mined", 2);
}
