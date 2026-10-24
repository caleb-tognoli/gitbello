//! The one core `Runtime`, owned by the main thread.
//!
//! It lives here rather than inside the `AppCore` node so that `AppCore` and
//! `RepoSession` can both reach it without binding each other. Borrows are
//! short and never span a call back into Godot (signal emission happens
//! after the borrow ends), so re-entrant GDScript calls are safe.

use std::cell::RefCell;

use gitbello_core::runtime::Runtime;

thread_local! {
    static RUNTIME: RefCell<Option<Runtime>> = const { RefCell::new(None) };
}

pub fn install(runtime: Runtime) {
    RUNTIME.with(|cell| *cell.borrow_mut() = Some(runtime));
}

pub fn uninstall() {
    // Take it out first so the runtime drops (joining threads) outside the borrow.
    let runtime = RUNTIME.with(|cell| cell.borrow_mut().take());
    drop(runtime);
}

/// Runs `f` with the runtime. `None` when it is not started or (by mistake)
/// already borrowed further up the stack.
pub fn with<R>(f: impl FnOnce(&mut Runtime) -> R) -> Option<R> {
    RUNTIME.with(|cell| {
        let mut guard = cell.try_borrow_mut().ok()?;
        guard.as_mut().map(f)
    })
}
