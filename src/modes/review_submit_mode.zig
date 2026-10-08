const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("../app.zig").App;
const comment_editor = @import("../comments/editor.zig");
const review_controller = @import("../pr/review_controller.zig");

/// Handle keyboard input in the submit-review dialog (FR-6/FR-7). Tab cycles the
/// verdict, Ctrl-D runs the two-step discard confirm, and the embedded vim editor
/// owns the body: Ctrl-S submits, Enter / Shift-Enter / Ctrl-J inserts a newline,
/// Esc from vim-normal closes the dialog (preserving the body for reopen).
pub fn handleKey(app: *App, key: vaxis.Key) !void {
    const review = &app.state.review;
    if (app.state.review_submit_editor == null) {
        app.mode = .normal;
        return;
    }
    const editor_state = &app.state.review_submit_editor.?;

    // While a submit is in flight, startSubmit has already captured the verdict +
    // body for the request. Ignore verdict-cycle and editor-mutation keys so the
    // dialog can't display a verdict/body that contradicts what's being submitted;
    // only Esc (close the dialog) stays live.
    if (review.submit.submitting) {
        if (key.codepoint == vaxis.Key.escape and editor_state.vim_mode == .normal) {
            app.closeReviewSubmit();
        }
        return;
    }

    // Tab / Shift-Tab cycle the verdict (before the editor, so Tab never inserts).
    if (key.codepoint == vaxis.Key.tab and !key.mods.shift) {
        review_controller.cycleVerdict(review, app.allocator, true);
        review_controller.disarmDiscardConfirm(review);
        app.needs_render = true;
        return;
    }
    if (key.codepoint == vaxis.Key.tab and key.mods.shift) {
        review_controller.cycleVerdict(review, app.allocator, false);
        review_controller.disarmDiscardConfirm(review);
        app.needs_render = true;
        return;
    }

    // Ctrl-D: two-step discard confirmation (AD-8 draft safety for a destructive op).
    if (key.mods.ctrl and key.codepoint == 'd') {
        if (review_controller.discardArmed(review)) {
            app.discardReviewNow();
        } else {
            review_controller.armDiscardConfirm(review);
            app.showStatusMessage("press ^D again to discard the pending review");
            app.needs_render = true;
        }
        return;
    }

    // Any other key disarms a pending discard confirmation.
    if (review_controller.discardArmed(review)) review_controller.disarmDiscardConfirm(review);

    // Esc from vim-normal closes the dialog; Esc from insert falls through to the
    // editor (leaves insert mode), matching vim muscle memory.
    if (key.codepoint == vaxis.Key.escape and editor_state.vim_mode == .normal) {
        app.closeReviewSubmit();
        return;
    }

    // A review body is multi-line prose, so plain Enter never submits here (^S
    // does): it inserts a newline while typing and is a no-op in vim-normal. The
    // shared editor treats Enter as save, and Shift-Enter only reaches us on
    // terminals with the kitty keyboard protocol, so rewrite it to Ctrl-J.
    var editor_key = key;
    if (key.matches(vaxis.Key.enter, .{})) {
        switch (editor_state.vim_mode) {
            .insert => editor_key = .{ .codepoint = 'j', .mods = .{ .ctrl = true } },
            .normal => return,
            .visual, .command => {},
        }
    }

    const action = try comment_editor.CommentEditor.VimEditor.handleKey(editor_state, editor_key, app.allocator);
    if (action) |act| {
        switch (act) {
            .save => app.submitReviewNow(),
            .cancel => app.closeReviewSubmit(),
        }
    } else {
        app.needs_render = true;
    }
}
