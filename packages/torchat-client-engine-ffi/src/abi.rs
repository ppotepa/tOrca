pub const TORCA_ENGINE_ABI_VERSION: u32 = 1;

#[unsafe(no_mangle)]
pub extern "C" fn torca_engine_abi_version() -> u32 {
    TORCA_ENGINE_ABI_VERSION
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum FfiStatus {
    Ok = 0,
    InvalidArgument = 1,
    InvalidHandle = 2,
    AlreadyShutdown = 3,
    Timeout = 4,
    InternalError = 5,
    PanicContained = 6,
    AbiMismatch = 7,
}

impl FfiStatus {
    pub const fn code(self) -> i32 {
        self as i32
    }
}
