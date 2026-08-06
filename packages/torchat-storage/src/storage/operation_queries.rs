use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::de::DeserializeOwned;
use torchat_runtime::{DurableOperation, OperationId, RuntimeError, RuntimeResult};

const UPSERT_OPERATION: &str =
    include_str!("../../sql/commands/operations/upsert_operation.sql");
const OPERATION_BY_ID: &str =
    include_str!("../../sql/queries/operations/operation_by_id.sql");
const PENDING_OPERATIONS: &str =
    include_str!("../../sql/queries/operations/pending_operations.sql");

pub(super) fn operation_by_id(
    connection: &Connection,
    operation_id: &OperationId,
) -> RuntimeResult<Option<DurableOperation>> {
    connection
        .query_row(OPERATION_BY_ID, [operation_id.as_str()], decode_operation)
        .optional()
        .map_err(storage_error)?
        .transpose()
}

pub(super) fn put_operation(
    connection: &Connection,
    operation: &DurableOperation,
) -> RuntimeResult<()> {
    connection
        .execute(
            UPSERT_OPERATION,
            params![
                operation.operation_id.as_str(),
                enum_wire(operation.operation_type)?,
                operation.entity_id,
                enum_wire(operation.state)?,
                operation.started_at,
                operation.updated_at,
                i64::from(operation.attempt_count),
                operation.retry_at,
                operation.error_code.map(enum_wire).transpose()?,
                operation.command_descriptor.as_deref(),
            ],
        )
        .map_err(storage_error)?;
    Ok(())
}

pub(super) fn pending_operations(
    connection: &Connection,
) -> RuntimeResult<Vec<DurableOperation>> {
    let mut statement = connection
        .prepare(PENDING_OPERATIONS)
        .map_err(storage_error)?;
    let rows = statement
        .query_map([], decode_operation)
        .map_err(storage_error)?;
    rows.map(|row| row.map_err(storage_error).and_then(|value| value))
        .collect()
}

fn decode_operation(row: &Row<'_>) -> rusqlite::Result<RuntimeResult<DurableOperation>> {
    let operation_id = row.get::<_, String>("operation_id")?;
    let operation_type = row.get::<_, String>("operation_type")?;
    let state = row.get::<_, String>("state")?;
    let error_code = row.get::<_, Option<String>>("error_code")?;
    Ok((|| {
        Ok(DurableOperation {
            operation_id: OperationId::parse(operation_id)?,
            operation_type: parse_enum(&operation_type)?,
            entity_id: row.get("entity_id").map_err(storage_error)?,
            state: parse_enum(&state)?,
            started_at: row.get("started_at").map_err(storage_error)?,
            updated_at: row.get("updated_at").map_err(storage_error)?,
            attempt_count: row
                .get::<_, i64>("attempt_count")
                .map_err(storage_error)?
                .try_into()
                .map_err(|_| RuntimeError::Storage("negative operation attempt count".to_owned()))?,
            retry_at: row.get("retry_at").map_err(storage_error)?,
            error_code: error_code.as_deref().map(parse_enum).transpose()?,
            command_descriptor: row.get("command_descriptor").map_err(storage_error)?,
        })
    })())
}

fn enum_wire<T: serde::Serialize>(value: T) -> RuntimeResult<String> {
    serde_json::to_value(value)
        .map_err(RuntimeError::from)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| RuntimeError::Storage("operation enum did not serialize as text".to_owned()))
}

fn parse_enum<T: DeserializeOwned>(value: &str) -> RuntimeResult<T> {
    serde_json::from_value(serde_json::Value::String(value.to_owned())).map_err(RuntimeError::from)
}

fn storage_error(error: rusqlite::Error) -> RuntimeError {
    RuntimeError::Storage(format!("{error:#}"))
}
