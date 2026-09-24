//! ConPTY manager for the Calcar agent. PLAN P4 slice 3.
//!
//! One PTY per workflow. Every workflow process runs inside a Windows Job
//! Object created with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so killing the job
//! or dropping the handle ends the whole tree, grandchildren included. PLAN P4
//! asks for parent to child to grandchild dead, and the test proves it.
//!
//! Output: one reader thread pumps the console stream into a bounded channel.
//! When the consumer falls behind, the reader blocks on send. Nothing is
//! dropped and memory stays inside the configured budget. Idle is a blocked
//! read on the pipe, never a poll loop.
//!
//! ConPTY merges stdout and stderr into a single console stream. The split
//! streams the plan mentions belong to the plain pipe path for non interactive
//! commands, which lands with the provider adapters. The interactive path
//! documented here has one merged stream, and this file says so rather than
//! pretending otherwise.

use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PtyError {
    #[error("windows call {call} failed: {message}")]
    Windows { call: &'static str, message: String },
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid spawn config: {0}")]
    InvalidConfig(String),
    #[error("pty is closed")]
    Closed,
}

pub type Result<T> = std::result::Result<T, PtyError>;

/// Default backlog for pumped output. The adapter parse step consumes fast, so
/// a megabyte of headroom rides out bursts without unbounded growth.
pub const DEFAULT_OUTPUT_BUFFER_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone)]
pub struct SpawnConfig {
    pub argv: Vec<String>,
    pub working_dir: Option<std::path::PathBuf>,
    /// Overrides layered on top of the current process environment.
    pub env: Vec<(String, String)>,
    pub cols: i16,
    pub rows: i16,
    pub output_buffer_bytes: usize,
}

impl SpawnConfig {
    pub fn new(argv: Vec<String>) -> Self {
        Self {
            argv,
            working_dir: None,
            env: Vec::new(),
            cols: 120,
            rows: 30,
            output_buffer_bytes: DEFAULT_OUTPUT_BUFFER_BYTES,
        }
    }

    /// Normalized command line, quoted the way CreateProcessW wants it.
    pub(crate) fn command_line(&self) -> Result<String> {
        if self.argv.is_empty() {
            return Err(PtyError::InvalidConfig("argv is empty".into()));
        }
        Ok(self
            .argv
            .iter()
            .map(|arg| quote_arg(arg))
            .collect::<Vec<_>>()
            .join(" "))
    }
}

fn quote_arg(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '"']) {
        return arg.to_string();
    }
    let mut out = String::from("\"");
    let mut backslashes = 0;
    for ch in arg.chars() {
        match ch {
            '\\' => {
                backslashes += 1;
                out.push(ch);
            }
            '"' => {
                // Backslashes before a quote must be doubled, then the quote escaped.
                for _ in 0..backslashes {
                    out.push('\\');
                }
                backslashes = 0;
                out.push('\\');
                out.push('"');
            }
            other => {
                backslashes = 0;
                out.push(other);
            }
        }
    }
    for _ in 0..backslashes {
        out.push('\\');
    }
    out.push('"');
    out
}

/// One workflow PTY plus its job object.
///
/// Dropping it kills the job, closes the console, and joins the pump thread.
pub struct WorkflowPty {
    #[cfg(windows)]
    inner: windows_impl::Inner,
    #[cfg(not(windows))]
    _private: (),
}

#[cfg(windows)]
mod windows_impl {
    use super::*;
    use std::collections::BTreeMap;
    use std::fs::File;
    use std::io::Read;
    use std::os::windows::io::FromRawHandle;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TryRecvError};
    use std::thread::JoinHandle;

    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::System::Console::{
        ClosePseudoConsole, CreatePseudoConsole, ResizePseudoConsole, COORD, HPCON,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CreateProcessW, DeleteProcThreadAttributeList, GetExitCodeProcess,
        InitializeProcThreadAttributeList, UpdateProcThreadAttribute, WaitForSingleObject,
        CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, PROCESS_INFORMATION,
        STARTUPINFOEXW,
    };

    /// ProcThreadAttributeValue(ProcThreadAttributePseudoconsole=22, FALSE, TRUE, FALSE).
    /// Windows 10 1809 and later. Spelled out because windows-sys exports no name.
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;

    /// Reader chunk size. Bounds channel memory against the byte budget.
    const PUMP_CHUNK_BYTES: usize = 16 * 1024;

    struct OwnedHandle(HANDLE);

    impl OwnedHandle {
        fn new(handle: HANDLE) -> Self {
            Self(handle)
        }
        fn raw(&self) -> HANDLE {
            self.0
        }
        /// Close now. Dropping the last write end lets a pipe reader see EOF,
        /// which is what releases the pump thread before we join it.
        fn close(&mut self) {
            if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
                unsafe { CloseHandle(self.0) };
                self.0 = std::ptr::null_mut();
            }
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            self.close();
        }
    }

    fn last_error(call: &'static str) -> PtyError {
        PtyError::Windows {
            call,
            message: format!("GetLastError={}", unsafe { GetLastError() }),
        }
    }

    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Environment block: current process environment plus overrides, sorted,
    /// double null terminated, UTF-16. Windows treats names case insensitively,
    /// so overrides key on the uppercase name.
    fn environment_block(overrides: &[(String, String)]) -> Vec<u16> {
        let mut map: BTreeMap<String, String> = std::env::vars()
            .map(|(k, v)| (k.to_uppercase(), v))
            .collect();
        for (key, value) in overrides {
            map.insert(key.to_uppercase(), value.clone());
        }
        let mut block = Vec::new();
        for (key, value) in map {
            block.extend(key.encode_utf16());
            block.push(u16::from(b'='));
            block.extend(value.encode_utf16());
            block.push(0);
        }
        block.push(0);
        block
    }

    pub struct Inner {
        job: OwnedHandle,
        process: OwnedHandle,
        conpty: HPCON,
        // Console ends of the pipes. They must stay open for the life of
        // the console: closing them kills console output and stdin early.
        // Never read by design; dropping them is the close. Dropped after
        // ClosePseudoConsole in Drop below.
        #[allow(dead_code)]
        console_input: OwnedHandle,
        #[allow(dead_code)]
        console_output: OwnedHandle,
        pid: u32,
        input: File,
        output_rx: Receiver<Vec<u8>>,
        output_closed: AtomicBool,
        exit_code: AtomicU32,
        exited: AtomicBool,
        pump: Option<JoinHandle<()>>,
    }

    impl Inner {
        pub fn spawn(config: SpawnConfig) -> Result<WorkflowPty> {
            let command_line_text = config.command_line()?;
            let mut command_line = wide(&command_line_text);
            let working_dir = config
                .working_dir
                .as_ref()
                .map(|dir| wide(&dir.to_string_lossy()))
                .unwrap_or_else(|| wide("."));
            let env_block = environment_block(&config.env);

            unsafe {
                // 1. Pipes. The console ends (input_read, output_write) stay
                // open inside Inner for the life of the console. The client
                // ends (input_write, output_read) become Files below.
                let mut input_read: HANDLE = std::ptr::null_mut();
                let mut input_write: HANDLE = std::ptr::null_mut();
                if CreatePipe(&mut input_read, &mut input_write, std::ptr::null(), 0) == 0 {
                    return Err(last_error("CreatePipe input"));
                }
                let mut output_read: HANDLE = std::ptr::null_mut();
                let mut output_write: HANDLE = std::ptr::null_mut();
                if CreatePipe(&mut output_read, &mut output_write, std::ptr::null(), 0) == 0 {
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    return Err(last_error("CreatePipe output"));
                }

                // 2. The pseudo console.
                let mut conpty: HPCON = 0;
                let created = CreatePseudoConsole(
                    COORD {
                        X: config.cols.max(1),
                        Y: config.rows.max(1),
                    },
                    input_read,
                    output_write,
                    0,
                    &mut conpty,
                );
                if created != 0 {
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(PtyError::Windows {
                        call: "CreatePseudoConsole",
                        message: format!("HRESULT 0x{:08X}", created as u32),
                    });
                }

                // 3. Job object. Kill on close is what makes drop a tree kill.
                let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if job.is_null() {
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(last_error("CreateJobObjectW"));
                }
                let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    &limits as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) == 0
                {
                    CloseHandle(job);
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(last_error("SetInformationJobObject"));
                }

                // 4. Attribute list carrying the pseudoconsole handle.
                let mut attr_size: usize = 0;
                InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut attr_size);
                let mut attr_buffer: Vec<u8> = vec![0u8; attr_size];
                let attr_list = attr_buffer.as_mut_ptr() as *mut core::ffi::c_void;
                if InitializeProcThreadAttributeList(attr_list, 1, 0, &mut attr_size) == 0 {
                    CloseHandle(job);
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(last_error("InitializeProcThreadAttributeList"));
                }
                if UpdateProcThreadAttribute(
                    attr_list,
                    0,
                    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    &conpty as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<HPCON>(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                ) == 0
                {
                    DeleteProcThreadAttributeList(attr_list);
                    CloseHandle(job);
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(last_error("UpdateProcThreadAttribute"));
                }

                // 5. Create attached to the console. EXTENDED_STARTUPINFO_PRESENT
                // is what makes the attribute list (and the attach) take effect.
                let mut startup: STARTUPINFOEXW = std::mem::zeroed();
                startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
                startup.lpAttributeList = attr_list;

                let mut process_info: PROCESS_INFORMATION = std::mem::zeroed();
                let created_process = CreateProcessW(
                    std::ptr::null(),
                    command_line.as_mut_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    0,
                    CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
                    env_block.as_ptr() as *const core::ffi::c_void,
                    working_dir.as_ptr(),
                    &startup.StartupInfo,
                    &mut process_info,
                );
                DeleteProcThreadAttributeList(attr_list);
                if created_process == 0 {
                    CloseHandle(job);
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(last_error("CreateProcessW"));
                }
                if !process_info.hThread.is_null() {
                    CloseHandle(process_info.hThread);
                }

                // 6. Join the job. Descendants inherit it, which is the tree kill.
                if AssignProcessToJobObject(job, process_info.hProcess) == 0 {
                    let err = last_error("AssignProcessToJobObject");
                    TerminateJobObject(job, 1);
                    CloseHandle(process_info.hProcess);
                    CloseHandle(job);
                    ClosePseudoConsole(conpty);
                    CloseHandle(input_read);
                    CloseHandle(input_write);
                    CloseHandle(output_read);
                    CloseHandle(output_write);
                    return Err(err);
                }

                // 7. Reader thread into a bounded channel. A full channel blocks
                // the reader: backpressure instead of loss or unbounded growth.
                // From here the client ends belong to the Files; the console
                // ends move into Inner below. No handle is closed twice.
                let capacity = (config.output_buffer_bytes / PUMP_CHUNK_BYTES).max(1);
                let (tx, output_rx) = sync_channel::<Vec<u8>>(capacity);
                let mut output_file = File::from_raw_handle(output_read as _);
                let input_file = File::from_raw_handle(input_write as _);
                let pump = match std::thread::Builder::new()
                    .name("calcar-pty-pump".into())
                    .spawn(move || pump_output(&mut output_file, tx))
                {
                    Ok(pump) => pump,
                    Err(e) => {
                        // output_file moved into the closure and drops with it
                        // on spawn failure, closing output_read. Drop the input
                        // File here to close input_write.
                        drop(input_file);
                        TerminateJobObject(job, 1);
                        CloseHandle(process_info.hProcess);
                        CloseHandle(job);
                        ClosePseudoConsole(conpty);
                        CloseHandle(input_read);
                        CloseHandle(output_write);
                        return Err(PtyError::Io(e));
                    }
                };

                // 8. Construct. The job, process, console, and console pipe ends
                // transfer into Inner, which closes them in Drop.
                Ok(WorkflowPty {
                    inner: Inner {
                        job: OwnedHandle::new(job),
                        process: OwnedHandle::new(process_info.hProcess),
                        conpty,
                        console_input: OwnedHandle::new(input_read),
                        console_output: OwnedHandle::new(output_write),
                        pid: process_info.dwProcessId,
                        input: input_file,
                        output_rx,
                        output_closed: AtomicBool::new(false),
                        exit_code: AtomicU32::new(0),
                        exited: AtomicBool::new(false),
                        pump: Some(pump),
                    },
                })
            }
        }

        /// Write bytes to the console input.
        pub fn write_input(&mut self, bytes: &[u8]) -> Result<()> {
            use std::io::Write;
            self.input.write_all(bytes)?;
            self.input.flush()?;
            Ok(())
        }

        pub fn resize(&self, cols: i16, rows: i16) -> Result<()> {
            let result = unsafe {
                ResizePseudoConsole(
                    self.conpty,
                    COORD {
                        X: cols.max(1),
                        Y: rows.max(1),
                    },
                )
            };
            if result != 0 {
                return Err(PtyError::Windows {
                    call: "ResizePseudoConsole",
                    message: format!("HRESULT 0x{:08X}", result as u32),
                });
            }
            Ok(())
        }

        /// Next pumped chunk, or None when nothing is ready. The stream counts
        /// as closed once the reader thread ends and the channel drains.
        pub fn try_output(&self) -> Option<Vec<u8>> {
            match self.output_rx.try_recv() {
                Ok(chunk) => Some(chunk),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => {
                    self.output_closed.store(true, Ordering::SeqCst);
                    None
                }
            }
        }

        /// Blocking read with a deadline. Ok(None) means the deadline passed.
        pub fn recv_output(&self, timeout: Duration) -> Result<Option<Vec<u8>>> {
            match self.output_rx.recv_timeout(timeout) {
                Ok(chunk) => Ok(Some(chunk)),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Ok(None),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    self.output_closed.store(true, Ordering::SeqCst);
                    Ok(None)
                }
            }
        }

        pub fn output_closed(&self) -> bool {
            self.output_closed.load(Ordering::SeqCst)
        }

        pub fn pid(&self) -> u32 {
            self.pid
        }

        /// Kill the whole job. Descendants included, by job membership.
        pub fn kill(&self) -> Result<()> {
            unsafe { TerminateJobObject(self.job.raw(), 1) };
            Ok(())
        }

        /// Wait for exit. Ok(None) means the deadline passed first.
        pub fn wait(&self, timeout: Option<Duration>) -> Result<Option<u32>> {
            if self.exited.load(Ordering::SeqCst) {
                return Ok(Some(self.exit_code.load(Ordering::SeqCst)));
            }
            let millis = match timeout {
                None => u32::MAX,
                Some(duration) => duration.as_millis().min(u32::MAX as u128) as u32,
            };
            let waited = unsafe { WaitForSingleObject(self.process.raw(), millis) };
            if waited == WAIT_TIMEOUT {
                return Ok(None);
            }
            if waited != WAIT_OBJECT_0 {
                return Err(last_error("WaitForSingleObject"));
            }
            let mut code: u32 = 0;
            if unsafe { GetExitCodeProcess(self.process.raw(), &mut code) } == 0 {
                return Err(last_error("GetExitCodeProcess"));
            }
            self.exit_code.store(code, Ordering::SeqCst);
            self.exited.store(true, Ordering::SeqCst);
            Ok(Some(code))
        }
    }

    impl Drop for Inner {
        fn drop(&mut self) {
            // Kill the tree, then close the console so the reader sees EOF and
            // the pump thread can finish. Closing our copies of the console
            // pipe ends first is load bearing: they are the last write ends,
            // and the pump read cannot return EOF while one stays open.
            // Both steps are idempotent.
            unsafe { TerminateJobObject(self.job.raw(), 1) };
            if self.conpty != 0 {
                unsafe { ClosePseudoConsole(self.conpty) };
                self.conpty = 0;
            }
            self.console_input.close();
            self.console_output.close();
            if let Some(pump) = self.pump.take() {
                let _ = pump.join();
            }
        }
    }

    /// Read until the console closes, sending chunks on a bounded channel.
    /// A full channel blocks this thread on purpose: backpressure, not loss.
    fn pump_output(file: &mut File, tx: SyncSender<Vec<u8>>) {
        let mut buffer = vec![0u8; PUMP_CHUNK_BYTES];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    if tx.send(buffer[..n].to_vec()).is_err() {
                        break; // consumer went away
                    }
                }
                Err(_) => break,
            }
        }
    }
}

#[cfg(windows)]
impl WorkflowPty {
    /// Spawn `argv` inside a fresh ConPTY attached to a fresh job object.
    pub fn spawn(config: SpawnConfig) -> Result<Self> {
        windows_impl::Inner::spawn(config)
    }

    /// Write bytes to the console input. Newlines need \r\n; the console is in
    /// cooked mode unless the child changes it.
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        self.inner.write_input(bytes)
    }

    pub fn resize(&self, cols: i16, rows: i16) -> Result<()> {
        self.inner.resize(cols, rows)
    }

    /// Non blocking read of the next chunk.
    pub fn try_read(&self) -> Option<Vec<u8>> {
        self.inner.try_output()
    }

    /// Blocking read with a deadline. None means the deadline passed first.
    pub fn read_timeout(&self, timeout: Duration) -> Result<Option<Vec<u8>>> {
        self.inner.recv_output(timeout)
    }

    /// True once the reader thread ended and the channel drained.
    pub fn output_closed(&self) -> bool {
        self.inner.output_closed()
    }

    pub fn pid(&self) -> u32 {
        self.inner.pid()
    }

    /// Kill the whole job, descendants included.
    pub fn kill(&self) -> Result<()> {
        self.inner.kill()
    }

    /// Wait for exit with a deadline. None means the deadline passed first.
    pub fn wait(&self, timeout: Option<Duration>) -> Result<Option<u32>> {
        self.inner.wait(timeout)
    }

    /// Read until `marker` shows up in the accumulated output or the deadline
    /// passes. Returns everything read so far. Used by adapters and tests to
    /// wait for a prompt or a result without polling the process.
    pub fn read_until(&self, marker: &str, timeout: Duration) -> Result<String> {
        let deadline = std::time::Instant::now() + timeout;
        let mut collected = String::new();
        loop {
            if collected.contains(marker) {
                return Ok(collected);
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Ok(collected);
            }
            match self.read_timeout(remaining.min(Duration::from_millis(200)))? {
                Some(chunk) => collected.push_str(&String::from_utf8_lossy(&chunk)),
                None => {
                    if self.output_closed() {
                        return Ok(collected);
                    }
                }
            }
        }
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    fn interactive_cmd_pty() -> WorkflowPty {
        WorkflowPty::spawn(SpawnConfig::new(vec!["cmd.exe".into(), "/Q".into()]))
            .expect("spawn cmd")
    }

    fn process_exists(pid: u32) -> bool {
        let output = std::process::Command::new("tasklist")
            .args(["/FI", &format!("PID eq {pid}"), "/NH"])
            .output()
            .expect("tasklist");
        String::from_utf8_lossy(&output.stdout).contains(&pid.to_string())
    }

    #[test]
    fn empty_argv_is_rejected() {
        match WorkflowPty::spawn(SpawnConfig::new(vec![])) {
            Err(PtyError::InvalidConfig(_)) => {}
            Err(other) => panic!("wrong error: {other:?}"),
            Ok(_) => panic!("empty argv should fail"),
        }
    }

    #[test]
    fn quoting_handles_spaces_quotes_and_trailing_backslashes() {
        assert_eq!(quote_arg("plain"), "plain");
        assert_eq!(quote_arg("has space"), "\"has space\"");
        assert_eq!(quote_arg("say \"hi\""), "\"say \\\"hi\\\"\"");
        assert_eq!(
            quote_arg("C:\\path with space\\"),
            "\"C:\\path with space\\\\\""
        );
    }

    #[test]
    fn echo_round_trip_through_the_console() {
        let mut pty = interactive_cmd_pty();
        pty.write(b"echo CALCAR_PTY_ECHO\r\n").expect("write");
        let output = pty
            .read_until("CALCAR_PTY_ECHO", Duration::from_secs(15))
            .expect("read");
        assert!(
            output.contains("CALCAR_PTY_ECHO"),
            "expected the echo back, got: {output}"
        );
        pty.kill().expect("kill");
        assert!(pty
            .wait(Some(Duration::from_secs(5)))
            .expect("wait")
            .is_some());
    }

    #[test]
    fn resize_is_accepted_and_the_session_keeps_working() {
        let mut pty = interactive_cmd_pty();
        pty.resize(100, 40).expect("resize");
        pty.write(b"echo AFTER_RESIZE\r\n").expect("write");
        let output = pty
            .read_until("AFTER_RESIZE", Duration::from_secs(15))
            .expect("read");
        assert!(output.contains("AFTER_RESIZE"), "got: {output}");
        pty.kill().expect("kill");
        let _ = pty.wait(Some(Duration::from_secs(5)));
    }

    #[test]
    fn kill_ends_the_whole_tree() {
        // PowerShell prints the grandchild PID, then idles so the tree is alive
        // when we kill it. The grandchild is what proves job membership.
        let script = "$c = Start-Process -FilePath ping -ArgumentList '-n','60','127.0.0.1' \
                      -WindowStyle Hidden -PassThru; Write-Output (\"GRANDCHILD=\" + $c.Id); \
                      Start-Sleep -Seconds 60";
        let config = SpawnConfig::new(vec![
            "powershell.exe".into(),
            "-NoProfile".into(),
            "-NonInteractive".into(),
            "-Command".into(),
            script.into(),
        ]);
        let pty = WorkflowPty::spawn(config).expect("spawn powershell");
        let output = pty
            .read_until("GRANDCHILD=", Duration::from_secs(30))
            .expect("read");
        let pid = output
            .lines()
            .find_map(|line| line.trim().strip_prefix("GRANDCHILD="))
            .and_then(|value| value.trim().parse::<u32>().ok())
            .unwrap_or_else(|| panic!("no grandchild pid in output: {output}"));
        assert!(
            process_exists(pid),
            "grandchild {pid} should be running before the kill"
        );

        pty.kill().expect("kill");
        let exit = pty.wait(Some(Duration::from_secs(10))).expect("wait");
        assert!(
            exit.is_some(),
            "the direct child should be reaped after the kill"
        );

        // Job termination is asynchronous for the descendant; poll briefly.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while process_exists(pid) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(200));
        }
        assert!(
            !process_exists(pid),
            "grandchild {pid} survived the job kill"
        );
    }

    #[test]
    fn large_output_arrives_complete_under_a_slow_consumer() {
        // 2000 lines through a 64 KB channel. The pump has to block, and the
        // count at the end proves backpressure without loss.
        let mut config = SpawnConfig::new(vec![
            "cmd.exe".into(),
            "/Q".into(),
            "/C".into(),
            "for /L %i in (1,1,2000) do @echo line-%i".into(),
        ]);
        config.output_buffer_bytes = 64 * 1024;
        let pty = WorkflowPty::spawn(config).expect("spawn");

        // Let the producer run ahead of the consumer for a moment.
        std::thread::sleep(Duration::from_millis(300));

        let mut collected = String::new();
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            match pty.read_timeout(Duration::from_millis(250)).expect("read") {
                Some(chunk) => collected.push_str(&String::from_utf8_lossy(&chunk)),
                None => {
                    if pty.output_closed() || std::time::Instant::now() > deadline {
                        break;
                    }
                }
            }
        }
        let lines = collected.matches("line-").count();
        assert_eq!(lines, 2000, "every line must arrive, got {lines}");
        let _ = pty.wait(Some(Duration::from_secs(5)));
    }
}
