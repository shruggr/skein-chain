// skein-chain (shruggr/skein#78): the chain module, a skein app — the one
// writer of an instance's chain state (headers, transactions, proofs,
// spends, settlement, broadcasts). Zig 0.16.0, wasm32-wasi, over the SDK's
// chain library (skein-sdk `chain`, a URL+hash dependency; bsvz comes
// through it, lazily).
//
//   zig build         → zig-out/bin/chain.wasm
//   zig build bin     the same, written to bin/chain.wasm (the app tree's module; committed)
//   zig build test    the app's pure parts (src/shape.zig), natively (the chain state's own tests are
//                     the SDK's: skein-sdk chain/test.zig; the flow through a kernel is skein's
//                     kernel-zig/equiv/chain.ts)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const chain = b.dependency("skein_sdk", .{ .target = wasi, .optimize = .ReleaseSafe }).module("chain");
    const exe = b.addExecutable(.{
        .name = "chain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasi,
            .optimize = .ReleaseSafe,
            .strip = true,
            .imports = &.{.{ .name = "chain", .module = chain }},
        }),
    });
    b.installArtifact(exe);
    const bin = b.addUpdateSourceFiles();
    bin.addCopyFileToSource(exe.getEmittedBin(), "bin/chain.wasm");
    b.step("bin", "write the module into the app tree: bin/chain.wasm").dependOn(&bin.step);

    const target = b.standardTargetOptions(.{});
    const native = b.dependency("skein_sdk", .{ .target = target, .optimize = .Debug }).module("chain");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "chain", .module = native }},
    }) });
    b.step("test", "the app's pure parts, natively").dependOn(&b.addRunArtifact(tests).step);
}
