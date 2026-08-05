use tokio::sync::mpsc;

use crate::EngineEvent;

pub(in crate::output) fn spawn_public_event_publisher(
    mut publish_rx: mpsc::UnboundedReceiver<EngineEvent>,
    public_events: mpsc::Sender<EngineEvent>,
) {
    tokio::spawn(async move {
        while let Some(event) = publish_rx.recv().await {
            if public_events.send(event).await.is_err() {
                break;
            }
        }
    });
}
