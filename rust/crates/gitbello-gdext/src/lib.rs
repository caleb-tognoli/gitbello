//! Godot bindings for gitbello. Type conversion and forwarding only; all logic
//! belongs in `gitbello-core`.

mod app_core;

// gdext requires an `unsafe impl` for the extension entry point. It lives in its
// own module so the `unsafe_code` allowance stays this narrow.
#[allow(unsafe_code)]
mod entry {
    use godot::prelude::*;

    struct GitbelloExtension;

    #[gdextension]
    unsafe impl ExtensionLibrary for GitbelloExtension {}
}
