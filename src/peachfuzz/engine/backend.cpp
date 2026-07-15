#include "backend.hpp"

#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace {

char *dup_utf8(const char *s, size_t n) {
    char *out = static_cast<char *>(std::malloc(n + 1));
    if (!out) return nullptr;
    std::memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

std::string python_executable() {
    const char *venv = std::getenv("VIRTUAL_ENV");
    if (venv && *venv) return std::string(venv) + "/bin/python3";
    return "python3";
}

std::string xa6_executable() {
    const char *bin = std::getenv("PEACHFUZZ_XA6_BIN");
    if (bin && *bin) return std::string(bin);
    return "xa6";
}

} // namespace

extern "C" char *engine_python_run(const char *body, const char *const *args, size_t nargs) {
    if (!body) return nullptr;

    int stdin_pipe[2];
    int stdout_pipe[2];
    if (pipe(stdin_pipe) != 0) return nullptr;
    if (pipe(stdout_pipe) != 0) {
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        return nullptr;
    }

    const std::string python_bin = python_executable();
    std::vector<char *> argv;
    argv.push_back(const_cast<char *>(python_bin.c_str()));
    argv.push_back(const_cast<char *>("-"));
    for (size_t i = 0; i < nargs; i++) argv.push_back(const_cast<char *>(args[i]));
    argv.push_back(nullptr);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdin_pipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);

    pid_t pid = 0;
    const int spawn_rc = posix_spawnp(&pid, python_bin.c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    if (spawn_rc != 0) {
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        return nullptr;
    }

    const size_t body_len = std::strlen(body);
    size_t written = 0;
    while (written < body_len) {
        const ssize_t n = write(stdin_pipe[1], body + written, body_len - written);
        if (n <= 0) break;
        written += static_cast<size_t>(n);
    }
    close(stdin_pipe[1]);

    std::string output;
    char buf[4096];
    ssize_t n = 0;
    while ((n = read(stdout_pipe[0], buf, sizeof(buf))) > 0) {
        output.append(buf, static_cast<size_t>(n));
    }
    close(stdout_pipe[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0)) return nullptr;

    return dup_utf8(output.data(), output.size());
}

extern "C" void engine_python_free(char *p) {
    std::free(p);
}

extern "C" char *engine_xa6_run(const char *body, const char *const *args, size_t nargs) {
    if (!body) return nullptr;

    int stdin_pipe[2];
    int stdout_pipe[2];
    if (pipe(stdin_pipe) != 0) return nullptr;
    if (pipe(stdout_pipe) != 0) {
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        return nullptr;
    }

    const std::string xa6_bin = xa6_executable();
    std::vector<char *> argv;
    argv.push_back(const_cast<char *>(xa6_bin.c_str()));
    argv.push_back(const_cast<char *>("-"));
    for (size_t i = 0; i < nargs; i++) argv.push_back(const_cast<char *>(args[i]));
    argv.push_back(nullptr);

    const char *xa6_libdir = std::getenv("PEACHFUZZ_XA6_LIBDIR");
    const char *existing_ld = std::getenv("LD_LIBRARY_PATH");
    const char *existing_ddb = std::getenv("XA6_CON_DDB_PATH");
    const bool override_ld = xa6_libdir && *xa6_libdir;
    const bool add_ddb = !(existing_ddb && *existing_ddb);

    std::vector<std::string> owned;
    std::vector<char *> envp;
    for (char **e = environ; *e; ++e) {
        if (override_ld && std::string_view(*e).rfind("LD_LIBRARY_PATH=", 0) == 0) continue;
        envp.push_back(*e);
    }
    if (override_ld) {
        std::string value = "LD_LIBRARY_PATH=";
        value += xa6_libdir;
        if (existing_ld && *existing_ld) {
            value += ":";
            value += existing_ld;
        }
        owned.push_back(std::move(value));
    }
    if (add_ddb) owned.push_back(std::string("XA6_CON_DDB_PATH=data/datamark.db"));
    for (std::string &s : owned) envp.push_back(const_cast<char *>(s.c_str()));
    envp.push_back(nullptr);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdin_pipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdin_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);

    pid_t pid = 0;
    const int spawn_rc = posix_spawnp(&pid, xa6_bin.c_str(), &actions, nullptr, argv.data(), envp.data());
    posix_spawn_file_actions_destroy(&actions);

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    if (spawn_rc != 0) {
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        return nullptr;
    }

    const size_t body_len = std::strlen(body);
    size_t written = 0;
    while (written < body_len) {
        const ssize_t n = write(stdin_pipe[1], body + written, body_len - written);
        if (n <= 0) break;
        written += static_cast<size_t>(n);
    }
    close(stdin_pipe[1]);

    std::string output;
    char buf[4096];
    ssize_t n = 0;
    while ((n = read(stdout_pipe[0], buf, sizeof(buf))) > 0) {
        output.append(buf, static_cast<size_t>(n));
    }
    close(stdout_pipe[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0)) return nullptr;

    static const char kBanner[] = "INFO: Starting Xa6\n";
    const size_t banner_len = sizeof(kBanner) - 1;
    const char *start = output.data();
    size_t length = output.size();
    if (length >= banner_len && std::memcmp(start, kBanner, banner_len) == 0) {
        start += banner_len;
        length -= banner_len;
    }

    return dup_utf8(start, length);
}

extern "C" void engine_xa6_free(char *p) {
    std::free(p);
}
