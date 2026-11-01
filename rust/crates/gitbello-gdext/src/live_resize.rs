//! Keeps the window drawing while the user drags its border on Windows.
//!
//! Dragging a border runs Windows' modal size/move loop, and Godot only draws
//! from that loop when its `WM_TIMER` (`TIMER_ID_MOVE_REDRAW`) fires. Timer
//! messages are generated only when the queue is otherwise empty, and Godot's
//! raw mouse input puts a `WM_INPUT` in the queue for every mouse report, so
//! while the mouse moves the timer starves: the window shrinks in steps and
//! grows into an undrawn area until the button is released.
//!
//! A helper thread watches the main thread's windows for the start and end of
//! that loop (`EVENT_SYSTEM_MOVESIZESTART/END`) and, in between, sends the same
//! timer message itself. Sent messages are handled before input, and sending
//! waits for the frame it triggers, so frames never queue up. The thread
//! sleeps in `GetMessageW` the rest of the time.

#[cfg(windows)]
pub use imp::{start, stop};

#[cfg(not(windows))]
pub fn start() {}

#[cfg(not(windows))]
pub fn stop() {}

#[cfg(windows)]
#[allow(unsafe_code)]
mod imp {
    use std::cell::Cell;
    use std::ffi::c_void;
    use std::ptr::null_mut;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Mutex};
    use std::thread::JoinHandle;
    use std::time::Duration;

    type Hwnd = *mut c_void;
    type Hook = *mut c_void;
    type WinEventProc = unsafe extern "system" fn(Hook, u32, Hwnd, i32, i32, u32, u32);

    #[repr(C)]
    struct Msg {
        hwnd: Hwnd,
        message: u32,
        wparam: usize,
        lparam: isize,
        time: u32,
        pt: [i32; 2],
        private: u32,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentThreadId() -> u32;
        fn GetCurrentProcessId() -> u32;
    }

    #[link(name = "user32")]
    extern "system" {
        fn SetWinEventHook(
            min: u32,
            max: u32,
            module: *mut c_void,
            callback: WinEventProc,
            process: u32,
            thread: u32,
            flags: u32,
        ) -> Hook;
        fn UnhookWinEvent(hook: Hook) -> i32;
        fn GetMessageW(msg: *mut Msg, hwnd: Hwnd, min: u32, max: u32) -> i32;
        fn PeekMessageW(msg: *mut Msg, hwnd: Hwnd, min: u32, max: u32, remove: u32) -> i32;
        fn DispatchMessageW(msg: *const Msg) -> isize;
        fn PostThreadMessageW(thread: u32, message: u32, wparam: usize, lparam: isize) -> i32;
        fn SendMessageTimeoutW(
            hwnd: Hwnd,
            message: u32,
            wparam: usize,
            lparam: isize,
            flags: u32,
            timeout: u32,
            result: *mut usize,
        ) -> isize;
    }

    const EVENT_SYSTEM_MOVESIZESTART: u32 = 0x000A;
    const EVENT_SYSTEM_MOVESIZEEND: u32 = 0x000B;
    const WINEVENT_OUTOFCONTEXT: u32 = 0;
    const OBJID_WINDOW: i32 = 0;
    const PM_NOREMOVE: u32 = 0;
    const PM_REMOVE: u32 = 1;
    const WM_NULL: u32 = 0x0000;
    const WM_QUIT: u32 = 0x0012;
    const WM_TIMER: u32 = 0x0113;
    const SMTO_ABORTIFHUNG: u32 = 0x0002;
    /// `DisplayServerWindows::TIMER_ID_MOVE_REDRAW` (Godot 4.7): the id Godot
    /// gives the timer it draws from during the size/move loop.
    const MOVE_REDRAW_TIMER: usize = 1;
    /// How long a frame may take before the helper gives up waiting for it.
    const FRAME_TIMEOUT_MS: u32 = 200;
    /// Pause between frames, so the size loop gets to apply the mouse moves.
    const FRAME_GAP: Duration = Duration::from_millis(2);

    struct Helper {
        thread_id: u32,
        handle: JoinHandle<()>,
    }

    static HELPER: Mutex<Option<Helper>> = Mutex::new(None);
    static STOP: AtomicBool = AtomicBool::new(false);

    thread_local! {
        /// The window in the size/move loop, set by the WinEvent callback
        /// (it runs on the helper thread, inside `GetMessageW`/`PeekMessageW`).
        static SIZING: Cell<Hwnd> = const { Cell::new(null_mut()) };
    }

    /// Starts the helper for the calling (main) thread's windows.
    pub fn start() {
        let Ok(mut helper) = HELPER.lock() else {
            return;
        };
        if helper.is_some() {
            return;
        }
        // SAFETY: plain Win32 calls without arguments.
        let (main_thread, process) = unsafe { (GetCurrentThreadId(), GetCurrentProcessId()) };
        STOP.store(false, Ordering::SeqCst);
        let (ready_tx, ready_rx) = mpsc::channel();
        let spawned = std::thread::Builder::new()
            .name("gitbello-live-resize".into())
            .spawn(move || run(main_thread, process, &STOP, ready_tx));
        let Ok(handle) = spawned else { return };
        // The helper's message queue exists once it reports its thread id.
        let Ok(thread_id) = ready_rx.recv() else {
            return;
        };
        *helper = Some(Helper { thread_id, handle });
    }

    /// Stops the helper and waits for it.
    pub fn stop() {
        let Some(helper) = HELPER.lock().ok().and_then(|mut helper| helper.take()) else {
            return;
        };
        STOP.store(true, Ordering::SeqCst);
        // SAFETY: posting to a thread id the helper reported; failure only
        // means it already exited.
        unsafe { PostThreadMessageW(helper.thread_id, WM_QUIT, 0, 0) };
        let _ = helper.handle.join();
    }

    unsafe extern "system" fn on_event(
        _: Hook,
        event: u32,
        hwnd: Hwnd,
        object: i32,
        _: i32,
        _: u32,
        _: u32,
    ) {
        if object != OBJID_WINDOW {
            return;
        }
        match event {
            EVENT_SYSTEM_MOVESIZESTART => {
                SIZING.with(|sizing| sizing.set(hwnd));
                // `GetMessageW` runs this callback without returning: wake it.
                PostThreadMessageW(GetCurrentThreadId(), WM_NULL, 0, 0);
            }
            EVENT_SYSTEM_MOVESIZEEND => SIZING.with(|sizing| sizing.set(null_mut())),
            _ => {}
        }
    }

    fn run(main_thread: u32, process: u32, stop: &AtomicBool, ready: mpsc::Sender<u32>) {
        let mut msg = Msg {
            hwnd: null_mut(),
            message: 0,
            wparam: 0,
            lparam: 0,
            time: 0,
            pt: [0; 2],
            private: 0,
        };
        // SAFETY: `msg` outlives every call that writes it; the hook callback
        // only touches this thread's `SIZING`; the hook is removed before return.
        unsafe {
            // Creates this thread's message queue before `stop()` can post to it.
            PeekMessageW(&mut msg, null_mut(), 0, 0, PM_NOREMOVE);
            let _ = ready.send(GetCurrentThreadId());
            let hook = SetWinEventHook(
                EVENT_SYSTEM_MOVESIZESTART,
                EVENT_SYSTEM_MOVESIZEEND,
                null_mut(),
                on_event,
                process,
                main_thread,
                WINEVENT_OUTOFCONTEXT,
            );
            if hook.is_null() {
                return;
            }
            'outer: while !stop.load(Ordering::SeqCst) {
                let sizing = SIZING.with(Cell::get);
                if sizing.is_null() {
                    if GetMessageW(&mut msg, null_mut(), 0, 0) <= 0 {
                        break;
                    }
                    DispatchMessageW(&msg);
                    continue;
                }
                while PeekMessageW(&mut msg, null_mut(), 0, 0, PM_REMOVE) != 0 {
                    if msg.message == WM_QUIT {
                        break 'outer;
                    }
                    DispatchMessageW(&msg);
                }
                let mut result: usize = 0;
                SendMessageTimeoutW(
                    sizing,
                    WM_TIMER,
                    MOVE_REDRAW_TIMER,
                    0,
                    SMTO_ABORTIFHUNG,
                    FRAME_TIMEOUT_MS,
                    &mut result,
                );
                std::thread::sleep(FRAME_GAP);
            }
            UnhookWinEvent(hook);
        }
    }
}
