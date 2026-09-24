
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashMap, io::Read, time::Duration};

#[derive(Deserialize)]
pub struct Request { url: String, method: String, headers: HashMap<String, String>, body: String }
fn checked_url(value: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(value).map_err(|_| "Invalid WebDAV URL")?;
    if url.scheme() != "https" || url.host_str().is_none() || !url.username().is_empty() ||
        url.password().is_some() || url.query().is_some() || url.fragment().is_some() {
        return Err("WebDAV requires HTTPS without credentials in the URL".into());
    }
    Ok(url)
}
#[tauri::command]
pub async fn webdav_request(request: Request) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || perform_request(request))
        .await.map_err(|_| "WebDAV worker failed".to_string())?
}
fn perform_request(request: Request) -> Result<Value, String> {
    if !["GET", "HEAD", "PUT", "PROPFIND", "MKCOL"].contains(&request.method.as_str()) {
        return Err("Unsupported WebDAV method".into());
    }
    let url = checked_url(&request.url)?;
    let method = reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|_| "Invalid method")?;
    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none()).timeout(Duration::from_secs(90))
        .build().map_err(|_| "Unable to create WebDAV client")?;
    let mut builder = client.request(method, url);
    for (key, value) in request.headers {
        if !["authorization", "content-type", "depth", "if-match", "if-none-match"]
            .contains(&key.to_lowercase().as_str()) { return Err("Unsupported WebDAV header".into()); }
        builder = builder.header(key, value);
    }
    let body = STANDARD.decode(request.body).map_err(|_| "Invalid request data")?;
    if body.len() > 128 * 1024 * 1024 { return Err("Upload exceeds 128 MiB".into()); }
    let response = builder.body(body).send().map_err(|_| "WebDAV connection failed")?;
    let status = response.status().as_u16();
    let etag = response.headers().get("etag").and_then(|v| v.to_str().ok()).map(str::to_string);
    let mut body = Vec::new();
    response.take(128 * 1024 * 1024 + 1).read_to_end(&mut body).map_err(|_| "Unable to read WebDAV response")?;
    if body.len() > 128 * 1024 * 1024 { return Err("Response exceeds 128 MiB".into()); }
    Ok(json!({"status": status, "etag": etag, "body": STANDARD.encode(body)}))
}
#[derive(Deserialize)]
pub struct StateKey { key: String }
#[derive(Deserialize)]
pub struct StateValue { key: String, value: String }
fn check_key(key: &str) -> Result<(), String> {
    if key.is_empty() || key.len() > 100 || !key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-') {
        return Err("Invalid sync state key".into());
    }
    Ok(())
}
fn state_db() -> Result<rusqlite::Connection, String> {
    let dirs = crate::storage::ensure_data_dirs()?;
    let db = rusqlite::Connection::open(dirs.data_dir.join("webdav-sync.sqlite")).map_err(|_| "Unable to open sync state")?;
    db.execute("CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)", [])
        .map_err(|_| "Unable to initialize sync state")?;
    Ok(db)
}
#[tauri::command]
pub fn webdav_read_state(request: StateKey) -> Result<Value, String> {
    use rusqlite::OptionalExtension;
    check_key(&request.key)?;
    let value: Option<String> = state_db()?.query_row(
        "SELECT value FROM sync_state WHERE key = ?1", [&request.key], |row| row.get(0),
    ).optional().map_err(|_| "Unable to read sync state")?;
    Ok(json!({"value": value}))
}
#[tauri::command]
pub fn webdav_write_state(request: StateValue) -> Result<Value, String> {
    check_key(&request.key)?;
    state_db()?.execute("INSERT INTO sync_state (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [&request.key, &request.value]).map_err(|_| "Unable to save sync state")?;
    Ok(json!({}))
}
#[cfg(any(target_os = "windows", target_os = "macos"))]
fn credential(key: &str) -> Result<keyring::Entry, String> {
    check_key(key)?;
    keyring::Entry::new("ProjectTabi-WebDAV", key).map_err(|_| "Unable to open system credential store".into())
}
#[tauri::command]
pub fn webdav_read_password(request: StateKey) -> Result<Value, String> {
    check_key(&request.key)?;
    #[cfg(any(target_os = "windows", target_os = "macos"))]
    {
        match credential(&request.key)?.get_password() {
            Ok(value) => Ok(json!({"value": value})),
            Err(keyring::Error::NoEntry) => Ok(json!({"value": null})),
            Err(_) => Err("Unable to read system credential store".into()),
        }
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    Ok(json!({"value": null}))
}
#[tauri::command]
pub fn webdav_write_password(request: StateValue) -> Result<Value, String> {
    check_key(&request.key)?;
    #[cfg(any(target_os = "windows", target_os = "macos"))]
    {
        let entry = credential(&request.key)?;
        let result = if request.value.is_empty() { entry.delete_credential() } else { entry.set_password(&request.value) };
        match result {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(json!({})),
            Err(_) => Err("Unable to save system credential store".into()),
        }
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    { let _ = request.value; Err("Secure storage is supported on Windows and macOS".into()) }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_https_and_state_keys() {
        assert!(checked_url("http://example.com/dav/").is_err());
        assert!(checked_url("https://user:secret@example.com/dav/").is_err());
        assert!(checked_url("https://example.com/dav/?token=secret").is_err());
        assert!(checked_url("https://example.com/dav/").is_ok());
        assert!(check_key("../config").is_err());
        assert!(check_key("baseline_0123456789abcdef").is_ok());
    }
}
