#include "CGSS.h"

#include <GSS/gssapi.h>
#include <GSS/gssapi_spnego.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct fp_gss_context {
  gss_ctx_id_t context;
  gss_name_t target;
};

static void set_error(char *error, size_t error_len, const char *format, ...) {
  if (error == NULL || error_len == 0) {
    return;
  }
  va_list args;
  va_start(args, format);
  vsnprintf(error, error_len, format, args);
  va_end(args);
  error[error_len - 1] = '\0';
}

static void append_status(char *buffer, size_t buffer_len, OM_uint32 code,
                          int status_type) {
  OM_uint32 minor = 0;
  OM_uint32 message_context = 0;
  gss_buffer_desc message = GSS_C_EMPTY_BUFFER;

  do {
    if (gss_display_status(&minor, code, status_type, GSS_C_NO_OID,
                           &message_context, &message) != GSS_S_COMPLETE) {
      break;
    }
    size_t used = strlen(buffer);
    if (used < buffer_len) {
      snprintf(buffer + used, buffer_len - used, "%s%s",
               used == 0 ? "" : "; ",
               message.value != NULL ? (const char *)message.value : "unknown GSS error");
    }
    gss_release_buffer(&minor, &message);
  } while (message_context != 0);
}

static void format_gss_error(char *error, size_t error_len, const char *stage,
                             OM_uint32 major, OM_uint32 minor) {
  char details[512] = {0};
  append_status(details, sizeof(details), major, GSS_C_GSS_CODE);
  char minor_details[256] = {0};
  append_status(minor_details, sizeof(minor_details), minor, GSS_C_MECH_CODE);

  if (minor_details[0] != '\0') {
    set_error(error, error_len, "%s failed: %s (%s)", stage, details, minor_details);
  } else {
    set_error(error, error_len, "%s failed: %s", stage, details);
  }
}

int fp_gss_create(const char *proxy_host, fp_gss_context **out, char *error,
                  size_t error_len) {
  if (proxy_host == NULL || out == NULL) {
    set_error(error, error_len, "invalid arguments");
    return 1;
  }

  *out = NULL;
  fp_gss_context *context = calloc(1, sizeof(fp_gss_context));
  if (context == NULL) {
    set_error(error, error_len, "out of memory");
    return 1;
  }
  context->context = GSS_C_NO_CONTEXT;
  context->target = GSS_C_NO_NAME;

  char service_name[1024];
  int written = snprintf(service_name, sizeof(service_name), "HTTP@%s", proxy_host);
  if (written < 0 || (size_t)written >= sizeof(service_name)) {
    set_error(error, error_len, "proxy host name is too long");
    free(context);
    return 1;
  }

  gss_buffer_desc name_buffer = GSS_C_EMPTY_BUFFER;
  name_buffer.length = strlen(service_name);
  name_buffer.value = service_name;

  OM_uint32 minor = 0;
  OM_uint32 major = gss_import_name(&minor, &name_buffer,
                                    GSS_C_NT_HOSTBASED_SERVICE, &context->target);
  if (major != GSS_S_COMPLETE) {
    format_gss_error(error, error_len, "gss_import_name", major, minor);
    free(context);
    return 1;
  }

  *out = context;
  return 0;
}

int fp_gss_step(fp_gss_context *context, const uint8_t *input, size_t input_len,
                uint8_t **output, size_t *output_len, int *complete,
                char *error, size_t error_len) {
  if (context == NULL || output == NULL || output_len == NULL || complete == NULL) {
    set_error(error, error_len, "invalid arguments");
    return 1;
  }

  *output = NULL;
  *output_len = 0;
  *complete = 0;

  gss_buffer_desc input_buffer = GSS_C_EMPTY_BUFFER;
  gss_buffer_t input_pointer = GSS_C_NO_BUFFER;
  if (input != NULL && input_len > 0) {
    input_buffer.length = input_len;
    input_buffer.value = (void *)input;
    input_pointer = &input_buffer;
  }

  gss_buffer_desc output_buffer = GSS_C_EMPTY_BUFFER;
  OM_uint32 minor = 0;
  OM_uint32 major = gss_init_sec_context(
      &minor, GSS_C_NO_CREDENTIAL, &context->context, context->target,
      GSS_SPNEGO_MECHANISM, 0, 0, GSS_C_NO_CHANNEL_BINDINGS, input_pointer,
      NULL, &output_buffer, NULL, NULL);

  if (major != GSS_S_COMPLETE && major != GSS_S_CONTINUE_NEEDED) {
    format_gss_error(error, error_len, "gss_init_sec_context", major, minor);
    if (output_buffer.value != NULL) {
      gss_release_buffer(&minor, &output_buffer);
    }
    return 1;
  }

  if (output_buffer.length > 0) {
    uint8_t *copy = malloc(output_buffer.length);
    if (copy == NULL) {
      gss_release_buffer(&minor, &output_buffer);
      set_error(error, error_len, "out of memory");
      return 1;
    }
    memcpy(copy, output_buffer.value, output_buffer.length);
    *output = copy;
    *output_len = output_buffer.length;
  }

  if (output_buffer.value != NULL) {
    gss_release_buffer(&minor, &output_buffer);
  }
  *complete = major == GSS_S_COMPLETE ? 1 : 0;
  return 0;
}

void fp_gss_buffer_free(uint8_t *buffer) {
  free(buffer);
}

void fp_gss_destroy(fp_gss_context *context) {
  if (context == NULL) {
    return;
  }
  OM_uint32 minor = 0;
  if (context->context != GSS_C_NO_CONTEXT) {
    gss_delete_sec_context(&minor, &context->context, GSS_C_NO_BUFFER);
  }
  if (context->target != GSS_C_NO_NAME) {
    gss_release_name(&minor, &context->target);
  }
  free(context);
}
