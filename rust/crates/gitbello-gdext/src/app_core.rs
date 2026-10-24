use godot::prelude::*;

/// Root of the native runtime, instanced once by the `Core` autoload
/// (`res://app/core/core.tscn`).
///
/// M0 only proves the boundary: a call from GDScript into Rust and a signal back.
/// The event-channel drain (PLAN §3.5) arrives with the job scheduler in M2.
#[derive(GodotClass)]
#[class(base = Node)]
pub struct AppCore {
    base: Base<Node>,
}

// Hand-written instead of `#[class(init)]`: clippy 1.99 flags the generated
// initializer with `redundant_field_names`.
#[godot_api]
impl INode for AppCore {
    fn init(base: Base<Node>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl AppCore {
    /// Emitted in response to `ping`.
    #[signal]
    fn pong(message: GString);

    /// Version of `gitbello-core`.
    #[func]
    fn core_version(&self) -> GString {
        gitbello_core::VERSION.into()
    }

    /// Asks the core for a greeting and emits it through `pong`.
    #[func]
    fn ping(&mut self, name: GString) {
        let message = gitbello_core::greeting(&name.to_string());
        self.signals().pong().emit(&GString::from(message.as_str()));
    }
}
