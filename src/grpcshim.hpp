#pragma once

#include <stddef.h>

typedef struct GrpcClient GrpcClient;

typedef struct UrmomUserInfo {
  int is_active;
  char** apps;
  size_t apps_len;
} UrmomUserInfo;

typedef struct UrmomUserInfoResult {
  int status;
  int has_userinfo;
  UrmomUserInfo userinfo;
} UrmomUserInfoResult;

typedef struct UrmomAuthenticateResult {
  int status;
  int authenticated;
  int has_userinfo;
  UrmomUserInfo userinfo;
} UrmomAuthenticateResult;

#ifdef __cplusplus
extern "C" {
#endif

GrpcClient* grpc_client_create(const char* target);
void grpc_client_destroy(GrpcClient* client);

UrmomUserInfoResult grpc_auth_user_info(GrpcClient* client,
                                        const char* username,
                                        int timeout_ms);

UrmomAuthenticateResult grpc_auth_authenticate(GrpcClient* client,
                                               const char* username,
                                               const char* password,
                                               int timeout_ms);

void grpc_user_info_result_destroy(UrmomUserInfoResult result);
void grpc_authenticate_result_destroy(UrmomAuthenticateResult result);

#ifdef __cplusplus
}
#endif
