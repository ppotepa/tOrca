use torchat_runtime::{RuntimeError, RuntimeResult};

pub(super) const MESSAGE_PAGE_PREFIX: &str = "torchat-page-v1\t";
pub(super) const MESSAGE_ALL_PREFIX: &str = "torchat-all-v1\t";
const DEFAULT_MESSAGE_PAGE_SIZE: usize = 50;
const MAX_MESSAGE_PAGE_SIZE: usize = 200;

pub(super) enum MessageQuery {
    All {
        conversation_id: String,
    },
    Page {
        conversation_id: String,
        limit: usize,
        before: Option<(i64, String)>,
    },
}

pub(super) fn parse(value: &str) -> RuntimeResult<MessageQuery> {
    if let Some(conversation_id) = value.strip_prefix(MESSAGE_ALL_PREFIX) {
        if conversation_id.trim().is_empty() || conversation_id.contains('\t') {
            return Err(RuntimeError::Storage(
                "invalid full-history conversation id".to_owned(),
            ));
        }
        return Ok(MessageQuery::All {
            conversation_id: conversation_id.to_owned(),
        });
    }

    if let Some(encoded) = value.strip_prefix(MESSAGE_PAGE_PREFIX) {
        let mut parts = encoded.splitn(4, '\t');
        let conversation_id = parts.next().unwrap_or_default().trim();
        let limit = parts
            .next()
            .unwrap_or_default()
            .parse::<usize>()
            .map_err(|_| RuntimeError::Storage("invalid message page limit".to_owned()))?
            .clamp(1, MAX_MESSAGE_PAGE_SIZE);
        let before_created_at = parts.next().unwrap_or_default();
        let before_id = parts.next().unwrap_or_default();
        if conversation_id.is_empty() || before_id.contains('\t') {
            return Err(RuntimeError::Storage(
                "invalid message page conversation id".to_owned(),
            ));
        }
        let before = match (before_created_at.is_empty(), before_id.is_empty()) {
            (true, true) => None,
            (false, false) => Some((
                before_created_at.parse::<i64>().map_err(|_| {
                    RuntimeError::Storage("invalid message page cursor timestamp".to_owned())
                })?,
                before_id.to_owned(),
            )),
            _ => {
                return Err(RuntimeError::Storage(
                    "incomplete message page cursor".to_owned(),
                ));
            }
        };
        return Ok(MessageQuery::Page {
            conversation_id: conversation_id.to_owned(),
            limit,
            before,
        });
    }

    if value.trim().is_empty() || value.contains('\t') {
        return Err(RuntimeError::Storage(
            "invalid conversation id for message query".to_owned(),
        ));
    }
    Ok(MessageQuery::Page {
        conversation_id: value.to_owned(),
        limit: DEFAULT_MESSAGE_PAGE_SIZE,
        before: None,
    })
}

#[cfg(test)]
mod tests {
    use super::{MessageQuery, parse};

    #[test]
    fn parses_full_history_and_clamps_page_size() {
        assert!(matches!(
            parse("torchat-all-v1\tconversation").unwrap(),
            MessageQuery::All { .. }
        ));
        assert!(matches!(
            parse("torchat-page-v1\tconversation\t999\t\t").unwrap(),
            MessageQuery::Page { limit: 200, .. }
        ));
    }

    #[test]
    fn rejects_incomplete_cursor() {
        assert!(parse("torchat-page-v1\tconversation\t10\t123\t").is_err());
    }
}
