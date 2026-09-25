use std::{sync::{Arc, Mutex}, time::Duration};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    supported: bool,
    phase: String,
    version: Option<String>,
    notes: String,
    downloaded: u64,
    total: u64,
    error: Option<String>,
}
impl Default for UpdateView {
    fn default() -> Self {
        Self { supported: cfg!(target_os = "windows"), phase: "idle".into(),
            version: None, notes: String::new(), downloaded: 0, total: 0, error: None }
    }
}

#[derive(Default)]
struct Machine {
    view: UpdateView,
    update: Option<Update>,
    // Only bytes verified by the updater plugin can reach install(). Kept private in memory.
    payload: Option<Vec<u8>>,
    task: Option<tauri::async_runtime::JoinHandle<()>>,
    generation: u64,
}

#[derive(Default)]
pub struct ManagedUpdater(Arc<Mutex<Machine>>);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateRequest { action: String, #[serde(default)] wifi_only: bool }

fn lock(machine: &Arc<Mutex<Machine>>) -> std::sync::MutexGuard<'_, Machine> {
    machine.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(target_os = "windows")]
fn on_wifi() -> bool {
    use windows::Networking::Connectivity::NetworkInformation;
    NetworkInformation::GetInternetConnectionProfile()
        .and_then(|profile| profile.IsWlanConnectionProfile())
        .unwrap_or(false)
}
#[cfg(not(target_os = "windows"))]
fn on_wifi() -> bool { false }

fn fail(machine: &Arc<Mutex<Machine>>, message: &str) {
    let mut m = lock(machine);
    m.view.phase = if m.payload.is_some() { "ready" } else { "error" }.into();
    m.view.error = Some(message.into());
}

fn start_download(machine: Arc<Mutex<Machine>>, wifi_only: bool) {
    let (update, generation) = {
        let mut m = lock(&machine);
        if matches!(m.view.phase.as_str(), "downloading" | "checking" | "verifying" | "ready" | "installing") { return; }
        let Some(update) = m.update.clone() else {
            m.view.error = Some("请先检查更新。".into());
            return;
        };
        if wifi_only && !on_wifi() {
            m.view.phase = "waiting".into();
            return;
        }
        m.generation += 1;
        m.view.phase = "downloading".into();
        m.view.error = None;
        m.view.downloaded = 0;
        m.payload = None;
        (update, m.generation)
    };
    let progress_machine = machine.clone();
    let finish_machine = machine.clone();
    let task_machine = machine.clone();
    let task = tauri::async_runtime::spawn(async move {
        let mut update = update;
        update.timeout = Some(Duration::from_secs(1800));
        let bytes = update.download(move |chunk, total| {
            if wifi_only && !on_wifi() {
                let mut m = lock(&progress_machine);
                if m.generation == generation {
                    m.generation += 1;
                    m.view.phase = "waiting".into();
                    if let Some(task) = m.task.take() { task.abort(); }
                }
                return;
            }
            let mut m = lock(&progress_machine);
            if m.generation == generation {
                m.view.downloaded += chunk as u64;
                if let Some(total) = total { m.view.total = total; }
            }
        }, move || {
            let mut m = lock(&finish_machine);
            if m.generation == generation { m.view.phase = "verifying".into(); }
        }).await;
        let mut m = lock(&task_machine);
        if m.generation != generation { return; }
        match bytes {
            Ok(bytes) => {
                m.view.total = bytes.len() as u64;
                m.view.downloaded = bytes.len() as u64;
                m.payload = Some(bytes);
                m.view.phase = "ready".into();
            }
            Err(error) => {
                crate::startup_log::write(&format!("updater download/verify failed: {error}"));
                m.view.phase = "error".into();
                m.view.error = Some("下载或签名校验失败，已停止更新。请检查网络后重试，或从官方发布页面下载。".into());
            }
        }
    });
    lock(&machine).task = Some(task);
}

#[tauri::command]
pub async fn updater_command(app: AppHandle, state: State<'_, ManagedUpdater>, request: UpdateRequest) -> Result<UpdateView, String> {
    let machine = state.0.clone();
    if !cfg!(target_os = "windows") { return Ok(lock(&machine).view.clone()); }
    match request.action.as_str() {
        "status" => {
            let waiting = lock(&machine).view.phase == "waiting";
            if waiting { start_download(machine.clone(), true); }
        }
        "check" => {
            {
                let mut m = lock(&machine);
                if matches!(m.view.phase.as_str(), "checking" | "downloading" | "verifying" | "waiting" | "ready" | "installing") {
                    return Ok(m.view.clone());
                }
                m.view.phase = "checking".into();
                m.view.error = None;
            }
            let result = async {
                // SemVer normally ignores +build. ProjectTabi also supports same-version revisions.
                app.updater_builder()
                    .timeout(Duration::from_secs(25))
                    .version_comparator(|current, remote| {
                        let incoming = remote.version;
                        let new_core = (incoming.major, incoming.minor, incoming.patch);
                        let old_core = (current.major, current.minor, current.patch);
                        incoming.pre.is_empty() && (new_core > old_core ||
                            (new_core == old_core && incoming.build.as_str().parse::<u64>().unwrap_or(0) > current.build.as_str().parse::<u64>().unwrap_or(0)))
                    })
                    .build()?.check().await
            }.await;
            match result {
                Ok(Some(update)) => {
                    let url = &update.download_url;
                    if url.scheme() != "https" || url.host_str() != Some("github.com") ||
                        !url.path().starts_with("/Ch1Zume/ProjectTabi/releases/download/") {
                        fail(&machine, "更新地址校验失败，请使用官方发布页面下载。");
                    } else {
                        let mut m = lock(&machine);
                        m.view.version = Some(update.version.clone());
                        m.view.notes = update.body.clone().unwrap_or_default();
                        m.view.total = update.raw_json.pointer("/platforms/windows-x86_64/size").and_then(|v| v.as_u64()).unwrap_or(0);
                        m.view.downloaded = 0;
                        m.view.phase = "available".into();
                        m.update = Some(update);
                        m.payload = None;
                    }
                }
                Ok(None) => {
                    let mut m = lock(&machine);
                    m.view = UpdateView { phase: "current".into(), ..UpdateView::default() };
                    m.update = None;
                    m.payload = None;
                }
                Err(error) => {
                    crate::startup_log::write(&format!("updater check failed: {error}"));
                    fail(&machine, "无法获取更新信息，请检查网络连接后重试，或使用手动下载。");
                }
            }
        }
        "download" => start_download(machine.clone(), request.wifi_only),
        "cancel" => {
            let mut m = lock(&machine);
            if m.view.phase == "installing" { return Ok(m.view.clone()); }
            m.generation += 1;
            if let Some(task) = m.task.take() { task.abort(); }
            m.payload = None;
            m.view.downloaded = 0;
            m.view.error = None;
            m.view.phase = if m.update.is_some() { "available" } else { "idle" }.into();
        }
        "install" => {
            let pending = {
                let mut m = lock(&machine);
                if m.view.phase != "ready" { return Err("请先完成更新包下载和校验。".into()); }
                let update = m.update.clone().ok_or("请重新检查更新。")?;
                let bytes = m.payload.take().ok_or("安装包已失效，请重新下载。")?;
                m.view.phase = "installing".into();
                (update, bytes)
            };
            // The plugin exits only after successfully launching the signed installer.
            let (update, bytes) = pending;
            if let Err(error) = update.install(&bytes) {
                crate::startup_log::write(&format!("updater install failed: {error}"));
                lock(&machine).payload = Some(bytes);
                fail(&machine, "无法启动更新安装程序，请检查系统权限后重试，或使用手动下载。");
            }
        }
        _ => return Err("无法识别更新操作。".into()),
    }
    let view = lock(&machine).view.clone();
    Ok(view)
}
