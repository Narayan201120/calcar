//! Plain-pipe executor for non-interactive generic commands (PLAN P4).
//!
//! [`PlainChild`] spawns one OS process with no ConPTY: stdout and stderr are
//! separate anonymous pipes, stdin is either closed or fed once from memory,
//! and the process joins a Windows Job Object created with
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so [`PlainChild::kill`] (or `Drop`)
//! ends the whole tree, grandchildren included.
//!
//! Output is collected by two pump threads into per-stream buffers bounded by
//! [`PlainConfig::output_cap_bytes`]. Past the cap, bytes are still drained
//! (so a verbose child never blocks on a full pipe) but no longer stored, and
//! [`PlainOutput::truncated`] reports the loss. Idle is a blocked pipe read,
//! never a poll loop.
//!
//! Ownership mirrors `lib.rs` `Inner`: the job and process handles are RAII,
//! `Drop` terminates the job first and then joins every thread, so abandoning
//! a [`PlainChild`] never leaks a process or a thread.

use std::path::PathBuf;

/// Default per-stream output cap: 1 MiB each for stdout and stderr.
pub const DEFAULT_PLAIN_OUTPUT_CAP_BYTES: usize = 1024 * 1024;

/// Hard ceiling for the per-stream cap. Guards against a misconfigured caller
/// turning a runaway child into an OOM.
pub const MAX_PLAIN_OUTPUT_CAP_BYTES: usize = 64 * 1024 * 1024;

/// Spawn configuration for [`PlainChild`].
#[derive(Debug, Clone)]
pub struct PlainConfig {
    pub argv: Vec<String>,
    pub working_dir: Option<PathBuf>,
    /// Overrides layered on top of the current process environment.
    pub env: Vec<(String, String)>,
    /// Bytes written to the child stdin once, then EOF. `None` means the
    /// child starts with a closed stdin.
    pub input: Option<Vec<u8>>,
    /// Per-stream cap for stdout and stderr each. Clamped to
    /// `1..=MAX_PLAIN_OUTPUT_CAP_BYTES`.
    pub output_cap_bytes: usize,
}

impl PlainConfig {
    pub fn new(argv: Vec<String>) -> Self {
        Self {
            argv,
            working_dir: None,
            env: Vec::new(),
            input: None,
            output_cap_bytes: DEFAULT_PLAIN_OUTPUT_CAP_BYTES,
        }
    }

    pub fn with_input(mut self, bytes: Vec<u8>) -> Self {
        self.input = Some(bytes);
        self
    }

    /// Adapt the shared PTY spawn config: same argv, cwd, and environment,
    /// with the PTY backlog budget reused as the per-stream pipe cap.
    pub fn from_spawn(config: &crate::SpawnConfig, input: Option<Vec<u8>>) -> Self {
        Self {
            argv: config.argv.clone(),
            working_dir: config.working_dir.clone(),
            env: config.env.clone(),
            input,
            output_cap_bytes: config.output_buffer_bytes,
        }
    }
}

/// Collected output of a plain child.
#[derive(Debug, Clone)]
pub struct PlainOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// `None` when sampled from a still-running child via
    /// [`PlainChild::snapshot`].
    pub exit_code: Option<u32>,
    /// True when either stream exceeded the cap and the tail was discarded.
    pub truncated: bool,
}

impl PlainOutput {
    pub fn stdout_lossy(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    pub fn stderr_lossy(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}

#[cfg(windows)]
pub use os::PlainChild;

#[cfg(windows)]
mod os {
    use super::{PlainConfig, PlainOutput, MAX_PLAIN_OUTPUT_CAP_BYTES};
    use crate::{PtyError, Result};
    use std::collections::BTreeMap;
    use std::fs::File;
    use std::io::Read;
    use std::os::windows::io::FromRawHandle;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;
    use std::time::{Duration, Instant};

    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, SetHandleInformation, HANDLE, HANDLE_FLAG_INHERIT,
        INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::Threading::{
        CreateProcessW, GetExitCodeProcess, TerminateProcess, WaitForSingleObject,
        CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION, STARTF_USESTDHANDLES,
        STARTUPINFOW,
    };

    /// Reader chunk size. Small enough to keep latency low, large enough to
    /// keep syscall overhead down.
    const PUMP_CHUNK_BYTES: usize = 16 * 1024;

    struct OwnedHandle(HANDLE);

    impl OwnedHandle {
        fn new(handle: HANDLE) -> Self {
            Self(handle)
        }

        fn raw(&self) -> HANDLE {
            self.0
        }

        /// Hand ownership to a `File` without closing. After this the
        /// `File` is the sole owner.
        fn detach(&mut self) -> HANDLE {
            let handle = self.0;
            self.0 = std::ptr::null_mut();
            handle
        }

        /// Close now. Closing the parent copies of the child pipe ends is
        /// what lets the pumps see EOF.
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
    /// double null terminated, UTF-16. Windows treats names case
    /// insensitively, so overrides key on the uppercase name.
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

    fn command_line(argv: &[String]) -> Result<String> {
        if argv.is_empty() {
            return Err(PtyError::InvalidConfig("argv is empty".into()));
        }
        Ok(argv
            .iter()
            .map(|arg| quote_arg(arg))
            .collect::<Vec<_>>()
            .join(" "))
    }

    /// Per-stream byte sink. Stores up to `cap` bytes, then keeps draining
    /// and discarding so the child never blocks on a full pipe.
    struct CappedSink {
        buf: Vec<u8>,
        cap: usize,
        truncated: bool,
    }

    impl CappedSink {
        fn new(cap: usize) -> Self {
            Self {
                buf: Vec::new(),
                cap,
                truncated: false,
            }
        }

        fn push(&mut self, chunk: &[u8]) {
            let room = self.cap.saturating_sub(self.buf.len());
            let keep = room.min(chunk.len());
            self.buf.extend_from_slice(&chunk[..keep]);
            if keep < chunk.len() {
                self.truncated = true;
            }
        }
    }

    fn lock_sink(sink: &Mutex<CappedSink>) -> std::sync::MutexGuard<'_, CappedSink> {
        sink.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    /// Anonymous pipe with an inheritable write end and a private read end:
    /// the child inherits the side it writes to, the parent keeps the side
    /// it reads from. Returns `(read, write)`.
    fn output_pipe() -> Result<(OwnedHandle, OwnedHandle)> {
        unsafe {
            let sa = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: std::ptr::null_mut(),
                bInheritHandle: 1,
            };
            let mut read: HANDLE = std::ptr::null_mut();
            let mut write: HANDLE = std::ptr::null_mut();
            if CreatePipe(&mut read, &mut write, &sa, 0) == 0 {
                return Err(last_error("CreatePipe"));
            }
            // The read end stays ours. Without this the child would inherit
            // it and EOF would never arrive.
            if SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0) == 0 {
                CloseHandle(read);
                CloseHandle(write);
                return Err(last_error("SetHandleInformation"));
            }
            Ok((OwnedHandle::new(read), OwnedHandle::new(write)))
        }
    }

    /// Stdin pipe with an inheritable read end (the child stdin) and a
    /// private write end (the feeder thread). Returns `(read, write)`.
    fn stdin_pipe() -> Result<(OwnedHandle, OwnedHandle)> {
        unsafe {
            let sa = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: std::ptr::null_mut(),
                bInheritHandle: 1,
            };
            let mut read: HANDLE = std::ptr::null_mut();
            let mut write: HANDLE = std::ptr::null_mut();
            if CreatePipe(&mut read, &mut write, &sa, 0) == 0 {
                return Err(last_error("CreatePipe stdin"));
            }
            if SetHandleInformation(write, HANDLE_FLAG_INHERIT, 0) == 0 {
                CloseHandle(read);
                CloseHandle(write);
                return Err(last_error("SetHandleInformation stdin"));
            }
            Ok((OwnedHandle::new(read), OwnedHandle::new(write)))
        }
    }

    fn kill_on_close_job() -> Result<OwnedHandle> {
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
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
                return Err(last_error("SetInformationJobObject"));
            }
            Ok(OwnedHandle::new(job))
        }
    }

    struct Inner {
        job: OwnedHandle,
        process: OwnedHandle,
        pid: u32,
        stdout_sink: Arc<Mutex<CappedSink>>,
        stderr_sink: Arc<Mutex<CappedSink>>,
        stdout_pump: Option<JoinHandle<()>>,
        stderr_pump: Option<JoinHandle<()>>,
        stdin_writer: Option<JoinHandle<()>>,
        exit_code: AtomicU32,
        exited: AtomicBool,
    }

    impl Drop for Inner {
        fn drop(&mut self) {
            // Tree kill first: it releases a writer blocked on a full stdin
            // pipe and lets both pumps see EOF. Both steps are idempotent.
            unsafe { TerminateJobObject(self.job.raw(), 1) };
            if let Some(writer) = self.stdin_writer.take() {
                let _ = writer.join();
            }
            if let Some(pump) = self.stdout_pump.take() {
                let _ = pump.join();
            }
            if let Some(pump) = self.stderr_pump.take() {
                let _ = pump.join();
            }
        }
    }

    /// Drain one pipe into its sink until EOF or error. Never blocks on the
    /// sink: past the cap, bytes are discarded but the drain continues.
    fn pump_stream(mut file: File, sink: Arc<Mutex<CappedSink>>) {
        let mut buffer = vec![0u8; PUMP_CHUNK_BYTES];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => lock_sink(&sink).push(&buffer[..n]),
                Err(_) => break,
            }
        }
    }

    /// Write the input once, then drop the `File` so the child sees EOF. The
    /// child may exit early; a broken pipe then is the expected outcome, not
    /// an error worth propagating.
    fn write_stdin(mut file: File, bytes: Vec<u8>) {
        use std::io::Write;
        let _ = file.write_all(&bytes);
        let _ = file.flush();
    }

    /// One non-interactive child plus its job object.
    ///
    /// Dropping it kills the job, then joins the writer and pump threads.
    pub struct PlainChild {
        inner: Inner,
    }

    impl PlainChild {
        /// Spawn `argv` with stdout and stderr on separate pipes, stdin
        /// closed or fed from [`PlainConfig::input`], attached to a fresh job
        /// object. No ConPTY, no console window.
        pub fn spawn(config: PlainConfig) -> Result<Self> {
            let PlainConfig {
                argv,
                working_dir,
                env,
                input,
                output_cap_bytes,
            } = config;
            let command_line_text = command_line(&argv)?;
            let mut command_line_wide = wide(&command_line_text);
            let working_dir_wide: Option<Vec<u16>> =
                working_dir.as_ref().map(|dir| wide(&dir.to_string_lossy()));
            let env_block = environment_block(&env);
            let cap = output_cap_bytes.clamp(1, MAX_PLAIN_OUTPUT_CAP_BYTES);

            unsafe {
                let (mut stdout_read, mut stdout_write) = output_pipe()?;
                let (mut stderr_read, mut stderr_write) = output_pipe()?;
                let stdin_pair: Option<(OwnedHandle, OwnedHandle)> = if input.is_some() {
                    Some(stdin_pipe()?)
                } else {
                    None
                };

                // Kill on close is what makes drop a tree kill.
                let job = kill_on_close_job()?;

                let mut startup: STARTUPINFOW = std::mem::zeroed();
                startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
                startup.dwFlags = STARTF_USESTDHANDLES;
                startup.hStdInput = stdin_pair
                    .as_ref()
                    .map_or(std::ptr::null_mut(), |(read, _)| read.raw());
                startup.hStdOutput = stdout_write.raw();
                startup.hStdError = stderr_write.raw();

                let mut process_info: PROCESS_INFORMATION = std::mem::zeroed();
                let cwd_ptr = working_dir_wide
                    .as_ref()
                    .map_or(std::ptr::null(), |wide| wide.as_ptr());
                let created = CreateProcessW(
                    std::ptr::null(),
                    command_line_wide.as_mut_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    1,
                    CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
                    env_block.as_ptr() as *const core::ffi::c_void,
                    cwd_ptr,
                    &startup,
                    &mut process_info,
                );
                if created == 0 {
                    return Err(last_error("CreateProcessW"));
                }
                if !process_info.hThread.is_null() {
                    CloseHandle(process_info.hThread);
                }
                let process = OwnedHandle::new(process_info.hProcess);
                let pid = process_info.dwProcessId;

                // Parent copies of the child ends. Closing them is what lets
                // the pumps see EOF; from here the read ends belong to Files.
                // No handle is closed twice: child ends close here, read ends
                // transfer into Files via detach below.
                stdout_write.close();
                stderr_write.close();
                let mut stdin_write: Option<OwnedHandle> = None;
                if let Some((mut stdin_read, write)) = stdin_pair {
                    stdin_read.close();
                    stdin_write = Some(write);
                }

                // Join the job. Descendants inherit membership: the tree kill.
                if AssignProcessToJobObject(job.raw(), process.raw()) == 0 {
                    let err = last_error("AssignProcessToJobObject");
                    TerminateProcess(process.raw(), 1);
                    return Err(err);
                }

                // Stdin writer first: if it fails to spawn, no pumps exist yet
                // and the job handle dropping still ends the tree.
                let stdin_writer: Option<JoinHandle<()>> = match (input, stdin_write) {
                    (Some(bytes), Some(mut write)) => {
                        let file = File::from_raw_handle(write.detach() as _);
                        match std::thread::Builder::new()
                            .name("calcar-plain-stdin".into())
                            .spawn(move || write_stdin(file, bytes))
                        {
                            Ok(handle) => Some(handle),
                            Err(e) => {
                                TerminateJobObject(job.raw(), 1);
                                return Err(PtyError::Io(e));
                            }
                        }
                    }
                    _ => None,
                };

                let stdout_sink = Arc::new(Mutex::new(CappedSink::new(cap)));
                let stderr_sink = Arc::new(Mutex::new(CappedSink::new(cap)));
                let stdout_file = File::from_raw_handle(stdout_read.detach() as _);
                let stderr_file = File::from_raw_handle(stderr_read.detach() as _);

                let stdout_pump = {
                    let sink = Arc::clone(&stdout_sink);
                    match std::thread::Builder::new()
                        .name("calcar-plain-pump-stdout".into())
                        .spawn(move || pump_stream(stdout_file, sink))
                    {
                        Ok(handle) => handle,
                        Err(e) => {
                            // The failed closure drops its File, closing that
                            // read end. Terminate the tree; the job and
                            // process handles close on return.
                            TerminateJobObject(job.raw(), 1);
                            return Err(PtyError::Io(e));
                        }
                    }
                };
                let stderr_pump = {
                    let sink = Arc::clone(&stderr_sink);
                    match std::thread::Builder::new()
                        .name("calcar-plain-pump-stderr".into())
                        .spawn(move || pump_stream(stderr_file, sink))
                    {
                        Ok(handle) => handle,
                        Err(e) => {
                            TerminateJobObject(job.raw(), 1);
                            return Err(PtyError::Io(e));
                        }
                    }
                };

                Ok(PlainChild {
                    inner: Inner {
                        job,
                        process,
                        pid,
                        stdout_sink,
                        stderr_sink,
                        stdout_pump: Some(stdout_pump),
                        stderr_pump: Some(stderr_pump),
                        stdin_writer,
                        exit_code: AtomicU32::new(0),
                        exited: AtomicBool::new(false),
                    },
                })
            }
        }

        pub fn pid(&self) -> u32 {
            self.inner.pid
        }

        /// Kill the whole job. Descendants included, by job membership.
        /// Idempotent.
        pub fn kill(&self) -> Result<()> {
            unsafe { TerminateJobObject(self.inner.job.raw(), 1) };
            Ok(())
        }

        /// Wait for exit. `Ok(None)` means the deadline passed first.
        pub fn wait(&self, timeout: Option<Duration>) -> Result<Option<u32>> {
            if self.inner.exited.load(Ordering::SeqCst) {
                return Ok(Some(self.inner.exit_code.load(Ordering::SeqCst)));
            }
            let millis = match timeout {
                None => u32::MAX,
                Some(duration) => duration.as_millis().min(u32::MAX as u128) as u32,
            };
            let waited = unsafe { WaitForSingleObject(self.inner.process.raw(), millis) };
            if waited == WAIT_TIMEOUT {
                return Ok(None);
            }
            if waited != WAIT_OBJECT_0 {
                return Err(last_error("WaitForSingleObject"));
            }
            let mut code: u32 = 0;
            if unsafe { GetExitCodeProcess(self.inner.process.raw(), &mut code) } == 0 {
                return Err(last_error("GetExitCodeProcess"));
            }
            self.inner.exit_code.store(code, Ordering::SeqCst);
            self.inner.exited.store(true, Ordering::SeqCst);
            Ok(Some(code))
        }

        /// Cached exit code. `None` while the child is still running.
        pub fn exit_code(&self) -> Option<u32> {
            self.inner
                .exited
                .load(Ordering::SeqCst)
                .then(|| self.inner.exit_code.load(Ordering::SeqCst))
        }

        /// True once either stream exceeded the cap.
        pub fn truncated(&self) -> bool {
            lock_sink(&self.inner.stdout_sink).truncated
                || lock_sink(&self.inner.stderr_sink).truncated
        }

        /// Non-blocking snapshot of what the pumps collected so far.
        pub fn snapshot(&self) -> PlainOutput {
            let stdout_guard = lock_sink(&self.inner.stdout_sink);
            let stderr_guard = lock_sink(&self.inner.stderr_sink);
            PlainOutput {
                stdout: stdout_guard.buf.clone(),
                stderr: stderr_guard.buf.clone(),
                exit_code: self.exit_code(),
                truncated: stdout_guard.truncated || stderr_guard.truncated,
            }
        }

        /// Wait for the process, drain both pumps, and return the bounded
        /// output. Typical flow: `wait(deadline)`; on `None` call `kill()`;
        /// then `join()` to collect. `pump_grace` bounds how long `join`
        /// waits for inherited pipe ends (a grandchild that outlived the
        /// direct child) before killing the job and draining anyway.
        pub fn join(mut self, pump_grace: Duration) -> Result<PlainOutput> {
            let code = self.wait(None)?.unwrap_or(1);
            let deadline = Instant::now() + pump_grace;
            loop {
                let stdout_done = self
                    .inner
                    .stdout_pump
                    .as_ref()
                    .is_none_or(|pump| pump.is_finished());
                let stderr_done = self
                    .inner
                    .stderr_pump
                    .as_ref()
                    .is_none_or(|pump| pump.is_finished());
                if stdout_done && stderr_done {
                    break;
                }
                if Instant::now() >= deadline {
                    // A descendant still holds a pipe end. The job kill ends
                    // it, which releases the pumps at EOF.
                    let _ = self.kill();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            if let Some(writer) = self.inner.stdin_writer.take() {
                let _ = writer.join();
            }
            if let Some(pump) = self.inner.stdout_pump.take() {
                let _ = pump.join();
            }
            if let Some(pump) = self.inner.stderr_pump.take() {
                let _ = pump.join();
            }
            let mut output = self.snapshot();
            output.exit_code = Some(code);
            Ok(output)
        }
    }
}

#[cfg(not(windows))]
pub use stub::PlainChild;

/// Windows-only executor surface so adapter code compiles everywhere.
/// `spawn` always fails off Windows.
#[cfg(not(windows))]
mod stub {
    use super::{PlainConfig, PlainOutput};
    use crate::{PtyError, Result};
    use std::time::Duration;

    pub struct PlainChild {
        _private: (),
    }

    impl PlainChild {
        pub fn spawn(_config: PlainConfig) -> Result<Self> {
            Err(PtyError::InvalidConfig(
                "plain pipe executor requires Windows".into(),
            ))
        }

        pub fn pid(&self) -> u32 {
            0
        }

        pub fn kill(&self) -> Result<()> {
            Err(PtyError::Closed)
        }

        pub fn wait(&self, _timeout: Option<Duration>) -> Result<Option<u32>> {
            Err(PtyError::Closed)
        }

        pub fn exit_code(&self) -> Option<u32> {
            None
        }

        pub fn truncated(&self) -> bool {
            false
        }

        pub fn snapshot(&self) -> PlainOutput {
            PlainOutput {
                stdout: Vec::new(),
                stderr: Vec::new(),
                exit_code: None,
                truncated: false,
            }
        }

        pub fn join(self, _pump_grace: Duration) -> Result<PlainOutput> {
            Err(PtyError::Closed)
        }
    }
}
