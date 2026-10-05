//! The chain app's pure parts (src/shape.zig), natively: its configuration,
//! its functions, and the shapes of its answers over a chain state in memory.
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
