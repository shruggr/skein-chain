//! The chain app's pure parts (src/shape.zig), natively: its configuration,
//! its functions, and the shapes of its answers over a chain state in memory
//! (a reorg: the same watcher answered `proven` again, with the new block).
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

// ------------------------------------------------------------ a reorg: another proof, the same watcher

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

test "a reorg: proven, reorged out, proven in another block — the same watcher answered `proven` twice, each with its block (#2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ms = c.store.MemStore.init(std.testing.allocator);
    defer ms.deinit();
    const State = c.state.State;

    // Height 1 holds the funding; the child comes in unproven over it, a caller watching.
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
    const caller: [33]u8 = .{0x02} ++ .{0x44} ** 32;
    const request: [36]u8 = .{ 0x01, 0x71, 0x12, 0x20 } ++ .{0x55} ** 32;
    _ = try st.ingest(beef);
    try st.watch(child.txid, &caller, "chain", &request);

    // Proven at height 2.
    const h2 = mine(c.header.hash(&h1), child.txid, 1_700_001_200);
    _ = try st.addHeaders(&.{&h2});
    try std.testing.expectEqual(State.Outcome.proven, try st.applyStatus(child.txid, "MINED", try soloPath(a, 2, child.txid)));
    const first = try shape.changeAnswers(a, &st, null);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    const proven = try st.save();

    // A heavier branch without it: unproven again, its broadcast registered again (to be broadcast).
    var st2 = try State.load(a, ms.store(), proven, .regtest);
    const alt2 = mine(c.header.hash(&h1), .{3} ** 32, 1_700_001_201);
    const alt3 = mine(c.header.hash(&alt2), .{4} ** 32, 1_700_001_202);
    _ = try st2.addHeaders(&.{ &alt2, &alt3 });
    try std.testing.expectEqual(@as(usize, 1), st2.reverted.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try shape.changeAnswers(a, &st2, null)).len);
    const reverted = try st2.save();

    // Proven again at height 4, another block.
    var st3 = try State.load(a, ms.store(), reverted, .regtest);
    const alt4 = mine(c.header.hash(&alt3), child.txid, 1_700_001_203);
    _ = try st3.addHeaders(&.{&alt4});
    try std.testing.expectEqual(State.Outcome.proven, try st3.applyStatus(child.txid, "MINED", try soloPath(a, 4, child.txid)));
    const second = try shape.changeAnswers(a, &st3, null);
    try std.testing.expectEqual(@as(usize, 1), second.len);

    // Two `proven` answers to the same watcher, to the same request, each naming its own block.
    for ([_]shape.Answer{ first[0], second[0] }) |x| {
        try std.testing.expectEqualSlices(u8, &caller, x.to);
        try std.testing.expectEqualStrings("chain", x.box);
        try std.testing.expectEqualSlices(u8, &request, x.body.getCid("replyTo").?);
        try std.testing.expectEqualStrings("proven", x.body.get("result").?.getText("state").?);
    }
    const r1 = first[0].body.get("result").?;
    const r2 = second[0].body.get("result").?;
    try std.testing.expectEqualSlices(u8, &c.store.hashCid(.block, c.header.hash(&h2)), r1.getCid("block").?);
    try std.testing.expectEqualSlices(u8, &c.store.hashCid(.block, c.header.hash(&alt4)), r2.getCid("block").?);
    try std.testing.expectEqual(@as(u64, 2), r1.getUint("height").?);
    try std.testing.expectEqual(@as(u64, 4), r2.getUint("height").?);
}
