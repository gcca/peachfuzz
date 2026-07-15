#include "httplibshim.hpp"

#include <iterator>

#include "../3rdparty/httplib.h"

struct Server {
  httplib::Server server;
};

struct Request {
  const httplib::Request& request;
};

struct Response {
  httplib::Response& response;
};

Server* server_create(void) {
  return new (std::nothrow) Server();
}

void server_destroy(Server* server) {
  delete server;
}

void server_get(Server* s, const char* p, Handler h) {
  s->server.Get(p, [h](const httplib::Request& rq, httplib::Response& rs) {
    Request srq{rq};
    Response srs{rs};
    h(&srq, &srs);
  });
}

void server_post(Server* s, const char* p, Handler h) {
  s->server.Post(p, [h](const httplib::Request& rq, httplib::Response& rs) {
    Request srq{rq};
    Response srs{rs};
    h(&srq, &srs);
  });
}

void server_put(Server* s, const char* p, Handler h) {
  s->server.Put(p, [h](const httplib::Request& rq, httplib::Response& rs) {
    Request srq{rq};
    Response srs{rs};
    h(&srq, &srs);
  });
}

void server_delete(Server* s, const char* p, Handler h) {
  s->server.Delete(p, [h](const httplib::Request& rq, httplib::Response& rs) {
    Request srq{rq};
    Response srs{rs};
    h(&srq, &srs);
  });
}

void server_listen(Server* server, const char* host, const int port) {
  server->server.listen(host, port);
}

int server_bind_any(Server* server, const char* host) {
  return server->server.bind_to_any_port(host);
}

void server_listen_after_bind(Server* server) {
  server->server.listen_after_bind();
}

void server_stop(Server* server) {
  server->server.stop();
}

int server_is_running(Server* server) {
  return server->server.is_running() ? 1 : 0;
}

const char* request_path_param(const Request* r, const char* key) {
  auto it = r->request.path_params.find(key);
  if (it == r->request.path_params.end()) return nullptr;
  return it->second.c_str();
}

const char* request_param(const Request* r, const char* key) {
  auto it = r->request.params.find(key);
  if (it == r->request.params.end()) return nullptr;
  return it->second.c_str();
}

size_t request_param_count(const Request* r) {
  return r->request.params.size();
}

const char* request_param_key_at(const Request* r, size_t index) {
  if (index >= r->request.params.size()) return nullptr;
  auto it = r->request.params.begin();
  std::advance(it, index);
  return it->first.c_str();
}

const char* request_param_value_at(const Request* r, size_t index) {
  if (index >= r->request.params.size()) return nullptr;
  auto it = r->request.params.begin();
  std::advance(it, index);
  return it->second.c_str();
}

const char* request_header(const Request* r, const char* key) {
  auto it = r->request.headers.find(key);
  if (it == r->request.headers.end()) return nullptr;
  return it->second.c_str();
}

void response_set_redirect(Response* r, const char* url) {
  r->response.set_redirect(url);
}

void response_set_content(Response* r,
                          const char* s,
                          size_t n,
                          const char* content_type) {
  r->response.set_content(s, n, content_type);
}

void response_set_status(Response* r, int status) {
  r->response.status = status;
}

void response_set_cookie(Response* r,
                         const char* name,
                         const char* value,
                         const char* path,
                         int max_age_s,
                         int http_only,
                         int secure,
                         const char* same_site) {
  std::string cookie = std::string(name) + "=" + value;
  if (path && *path) cookie += "; Path=" + std::string(path);
  cookie += "; Max-Age=" + std::to_string(max_age_s);
  if (http_only) cookie += "; HttpOnly";
  if (secure) cookie += "; Secure";
  if (same_site && *same_site) cookie += "; SameSite=" + std::string(same_site);
  r->response.set_header("Set-Cookie", cookie);
}
