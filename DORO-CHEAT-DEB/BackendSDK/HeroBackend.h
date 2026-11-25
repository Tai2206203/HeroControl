#ifndef HERO_BACKEND_H
#define HERO_BACKEND_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// All three symbols must be visible from the dynamic library.
uint32_t hc_backend_api_version(void);
// Request is valid only until this function returns. Copy it if needed.
// Returns owned, NUL-terminated UTF-8 JSON, at most 4 MiB excluding NUL.
// Calls are serialized by the app; do not call UI APIs directly here.
const char *hc_backend_request(const char *request_json);
// Free the returned allocation, on every successful request and decode failure.
void hc_backend_release(const char *response_json);
#ifdef __cplusplus
}
#endif
#endif
