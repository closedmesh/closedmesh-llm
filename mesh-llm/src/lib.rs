mod api;
mod cli;
mod inference;
mod mesh;
mod models;
mod network;
mod plugin;
mod plugins;
mod protocol;
pub(crate) mod runtime;
mod system;

pub mod proto {
    pub mod node {
        include!(concat!(env!("OUT_DIR"), "/meshllm.node.v1.rs"));
    }
}

pub(crate) use autoupdate::{latest_release_version, version_newer};
pub(crate) use inference::{election, launch, moe, pipeline};
pub(crate) use network::{nostr, proxy, rewrite, router, tunnel};
pub use plugins::blackboard;
pub use plugins::blackboard::mcp as blackboard_mcp;
pub(crate) use system::benchmark;
pub(crate) use system::{affinity, autoupdate, hardware};

use anyhow::Result;

pub const VERSION: &str = "0.54.0";

pub async fn run() -> Result<()> {
    runtime::run().await
}
