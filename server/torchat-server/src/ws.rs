use axum::body::Bytes;
use axum::extract::ws::Message;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{RwLock, mpsc, oneshot};
use uuid::Uuid;

#[derive(Clone)]
pub(crate) struct Connection {
    pub(crate) id: Uuid,
    pub(crate) sender: mpsc::Sender<OutboundCommand>,
}

pub(crate) enum OutboundCommand {
    Frame {
        frame: torchat_core::relay::RelayServerFrame,
        completion: Option<oneshot::Sender<Result<(), String>>>,
    },
    WebSocketPong(Bytes),
    Close,
}

pub(crate) async fn send_server_frame_to_connections(
    connections: &Arc<RwLock<HashMap<String, Connection>>>,
    target_id: &str,
    frame_value: torchat_core::relay::RelayServerFrame,
) -> Result<(), String> {
    if let Some(target) = connections.read().await.get(target_id).cloned() {
        let _ = target.sender.try_send(OutboundCommand::Frame {
            frame: frame_value,
            completion: None,
        });
    }
    Ok(())
}

pub(crate) fn frame_message<T: Serialize>(value: T) -> Message {
    Message::Text(
        serde_json::to_string(&value)
            .expect("server frame must serialize")
            .into(),
    )
}
