//! The merge dialog (`pr_merge` mode): opening it on the PR under review, its
//! keys, and landing the merge worker's results. The logic is
//! `pr/merge_controller.zig`'s; this file hands it the review session's facts
//! and turns outcomes into status messages.

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const merge_controller = @import("../pr/merge_controller.zig");
const review_controller = @import("../pr/review_controller.zig");
const pr_surface = if (@import("../platform.zig").is_web) @import("../pr/surface_stub.zig") else @import("../pr/surface.zig");

const Key = vaxis.Key;

/// `gm` / the palette's Merge PR.
pub fn open(app: *App) void {
    app.needs_render = true;
    const review = &app.state.review;
    if (!review_controller.isActive(review)) return app.showStatusMessage("no active PR review session");
    const result = merge_controller.open(&app.state.merge, app.allocator, .{
        .number = review.number,
        .generation = review.generation,
        .head_oid = review.head_ref_oid,
        .owner_repo = review.owner_repo,
        .stacked_on = stackedOn(app),
    }) catch return app.showStatusError("couldn't start the merge status fetch");
    switch (result) {
        .started => app.mode = .pr_merge,
        .not_loaded => app.showStatusMessage("PR still loading — try again in a moment"),
        .busy => app.showStatusMessage("a merge is still running"),
    }
}

pub fn close(app: *App) void {
    merge_controller.close(&app.state.merge);
    app.mode = .normal;
    app.needs_render = true;
}

pub fn handleKey(app: *App, key: Key) !void {
    app.needs_render = true;
    const merge = &app.state.merge;
    if (key.codepoint == Key.escape or (key.codepoint == 'q' and !key.mods.ctrl)) return close(app);
    if (key.codepoint == Key.tab) {
        if (!merge.merging) merge_controller.cycleMethod(merge, !key.mods.shift);
        return;
    }
    if (key.matches(Key.enter, .{})) {
        const result = try merge_controller.confirm(merge, app.allocator, app.state.review.pr_node_id);
        switch (result) {
            .started => app.showStatusMessage("merging…"),
            .not_ready, .busy => {},
        }
    }
}

/// Land a finished merge-status fetch or merge.
pub fn poll(app: *App) void {
    const merge = &app.state.merge;
    const outcome = merge_controller.poll(merge, app.allocator, app.state.review.generation);
    switch (outcome) {
        .none => return,
        .info_loaded, .info_failed => {},
        .merged, .auto_merge_enabled => {
            if (app.mode == .pr_merge and !merge.open) app.mode = .normal;
            // The sidebar drops a merged PR on its next sync; ask for it now.
            pr_surface.requestSync(&app.state.pr_surface);
            if (review_controller.isActive(&app.state.review)) app.startReviewRefetch();
            var buf: [96]u8 = undefined;
            app.showStatusMessage(switch (outcome) {
                .merged => |m| std.fmt.bufPrint(&buf, "merged #{d} ({s})", .{ m.number, merge_controller.methodLabel(m.method) }) catch "merged",
                .auto_merge_enabled => |number| std.fmt.bufPrint(&buf, "auto-merge enabled for #{d}", .{number}) catch "auto-merge enabled",
                else => unreachable,
            });
        },
        .merge_failed => app.showStatusError(if (app.mode == .pr_merge) "merge failed — see dialog" else "merge failed"),
    }
    app.needs_render = true;
}

/// The open PR whose head branch is this PR's base: merging lands this one
/// there, not on trunk.
fn stackedOn(app: *const App) ?u32 {
    const review = &app.state.review;
    const records = app.state.sidebar.records orelse return null;
    for (records.items) |record| {
        if (record.state != .open or record.number == review.number) continue;
        if (std.mem.eql(u8, record.head_ref, review.base_ref)) return record.number;
    }
    return null;
}
