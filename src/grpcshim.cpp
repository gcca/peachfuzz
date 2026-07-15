#include "grpcshim.hpp"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <string>

#include <grpcpp/grpcpp.h>

#include "auth.grpc.pb.h"

struct GrpcClient {
  std::shared_ptr<grpc::Channel> channel;
  std::unique_ptr<urmom::v1::AuthService::Stub> stub;
};

namespace {

const UrmomUserInfo empty_user_info = {0, nullptr, 0};

UrmomUserInfo clone_user_info(const urmom::v1::UserInfo& info) {
  UrmomUserInfo out = empty_user_info;
  out.is_active = info.is_active() ? 1 : 0;
  out.apps_len = static_cast<size_t>(info.apps_size());
  if (out.apps_len == 0)
    return out;

  out.apps = static_cast<char**>(std::malloc(sizeof(char*) * out.apps_len));
  if (out.apps == nullptr) {
    out.apps_len = 0;
    return out;
  }

  for (int i = 0; i < info.apps_size(); ++i) {
    const std::string& app = info.apps(i);
    char* copy = static_cast<char*>(std::malloc(app.size() + 1));
    std::memcpy(copy, app.data(), app.size());
    copy[app.size()] = '\0';
    out.apps[i] = copy;
  }
  return out;
}

void free_user_info(UrmomUserInfo info) {
  for (size_t i = 0; i < info.apps_len; ++i)
    std::free(info.apps[i]);
  std::free(info.apps);
}

void set_deadline(grpc::ClientContext& context, int timeout_ms) {
  if (timeout_ms > 0) {
    context.set_deadline(std::chrono::system_clock::now() +
                         std::chrono::milliseconds(timeout_ms));
  }
}

}  // namespace

GrpcClient* grpc_client_create(const char* target) {
  GrpcClient* client = new (std::nothrow) GrpcClient;
  if (client == nullptr)
    return nullptr;

  try {
    client->channel =
        grpc::CreateChannel(target, grpc::InsecureChannelCredentials());
    client->stub = urmom::v1::AuthService::NewStub(client->channel);
    return client;
  } catch (...) {
    delete client;
    return nullptr;
  }
}

void grpc_client_destroy(GrpcClient* client) {
  delete client;
}

UrmomUserInfoResult grpc_auth_user_info(GrpcClient* client,
                                        const char* username,
                                        int timeout_ms) {
  UrmomUserInfoResult result = {static_cast<int>(grpc::StatusCode::INTERNAL), 0,
                                empty_user_info};
  if (client == nullptr)
    return result;

  try {
    urmom::v1::UserInfoRequest request;
    request.set_username(username);

    urmom::v1::UserInfoResponse response;
    grpc::ClientContext context;
    set_deadline(context, timeout_ms);

    const grpc::Status status =
        client->stub->UserInfo(&context, request, &response);
    result.status = status.error_code();
    if (status.ok() && response.has_userinfo()) {
      result.has_userinfo = 1;
      result.userinfo = clone_user_info(response.userinfo());
    }
  } catch (...) {
    result.status = static_cast<int>(grpc::StatusCode::INTERNAL);
  }
  return result;
}

UrmomAuthenticateResult grpc_auth_authenticate(GrpcClient* client,
                                               const char* username,
                                               const char* password,
                                               int timeout_ms) {
  UrmomAuthenticateResult result = {
      static_cast<int>(grpc::StatusCode::INTERNAL), 0, 0, empty_user_info};
  if (client == nullptr)
    return result;

  try {
    urmom::v1::AuthenticateRequest request;
    request.set_username(username);
    request.set_password(password);

    urmom::v1::AuthenticateResponse response;
    grpc::ClientContext context;
    set_deadline(context, timeout_ms);

    const grpc::Status status =
        client->stub->Authenticate(&context, request, &response);
    result.status = status.error_code();
    if (status.ok()) {
      result.authenticated = response.authenticated() ? 1 : 0;
      if (response.has_userinfo()) {
        result.has_userinfo = 1;
        result.userinfo = clone_user_info(response.userinfo());
      }
    }
  } catch (...) {
    result.status = static_cast<int>(grpc::StatusCode::INTERNAL);
  }
  return result;
}

void grpc_user_info_result_destroy(UrmomUserInfoResult result) {
  free_user_info(result.userinfo);
}

void grpc_authenticate_result_destroy(UrmomAuthenticateResult result) {
  free_user_info(result.userinfo);
}
