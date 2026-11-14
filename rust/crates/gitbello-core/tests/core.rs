//! The core's integration tests, in one binary: every file here is a
//! module, so they link once and run in parallel. Run one file's tests
//! with `cargo test -p gitbello-core --test core <file>::`.

mod support;

mod add_repository;
mod avatars;
mod backend;
mod blame;
mod branch_delete;
mod branches;
mod busy;
mod changes;
mod commit_details;
mod compare;
mod content_merge;
mod diff_layout;
mod diff_retry;
mod file_history;
mod git_runner;
mod graph_load;
mod graph_search;
mod highlight;
mod history;
mod ignore;
mod ignore_rules;
mod image_diffs;
mod jobs;
mod library;
mod line_endings;
mod line_staging;
mod line_states;
mod merge;
mod minimap;
mod moves;
mod open_version;
mod remotes;
mod runtime;
mod selection;
mod shelf_files;
mod shelves;
mod sync;
mod syntax_detection;
mod watch;
mod worktrees;
