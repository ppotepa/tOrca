use crate::{EngineError, EngineResult};

pub(crate) fn exactly_one(changed: usize, operation: &str) -> EngineResult<()> {
    if changed == 1 {
        Ok(())
    } else {
        Err(EngineError::Storage(format!(
            "{operation} expected exactly one row, changed {changed}"
        )))
    }
}

#[allow(dead_code)]
pub(crate) fn zero_or_one(changed: usize, operation: &str) -> EngineResult<()> {
    if changed <= 1 {
        Ok(())
    } else {
        Err(EngineError::Storage(format!(
            "{operation} expected zero or one row, changed {changed}"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn affected_row_contracts_are_strict() {
        assert!(exactly_one(1, "write").is_ok());
        assert!(exactly_one(0, "write").is_err());
        assert!(zero_or_one(0, "delete").is_ok());
        assert!(zero_or_one(2, "delete").is_err());
    }
}
