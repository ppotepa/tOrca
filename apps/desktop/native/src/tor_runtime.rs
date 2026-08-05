use anyhow::{Context, Result, bail};
#[cfg(test)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex, mpsc},
};
use torchat_client_engine::TorPhase;

use crate::process_lock::TorDataLock;

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct TorStatus {
    pub phase: TorPhase,
    pub label: String,
    pub detail: String,
    pub progress: i32,
    #[cfg(test)]
    pub latency_ms: Option<u64>,
    #[cfg(test)]
    pub retry_attempt: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TorLogSeverity {
    Notice,
    Warning,
    Fatal,
}

#[allow(dead_code)]
pub struct TorRuntime {
    child: Option<Arc<Mutex<Child>>>,
    data_dir_lock: Option<TorDataLock>,
    socks_url: String,
    control_port: Option<u16>,
    data_dir: Option<PathBuf>,
    onion_mapping: Mutex<Option<(u16, u16)>>,
    #[cfg(test)]
    ready: Arc<AtomicBool>,
}

impl TorRuntime {
    pub fn external(socks_url: String) -> (Self, mpsc::Receiver<TorStatus>) {
        let (tx, rx) = mpsc::channel();
        let _ = tx.send(TorStatus {
            phase: TorPhase::Ready,
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
                data_dir_lock: None,
                socks_url,
                control_port: None,
                data_dir: None,
                onion_mapping: Mutex::new(None),
                #[cfg(test)]
                ready: Arc::new(AtomicBool::new(true)),
            },
            rx,
        )
    }

    pub fn start(
        binary: &Path,
        data_dir: &Path,
        outbound_socks_url: Option<String>,
    ) -> Result<(Self, mpsc::Receiver<TorStatus>)> {
        if !binary.is_file() {
            bail!("Tor binary not found: {}", binary.display())
        }
        fs::create_dir_all(data_dir).context("create Tor data directory")?;
        let runtime_generation = std::env::var("TORCHAT_RUNTIME_GENERATION")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or_else(|| {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64
            });
        let data_dir_lock = TorDataLock::acquire(data_dir, runtime_generation)?;

        let cookie_path = data_dir.join("control_auth_cookie");
        if cookie_path.is_file() {
            fs::remove_file(&cookie_path).context("remove stale Tor auth cookie")?;
        }
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
                tor_path(&geoip6),
            )
        } else {
            String::new()
        };
        fs::write(
            &torrc,
            format!(
                "DataDirectory {}\nCookieAuthFile {}\n{}SocksPort 127.0.0.1:{socks_port}\nControlPort 127.0.0.1:{control_port}\nCookieAuthentication 1\nLog notice stdout\n",
                tor_path(data_dir),
                tor_path(&data_dir.join("control_auth_cookie")),
                geoip_config,
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
            phase: TorPhase::Starting,
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
        let stderr_tx = tx.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let lowered = line.to_ascii_lowercase();
                if classify_tor_log_line(&lowered) == TorLogSeverity::Fatal {
                    let _ = status_tx.send(TorStatus {
                        phase: TorPhase::Failed,
                        label: line.clone(),
                        detail: String::new(),
                        progress: 0,
                        #[cfg(test)]
                        latency_ms: None,
                        #[cfg(test)]
                        retry_attempt: 0,
                    });
                }
                if let Some(progress) = bootstrap_progress(&line) {
                    #[cfg(test)]
                    if progress >= 100 {
                        status_ready.store(true, Ordering::Release);
                    }
                    let detail = if progress >= 100 {
                        "Tor ready, connecting to onion".to_owned()
                    } else {
                        format!("Bootstrap Tor: {progress}%")
                    };
                    let _ = status_tx.send(TorStatus {
                        phase: if progress >= 100 {
                            TorPhase::Ready
                        } else {
                            TorPhase::Bootstrapping
                        },
                        label: detail.clone(),
                        detail,
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
                if classify_tor_log_line(&lowered) == TorLogSeverity::Fatal {
                    let _ = stderr_tx.send(TorStatus {
                        phase: TorPhase::Failed,
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
        let status_tx = tx.clone();
        let child_status = child.clone();
        std::thread::spawn(move || {
            loop {
                let exited = child_status
                    .lock()
                    .ok()
                    .and_then(|mut child| child.try_wait().ok().flatten());
                if let Some(status) = exited {
                    let _ = status_tx.send(TorStatus {
                        phase: TorPhase::Failed,
                        label: format!("embedded Tor exited: {status}"),
                        detail: String::new(),
                        progress: 0,
                        #[cfg(test)]
                        latency_ms: None,
                        #[cfg(test)]
                        retry_attempt: 0,
                    });
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        });

        Ok((
            Self {
                child: Some(child),
                data_dir_lock: Some(data_dir_lock),
                socks_url: outbound_socks_url
                    .unwrap_or_else(|| format!("socks5h://127.0.0.1:{socks_port}")),
                control_port: Some(control_port),
                data_dir: Some(data_dir.to_path_buf()),
                onion_mapping: Mutex::new(None),
                #[cfg(test)]
                ready,
            },
            rx,
        ))
    }

    pub fn socks_url(&self) -> &str {
        &self.socks_url
    }

    pub fn is_ready(&self) -> bool {
        let Some(control_port) = self.control_port else {
            return true;
        };
        let Some(data_dir) = &self.data_dir else {
            return false;
        };
        let cookie_path = data_dir.join("control_auth_cookie");
        cookie_path.is_file()
            && connect_control(control_port, std::time::Duration::from_millis(200)).is_ok()
    }

    pub fn configure_onion_service(
        &self,
        local_port: u16,
        virtual_port: u16,
        generation: u64,
    ) -> Result<String> {
        let control_port = self
            .control_port
            .context("external Tor cannot host a managed onion service")?;
        let data_dir = self
            .data_dir
            .as_ref()
            .context("managed Tor data directory is unavailable")?;
        let service_dir = data_dir
            .join("onion-service")
            .join(format!("generation-{generation}"));
        fs::create_dir_all(&service_dir).context("create persistent onion service directory")?;

        let cookie_path = data_dir.join("control_auth_cookie");
        let cookie = wait_for_file(&cookie_path, std::time::Duration::from_secs(15))?;
        let cookie_hex = cookie
            .iter()
            .map(|byte| format!("{byte:02X}"))
            .collect::<String>();
        let stream = connect_control(control_port, std::time::Duration::from_secs(15))?;
        let mut control = BufReader::new(stream);
        control_command(&mut control, &format!("AUTHENTICATE {cookie_hex}"))?;
        let key_path = service_dir.join("hs_ed25519_secret_key");
        let key = match fs::read_to_string(&key_path) {
            Ok(value) if value.trim().starts_with("ED25519-V3:") => value.trim().to_owned(),
            _ => "NEW:ED25519-V3".to_owned(),
        };
        let lines = control_command_lines(
            &mut control,
            &format!("ADD_ONION {key} Flags=Detach Port={virtual_port},127.0.0.1:{local_port}",),
        )?;
        let service_id = lines
            .iter()
            .find_map(|line| line.strip_prefix("250-ServiceID="))
            .context("Tor did not return an onion service id")?;
        if key == "NEW:ED25519-V3"
            && let Some(private_key) = lines
                .iter()
                .find_map(|line| line.strip_prefix("250-PrivateKey="))
        {
            fs::write(&key_path, format!("{private_key}\n"))?;
        }
        let hostname = format!("{service_id}.onion").to_ascii_lowercase();
        fs::write(service_dir.join("hostname"), format!("{hostname}\n"))?;
        if !torchat_core::is_valid_onion_address(&hostname) {
            bail!("Tor produced an invalid onion service hostname")
        }
        *self
            .onion_mapping
            .lock()
            .map_err(|_| anyhow::anyhow!("onion mapping lock is poisoned"))? =
            Some((local_port, virtual_port));
        Ok(hostname)
    }

    pub fn rotate_onion_service(&self, generation: u64) -> Result<(String, u16, u16)> {
        let (local_port, virtual_port) = self
            .onion_mapping
            .lock()
            .map_err(|_| anyhow::anyhow!("onion mapping lock is poisoned"))?
            .context("onion service has not been configured")?;
        let hostname = self.configure_onion_service(local_port, virtual_port, generation)?;
        Ok((hostname, local_port, virtual_port))
    }

    #[cfg(test)]
    #[allow(dead_code)]
    pub fn readiness(&self) -> Arc<AtomicBool> {
        self.ready.clone()
    }
}

fn connect_control(port: u16, timeout: std::time::Duration) -> Result<TcpStream> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match TcpStream::connect(("127.0.0.1", port)) {
            Ok(stream) => return Ok(stream),
            Err(error) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(100));
                let _ = error;
            }
            Err(error) => return Err(error).context("connect to Tor control port"),
        }
    }
}

fn control_command(stream: &mut BufReader<TcpStream>, command: &str) -> Result<()> {
    let _ = control_command_lines(stream, command)?;
    Ok(())
}

fn control_command_lines(stream: &mut BufReader<TcpStream>, command: &str) -> Result<Vec<String>> {
    stream
        .get_mut()
        .write_all(format!("{command}\r\n").as_bytes())
        .context("write Tor control command")?;
    stream
        .get_mut()
        .flush()
        .context("flush Tor control command")?;
    let mut lines = Vec::new();
    loop {
        let mut line = String::new();
        if stream
            .read_line(&mut line)
            .context("read Tor control response")?
            == 0
        {
            bail!("Tor control connection closed unexpectedly")
        }
        if line.starts_with("250 ") {
            return Ok(lines);
        }
        if line.starts_with('4') || line.starts_with('5') {
            bail!("Tor control command failed: {}", line.trim())
        }
        lines.push(line.trim_end().to_owned());
    }
}

fn wait_for_file(path: &Path, timeout: std::time::Duration) -> Result<Vec<u8>> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match fs::File::open(path) {
            Ok(mut file) => {
                let mut value = Vec::new();
                file.read_to_end(&mut value)
                    .with_context(|| format!("read {}", path.display()))?;
                if !value.is_empty() {
                    return Ok(value);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| format!("open {}", path.display()));
            }
        }
        if std::time::Instant::now() >= deadline {
            bail!("timed out waiting for {}", path.display())
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
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
        self.data_dir_lock.take();
    }
}

fn free_port() -> Result<u16> {
    Ok(TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())
}

fn classify_tor_log_line(line: &str) -> TorLogSeverity {
    // Tor emits [warn] for recoverable guard and circuit conditions. Those
    // conditions must remain visible in diagnostics but must not stop the
    // relay actor or discard a working SOCKS endpoint.
    if line.contains("[err]")
        || line.contains("fatal")
        || line.contains("configuration was invalid")
        || line.contains("failed to bind")
    {
        TorLogSeverity::Fatal
    } else if line.contains("[warn]") {
        TorLogSeverity::Warning
    } else {
        TorLogSeverity::Notice
    }
}

fn bootstrap_progress(line: &str) -> Option<i32> {
    let start = line.find("Bootstrapped ")? + "Bootstrapped ".len();
    let end = line[start..].find('%')? + start;
    line[start..end].parse().ok()
}

fn tor_path(path: &Path) -> String {
    let value: PathBuf = path.canonicalize().unwrap_or_else(|_| {
        path.parent()
            .and_then(|parent| parent.canonicalize().ok())
            .and_then(|parent| path.file_name().map(|name| parent.join(name)))
            .unwrap_or_else(|| path.to_path_buf())
    });
    format!("\"{}\"", value.to_string_lossy().replace('\\', "/"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bootstrap_progress() {
        assert_eq!(
            bootstrap_progress("[notice] Bootstrapped 45% (requesting_descriptors)"),
            Some(45),
        );
        assert_eq!(bootstrap_progress("unrelated"), None);
    }
}
