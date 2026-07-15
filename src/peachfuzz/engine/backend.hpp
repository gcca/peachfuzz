#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

char *engine_python_run(const char *body, const char *const *args, size_t nargs);
void engine_python_free(char *p);

#ifdef __cplusplus
}
#endif
