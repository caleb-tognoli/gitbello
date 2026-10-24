//! Godot bindings for gitbello. Type conversion and forwarding only; all logic
//! belongs in `gitbello-core`.

mod app_core;
mod convert;
mod repo_session;
mod runtime_cell;

// gdext requires an `unsafe impl` for the extension entry point. It lives in its
// own module so the `unsafe_code` allowance stays this narrow.
#[allow(unsafe_code)]
mod entry {
    use godot::prelude::*;

    struct GitbelloExtension;

    #[gdextension]
    unsafe impl ExtensionLibrary for GitbelloExtension {}
}
