use crate::{RuntimeResult, RuntimeTorStatus};

pub trait RuntimeTransport {
    fn connect(&mut self) -> RuntimeResult<RuntimeTorStatus>;
    fn status(&self) -> RuntimeTorStatus;
}
