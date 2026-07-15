#include "mustacheshim.hpp"

#include "../3rdparty/mustache.hpp"

struct Mustache {
  kainjow::mustache::mustache mustache;
};

struct Data {
  kainjow::mustache::data data;
};

size_t MustacheSize = sizeof(Mustache);
size_t MustacheAlign = alignof(Mustache);

Mustache* mustache_init(void* m, const char* s) {
  return new (m) Mustache{kainjow::mustache::mustache{s}};
}

void mustache_deinit(Mustache* mustache) {
  mustache->~Mustache();
}

void mustache_render(Mustache* mustache, Data* data, RenderHandler h, void* p) {
  mustache->mustache.render(
      data->data, [h, p](const std::string& c) { h(p, c.data(), c.size()); });
}

size_t DataSize = sizeof(Data);
size_t DataAlign = alignof(Data);

Data* data_init(void* m) {
  return new (m) Data{};
}

void data_deinit(Data* data) {
  data->~Data();
}

void data_setstring(Data* d, const char* s, const char* v) {
  d->data.set(s, v);
}

void data_setbool(Data* d, const char* s, bool v) {
  d->data.set(s, v);
}

void data_setdata(Data* d, const char* s, Data* v) {
  d->data.set(s, v->data);
}
