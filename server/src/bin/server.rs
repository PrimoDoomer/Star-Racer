use colored::Colorize;
use pocket_racing_server::tracks_dir;
use std::{
    io::Write,
    path::PathBuf,
    sync::{Arc, RwLock},
};
use tokio::time::Instant;

pub fn log_init() {
    let launch_time = Instant::now();

    let mut binding = env_logger::builder();
    binding
        .filter_level(log::LevelFilter::Info)
        .parse_default_env();
    let builder = binding.format(move |buf, record| {
        let target_str = record.target();
        if !target_str.contains("pocket_racing") {
            return write!(buf, "");
        }

        let now_time = Instant::now();
        let elapsed = now_time - launch_time;
        let elapsed = elapsed.as_millis() as f32 / 1000.;

        let args_str = format!("{}", record.args());

        writeln!(
            buf,
            "{:>8}|{}",
            elapsed.to_string().truecolor(255, 255, 255),
            args_str,
        )
    });
    builder.init();
}

#[cfg(windows)]
fn raise_timer_resolution() {
    unsafe { windows_sys::Win32::Media::timeBeginPeriod(1) };
}

#[cfg(not(windows))]
fn raise_timer_resolution() {}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> anyhow::Result<()> {
    log_init();
    raise_timer_resolution();

    let tracks_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("./tracks"));

    let tracks = tracks_dir::load_all(&tracks_path)
        .map_err(|e| anyhow::anyhow!("loading tracks from {}: {e}", tracks_path.display()))?;
    log::info!(
        "loaded {} track(s) from {}: [{}]",
        tracks.len(),
        tracks_path.display(),
        tracks.keys().cloned().collect::<Vec<_>>().join(", ")
    );

    // Wrap in a hot-swappable handle so the reload watcher (spawned in `run`) can
    // pick up added/edited circuits without a restart.
    let shared = Arc::new(RwLock::new(Arc::new(tracks)));
    pocket_racing_server::run::run(8080, shared, tracks_path).await?;

    anyhow::Ok(())
}
