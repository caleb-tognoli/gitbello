//! Access to the system `git` executable. Every git process is spawned by [`GitRunner`].

mod cancel;
mod error;
mod log;
mod progress;
mod runner;
mod version;

pub use cancel::CancelToken;
pub use error::{GitError, GitErrorKind};
pub use log::{CommandLog, CommandOutcome, CommandRecord};
pub use progress::{LineSplitter, Progress};
pub use runner::{Access, GitCommand, GitOutput, GitRunner, GitStream};
pub use version::{GitVersion, MIN_GIT_VERSION};
