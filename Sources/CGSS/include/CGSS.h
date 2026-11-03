#ifndef FASTPROXY_CGSS_H
#define FASTPROXY_CGSS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fp_gss_context fp_gss_context;

/// Creates a SPNEGO initiator context for `HTTP@<proxyHost>`.
int fp_gss_create(const char *proxy_host, fp_gss_context **out, char *error, size_t error_len);

/// Advances the context. Pass input == NULL for the initial token.
/// On success returns 0, sets *output to a malloc'd buffer (caller frees with
/// fp_gss_buffer_free), and sets *complete to 1 when the context is complete.
int fp_gss_step(fp_gss_context *context,
                const uint8_t *input,
                size_t input_len,
                uint8_t **output,
                size_t *output_len,
                int *complete,
                char *error,
                size_t error_len);

void fp_gss_buffer_free(uint8_t *buffer);
void fp_gss_destroy(fp_gss_context *context);

#ifdef __cplusplus
}
#endif

#endif
