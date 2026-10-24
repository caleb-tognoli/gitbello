use std::path::PathBuf;

use gitbello_core::git::GitRunner;
use gitbello_core::graph::{to_hex, GraphLoader, LoadState};
use godot::prelude::*;

/// One open repository or worktree tab (PLAN §3.5). M1 exposes the graph only.
///
/// Signals:
/// - `graph_changed(start, count)`: rows `start..start + count` were appended.
/// - `graph_loaded(row_count, error)`: loading ended; `error` is empty on success.
#[derive(GodotClass)]
#[class(base = Node)]
pub struct RepoSession {
    base: Base<Node>,
    path: String,
    loader: Option<GraphLoader>,
    reported_rows: usize,
}

#[godot_api]
impl INode for RepoSession {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            path: String::new(),
            loader: None,
            reported_rows: 0,
        }
    }

    fn ready(&mut self) {
        self.base_mut().set_process(false);
    }

    /// Runs only while loading: one atomic read per frame, plus a lock when done.
    fn process(&mut self, _delta: f64) {
        let Some(loader) = &self.loader else {
            self.base_mut().set_process(false);
            return;
        };
        let rows = loader.row_count();
        if rows > self.reported_rows {
            let start = self.reported_rows;
            self.reported_rows = rows;
            self.signals()
                .graph_changed()
                .emit(to_i64(start), to_i64(rows - start));
            return;
        }
        let progress = loader.progress();
        if !progress.is_finished() || progress.rows > self.reported_rows {
            // Rows published after our read get reported next frame.
            return;
        }
        let error = match &progress.state {
            LoadState::Failed(err) => err.to_string(),
            LoadState::Cancelled => "cancelled".to_owned(),
            LoadState::Loading | LoadState::Done => String::new(),
        };
        self.base_mut().set_process(false);
        self.signals()
            .graph_loaded()
            .emit(to_i64(rows), &GString::from(error.as_str()));
    }
}

#[godot_api]
impl RepoSession {
    #[signal]
    fn graph_changed(start: i64, count: i64);

    #[signal]
    fn graph_loaded(row_count: i64, error: GString);

    /// Starts loading the history of the repository at `path`. Returns an error
    /// message, or an empty string when loading started.
    #[func]
    fn open(&mut self, path: GString) -> GString {
        self.loader = None;
        self.reported_rows = 0;
        self.path = path.to_string();
        match GitRunner::discover() {
            Ok(runner) => {
                self.loader = Some(GraphLoader::start(runner, PathBuf::from(&self.path)));
                self.base_mut().set_process(true);
                GString::new()
            }
            Err(err) => GString::from(err.to_string().as_str()),
        }
    }

    #[func]
    fn repo_path(&self) -> GString {
        GString::from(self.path.as_str())
    }

    #[func]
    fn is_loading(&self) -> bool {
        self.loader
            .as_ref()
            .is_some_and(|loader| !loader.progress().is_finished())
    }

    /// Rows reported through `graph_changed` so far.
    #[func]
    fn graph_row_count(&self) -> i64 {
        to_i64(self.reported_rows)
    }

    /// Visible slice of the graph. Each row is a Dictionary with `row`, `hash`,
    /// `subject`, `author`, `email`, `time` (unix seconds), `column`, `color`,
    /// `width` (columns used) and `segments` (PackedInt32Array of
    /// `kind, from, to, color` quadruples; kind 0 = pass, 1 = in, 2 = out).
    #[func]
    fn graph_rows(&self, start: i64, count: i64) -> Array<VarDictionary> {
        let mut rows = Array::new();
        let Some(loader) = &self.loader else {
            return rows;
        };
        let start = usize::try_from(start).unwrap_or(0);
        let available = self.reported_rows.saturating_sub(start);
        let count = usize::try_from(count).unwrap_or(0).min(available);
        let index = loader.index();
        for (offset, layout) in index.layouts(start, count).iter().enumerate() {
            let row = start + offset;
            let Some(commit) = index.commit(row) else {
                break;
            };
            let mut segments = PackedInt32Array::new();
            for segment in &layout.segments {
                segments.push(segment.kind as i32);
                segments.push(i32::from(segment.from));
                segments.push(i32::from(segment.to));
                segments.push(i32::from(segment.color));
            }
            rows.push(&vdict! {
                "row" => to_i64(row),
                "hash" => &GString::from(to_hex(commit.hash).as_str()),
                "subject" => &GString::from(commit.subject),
                "author" => &GString::from(commit.author_name),
                "email" => &GString::from(commit.author_email),
                "time" => commit.author_time,
                "column" => i64::from(layout.column),
                "color" => i64::from(layout.color),
                "width" => i64::from(layout.width()),
                "segments" => &segments,
            });
        }
        rows
    }

    /// Load timings and index size, for the status bar and benchmarks.
    #[func]
    fn load_stats(&self) -> VarDictionary {
        let Some(loader) = &self.loader else {
            return VarDictionary::new();
        };
        let progress = loader.progress();
        let index = loader.index();
        let memory = index.memory();
        let ms = |d: Option<std::time::Duration>| d.map_or(-1.0, |d| d.as_secs_f64() * 1e3);
        vdict! {
            "rows" => to_i64(progress.rows),
            "first_page_ms" => ms(progress.first_page),
            "total_ms" => ms(progress.total),
            "max_lanes" => to_i64(index.max_width()),
            "index_bytes" => to_i64(memory.index_bytes),
            "string_bytes" => to_i64(memory.string_bytes),
        }
    }
}

fn to_i64(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}
