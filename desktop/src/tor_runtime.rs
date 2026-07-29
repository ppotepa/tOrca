use anyhow::{Context, Result, bail};
use std::{
    fs,
    io::{BufRead, BufReader},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Debug)]
pub struct TorStatus {
    pub phase: String,
    pub label: String,
    pub detail: String,
    pub progress: i32,
    #[cfg(test)]
    pub latency_ms: Option<u64>,
    #[cfg(test)]
    pub retry_attempt: u32,
}

pub struct TorRuntime {
    child: Option<Arc<Mutex<Child>>>,
    socks_url: String,
    #[cfg(test)]
    ready: Arc<AtomicBool>,
}

impl TorRuntime {
    pub fn external(socks_url: String) -> (Self, mpsc::Receiver<TorStatus>) {
        let (tx, rx) = mpsc::channel();
        let _ = tx.send(TorStatus {
            phase: "external".into(),
            label: "External Tor SOCKS".into(),
            detail: "External Tor SOCKS".into(),
            progress: 70,
            #[cfg(test)]
            latency_ms: None,
            #[cfg(test)]
            retry_attempt: 0,
        });
        (
            Self {
                child: None,
                socks_url,
                #[cfg(test)]
                ready: Arc::new(AtomicBool::new(true)),
            },
            rx,
        )
    }

    pub fn start(binary: &Path, data_dir: &Path) -> Result<(Self, mpsc::Receiver<TorStatus>)> {
        if !binary.is_file() {
            bail!("Tor binary not found: {}", binary.display())
        }
        fs::create_dir_all(data_dir).context("create Tor data directory")?;
        let socks_port = free_port()?;
        let control_port = free_port()?;
        let torrc = data_dir.join("torrc.generated");
        let bundle_root = binary
            .parent()
            .and_then(Path::parent)
            .unwrap_or_else(|| Path::new("."));
        let geoip = bundle_root.join("data").join("geoip");
        let geoip6 = bundle_root.join("data").join("geoip6");
        let geoip_config = if geoip.is_file() && geoip6.is_file() {
            format!(
                "GeoIPFile {}\nGeoIPv6File {}\n",
                tor_path(&geoip),
                tor_path(&geoip6)
            )
        } else {
            String::new()
        };
        #[cfg(windows)]
        let owner_config = format!("__OwningControllerProcess {}\n", std::process::id());
        #[cfg(not(windows))]
        let owner_config = String::new();
        fs::write(
            &torrc,
            format!(
                "DataDirectory {}\n{}{}SocksPort 127.0.0.1:{socks_port}\nControlPort 127.0.0.1:{control_port}\nCookieAuthentication 1\nLog notice stdout\n",
                tor_path(data_dir),
                geoip_config,
                owner_config,
            ),
        )
        .context("write generated torrc")?;

        let mut command = Command::new(binary);
        command
            .arg("-f")
            .arg(&torrc)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let mut child = command.spawn().context("start embedded Tor")?;
        let stdout = child.stdout.take().context("capture Tor output")?;
        let stderr = child.stderr.take().context("capture Tor errors")?;
        let child = Arc::new(Mutex::new(child));
        let (tx, rx) = mpsc::channel();
        #[cfg(test)]
        let ready = Arc::new(AtomicBool::new(false));
        let _ = tx.send(TorStatus {
            phase: "starting".into(),
            label: "Starting Tor".into(),
            detail: "Starting Tor".into(),
            progress: 0,
            #[cfg(test)]
            latency_ms: None,
            #[cfg(test)]
            retry_attempt: 0,
        });

        let status_tx = tx.clone();
        #[cfg(test)]
        let status_ready = ready.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(progress) = bootstrap_progress(&line) {
                    #[cfg(test)]
                    if progress >= 100 {
                        status_ready.store(true, Ordering::Release);
                    }
                    let _ = status_tx.send(TorStatus {
                        phase: if progress >= 100 {
                            "ready".into()
                        } else {
                            "bootstrapping".into()
                        },
                        label: if progress >= 100 {
                            "Tor ready, connecting to onion".into()
                        } else {
                            format!("Bootstrap Tor: {progress}%")
                        },
                        detail: if progress >= 100 {
                            "Tor ready, connecting to onion".into()
                        } else {
                            format!("Bootstrap Tor: {progress}%")
                        },
                        progress: progress.clamp(0, 100) * 70 / 100,
                        #[cfg(test)]
                        latency_ms: None,
                        #[cfg(test)]
                        retry_attempt: 0,
                    });
                }
            }
        });
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                let lowered = line.to_ascii_lowercase();
                if lowered.contains("[err]") || lowered.contains("[warn]") {
                    let _ = tx.send(TorStatus {
                        phase: "warning".into(),
                        label: line,
                        detail: String::new(),
                        progress: 0,
                        #[cfg(test)]
                        latency_ms: None,
                        #[cfg(test)]
                        retry_attempt: 0,
                    });
                }
            }
        });

        Ok((
            Self {
                child: Some(child),
                socks_url: format!("socks5h://127.0.0.1:{socks_port}"),
                #[cfg(test)]
                ready,
            },
            rx,
        ))
    }

    pub fn socks_url(&self) -> &str {
        &self.socks_url
    }

    #[cfg(test)]
    pub fn readiness(&self) -> Arc<AtomicBool> {
        self.ready.clone()
    }
}

impl Drop for TorRuntime {
    fn drop(&mut self) {
        if let Some(child) = &self.child
            && let Ok(mut child) = child.lock()
        {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn free_port() -> Result<u16> {
    Ok(TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())
}

fn bootstrap_progress(line: &str) -> Option<i32> {
    let start = line.find("Bootstrapped ")? + "Bootstrapped ".len();
    let end = line[start..].find('%')? + start;
    line[start..end].parse().ok()
}

fn tor_path(path: &Path) -> String {
    let value: PathBuf = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    format!("\"{}\"", value.to_string_lossy().replace('\\', "/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bootstrap_progress() {
        assert_eq!(
            bootstrap_progress("[notice] Bootstrapped 45% (requesting_descriptors)"),
            Some(45)
        );
        assert_eq!(bootstrap_progress("unrelated"), None);
    }
}
