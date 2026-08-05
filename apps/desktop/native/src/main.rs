mod cli;
mod identity_store;
mod process_lock;
mod runtime_engine_stdio;
mod secret_store;
mod tor_runtime;

use anyhow::Result;
use clap::Parser;
use cli::Cli;

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.reset_profile {
        return identity_store::reset_profile(
            cli.identity_file.as_deref(),
            cli.tor_data_dir.as_deref(),
        );
    }
    if cli.stdio_engine {
        return runtime_engine_stdio::run_stdio_engine(cli);
    }
    anyhow::bail!("The desktop frontend is Flutter. Run scripts/torchat.ps1 run -Target windows.")
}
