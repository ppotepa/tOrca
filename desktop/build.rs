fn main() {
    // The desktop sidecar embeds the relay hostname. Cargo does not otherwise
    // know that an environment-only configuration change must invalidate the
    // crate, which could leave a client pointing at an old onion service.
    println!("cargo:rerun-if-env-changed=TORCHAT_COMPILED_ONION_URL");
}
