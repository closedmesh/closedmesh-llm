//! `closedmesh service start|stop|status|logs` — OS-native autostart wrappers.
//!
//! The agent itself is installed by the platform installer:
//!   - macOS:   `install.sh --service`     -> launchd LaunchAgent
//!   - Linux:   `install.sh --service`     -> systemd --user unit
//!   - Windows: `install.ps1 -Service`     -> Task Scheduler task
//!
//! This module just handles the lifecycle commands users want to run from the
//! CLI ("start it", "stop it", "is it running", "show me the logs"), routing
//! to whichever service manager owns the unit on this OS.

use anyhow::{anyhow, Context, Result};
use std::path::PathBuf;
use std::process::Command;

use crate::cli::ServiceCommand;
use crate::process_util::HideConsole;

const SERVICE_LABEL_DARWIN: &str = "dev.closedmesh.closedmesh";
const SERVICE_NAME_LINUX: &str = "closedmesh";
const SERVICE_NAME_WINDOWS: &str = "ClosedMesh";

pub(crate) async fn dispatch(cmd: &ServiceCommand) -> Result<()> {
    match cmd {
        ServiceCommand::Start => start(),
        ServiceCommand::Stop => stop(),
        ServiceCommand::Status => status(),
        ServiceCommand::Logs { follow } => logs(*follow),
    }
}

fn start() -> Result<()> {
    if cfg!(target_os = "macos") {
        darwin::start()
    } else if cfg!(target_os = "linux") {
        linux::start()
    } else if cfg!(target_os = "windows") {
        windows::start()
    } else {
        Err(unsupported_os())
    }
}

fn stop() -> Result<()> {
    if cfg!(target_os = "macos") {
        darwin::stop()
    } else if cfg!(target_os = "linux") {
        linux::stop()
    } else if cfg!(target_os = "windows") {
        windows::stop()
    } else {
        Err(unsupported_os())
    }
}

fn status() -> Result<()> {
    if cfg!(target_os = "macos") {
        darwin::status()
    } else if cfg!(target_os = "linux") {
        linux::status()
    } else if cfg!(target_os = "windows") {
        windows::status()
    } else {
        Err(unsupported_os())
    }
}

fn logs(follow: bool) -> Result<()> {
    if cfg!(target_os = "macos") {
        darwin::logs(follow)
    } else if cfg!(target_os = "linux") {
        linux::logs(follow)
    } else if cfg!(target_os = "windows") {
        windows::logs(follow)
    } else {
        Err(unsupported_os())
    }
}

fn unsupported_os() -> anyhow::Error {
    anyhow!(
        "`closedmesh service` does not yet support this OS. \
         Run the binary directly: `closedmesh serve --private-only`."
    )
}

fn home_dir() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| anyhow!("cannot determine home directory"))
}

// ───────── macOS / launchd ─────────

mod darwin {
    use super::*;

    fn plist_path() -> Result<PathBuf> {
        Ok(home_dir()?
            .join("Library")
            .join("LaunchAgents")
            .join(format!("{SERVICE_LABEL_DARWIN}.plist")))
    }

    fn uid_target() -> Result<String> {
        let output = Command::new("id")
            .arg("-u")
            .output()
            .context("failed to invoke `id -u`")?;
        if !output.status.success() {
            return Err(anyhow!("`id -u` failed"));
        }
        let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Ok(format!("gui/{uid}"))
    }

    pub(super) fn start() -> Result<()> {
        let plist = plist_path()?;
        if !plist.exists() {
            return Err(anyhow!(
                "ClosedMesh service is not installed at {}. Run: \
                 curl -fsSL https://closedmesh.com/install | sh -s -- --service",
                plist.display()
            ));
        }
        let target = uid_target()?;
        let full_target = format!("{target}/{SERVICE_LABEL_DARWIN}");

        // `launchctl bootstrap` returns exit 5 (EIO) if the service is
        // already bootstrapped in this domain, which is a common state
        // (install.sh bootstraps the LaunchAgent on install, then the user
        // runs `closedmesh service start` and hits the noisy error).
        // Mirror install.sh's idempotent dance: best-effort bootout first
        // so bootstrap has a clean slate. Errors here are expected when the
        // service isn't loaded — ignore them.
        let _ = Command::new("launchctl")
            .args(["bootout", &full_target])
            .output();

        // macOS's `launchctl bootout` returns immediately, but the
        // underlying unload is queued. A `bootstrap` issued in the next
        // ~1 s reliably fails with EIO ("Bootstrap failed: 5: Input/output
        // error") because launchd still considers the previous instance
        // loaded. The desktop app already retries with backoff for its own
        // bounce path; mirror that here so anyone running `service start`
        // from the CLI (or via the dashboard's "Set as startup" flow that
        // shells out to it) gets the same robustness.
        //
        // Three attempts spaced 0 s / 2 s / 4 s. Anything still failing
        // after ~6 s of accumulated wait is almost certainly a real
        // plist / permissions problem and we should surface it.
        let backoff = [
            std::time::Duration::from_secs(0),
            std::time::Duration::from_secs(2),
            std::time::Duration::from_secs(4),
        ];
        let mut last_code: Option<i32> = None;
        for (i, wait) in backoff.iter().enumerate() {
            if !wait.is_zero() {
                std::thread::sleep(*wait);
            }
            let status = Command::new("launchctl")
                .args(["bootstrap", &target])
                .arg(&plist)
                .status()
                .context("failed to invoke launchctl")?;
            if status.success() {
                if i > 0 {
                    eprintln!(
                        "✓ ClosedMesh service started (label: {SERVICE_LABEL_DARWIN}, attempt {})",
                        i + 1,
                    );
                } else {
                    eprintln!("✓ ClosedMesh service started (label: {SERVICE_LABEL_DARWIN})");
                }
                return Ok(());
            }
            last_code = status.code();
            // Only the EIO race is worth retrying. Any other exit code is
            // a real configuration error and a retry would just delay the
            // failure surfacing to the user.
            if last_code != Some(5) {
                break;
            }
        }
        Err(anyhow!(
            "launchctl bootstrap failed with exit code {:?}",
            last_code
        ))
    }

    pub(super) fn stop() -> Result<()> {
        let target = uid_target()?;
        let full_target = format!("{target}/{SERVICE_LABEL_DARWIN}");
        let status = Command::new("launchctl")
            .args(["bootout", &full_target])
            .status()
            .context("failed to invoke launchctl")?;
        if !status.success() {
            return Err(anyhow!(
                "launchctl bootout failed (was the service running?). exit code {:?}",
                status.code()
            ));
        }
        eprintln!("✓ ClosedMesh service stopped");
        Ok(())
    }

    pub(super) fn status() -> Result<()> {
        let target = uid_target()?;
        let full_target = format!("{target}/{SERVICE_LABEL_DARWIN}");
        let output = Command::new("launchctl")
            .args(["print", &full_target])
            .output()
            .context("failed to invoke launchctl")?;

        if !output.status.success() {
            println!("ClosedMesh service: stopped");
            return Ok(());
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut state: Option<&str> = None;
        let mut pid: Option<&str> = None;
        for line in stdout.lines() {
            let trimmed = line.trim();
            if let Some(rest) = trimmed.strip_prefix("state =") {
                state = Some(rest.trim());
            } else if let Some(rest) = trimmed.strip_prefix("pid =") {
                pid = Some(rest.trim());
            }
        }

        println!(
            "ClosedMesh service: {}{}",
            state.unwrap_or("running"),
            match pid {
                Some(p) => format!(" (pid {p})"),
                None => String::new(),
            }
        );
        Ok(())
    }

    pub(super) fn logs(follow: bool) -> Result<()> {
        let log_dir = home_dir()?.join("Library/Logs/closedmesh");
        let stdout = log_dir.join("stdout.log");
        let stderr = log_dir.join("stderr.log");
        if !stdout.exists() && !stderr.exists() {
            return Err(anyhow!(
                "no log files at {}. Is the service installed?",
                log_dir.display()
            ));
        }
        let mut cmd = Command::new("tail");
        if follow {
            cmd.arg("-F");
        } else {
            cmd.args(["-n", "200"]);
        }
        let status = cmd
            .arg(&stdout)
            .arg(&stderr)
            .status()
            .context("failed to invoke tail")?;
        if !status.success() {
            return Err(anyhow!("tail exited with code {:?}", status.code()));
        }
        Ok(())
    }
}

// ───────── Linux / systemd --user ─────────

mod linux {
    use super::*;

    fn unit_path() -> Result<PathBuf> {
        Ok(home_dir()?
            .join(".config/systemd/user")
            .join(format!("{SERVICE_NAME_LINUX}.service")))
    }

    fn require_unit() -> Result<()> {
        let p = unit_path()?;
        if !p.exists() {
            return Err(anyhow!(
                "ClosedMesh service is not installed at {}. Run: \
                 curl -fsSL https://closedmesh.com/install | sh -s -- --service",
                p.display()
            ));
        }
        Ok(())
    }

    pub(super) fn start() -> Result<()> {
        require_unit()?;
        let status = Command::new("systemctl")
            .args(["--user", "enable", "--now", SERVICE_NAME_LINUX])
            .status()
            .context("failed to invoke systemctl")?;
        if !status.success() {
            return Err(anyhow!(
                "systemctl --user enable --now failed with exit code {:?}",
                status.code()
            ));
        }
        eprintln!("✓ ClosedMesh service started ({SERVICE_NAME_LINUX}.service)");
        Ok(())
    }

    pub(super) fn stop() -> Result<()> {
        let status = Command::new("systemctl")
            .args(["--user", "stop", SERVICE_NAME_LINUX])
            .status()
            .context("failed to invoke systemctl")?;
        if !status.success() {
            return Err(anyhow!(
                "systemctl --user stop failed with exit code {:?}",
                status.code()
            ));
        }
        eprintln!("✓ ClosedMesh service stopped");
        Ok(())
    }

    pub(super) fn status() -> Result<()> {
        let output = Command::new("systemctl")
            .args(["--user", "is-active", SERVICE_NAME_LINUX])
            .output()
            .context("failed to invoke systemctl")?;
        let state = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if state.is_empty() {
            println!("ClosedMesh service: unknown");
        } else {
            println!("ClosedMesh service: {state}");
        }

        // Best-effort pid fetch via systemctl show.
        if let Ok(pid_out) = Command::new("systemctl")
            .args([
                "--user",
                "show",
                "--property=MainPID",
                "--value",
                SERVICE_NAME_LINUX,
            ])
            .output()
        {
            let pid = String::from_utf8_lossy(&pid_out.stdout).trim().to_string();
            if !pid.is_empty() && pid != "0" {
                println!("  pid: {pid}");
            }
        }
        Ok(())
    }

    pub(super) fn logs(follow: bool) -> Result<()> {
        let mut cmd = Command::new("journalctl");
        cmd.args(["--user-unit", SERVICE_NAME_LINUX]);
        if follow {
            cmd.arg("-f");
        } else {
            cmd.args(["-n", "200", "--no-pager"]);
        }
        let status = cmd.status().context("failed to invoke journalctl")?;
        if !status.success() {
            return Err(anyhow!("journalctl exited with code {:?}", status.code()));
        }
        Ok(())
    }
}

// ───────── Windows / Task Scheduler ─────────

mod windows {
    use super::*;

    fn schtasks_query_ok() -> Result<bool> {
        let output = Command::new("schtasks")
            .args(["/Query", "/TN", SERVICE_NAME_WINDOWS])
            .hide_console()
            .output()
            .context("failed to invoke schtasks")?;
        Ok(output.status.success())
    }

    pub(super) fn start() -> Result<()> {
        if !schtasks_query_ok()? {
            return Err(anyhow!(
                "ClosedMesh task '{SERVICE_NAME_WINDOWS}' not registered. Run: \
                 iwr -useb https://closedmesh.com/install.ps1 | iex; closedmesh-install -Service"
            ));
        }
        let status = Command::new("schtasks")
            .args(["/Run", "/TN", SERVICE_NAME_WINDOWS])
            .hide_console()
            .status()
            .context("failed to invoke schtasks")?;
        if !status.success() {
            return Err(anyhow!(
                "schtasks /Run failed with exit code {:?}",
                status.code()
            ));
        }
        eprintln!("✓ ClosedMesh service started (Scheduled Task '{SERVICE_NAME_WINDOWS}')");
        Ok(())
    }

    pub(super) fn stop() -> Result<()> {
        // `schtasks /End` only signals the wscript launcher and the cmd
        // wrapper above it; the actual `closedmesh.exe` runtime (and its
        // child `rpc-server.exe` / `llama-server.exe`) is reparented to
        // the host and keeps running. From the user's perspective they
        // clicked "Quit ClosedMesh", the GUI vanished, and the entry
        // node continued seeing their machine for the next 5–30 minutes
        // (until the laptop lid closed, Modern Standby suspended it,
        // and the entry's heartbeat watchdog evicted on timeout).
        //
        // Match the startup-side `stop_runtime_aggressively_windows`
        // hygiene: schtasks /End for the polite path, sleep so the
        // process tree has a chance to wind down on its own, then
        // taskkill /F /T per image as the safety net for orphaned
        // children. We exclude our own PID via `/FI "PID ne …"` so
        // that running `closedmesh service stop` from a console attached
        // to closedmesh.exe (the CLI subcommand is part of the same
        // binary) doesn't kill the process executing the command before
        // the response writes back. taskkill returns non-zero when no
        // matching process is running, which is the *expected* path on
        // a cleanly-shut-down system, so we don't propagate that as an
        // error — the schtasks step is the one whose status we trust.
        let status = Command::new("schtasks")
            .args(["/End", "/TN", SERVICE_NAME_WINDOWS])
            .hide_console()
            .status()
            .context("failed to invoke schtasks")?;
        if !status.success() {
            return Err(anyhow!(
                "schtasks /End failed with exit code {:?}",
                status.code()
            ));
        }

        std::thread::sleep(std::time::Duration::from_millis(800));

        let self_pid = std::process::id();
        let pid_filter = format!("PID ne {self_pid}");
        for image in ["llama-server.exe", "rpc-server.exe", "closedmesh.exe"] {
            let _ = Command::new("taskkill")
                .args(["/F", "/T", "/IM", image, "/FI", &pid_filter])
                .hide_console()
                .output();
        }

        eprintln!("✓ ClosedMesh service stopped");
        Ok(())
    }

    pub(super) fn status() -> Result<()> {
        let output = Command::new("schtasks")
            .args(["/Query", "/TN", SERVICE_NAME_WINDOWS, "/FO", "LIST", "/V"])
            .hide_console()
            .output()
            .context("failed to invoke schtasks")?;
        if !output.status.success() {
            println!("ClosedMesh service: not registered");
            return Ok(());
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut state: Option<String> = None;
        for line in stdout.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("Status:") {
                state = Some(rest.trim().to_string());
            } else if let Some(rest) = line.strip_prefix("Scheduled Task State:") {
                if state.is_none() {
                    state = Some(rest.trim().to_string());
                }
            }
        }
        println!(
            "ClosedMesh service: {}",
            state.as_deref().unwrap_or("registered")
        );
        Ok(())
    }

    pub(super) fn logs(follow: bool) -> Result<()> {
        // The Windows Scheduled Task doesn't capture stdout/stderr by default.
        // The closedmesh process logs to %LOCALAPPDATA%\closedmesh\logs when
        // `serve` is run with --headless from install.ps1.
        let local_app_data = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .ok_or_else(|| anyhow!("LOCALAPPDATA is not set"))?;
        let log_dir = local_app_data.join("closedmesh").join("logs");
        let stdout = log_dir.join("stdout.log");
        let stderr = log_dir.join("stderr.log");
        if !stdout.exists() && !stderr.exists() {
            return Err(anyhow!(
                "no log files at {}. Is the service installed?",
                log_dir.display()
            ));
        }
        // PowerShell's Get-Content has -Wait for follow mode.
        let ps_cmd = if follow {
            format!(
                "Get-Content -Wait -Path '{}','{}'",
                stdout.display(),
                stderr.display()
            )
        } else {
            format!(
                "Get-Content -Tail 200 -Path '{}','{}'",
                stdout.display(),
                stderr.display()
            )
        };
        let status = Command::new("powershell")
            .args(["-NoProfile", "-Command", &ps_cmd])
            .status()
            .context("failed to invoke powershell")?;
        if !status.success() {
            return Err(anyhow!(
                "powershell Get-Content exited with code {:?}",
                status.code()
            ));
        }
        Ok(())
    }
}
