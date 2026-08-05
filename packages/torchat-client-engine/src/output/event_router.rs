use tokio::sync::mpsc;

use crate::{EngineEvent, logging::StartupJournal};

use super::{PendingResponseRegistry, publisher::spawn_public_event_publisher};

pub(crate) fn spawn_event_router(
    mut actor_events: mpsc::Receiver<EngineEvent>,
    public_events: mpsc::Sender<EngineEvent>,
    pending: PendingResponseRegistry,
    mut journal: Option<StartupJournal>,
) {
    let (publish_tx, publish_rx) = mpsc::unbounded_channel();
    spawn_public_event_publisher(publish_rx, public_events);

    let pending_on_close = pending.clone();
    tokio::spawn(async move {
        while let Some(event) = actor_events.recv().await {
            if let Some(journal) = journal.as_mut() {
                journal.record(&event);
            }
            if let EngineEvent::Response { request_id, result } = &event {
                pending.complete(request_id, result.clone()).await;
            }
            if publish_tx.send(event).is_err() {
                break;
            }
        }
        pending_on_close
            .fail_all("engine_closed", "engine stopped before producing a response")
            .await;
    });
}
