use anyhow::Result;
use std::time::Instant;
use torchat_core::Identity;

use crate::{
    DesktopState,
    runtime_support::{wait_for_pairing_code, wait_for_pairing_request},
};

pub fn run_headless(cli: crate::cli::Cli) -> Result<()> {
    let headless_send = cli.headless_send.clone();
    let headless_pairing_code = cli.headless_pairing_code;
    let headless_submit_pairing_code = cli.headless_submit_pairing_code.clone();
    let mut state = DesktopState::new(cli)?;
    // A cold Tor client may need several minutes for its first consensus and
    // onion circuit.  The Flutter UI remains responsive during this period;
    // headless smoke must wait for the same real startup window instead of
    // reporting a false relay failure after 90 seconds.
    let deadline = Instant::now() + std::time::Duration::from_secs(180);
    let mut sent_message_id = None;
    while Instant::now() < deadline {
        state.tick();
        if state.connected {
            if let Some(code) = headless_submit_pairing_code.as_deref() {
                let code = Identity::pairing_code_digits(code).map_err(anyhow::Error::msg)?;
                let request =
                    wait_for_pairing_request(&mut state, code, std::time::Duration::from_secs(30))?;
                println!("PAIRING_REQUEST_ID={}", request.pairing_id);
                return Ok(());
            } else if headless_pairing_code {
                let code = wait_for_pairing_code(&mut state, std::time::Duration::from_secs(30))?;
                println!("PAIRING_CODE={}", code.code);
                return Ok(());
            } else if let Some(text) = headless_send.as_deref() {
                if sent_message_id.is_none() {
                    state.send(text)?;
                    sent_message_id = state.messages.last().map(|message| message.id.clone());
                }
                if let Some(message) = state
                    .messages
                    .iter()
                    .find(|message| Some(&message.id) == sent_message_id.as_ref())
                {
                    if message.state.is_delivered() {
                        return Ok(());
                    }
                    if message.state.is_failed() {
                        anyhow::bail!("relay rejected message {}", message.id);
                    }
                }
            } else {
                return Ok(());
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    anyhow::bail!(
        "desktop runtime smoke timed out: {} {}",
        state.tor_status.label,
        state.error
    )
}
