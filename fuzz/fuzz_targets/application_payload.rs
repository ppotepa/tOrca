#![no_main]

use libfuzzer_sys::fuzz_target;
use torchat_protocol::application::ApplicationPayloadV1;

fuzz_target!(|data: &[u8]| {
    let _ = ApplicationPayloadV1::decode(data);
});
