#pragma once

#include <stddef.h>

typedef struct Server Server;
typedef struct Request Request;
typedef struct Response Response;

typedef void (*Handler)(const Request* req, Response* res);

#ifdef __cplusplus
extern "C" {
#endif

Server* server_create(void);
void server_destroy(Server*);
void server_get(Server*, const char* pattern, Handler handler);
void server_post(Server*, const char* pattern, Handler handler);
void server_put(Server*, const char* pattern, Handler handler);
void server_delete(Server*, const char* pattern, Handler handler);
void server_listen(Server*, const char* host, int port);
int server_bind_any(Server*, const char* host);
void server_listen_after_bind(Server*);
void server_stop(Server*);
int server_is_running(Server*);

const char* request_path_param(const Request*, const char* key);
const char* request_param(const Request*, const char* key);
size_t request_param_count(const Request*);
const char* request_param_key_at(const Request*, size_t index);
const char* request_param_value_at(const Request*, size_t index);
const char* request_header(const Request*, const char* key);

void response_set_redirect(Response*, const char* url);
void response_set_content(Response*,
                          const char* s,
                          size_t n,
                          const char* content_type);
void response_set_status(Response*, int status);
void response_set_cookie(Response*,
                         const char* name,
                         const char* value,
                         const char* path,
                         int max_age_s,
                         int http_only,
                         int secure,
                         const char* same_site);

#ifdef __cplusplus
}
#endif
