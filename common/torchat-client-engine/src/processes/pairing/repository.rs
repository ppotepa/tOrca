use crate::EngineResult;

use super::PairingProcess;

pub trait PairingProcessRepository {
    fn load(&self, pairing_id: &str) -> EngineResult<Option<PairingProcess>>;
    fn save(&mut self, process: &PairingProcess) -> EngineResult<()>;
    fn active(&self) -> EngineResult<Vec<PairingProcess>>;
}
