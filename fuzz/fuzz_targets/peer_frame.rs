#![no_main]

use libfuzzer_sys::fuzz_target;
use torchat_core::peer_protocol::decode_frame;

fuzz_target!(|data: &[u8]| {
    let _ = decode_frame(data, true);
});
