//! Controller for merging the PR under review (`gm` / the palette's Merge PR).
//! Owns `MergeState` and all logic over it as free functions (App Struct
//! Boundaries pattern).
//!
//! Opening the dialog fetches the PR's merge state fresh: `mergeable` and
//! `mergeStateStatus` are computed lazily by GitHub and go stale fast, so the
//! review payload's copy is not trusted for this. The merge itself is pinned
//! to the head commit the user reviewed (`expectedHeadOid`), so a push that
//! lands after the diff was loaded makes GitHub refuse rather than merge
//! unseen code.
//!
//! Async idiom (AD-3, as in `review_controller`): one detached worker at a
//! time allocates with `c_allocator`, publishes under `mutex`, then sets
//! `ready`; `poll` joins it on the main loop and consumes the result.

const std = @import("std");
const Allocator = std.mem.Allocator;

const github = @import("github.zig");
const review_parse = @import("review_parse.zig");
const skim_io = @import("skim_io");

const MergeInfo = review_parse.MergeInfo;
pub const MergeMethod = review_parse.MergeMethod;

pub const Level = enum { ok, warn, block };

/// One row of the dialog's readiness checklist. `text` is static.
pub const Line = struct { level: Level, text: []const u8 };

pub const max_lines = 8;

/// What confirming does: merge now, or let GitHub merge once requirements pass.
pub const Action = enum { merge, auto_merge };

pub const OpenParams = struct {
    number: u32,
    /// The review session's generation: results for any other are dropped.
    generation: u64,
    /// The head commit the user reviewed; the merge is pinned to it.
    head_oid: []const u8,
    /// Borrowed; null makes the worker resolve it from `origin`.
    owner_repo: ?github.OwnerRepo,
    /// The open PR whose head branch is this PR's base, if any.
    stacked_on: ?u32 = null,
};

pub const OpenAction = enum { started, not_loaded, busy };

pub const ConfirmAction = enum { started, not_ready, busy };

pub const Outcome = union(enum) {
    none,
    info_loaded,
    info_failed,
    merged: struct { number: u32, method: MergeMethod },
    auto_merge_enabled: u32,
    merge_failed,
};

const Request = enum { info, merge, auto_merge };

/// Thread-safe handoff of the one in-flight request. Inputs are set before
/// spawn; outputs are written under `mutex`, then `ready` is set. Buffers are
/// `c_allocator`-owned so they survive the thread boundary.
const Pending = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    request: Request = .info,
    number: u32 = 0,
    generation: u64 = 0,
    method: MergeMethod = .squash,
    in_owner_repo: ?github.OwnerRepo = null,
    in_pr_node_id: []u8 = &.{},
    in_head_oid: []u8 = &.{},

    out_info: ?MergeInfo = null,
    out_error_msg: ?[]u8 = null,
    failed: bool = false,
    fail_kind: github.GhErrorKind = .other,
};

pub const MergeState = struct {
    /// The dialog is on screen. Results still land after it closes.
    open: bool = false,
    number: u32 = 0,
    generation: u64 = 0,
    reviewed_oid_buf: [64]u8 = undefined,
    reviewed_oid_len: usize = 0,
    stacked_on: ?u32 = null,
    /// Allocator-owned copies, for the worker re-spawned by `poll`.
    owner_repo: ?github.OwnerRepo = null,

    info: ?MergeInfo = null,
    method: MergeMethod = .squash,
    loading: bool = false,
    merging: bool = false,
    /// Allocator-owned; the last failure, shown in the dialog.
    error_msg: ?[]u8 = null,

    pending: Pending = .{},
    thread: ?std.Thread = null,
    in_flight: bool = false,

    // Executables the worker spawns; tests point them at fakes.
    gh_bin: []const u8 = "gh",
    git_bin: []const u8 = "git",
};

/// Show the dialog for PR `params.number` and fetch its merge state. Refuses
/// when the review payload has not landed, since there is no head to pin to,
/// and while a merge is still running.
pub fn open(state: *MergeState, allocator: Allocator, params: OpenParams) !OpenAction {
    if (state.merging) return .busy;
    if (params.head_oid.len == 0 or params.head_oid.len > state.reviewed_oid_buf.len) return .not_loaded;
    clearError(state, allocator);
    freeOwnerRepo(state, allocator);
    if (params.owner_repo) |owner_repo| {
        const owner = try allocator.dupe(u8, owner_repo.owner);
        errdefer allocator.free(owner);
        state.owner_repo = .{ .owner = owner, .repo = try allocator.dupe(u8, owner_repo.repo) };
    }
    state.open = true;
    state.number = params.number;
    state.generation = params.generation;
    state.stacked_on = params.stacked_on;
    state.reviewed_oid_len = params.head_oid.len;
    @memcpy(state.reviewed_oid_buf[0..params.head_oid.len], params.head_oid);
    state.info = null;
    state.loading = true;
    // A worker still running for an earlier open is dropped by `poll`, which
    // then starts this fetch.
    if (!state.in_flight) try spawnInfo(state);
    return .started;
}

pub fn close(state: *MergeState) void {
    state.open = false;
}

/// Tab / Shift-Tab: step through the methods the repo allows.
pub fn cycleMethod(state: *MergeState, forward: bool) void {
    const info = state.info orelse return;
    var buf: [3]MergeMethod = undefined;
    const methods = allowedMethods(info, &buf);
    if (methods.len == 0) return;
    const current = std.mem.indexOfScalar(MergeMethod, methods, state.method) orelse 0;
    const next = if (forward) (current + 1) % methods.len else (current + methods.len - 1) % methods.len;
    state.method = methods[next];
}

/// Enter: merge (or enable auto-merge) with the selected method.
pub fn confirm(state: *MergeState, allocator: Allocator, pr_node_id: []const u8) !ConfirmAction {
    if (state.in_flight) return .busy;
    const info = state.info orelse return .not_ready;
    const chosen = action(info, reviewedOid(state)) orelse return .not_ready;
    clearError(state, allocator);
    try spawnMerge(state, .{ .pr_node_id = pr_node_id, .auto = chosen == .auto_merge });
    state.merging = true;
    return .started;
}

/// Consume a finished request, if any. `generation` is the review session's
/// current one: an info result for an older PR is dropped, but a merge is
/// always reported, since it happened whichever PR is on screen now.
pub fn poll(state: *MergeState, allocator: Allocator, generation: u64) Outcome {
    if (!state.pending.ready.load(.acquire)) return .none;

    const pending = &state.pending;
    pending.mutex.lockUncancelable(skim_io.get());
    const out_info = pending.out_info;
    const out_error_msg = pending.out_error_msg;
    pending.out_info = null;
    pending.out_error_msg = null;
    pending.mutex.unlock(skim_io.get());
    pending.ready.store(false, .release);

    if (state.thread) |t| {
        t.join();
        state.thread = null;
    }
    state.in_flight = false;
    freeWorkerInputs(state);
    defer if (out_error_msg) |m| std.heap.c_allocator.free(m);

    const current = pending.number == state.number and pending.generation == state.generation and state.generation == generation;
    switch (pending.request) {
        .info => {
            if (!current) {
                if (state.loading and state.generation == generation) spawnInfo(state) catch {
                    state.loading = false;
                    setError(state, allocator, "couldn't start the merge status fetch");
                };
                return .none;
            }
            state.loading = false;
            if (pending.failed) {
                setError(state, allocator, out_error_msg orelse infoFailureMessage(pending.fail_kind));
                return .info_failed;
            }
            state.info = out_info;
            if (out_info) |info| state.method = initialMethod(info);
            return .info_loaded;
        },
        .merge, .auto_merge => {
            state.merging = false;
            if (pending.failed) {
                if (current) setError(state, allocator, out_error_msg orelse mergeFailureMessage(pending.fail_kind));
                return .merge_failed;
            }
            if (current) {
                state.open = false;
                state.info = null;
            }
            if (pending.request == .auto_merge) return .{ .auto_merge_enabled = pending.number };
            return .{ .merged = .{ .number = pending.number, .method = pending.method } };
        },
    }
}

pub fn deinitState(state: *MergeState, allocator: Allocator) void {
    if (state.thread) |t| t.join();
    state.thread = null;
    state.in_flight = false;
    if (state.pending.out_error_msg) |m| std.heap.c_allocator.free(m);
    state.pending.out_error_msg = null;
    freeWorkerInputs(state);
    clearError(state, allocator);
    freeOwnerRepo(state, allocator);
}

pub fn reviewedOid(state: *const MergeState) []const u8 {
    return state.reviewed_oid_buf[0..state.reviewed_oid_len];
}

/// The dialog's readiness rows: what stops the merge first, then what it
/// would override, then what is fine.
pub fn checklist(info: MergeInfo, reviewed_oid: []const u8, out: *[max_lines]Line) []const Line {
    var n: usize = 0;
    for (blockers(info, reviewed_oid)) |blocker| {
        if (blocker) |text| {
            out[n] = .{ .level = .block, .text = text };
            n += 1;
        }
    }
    const notes = [_]?Line{
        switch (info.review_decision) {
            .approved => .{ .level = .ok, .text = "Approved" },
            .changes_requested => .{ .level = .warn, .text = "Changes requested" },
            .review_required => .{ .level = .warn, .text = "Review required" },
            .none => null,
        },
        switch (info.rollup) {
            .success => .{ .level = .ok, .text = "Checks passed" },
            .failure, .err => .{ .level = .warn, .text = "Checks failing" },
            .pending => .{ .level = .warn, .text = "Checks still running" },
            .none => null,
        },
        if (info.merge_state == .behind) .{ .level = .warn, .text = "Behind the base branch" } else null,
        if (info.merge_state == .blocked) .{ .level = .warn, .text = "Blocked by branch protection" } else null,
        if (info.mergeable == .unknown and info.state == .open) .{ .level = .warn, .text = "GitHub is still checking for conflicts" } else null,
    };
    for (notes) |note| {
        const line = note orelse continue;
        if (n == out.len) break;
        out[n] = line;
        n += 1;
    }
    return out[0..n];
}

/// What Enter does, or null when a blocker stands. Auto-merge when the repo
/// and viewer allow it and GitHub would otherwise refuse or wait: checks still
/// running, or branch protection not yet satisfied.
pub fn action(info: MergeInfo, reviewed_oid: []const u8) ?Action {
    for (blockers(info, reviewed_oid)) |blocker| {
        if (blocker != null) return null;
    }
    const waiting = info.rollup == .pending or info.merge_state == .blocked;
    if (waiting and info.auto_merge_allowed and info.viewer_can_enable_auto_merge) return .auto_merge;
    return .merge;
}

/// The methods the repo allows, in display order.
pub fn allowedMethods(info: MergeInfo, buf: *[3]MergeMethod) []const MergeMethod {
    var n: usize = 0;
    const flags = [_]struct { MergeMethod, bool }{
        .{ .squash, info.squash_allowed },
        .{ .merge, info.merge_allowed },
        .{ .rebase, info.rebase_allowed },
    };
    for (flags) |flag| {
        if (!flag[1]) continue;
        buf[n] = flag[0];
        n += 1;
    }
    return buf[0..n];
}

pub fn methodLabel(method: MergeMethod) []const u8 {
    return switch (method) {
        .squash => "Squash",
        .merge => "Merge commit",
        .rebase => "Rebase",
    };
}

// =============================================================================
// Helpers
// =============================================================================

/// Each condition that makes GitHub refuse the merge, or null when it holds.
fn blockers(info: MergeInfo, reviewed_oid: []const u8) [6]?[]const u8 {
    var buf: [3]MergeMethod = undefined;
    return .{
        switch (info.state) {
            .open => null,
            .merged => "Already merged",
            .closed => "PR is closed",
        },
        if (info.is_draft) "Draft: mark it ready for review first" else null,
        if (!std.mem.eql(u8, info.headOid(), reviewed_oid)) "New commits since you loaded it: refresh with r" else null,
        if (info.mergeable == .conflicting) "Conflicts with the base branch" else null,
        if (info.auto_merge_enabled) "Auto-merge is already enabled" else null,
        if (allowedMethods(info, &buf).len == 0) "The repo allows no merge method" else null,
    };
}

/// The viewer's default method when the repo allows it, else the first allowed.
fn initialMethod(info: MergeInfo) MergeMethod {
    var buf: [3]MergeMethod = undefined;
    const methods = allowedMethods(info, &buf);
    if (info.default_method) |method| {
        if (std.mem.indexOfScalar(MergeMethod, methods, method) != null) return method;
    }
    return if (methods.len > 0) methods[0] else .squash;
}

fn infoFailureMessage(kind: github.GhErrorKind) []const u8 {
    return if (kind == .other) "couldn't load the merge status from gh" else github.kindMessage(kind);
}

fn mergeFailureMessage(kind: github.GhErrorKind) []const u8 {
    return if (kind == .other) "gh failed to merge the PR" else github.kindMessage(kind);
}

fn setError(state: *MergeState, allocator: Allocator, message: []const u8) void {
    clearError(state, allocator);
    state.error_msg = allocator.dupe(u8, message) catch null;
}

fn clearError(state: *MergeState, allocator: Allocator) void {
    if (state.error_msg) |m| allocator.free(m);
    state.error_msg = null;
}

fn freeOwnerRepo(state: *MergeState, allocator: Allocator) void {
    const owner_repo = state.owner_repo orelse return;
    allocator.free(owner_repo.owner);
    allocator.free(owner_repo.repo);
    state.owner_repo = null;
}

fn spawnInfo(state: *MergeState) !void {
    const ca = std.heap.c_allocator;
    resetPending(state, .info);
    if (state.owner_repo) |owner_repo| {
        const owner = try ca.dupe(u8, owner_repo.owner);
        errdefer ca.free(owner);
        state.pending.in_owner_repo = .{ .owner = owner, .repo = try ca.dupe(u8, owner_repo.repo) };
    }
    try spawn(state);
}

fn spawnMerge(state: *MergeState, params: struct { pr_node_id: []const u8, auto: bool }) !void {
    const ca = std.heap.c_allocator;
    resetPending(state, if (params.auto) .auto_merge else .merge);
    state.pending.method = state.method;
    state.pending.in_pr_node_id = try ca.dupe(u8, params.pr_node_id);
    state.pending.in_head_oid = try ca.dupe(u8, reviewedOid(state));
    try spawn(state);
}

fn resetPending(state: *MergeState, request: Request) void {
    freeWorkerInputs(state);
    state.pending.request = request;
    state.pending.number = state.number;
    state.pending.generation = state.generation;
    state.pending.failed = false;
    state.pending.fail_kind = .other;
}

fn spawn(state: *MergeState) !void {
    state.thread = std.Thread.spawn(.{}, worker, .{state}) catch |err| {
        freeWorkerInputs(state);
        return err;
    };
    state.in_flight = true;
}

fn freeWorkerInputs(state: *MergeState) void {
    const ca = std.heap.c_allocator;
    if (state.pending.in_owner_repo) |owner_repo| {
        ca.free(owner_repo.owner);
        ca.free(owner_repo.repo);
    }
    state.pending.in_owner_repo = null;
    if (state.pending.in_pr_node_id.len > 0) ca.free(state.pending.in_pr_node_id);
    state.pending.in_pr_node_id = &.{};
    if (state.pending.in_head_oid.len > 0) ca.free(state.pending.in_head_oid);
    state.pending.in_head_oid = &.{};
}

fn worker(state: *MergeState) void {
    const pending = &state.pending;
    var result: WorkerResult = switch (pending.request) {
        .info => fetchInfo(state),
        .merge, .auto_merge => runMerge(state),
    };
    pending.mutex.lockUncancelable(skim_io.get());
    pending.out_info = result.info;
    pending.out_error_msg = result.error_msg;
    pending.failed = result.failed;
    pending.fail_kind = result.fail_kind;
    result.error_msg = null;
    pending.mutex.unlock(skim_io.get());
    pending.ready.store(true, .release);
}

const WorkerResult = struct {
    info: ?MergeInfo = null,
    error_msg: ?[]u8 = null,
    failed: bool = false,
    fail_kind: github.GhErrorKind = .other,
};

fn fetchInfo(state: *MergeState) WorkerResult {
    const ca = std.heap.c_allocator;
    const pending = &state.pending;
    const resolved = if (pending.in_owner_repo == null) github.getOriginOwnerRepo(ca, state.git_bin) catch {
        return .{ .failed = true, .error_msg = ca.dupe(u8, "couldn't resolve the GitHub repo from origin") catch null };
    } else null;
    defer if (resolved) |owner_repo| {
        ca.free(owner_repo.owner);
        ca.free(owner_repo.repo);
    };
    const owner_repo = pending.in_owner_repo orelse resolved.?;
    const fetch = github.fetchMergeInfo(ca, .{ .owner_repo = owner_repo, .number = pending.number, .gh_bin = state.gh_bin }) catch {
        return .{ .failed = true };
    };
    switch (fetch) {
        .failed => |kind| return .{ .failed = true, .fail_kind = kind },
        .ok => |bytes| {
            defer ca.free(bytes);
            const info = review_parse.parseMergeInfo(ca, bytes) catch return .{ .failed = true };
            return .{ .info = info };
        },
    }
}

fn runMerge(state: *MergeState) WorkerResult {
    const ca = std.heap.c_allocator;
    const pending = &state.pending;
    const fetch = github.mergePullRequest(ca, .{
        .pr_node_id = pending.in_pr_node_id,
        .method = pending.method,
        .head_oid = pending.in_head_oid,
        .auto = pending.request == .auto_merge,
        .gh_bin = state.gh_bin,
    }) catch return .{ .failed = true };
    switch (fetch) {
        .failed => |kind| return .{ .failed = true, .fail_kind = kind },
        .ok => |bytes| {
            defer ca.free(bytes);
            const message = review_parse.firstErrorMessage(ca, bytes) catch return .{ .failed = true };
            if (message) |m| return .{ .failed = true, .error_msg = m };
            return .{};
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const reviewed = "9d50cfc37de553870844565c204dd17b2476dae5";

fn readyInfo() MergeInfo {
    var info = MergeInfo{
        .state = .open,
        .mergeable = .mergeable,
        .merge_state = .clean,
        .review_decision = .approved,
        .rollup = .success,
        .squash_allowed = true,
        .merge_allowed = true,
        .rebase_allowed = true,
        .auto_merge_allowed = true,
        .viewer_can_enable_auto_merge = true,
    };
    info.head_oid_len = reviewed.len;
    @memcpy(info.head_oid_buf[0..reviewed.len], reviewed);
    return info;
}

fn hasLine(lines: []const Line, level: Level, text: []const u8) bool {
    for (lines) |line| {
        if (line.level == level and std.mem.eql(u8, line.text, text)) return true;
    }
    return false;
}

test "action: a clean, approved PR merges now" {
    try testing.expectEqual(@as(?Action, .merge), action(readyInfo(), reviewed));
}

test "action: running checks enable auto-merge instead" {
    var info = readyInfo();
    info.rollup = .pending;
    try testing.expectEqual(@as(?Action, .auto_merge), action(info, reviewed));
}

test "action: branch protection not yet met enables auto-merge" {
    var info = readyInfo();
    info.merge_state = .blocked;
    try testing.expectEqual(@as(?Action, .auto_merge), action(info, reviewed));
}

test "action: running checks merge now when the repo has auto-merge off" {
    var info = readyInfo();
    info.rollup = .pending;
    info.auto_merge_allowed = false;
    try testing.expectEqual(@as(?Action, .merge), action(info, reviewed));
}

test "action: running checks merge now when the viewer cannot enable auto-merge" {
    var info = readyInfo();
    info.rollup = .pending;
    info.viewer_can_enable_auto_merge = false;
    try testing.expectEqual(@as(?Action, .merge), action(info, reviewed));
}

test "action: refuses when the head moved past the reviewed commit" {
    try testing.expectEqual(@as(?Action, null), action(readyInfo(), "0000000"));
}

test "action: refuses a draft" {
    var info = readyInfo();
    info.is_draft = true;
    try testing.expectEqual(@as(?Action, null), action(info, reviewed));
}

test "action: refuses a conflicting PR" {
    var info = readyInfo();
    info.mergeable = .conflicting;
    try testing.expectEqual(@as(?Action, null), action(info, reviewed));
}

test "action: refuses a PR that is already merged" {
    var info = readyInfo();
    info.state = .merged;
    try testing.expectEqual(@as(?Action, null), action(info, reviewed));
}

test "action: refuses when auto-merge is already on" {
    var info = readyInfo();
    info.auto_merge_enabled = true;
    try testing.expectEqual(@as(?Action, null), action(info, reviewed));
}

test "action: refuses when the repo allows no merge method" {
    var info = readyInfo();
    info.squash_allowed = false;
    info.merge_allowed = false;
    info.rebase_allowed = false;
    try testing.expectEqual(@as(?Action, null), action(info, reviewed));
}

test "checklist: a ready PR shows approval and passing checks" {
    var buf: [max_lines]Line = undefined;
    const lines = checklist(readyInfo(), reviewed, &buf);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expect(hasLine(lines, .ok, "Approved"));
    try testing.expect(hasLine(lines, .ok, "Checks passed"));
}

test "checklist: blockers come before warnings" {
    var info = readyInfo();
    info.review_decision = .changes_requested;
    info.mergeable = .conflicting;
    var buf: [max_lines]Line = undefined;
    const lines = checklist(info, reviewed, &buf);
    try testing.expectEqual(Level.block, lines[0].level);
    try testing.expectEqualStrings("Conflicts with the base branch", lines[0].text);
    try testing.expect(hasLine(lines, .warn, "Changes requested"));
}

test "checklist: names a moved head" {
    var buf: [max_lines]Line = undefined;
    const lines = checklist(readyInfo(), "0000000", &buf);
    try testing.expect(hasLine(lines, .block, "New commits since you loaded it: refresh with r"));
}

test "checklist: every condition at once fits the buffer" {
    var info = readyInfo();
    info.state = .closed;
    info.is_draft = true;
    info.mergeable = .conflicting;
    info.auto_merge_enabled = true;
    info.squash_allowed = false;
    info.merge_allowed = false;
    info.rebase_allowed = false;
    info.review_decision = .review_required;
    info.rollup = .failure;
    info.merge_state = .behind;
    var buf: [max_lines]Line = undefined;
    const lines = checklist(info, "0000000", &buf);
    try testing.expectEqual(@as(usize, max_lines), lines.len);
    try testing.expectEqual(Level.block, lines[0].level);
}

test "allowedMethods: keeps only what the repo allows, in display order" {
    var info = readyInfo();
    info.squash_allowed = false;
    var buf: [3]MergeMethod = undefined;
    try testing.expectEqualSlices(MergeMethod, &.{ .merge, .rebase }, allowedMethods(info, &buf));
}

test "initialMethod: the viewer's default when the repo allows it" {
    var info = readyInfo();
    info.default_method = .rebase;
    try testing.expectEqual(MergeMethod.rebase, initialMethod(info));
}

test "initialMethod: the first allowed method when the default is disallowed" {
    var info = readyInfo();
    info.default_method = .merge;
    info.merge_allowed = false;
    info.squash_allowed = false;
    try testing.expectEqual(MergeMethod.rebase, initialMethod(info));
}

test "cycleMethod: wraps through the allowed methods both ways" {
    var state = MergeState{};
    var info = readyInfo();
    info.merge_allowed = false;
    state.info = info;
    state.method = .squash;

    cycleMethod(&state, true);
    try testing.expectEqual(MergeMethod.rebase, state.method);
    cycleMethod(&state, true);
    try testing.expectEqual(MergeMethod.squash, state.method);
    cycleMethod(&state, false);
    try testing.expectEqual(MergeMethod.rebase, state.method);
}

test "open: refuses before the review payload names a head commit" {
    var state = MergeState{};
    defer deinitState(&state, testing.allocator);
    const result = try open(&state, testing.allocator, .{ .number = 7, .generation = 1, .head_oid = "", .owner_repo = null });
    try testing.expectEqual(OpenAction.not_loaded, result);
    try testing.expect(!state.open);
}

test "open: refuses while a merge is still running" {
    var state = MergeState{ .merging = true };
    defer deinitState(&state, testing.allocator);
    const result = try open(&state, testing.allocator, .{ .number = 7, .generation = 1, .head_oid = reviewed, .owner_repo = null });
    try testing.expectEqual(OpenAction.busy, result);
}

test "confirm: refuses while the merge status is loading" {
    var state = MergeState{ .open = true, .loading = true };
    defer deinitState(&state, testing.allocator);
    try testing.expectEqual(ConfirmAction.not_ready, try confirm(&state, testing.allocator, "PR_1"));
}

test "confirm: refuses a blocked PR" {
    var state = MergeState{ .open = true };
    defer deinitState(&state, testing.allocator);
    var info = readyInfo();
    info.is_draft = true;
    state.info = info;
    setReviewed(&state, reviewed);
    try testing.expectEqual(ConfirmAction.not_ready, try confirm(&state, testing.allocator, "PR_1"));
    try testing.expect(!state.merging);
}

test "open + poll: loads the merge status and picks the viewer's default method" {
    var fake = try FakeGh.init(&.{.{ .name = "info.json", .bytes = merge_info_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh };
    defer deinitState(&state, testing.allocator);

    _ = try open(&state, testing.allocator, .{ .number = 42, .generation = 3, .head_oid = reviewed, .owner_repo = .{ .owner = "fake", .repo = "repo" } });
    try waitReady(&state.pending.ready);

    try testing.expectEqual(Outcome.info_loaded, poll(&state, testing.allocator, 3));
    try testing.expect(!state.loading);
    try testing.expectEqual(MergeMethod.rebase, state.method);
    try testing.expectEqualStrings(reviewed, state.info.?.headOid());
    const log = try fake.ghLog();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "owner=fake") != null);
    try testing.expect(std.mem.indexOf(u8, log, "number=42") != null);
}

test "poll: an info result for a PR the user has left is dropped" {
    var fake = try FakeGh.init(&.{.{ .name = "info.json", .bytes = merge_info_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh };
    defer deinitState(&state, testing.allocator);

    _ = try open(&state, testing.allocator, .{ .number = 42, .generation = 3, .head_oid = reviewed, .owner_repo = .{ .owner = "fake", .repo = "repo" } });
    try waitReady(&state.pending.ready);

    try testing.expectEqual(Outcome.none, poll(&state, testing.allocator, 4));
    try testing.expect(state.info == null);
}

test "confirm + poll: merges with the chosen method, pinned to the reviewed head" {
    var fake = try FakeGh.init(&.{.{ .name = "merge.json", .bytes = merge_ok_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh, .open = true, .number = 42, .generation = 3, .method = .squash };
    defer deinitState(&state, testing.allocator);
    state.info = readyInfo();
    setReviewed(&state, reviewed);

    try testing.expectEqual(ConfirmAction.started, try confirm(&state, testing.allocator, "PR_42"));
    try waitReady(&state.pending.ready);

    const outcome = poll(&state, testing.allocator, 3);
    try testing.expectEqual(@as(u32, 42), outcome.merged.number);
    try testing.expectEqual(MergeMethod.squash, outcome.merged.method);
    try testing.expect(!state.open);
    const log = try fake.ghLog();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "prId=PR_42") != null);
    try testing.expect(std.mem.indexOf(u8, log, "method=SQUASH") != null);
    try testing.expect(std.mem.indexOf(u8, log, "oid=" ++ reviewed) != null);
}

test "confirm + poll: GitHub's rejection stays in the dialog" {
    var fake = try FakeGh.init(&.{.{ .name = "merge.json", .bytes = merge_rejected_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh, .open = true, .number = 42, .generation = 3 };
    defer deinitState(&state, testing.allocator);
    state.info = readyInfo();
    setReviewed(&state, reviewed);

    _ = try confirm(&state, testing.allocator, "PR_42");
    try waitReady(&state.pending.ready);

    try testing.expectEqual(Outcome.merge_failed, poll(&state, testing.allocator, 3));
    try testing.expect(state.open);
    try testing.expect(!state.merging);
    try testing.expectEqualStrings("Head branch was modified. Review and try the merge again.", state.error_msg.?);
}

test "confirm + poll: a merge that lands after the user moved on is still reported" {
    var fake = try FakeGh.init(&.{.{ .name = "merge.json", .bytes = merge_ok_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh, .open = true, .number = 42, .generation = 3 };
    defer deinitState(&state, testing.allocator);
    state.info = readyInfo();
    setReviewed(&state, reviewed);

    _ = try confirm(&state, testing.allocator, "PR_42");
    try waitReady(&state.pending.ready);

    const outcome = poll(&state, testing.allocator, 9);
    try testing.expectEqual(@as(u32, 42), outcome.merged.number);
}

test "confirm + poll: running checks enable auto-merge" {
    var fake = try FakeGh.init(&.{.{ .name = "merge.json", .bytes = auto_merge_ok_fixture }});
    defer fake.deinit();
    var state = MergeState{ .gh_bin = fake.gh, .open = true, .number = 42, .generation = 3 };
    defer deinitState(&state, testing.allocator);
    var info = readyInfo();
    info.rollup = .pending;
    state.info = info;
    setReviewed(&state, reviewed);

    _ = try confirm(&state, testing.allocator, "PR_42");
    try waitReady(&state.pending.ready);

    try testing.expectEqual(@as(u32, 42), poll(&state, testing.allocator, 3).auto_merge_enabled);
    const log = try fake.ghLog();
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "enablePullRequestAutoMerge") != null);
}

fn setReviewed(state: *MergeState, oid: []const u8) void {
    state.reviewed_oid_len = oid.len;
    @memcpy(state.reviewed_oid_buf[0..oid.len], oid);
}

const merge_info_fixture =
    \\{"data":{"repository":{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,
    \\"autoMergeAllowed":true,"viewerDefaultMergeMethod":"REBASE","pullRequest":{"state":"OPEN","isDraft":false,
    \\"headRefOid":"9d50cfc37de553870844565c204dd17b2476dae5","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
    \\"reviewDecision":"APPROVED","viewerCanEnableAutoMerge":true,"autoMergeRequest":null,"statusCheckRollup":{"state":"SUCCESS"}}}}}
;
const merge_ok_fixture =
    \\{"data":{"mergePullRequest":{"pullRequest":{"state":"MERGED"}}}}
;
const auto_merge_ok_fixture =
    \\{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"autoMergeRequest":{"enabledAt":"2026-10-08T00:00:00Z"}}}}}
;
const merge_rejected_fixture =
    \\{"data":{"mergePullRequest":null},"errors":[{"type":"UNPROCESSABLE","path":["mergePullRequest"],"message":"Head branch was modified. Review and try the merge again."}]}
;

// Dispatches on the GraphQL operation in the query argument; anything else
// exits 1. A rejection mirrors gh: the error envelope on stdout, exit 1.
const fake_gh_script =
    \\#!/bin/sh
    \\d=$(dirname "$0")
    \\echo "$*" >> "$d/gh.log"
    \\case "$*" in
    \\  *viewerDefaultMergeMethod*) cat "$d/info.json" ;;
    \\  *mergePullRequest*|*enablePullRequestAutoMerge*)
    \\    cat "$d/merge.json"
    \\    grep -q '"errors"' "$d/merge.json" && exit 1 ;;
    \\  *) echo "unknown fake gh call" >&2; exit 1 ;;
    \\esac
    \\exit 0
    \\
;

const FakeFile = struct { name: []const u8, bytes: []const u8 };

/// A fake `gh` in a temp dir; the real worker spawns it through `gh_bin`.
const FakeGh = struct {
    tmp: testing.TmpDir,
    dir: []u8,
    gh: []u8,

    fn init(files: []const FakeFile) !FakeGh {
        const a = testing.allocator;
        const io = skim_io.get();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "gh", .data = fake_gh_script, .flags = .{ .permissions = .executable_file } });
        for (files) |file| try tmp.dir.writeFile(io, .{ .sub_path = file.name, .data = file.bytes });

        const relative = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        defer a.free(relative);
        const dir = try skim_io.absolutePathAlloc(a, relative);
        errdefer a.free(dir);
        const gh = try std.fmt.allocPrint(a, "{s}/gh", .{dir});
        return .{ .tmp = tmp, .dir = dir, .gh = gh };
    }

    fn deinit(self: *FakeGh) void {
        testing.allocator.free(self.gh);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn ghLog(self: *FakeGh) ![]u8 {
        return self.tmp.dir.readFileAlloc(skim_io.get(), "gh.log", testing.allocator, .limited(1024 * 1024));
    }
};

fn waitReady(ready: *std.atomic.Value(bool)) !void {
    var waited_ms: usize = 0;
    while (!ready.load(.acquire)) : (waited_ms += 1) {
        if (waited_ms >= 5000) return error.Timeout;
        skim_io.sleep(std.time.ns_per_ms);
    }
}
