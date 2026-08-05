use std::{collections::HashMap, sync::Arc};

use tokio::sync::{Mutex, oneshot};

use crate::ResponseResult;

#[derive(Clone, Default)]
pub(crate) struct PendingResponseRegistry {
    inner: Arc<Mutex<HashMap<String, oneshot::Sender<ResponseResult>>>>,
}

impl PendingResponseRegistry {
    pub(crate) async fn register(
        &self,
        request_id: String,
        sender: oneshot::Sender<ResponseResult>,
    ) {
        self.inner.lock().await.insert(request_id, sender);
    }

    pub(crate) async fn remove(&self, request_id: &str) {
        self.inner.lock().await.remove(request_id);
    }

    pub(crate) async fn complete(&self, request_id: &str, result: ResponseResult) {
        if let Some(sender) = self.inner.lock().await.remove(request_id) {
            let _ = sender.send(result);
        }
    }

    pub(crate) async fn fail_all(&self, code: &str, message: &str) {
        let pending = {
            let mut guard = self.inner.lock().await;
            std::mem::take(&mut *guard)
        };
        for (_, sender) in pending {
            let _ = sender.send(ResponseResult::Error {
                code: code.to_owned(),
                message: message.to_owned(),
            });
        }
    }

    #[cfg(test)]
    async fn len(&self) -> usize {
        self.inner.lock().await.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ResponsePayload;

    #[tokio::test]
    async fn registry_completes_and_removes_response() {
        let registry = PendingResponseRegistry::default();
        let (sender, receiver) = oneshot::channel();
        registry.register("request-1".to_owned(), sender).await;
        registry
            .complete(
                "request-1",
                ResponseResult::Ok {
                    payload: ResponsePayload::Empty,
                },
            )
            .await;
        assert!(matches!(receiver.await, Ok(ResponseResult::Ok { .. })));
        assert_eq!(registry.len().await, 0);
    }

    #[tokio::test]
    async fn registry_fails_every_waiter_on_actor_close() {
        let registry = PendingResponseRegistry::default();
        let (first_tx, first_rx) = oneshot::channel();
        let (second_tx, second_rx) = oneshot::channel();
        registry.register("first".to_owned(), first_tx).await;
        registry.register("second".to_owned(), second_tx).await;
        registry.fail_all("closed", "actor stopped").await;
        assert!(matches!(first_rx.await, Ok(ResponseResult::Error { .. })));
        assert!(matches!(second_rx.await, Ok(ResponseResult::Error { .. })));
        assert_eq!(registry.len().await, 0);
    }
}
