#ifndef MIRROR_FAIRPLAY_BRIDGE_H
#define MIRROR_FAIRPLAY_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mlfp_context mlfp_context;

mlfp_context *mlfp_create(void);
void mlfp_destroy(mlfp_context *ctx);
void mlfp_reset(mlfp_context *ctx);

int mlfp_setup(
    mlfp_context *ctx,
    const uint8_t *request,
    size_t request_len,
    uint8_t *response,
    size_t response_capacity
);

int mlfp_handshake(
    mlfp_context *ctx,
    const uint8_t *request,
    size_t request_len,
    uint8_t *response,
    size_t response_capacity
);

int mlfp_decrypt_session_key(
    mlfp_context *ctx,
    const uint8_t *encrypted_key,
    size_t encrypted_key_len,
    uint8_t *session_key,
    size_t session_key_capacity
);

int mlfp_prepare_video_crypto(
    mlfp_context *ctx,
    const uint8_t *session_key,
    size_t session_key_len,
    uint64_t stream_connection_id
);

int mlfp_decrypt_video(
    mlfp_context *ctx,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_capacity
);

int mlfp_video_crypto_ready(const mlfp_context *ctx);

int mlfp_decrypt_audio_cbc(
    mlfp_context *ctx,
    const uint8_t *session_key,
    size_t session_key_len,
    const uint8_t *iv,
    size_t iv_len,
    const uint8_t *input,
    size_t input_len,
    uint8_t *output,
    size_t output_capacity
);

const char *mlfp_version(void);

#ifdef __cplusplus
}
#endif

#endif
