use crate::NotificationRequest;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotificationProjectionInput {
    pub id: String,
    pub title: String,
    pub body: String,
    pub conversation_id: Option<String>,
    pub contact_muted: bool,
    pub contact_blocked: bool,
    pub app_foreground: bool,
    pub selected_conversation_id: Option<String>,
}

pub struct NotificationProjector;

impl NotificationProjector {
    pub fn project(input: NotificationProjectionInput) -> Option<NotificationRequest> {
        if input.contact_blocked || input.contact_muted {
            return None;
        }
        if input.app_foreground
            && input.conversation_id.as_deref()
                == input.selected_conversation_id.as_deref()
        {
            return None;
        }
        Some(NotificationRequest {
            id: input.id,
            title: input.title,
            body: input.body,
            conversation_id: input.conversation_id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selected_foreground_conversation_does_not_notify() {
        let request = NotificationProjector::project(NotificationProjectionInput {
            id: "notification".to_owned(),
            title: "Alice".to_owned(),
            body: "message".to_owned(),
            conversation_id: Some("conversation".to_owned()),
            contact_muted: false,
            contact_blocked: false,
            app_foreground: true,
            selected_conversation_id: Some("conversation".to_owned()),
        });
        assert_eq!(request, None);
    }

    #[test]
    fn background_unmuted_message_creates_request() {
        let request = NotificationProjector::project(NotificationProjectionInput {
            id: "notification".to_owned(),
            title: "Alice".to_owned(),
            body: "message".to_owned(),
            conversation_id: Some("conversation".to_owned()),
            contact_muted: false,
            contact_blocked: false,
            app_foreground: false,
            selected_conversation_id: None,
        });
        assert!(request.is_some());
    }
}
