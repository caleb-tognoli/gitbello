//! History graph: streamed log parsing, the compact index and lane layout.

mod index;
mod lanes;
mod loader;
mod log;
mod search;

pub use index::{to_hex, CommitRow, GraphIndex, IndexMemory, CHECKPOINT_INTERVAL};
pub use lanes::{Lane, LaneState, NodeId, RowLayout, Segment, SegmentKind};
pub use loader::{
    GraphLoadError, GraphLoader, GraphReader, LoadProgress, LoadState, FIRST_PAGE_ROWS,
    GRAPH_JOB_LABEL,
};
pub use log::{LogParseError, LogRecord, RecordSplitter, LOG_ARGS};
pub use search::{CommitMatcher, CommitSearch, SEARCH_CHUNK_ROWS, SEARCH_JOB_LABEL};
