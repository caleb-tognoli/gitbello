//! Access to the system `git` executable. Every git process is spawned by [`GitRunner`].

mod error;
mod runner;
mod version;

pub use error::{GitError, GitErrorKind};
pub use runner::{Access, GitCommand, GitOutput, GitRunner, GitStream};
pub use version::{GitVersion, MIN_GIT_VERSION};
