const std = @import("std");

// Build the three hook binaries from one source tree, parameterized by -Dtool.
// Mirrors the real rewrite: one Zig codebase, comptime-selected tool identity.
//
//   <tool>-hook        — UserPromptSubmit  (src/main.zig)
//   <tool>-activate    — SessionStart      (src/activate.zig)
//   <tool>-statusline  — statusline badge  (src/statusline.zig)
//   <tool>-mcp         — stdio MCP server  (src/mcp.zig)
//
// All three share src/common.zig (mode whitelist, config resolution, the
// symlink-safe flag write, path resolution).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Default to this repo's identity. The shared codebase still builds the
    // caveman variant via -Dtool=caveman, but only when run inside the caveman
    // repo where ../skills/caveman/SKILL.md exists for the activate embed.
    const tool = b.option([]const u8, "tool", "caveman | ponytail") orelse "ponytail";

    // Reject typos at configure time — an unknown -Dtool would silently build a
    // binary with a broken command prefix and flag filename.
    if (!std.mem.eql(u8, tool, "caveman") and !std.mem.eql(u8, tool, "ponytail")) {
        std.debug.print("error: -Dtool must be 'caveman' or 'ponytail', got '{s}'\n", .{tool});
        std.process.exit(1);
    }

    const opts = b.addOptions();
    opts.addOption([]const u8, "tool", tool);

    // The SessionStart binary embeds the tool's SKILL.md at comptime so it can
    // emit the (mode-filtered) ruleset without a runtime file dependency. Path
    // is relative to the repo root (parent of zig/).
    const skill_md_path = b.fmt("../skills/{s}/SKILL.md", .{tool});

    const test_step = b.step("test", "Run unit tests");
    const run_step = b.step("run", "Run the hook (UserPromptSubmit)");

    // ── shared module test (src/common.zig) ──────────────────────────────────
    {
        const common_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/common.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        common_tests.root_module.addOptions("build_options", opts);
        common_tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(common_tests).step);
    }

    // ── <tool>-hook (UserPromptSubmit, src/main.zig) ─────────────────────────
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-hook", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        run_step.dependOn(&run.step);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-activate (SessionStart, src/activate.zig) ─────────────────────
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-activate", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/activate.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/activate.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-statusline (statusline badge, src/statusline.zig) ─────────────
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-statusline", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/statusline.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/statusline.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-mcp (stdio MCP server, src/mcp.zig) ───────────────────────────
    // Hand-rolled JSON-RPC MCP server. Embeds the SKILL.md (same `skill_md`
    // anonymous import as activate) so tools/call and prompts/get can serve the
    // mode-filtered ruleset via common.getInstructions.
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-mcp", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mcp.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mcp.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
