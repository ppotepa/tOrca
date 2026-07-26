# Protocol errors v1

Servers return `{"error":"code"}` with HTTP status. MVP codes are:
`invalid_request`, `invalid_signature`, `challenge_expired`,
`challenge_replayed`, `installation_not_found`, `envelope_not_found`,
`envelope_replayed`, and `rate_limited`.
