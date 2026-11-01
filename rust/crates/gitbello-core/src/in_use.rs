//! Programs that keep a folder from being deleted. Windows cannot delete a
//! running executable or a loaded DLL, so `git worktree remove` stops
//! partway through the folder, after it has already unregistered the
//! worktree. Other systems delete files in use, so nothing is reported there.

use std::fmt;
#[cfg(not(windows))]
use std::path::Path;
use std::path::PathBuf;

/// A process running an executable or a library from inside a folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessUse {
    pub pid: u32,
    /// The executable's file name, `godot.exe`.
    pub name: String,
    /// Its first loaded file inside the folder.
    pub file: PathBuf,
}

impl fmt::Display for ProcessUse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (PID {})", self.name, self.pid)
    }
}

#[cfg(windows)]
pub use imp::processes_using;

/// The processes that have an executable or library inside `dir` loaded,
/// among those this user can inspect. Always empty outside Windows.
#[cfg(not(windows))]
pub fn processes_using(_dir: &Path) -> Vec<ProcessUse> {
    Vec::new()
}

#[cfg(windows)]
#[allow(unsafe_code)]
mod imp {
    use std::ffi::{c_void, OsString};
    use std::io;
    use std::os::windows::ffi::OsStringExt;
    use std::path::{Path, PathBuf};

    use super::ProcessUse;
    use crate::runtime::normalize;

    const TH32CS_SNAPPROCESS: u32 = 0x2;
    const TH32CS_SNAPMODULE: u32 = 0x8;
    const TH32CS_SNAPMODULE32: u32 = 0x10;
    const ERROR_BAD_LENGTH: i32 = 24;
    const MAX_PATH: usize = 260;
    const MAX_MODULE_NAME: usize = 256;

    type Handle = *mut c_void;

    /// `PROCESSENTRY32W`.
    #[repr(C)]
    struct ProcessEntry {
        size: u32,
        usage: u32,
        pid: u32,
        heap_id: usize,
        module_id: u32,
        threads: u32,
        parent_pid: u32,
        priority: i32,
        flags: u32,
        exe_file: [u16; MAX_PATH],
    }

    /// `MODULEENTRY32W`.
    #[repr(C)]
    struct ModuleEntry {
        size: u32,
        module_id: u32,
        pid: u32,
        global_usage: u32,
        process_usage: u32,
        base_address: *mut u8,
        base_size: u32,
        module: *mut c_void,
        module_name: [u16; MAX_MODULE_NAME],
        exe_path: [u16; MAX_PATH],
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> Handle;
        fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
        fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry) -> i32;
        fn Module32FirstW(snapshot: Handle, entry: *mut ModuleEntry) -> i32;
        fn Module32NextW(snapshot: Handle, entry: *mut ModuleEntry) -> i32;
        fn CloseHandle(handle: Handle) -> i32;
    }

    struct Snapshot(Handle);

    impl Snapshot {
        fn take(flags: u32, pid: u32) -> Option<Self> {
            // A module snapshot fails with ERROR_BAD_LENGTH while the
            // process is loading or unloading one: try again.
            for _ in 0..3 {
                // SAFETY: takes plain values and returns a handle we own.
                let handle = unsafe { CreateToolhelp32Snapshot(flags, pid) };
                // INVALID_HANDLE_VALUE is -1.
                if handle as isize != -1 {
                    return Some(Self(handle));
                }
                if io::Error::last_os_error().raw_os_error() != Some(ERROR_BAD_LENGTH) {
                    return None;
                }
            }
            None
        }
    }

    impl Drop for Snapshot {
        fn drop(&mut self) {
            // SAFETY: the handle came from CreateToolhelp32Snapshot and is
            // closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    /// The processes that have an executable or library inside `dir`
    /// loaded, among those this user can inspect.
    pub fn processes_using(dir: &Path) -> Vec<ProcessUse> {
        let folder = folder_key(dir);
        processes()
            .into_iter()
            .filter(|&(pid, _)| pid != 0)
            .filter_map(|(pid, name)| {
                let file = modules(pid)
                    .into_iter()
                    .find(|file| module_key(file).starts_with(&folder))?;
                Some(ProcessUse { pid, name, file })
            })
            .collect()
    }

    /// `(pid, executable name)` of every process.
    fn processes() -> Vec<(u32, String)> {
        let Some(snapshot) = Snapshot::take(TH32CS_SNAPPROCESS, 0) else {
            return Vec::new();
        };
        let mut entry = ProcessEntry {
            size: entry_size::<ProcessEntry>(),
            usage: 0,
            pid: 0,
            heap_id: 0,
            module_id: 0,
            threads: 0,
            parent_pid: 0,
            priority: 0,
            flags: 0,
            exe_file: [0; MAX_PATH],
        };
        let mut list = Vec::new();
        // SAFETY: `entry` is a PROCESSENTRY32W with its size set.
        let mut more = unsafe { Process32FirstW(snapshot.0, &mut entry) } != 0;
        while more {
            list.push((
                entry.pid,
                String::from_utf16_lossy(until_nul(&entry.exe_file)),
            ));
            // SAFETY: as above.
            more = unsafe { Process32NextW(snapshot.0, &mut entry) } != 0;
        }
        list
    }

    /// The executable and libraries `pid` has loaded; empty when it cannot
    /// be inspected (another user's or an elevated process).
    fn modules(pid: u32) -> Vec<PathBuf> {
        let Some(snapshot) = Snapshot::take(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid) else {
            return Vec::new();
        };
        let mut entry = ModuleEntry {
            size: entry_size::<ModuleEntry>(),
            module_id: 0,
            pid: 0,
            global_usage: 0,
            process_usage: 0,
            base_address: std::ptr::null_mut(),
            base_size: 0,
            module: std::ptr::null_mut(),
            module_name: [0; MAX_MODULE_NAME],
            exe_path: [0; MAX_PATH],
        };
        let mut list = Vec::new();
        // SAFETY: `entry` is a MODULEENTRY32W with its size set.
        let mut more = unsafe { Module32FirstW(snapshot.0, &mut entry) } != 0;
        while more {
            list.push(PathBuf::from(OsString::from_wide(until_nul(
                &entry.exe_path,
            ))));
            // SAFETY: as above.
            more = unsafe { Module32NextW(snapshot.0, &mut entry) } != 0;
        }
        list
    }

    fn entry_size<T>() -> u32 {
        u32::try_from(size_of::<T>()).unwrap_or(u32::MAX)
    }

    fn until_nul(text: &[u16]) -> &[u16] {
        let end = text.iter().position(|&c| c == 0).unwrap_or(text.len());
        &text[..end]
    }

    /// Lowercase, backslashed, without `\\?\`: how paths compare on NTFS.
    fn path_key(path: &Path) -> String {
        let text = path.to_string_lossy().replace('/', "\\");
        text.strip_prefix(r"\\?\").unwrap_or(&text).to_lowercase()
    }

    /// A loaded file's key. A program started through an 8.3 short name
    /// (`RUNNER~1`) reports its files by it, so those are expanded first;
    /// only they contain `~`, which keeps the file system out of the scan.
    fn module_key(file: &Path) -> String {
        let key = path_key(file);
        if key.contains('~') {
            path_key(&normalize(file))
        } else {
            key
        }
    }

    /// `dir`'s key with a trailing separator, so `wt` does not match `wt2`.
    fn folder_key(dir: &Path) -> String {
        let mut key = path_key(&normalize(dir));
        if !key.ends_with('\\') {
            key.push('\\');
        }
        key
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn entry_layouts_match_windows() {
            assert_eq!(size_of::<ProcessEntry>(), 568);
            assert_eq!(size_of::<ModuleEntry>(), 1080);
        }

        #[test]
        fn folder_matches_its_files_only() {
            let folder = folder_key(Path::new(r"C:/Repos/WT"));
            assert_eq!(folder, r"c:\repos\wt\");
            assert!(path_key(Path::new(r"\\?\C:\repos\wt\bin\a.dll")).starts_with(&folder));
            assert!(!path_key(Path::new(r"C:\repos\wt2\a.dll")).starts_with(&folder));
        }

        #[test]
        fn finds_this_test_binary() {
            let exe = std::env::current_exe().unwrap();
            let found = processes_using(exe.parent().unwrap());
            let me = found
                .iter()
                .find(|p| p.pid == std::process::id())
                .expect("this process runs from its folder");
            assert_eq!(normalize(&me.file), normalize(&exe));
        }
    }
}
