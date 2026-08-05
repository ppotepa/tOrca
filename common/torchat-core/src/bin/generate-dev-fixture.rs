use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Serialize;
use torchat_crypto::mls::MlsMember;

#[derive(Serialize)]
struct Fixture {
    android_snapshot: String,
    peer_snapshot: String,
}

fn main() {
    let android = MlsMember::create(b"android-dev").expect("android member");
    let peer = MlsMember::create(b"peer-dev").expect("peer member");
    let mut android_chat = android.create_conversation().expect("android conversation");
    let (welcome, tree) = android_chat
        .invite(&peer.key_package().expect("peer key package"))
        .expect("invite peer");
    let peer_chat = peer
        .accept_conversation(&welcome, &tree)
        .expect("peer conversation");
    let fixture = serde_json::to_string_pretty(&Fixture {
        android_snapshot: URL_SAFE_NO_PAD
            .encode(android_chat.snapshot().expect("android snapshot")),
        peer_snapshot: URL_SAFE_NO_PAD.encode(peer_chat.snapshot().expect("peer snapshot")),
    })
    .expect("fixture json");
    std::fs::create_dir_all("tests/fixtures/protocol").expect("fixture directory");
    std::fs::write("tests/fixtures/protocol/android-peer.json", &fixture)
        .expect("fixture file");
    println!("{fixture}");
}
