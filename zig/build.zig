const std = @import("std");

// Build the ponytail Zig binaries from one source tree, parameterized by -Dtool.
// Mirrors the real rewrite: one Zig codebase, comptime-selected tool identity.
//
//   <tool>-hook          — UserPromptSubmit       (src/main.zig)
//   <tool>-activate      — SessionStart           (src/activate.zig)
//   <tool>-statusline    — statusline badge       (src/statusline.zig)
//   <tool>-mcp           — stdio MCP server       (src/mcp.zig)
//   <tool>-instructions  — one-shot ruleset print (src/instructions.zig)
//                          (exec target for the opencode/pi ESM/JS shims)
//   <tool>-subagent      — SubagentStart          (src/subagent.zig)
//                          (#254: inject ruleset into Task-spawned subagents)
//   <tool>-openclaw      — OpenClaw skill gen      (src/openclaw.zig)
//                          (emits .openclaw/skills/*/SKILL.md; replaces the JS)
//   <tool>-pz            — pz skill adapter        (src/pz.zig)
//                          (emits .pz/skills/<tool>/SKILL.md; pure-Zig, no shim)
//   <tool>-config        — config CLI verb         (src/config.zig)
//                          (get-default/set-default/write-mode; Option B)
//
// All of these binaries share src/common.zig (mode whitelist, config resolution,
// the symlink-safe flag write, path resolution).
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

    // ── <tool>-instructions (one-shot ruleset print, src/instructions.zig) ────
    // Exec target for the host-mandated opencode/pi ESM/JS shims. Takes the mode
    // as argv[1] (or resolves the default), prints common.getInstructions over
    // the embedded SKILL.md to stdout, nothing else. Embeds the same `skill_md`
    // anonymous import as activate / mcp.
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-instructions", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/instructions.zig"),
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
                .root_source_file = b.path("src/instructions.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-config (config CLI verb, src/config.zig) ──────────────────────
    // Option B: out-of-process get-default / set-default / write-mode so the
    // host-mandated pi/opencode JS config+fs-safe modules collapse to thin exec
    // wrappers. ponytail: env-var driven (no argv) is an intentional simplification
    // — this toolchain dropped std.os.argv; ceiling is env-size/visibility, upgrade
    // path is argv once it's restored (see src/config.zig header). Reuses common.
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-config", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/config.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/config.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-openclaw (OpenClaw skill generator, src/openclaw.zig) ──────────
    // Dev/CI verb: emits .openclaw/skills/<name>/SKILL.md from skills/<name>/.
    // Reads the canonical SKILL.md sources at runtime (no skill_md embed) and
    // writes through common.safeWriteFlag. Replaces scripts/build-openclaw-skills.js.
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-openclaw", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/openclaw.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addOptions("build_options", opts);
        exe.root_module.link_libc = true;
        b.installArtifact(exe);

        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/openclaw.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-pz (pz skill adapter, src/pz.zig) ─────────────────────────────
    // §3.1 pure-Zig pz adapter (no host shim — pz scans skill files). Emits
    // <root>/.pz/skills/<tool>/SKILL.md (+ ~/.pz/skills/<tool>/) with pz
    // frontmatter (name/description/user_invocable) and the mode-filtered body.
    // Embeds the same `skill_md` import as activate / instructions / subagent.
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-pz", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/pz.zig"),
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
                .root_source_file = b.path("src/pz.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        tests.root_module.addOptions("build_options", opts);
        tests.root_module.addAnonymousImport("skill_md", .{ .root_source_file = b.path(skill_md_path) });
        tests.root_module.link_libc = true;
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ── <tool>-subagent (SubagentStart, src/subagent.zig) ──
    // #254: inject the active ruleset into Task-spawned subagents (SessionStart
    // context never reaches them, issue #252). Embeds the same `skill_md` import
    // as activate / instructions; the SubagentStart output is the
    // {"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":…}}
    // envelope built in common.buildHookOutputFor (the SubagentStart branch).
    {
        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-subagent", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/subagent.zig"),
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
                .root_source_file = b.path("src/subagent.zig"),
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
