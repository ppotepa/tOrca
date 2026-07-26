#ifndef TORCHAT_CORE_H
#define TORCHAT_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct TorchatIdentity TorchatIdentity;
typedef struct TorchatConversation TorchatConversation;

typedef struct {
    uint8_t *data;
    size_t len;
} TorchatBytes;

typedef struct {
    TorchatBytes first;
    TorchatBytes second;
} TorchatPair;

char *torchat_last_error(void);
void torchat_free_string(char *value);
void torchat_free_bytes(TorchatBytes value);
void torchat_free_pair(TorchatPair value);

TorchatIdentity *torchat_identity_generate(void);
TorchatIdentity *torchat_identity_from_private_key(const uint8_t *data, size_t len);
void torchat_identity_free(TorchatIdentity *value);
char *torchat_identity_installation_id(const TorchatIdentity *value);
char *torchat_identity_public_key(const TorchatIdentity *value);
char *torchat_identity_fingerprint(const TorchatIdentity *value);
char *torchat_identity_sign(const TorchatIdentity *value, const uint8_t *data, size_t len);
char *torchat_identity_invite(const TorchatIdentity *value);
char *torchat_identity_contact_invite(const TorchatIdentity *value);

int32_t torchat_validate_contact_invite(const uint8_t *data, size_t len);
TorchatBytes torchat_contact_invite_key_package(const uint8_t *data, size_t len);

TorchatConversation *torchat_conversation_create(const TorchatIdentity *identity);
TorchatConversation *torchat_conversation_restore(const uint8_t *data, size_t len);
TorchatConversation *torchat_conversation_accept(
    const TorchatIdentity *identity,
    const uint8_t *welcome,
    size_t welcome_len,
    const uint8_t *tree,
    size_t tree_len);
void torchat_conversation_free(TorchatConversation *value);
TorchatPair torchat_conversation_invite(TorchatConversation *value, const uint8_t *key_package, size_t len);
TorchatBytes torchat_conversation_encrypt(TorchatConversation *value, const uint8_t *data, size_t len);
TorchatBytes torchat_conversation_decrypt(TorchatConversation *value, const uint8_t *data, size_t len);
TorchatBytes torchat_conversation_snapshot(const TorchatConversation *value);

#endif
