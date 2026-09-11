//! Environment/config helpers and the RPC unix-socket path, shared by
//! both background workers.

use crate::{DEFAULT_DB, DEFAULT_HTTP_ADDR};
use pgrx::prelude::*;
use std::ffi::CStr;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub(crate) fn env_opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

pub(crate) fn configured_database() -> String {
    env_opt("ALLGRES_DATABASE").unwrap_or_else(|| DEFAULT_DB.to_string())
}

pub(crate) fn configured_http_addr() -> String {
    env_opt("ALLGRES_HTTP_ADDR").unwrap_or_else(|| DEFAULT_HTTP_ADDR.to_string())
}

/// `DataDir` is set by the postmaster before any background worker is forked,
/// so both workers derive the same path without needing SPI.
fn data_directory() -> Option<PathBuf> {
    let ptr = unsafe { *(&raw const pg_sys::DataDir) };
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr) }.to_str().ok()?;
    (!s.is_empty()).then(|| PathBuf::from(s))
}

/// A 0700 directory, instance-private.  The RPC socket used to live at a fixed
/// `/tmp` path with default permissions, which let any local user call
/// `dashboard_rpc` and bypass the dashboard token entirely.
pub(crate) fn socket_dir() -> PathBuf {
    if let Some(dir) = env_opt("ALLGRES_SOCKET_DIR") {
        return PathBuf::from(dir);
    }
    match data_directory() {
        Some(base) => base.join("allgres"),
        None => std::env::temp_dir().join("allgres"),
    }
}

pub(crate) fn rpc_socket_path() -> PathBuf {
    socket_dir().join("runtime.sock")
}

fn ensure_socket_dir(dir: &Path) -> std::io::Result<()> {
    if !dir.exists() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    let meta = fs::metadata(dir)?;
    if !meta.is_dir() {
        return Err(std::io::Error::other(format!(
            "{} exists and is not a directory",
            dir.display()
        )));
    }
    // Tighten an inherited or pre-created directory rather than trusting it.
    if meta.permissions().mode() & 0o077 != 0 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

pub(crate) fn bind_rpc_socket() -> std::io::Result<UnixListener> {
    let dir = socket_dir();
    ensure_socket_dir(&dir)?;
    let path = dir.join("runtime.sock");
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}
