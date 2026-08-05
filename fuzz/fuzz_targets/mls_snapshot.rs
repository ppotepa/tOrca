#![no_main]

use libfuzzer_sys::fuzz_target;
use torchat_crypto::mls::DirectConversation;

fuzz_target!(|data: &[u8]| {
    let _ = DirectConversation::restore_current(data);
});
