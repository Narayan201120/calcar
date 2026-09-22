//! Doctor checks. PLAN P4 slice 1: OS version, ConPTY, DPAPI round trip,
//! storage migrate, bind check. Gate requires all of them green on a clean
//! Win10 and Win11 machine.

use calcar_storage::Storage;
use std::net::TcpListener;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub checks: Vec<Check>,
}

impl Report {
    pub fn all_ok(&self) -> bool {
        self.checks.iter().all(|check| check.ok)
    }
}

pub fn run() -> Result<Report, String> {
    Ok(Report {
        checks: vec![
            os_check(),
            conpty_check(),
            dpapi_check(),
            migrate_check(),
            bind_check(),
        ],
    })
}

fn os_check() -> Check {
    // Read the real product name and build from the registry. GetVersionExW
    // lies without a manifest, and the doctor must not.
    #[cfg(windows)]
    {
        use winreg::enums::HKEY_LOCAL_MACHINE;
        use winreg::RegKey;
        let current = RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
        match current {
            Ok(key) => {
                let product: String = key
                    .get_value("ProductName")
                    .unwrap_or_else(|_| "Windows".to_string());
                let build: String = key
                    .get_value("CurrentBuildNumber")
                    .unwrap_or_else(|_| "?".to_string());
                Check {
                    name: "os",
                    ok: true,
                    detail: format!("{product}, build {build}"),
                }
            }
            Err(error) => Check {
                name: "os",
                ok: false,
                detail: format!("registry read failed: {error}"),
            },
        }
    }
    #[cfg(not(windows))]
    {
        Check {
            name: "os",
            ok: false,
            detail: format!("platform {} is not Windows", std::env::consts::OS),
        }
    }
}

#[cfg(windows)]
fn conpty_check() -> Check {
    // Prove ConPTY works by creating one and closing it. A DLL existing proves
    // nothing; creation proves the gate. Handles are always cleaned up.
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError};
    use windows_sys::Win32::System::Console::{
        ClosePseudoConsole, CreatePseudoConsole, COORD, HPCON,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;

    unsafe {
        let mut conpty_read: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut conpty_write: *mut core::ffi::c_void = std::ptr::null_mut();
        if CreatePipe(&mut conpty_read, &mut conpty_write, std::ptr::null(), 0) == 0 {
            return Check {
                name: "conpty",
                ok: false,
                detail: format!(
                    "input pipe creation failed, GetLastError={}",
                    GetLastError()
                ),
            };
        }
        let mut out_read: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut out_write: *mut core::ffi::c_void = std::ptr::null_mut();
        if CreatePipe(&mut out_read, &mut out_write, std::ptr::null(), 0) == 0 {
            CloseHandle(conpty_read);
            CloseHandle(conpty_write);
            return Check {
                name: "conpty",
                ok: false,
                detail: format!(
                    "output pipe creation failed, GetLastError={}",
                    GetLastError()
                ),
            };
        }
        let mut hpcon: HPCON = 0;
        // CreatePseudoConsole returns an HRESULT, not a BOOL: 0 is S_OK.
        let created = CreatePseudoConsole(
            COORD { X: 120, Y: 30 },
            conpty_read,
            out_write,
            0,
            &mut hpcon,
        );
        // The conpty keeps its ends; the probe owns all four pipe handles.
        CloseHandle(conpty_read);
        CloseHandle(conpty_write);
        CloseHandle(out_read);
        CloseHandle(out_write);
        if created != 0 {
            return Check {
                name: "conpty",
                ok: false,
                detail: format!(
                    "CreatePseudoConsole failed, HRESULT 0x{:08X}",
                    created as u32
                ),
            };
        }
        ClosePseudoConsole(hpcon);
        Check {
            name: "conpty",
            ok: true,
            detail: "created and closed a 120x30 pseudo console".into(),
        }
    }
}

#[cfg(not(windows))]
fn conpty_check() -> Check {
    Check {
        name: "conpty",
        ok: false,
        detail: format!(
            "ConPTY is Windows only, platform is {}",
            std::env::consts::OS
        ),
    }
}

#[cfg(windows)]
fn dpapi_check() -> Check {
    // Round trip a fixed secret through CryptProtectData and CryptUnprotectData
    // in memory only. Proves the DPAPI boundary the agent needs for key sealing.
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    const SECRET: &[u8] = b"calcar-doctor-dpapi-probe";

    unsafe {
        let input = CRYPT_INTEGER_BLOB {
            cbData: SECRET.len() as u32,
            pbData: SECRET.as_ptr() as *mut u8,
        };
        let mut encrypted = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        let protected = CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut encrypted,
        );
        if protected == 0 {
            return Check {
                name: "dpapi",
                ok: false,
                detail: "CryptProtectData failed".into(),
            };
        }
        let mut decrypted = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        let unprotected = CryptUnprotectData(
            &encrypted,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null(),
            0,
            &mut decrypted,
        );
        let round_trip = unprotected != 0
            && decrypted.cbData == SECRET.len() as u32
            && !decrypted.pbData.is_null()
            && std::slice::from_raw_parts(decrypted.pbData, decrypted.cbData as usize) == SECRET;
        // The returned blob is the caller's to free.
        if !decrypted.pbData.is_null() {
            LocalFree(decrypted.pbData as _);
        }
        if !encrypted.pbData.is_null() {
            LocalFree(encrypted.pbData as _);
        }
        if round_trip {
            Check {
                name: "dpapi",
                ok: true,
                detail: format!("round trip ok, {} encrypted bytes", encrypted.cbData),
            }
        } else {
            Check {
                name: "dpapi",
                ok: false,
                detail: "CryptUnprotectData output did not match the input".into(),
            }
        }
    }
}

#[cfg(not(windows))]
fn dpapi_check() -> Check {
    Check {
        name: "dpapi",
        ok: false,
        detail: format!(
            "DPAPI is Windows only, platform is {}",
            std::env::consts::OS
        ),
    }
}

fn migrate_check() -> Check {
    match Storage::open_in_memory().and_then(|mut storage| storage.migrate()) {
        Ok(applied) => Check {
            name: "migrate",
            ok: true,
            detail: format!("applied {}", applied.join(", ")),
        },
        Err(error) => Check {
            name: "migrate",
            ok: false,
            detail: error.to_string(),
        },
    }
}

fn bind_check() -> Check {
    match TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => {
            let port = listener.local_addr().map(|addr| addr.port()).unwrap_or(0);
            drop(listener);
            Check {
                name: "bind",
                ok: true,
                detail: format!("ephemeral bind ok, got port {port}"),
            }
        }
        Err(error) => Check {
            name: "bind",
            ok: false,
            detail: error.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrate_check_is_green() {
        let check = migrate_check();
        assert!(check.ok, "migrate check failed: {}", check.detail);
    }

    #[test]
    fn bind_check_is_green() {
        let check = bind_check();
        assert!(check.ok, "bind check failed: {}", check.detail);
    }

    #[test]
    fn os_check_detects_windows() {
        // The gate runs on Windows; on other platforms this check must fail
        // loudly rather than pass vacuously.
        let check = os_check();
        assert_eq!(check.ok, std::env::consts::OS == "windows");
    }
}
