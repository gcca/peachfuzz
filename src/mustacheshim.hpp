#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct Mustache Mustache;
typedef struct Data Data;

typedef void (*RenderHandler)(void *ctx, const char *chunk, size_t length);

extern size_t MustacheSize;
extern size_t MustacheAlign;
extern size_t DataSize;
extern size_t DataAlign;

#ifdef __cplusplus
extern "C" {
#endif

Mustache *mustache_init(void *, const char *s);
void mustache_deinit(Mustache *);
void mustache_render(Mustache *, Data *, RenderHandler h, void *p);

Data *data_init(void *);
void data_deinit(Data *);
void data_setstring(Data *, const char *s, const char *v);
void data_setbool(Data *, const char *s, bool v);
void data_setdata(Data *, const char *s, Data *v);

#ifdef __cplusplus
}
#endif
