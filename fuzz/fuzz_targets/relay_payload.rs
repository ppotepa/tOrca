#![no_main]

use base64::Engine;
use libfuzzer_sys::fuzz_target;
use torchat_core::relay::RelayPayloadV1;

fuzz_target!(|data: &[u8]| {
    let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data);
    let _ = RelayPayloadV1::decode(&encoded);
});
