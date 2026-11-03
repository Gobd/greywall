// Disposable native socket test. No credentials, project data, or system writes.
// Each role is compiled to a fresh, differently named executable so installed
// program and per-executable allow rules should not conceal process-tree behavior.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef TEST_ROLE
#define TEST_ROLE "parent"
#endif

static void sibling_path(const char *role, char *path, size_t length) {
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) { perror("executable path"); exit(1); }
    char *slash = strrchr(executable, '/');
    if (!slash) exit(1);
    *slash = '\0';
    if (snprintf(path, length, "%s/gw-lulu-%s", executable, role) >= (int)length) exit(1);
}

static int probe(int timeout_seconds) {
    printf("REQUEST role=%s pid=%d ppid=%d destination=1.1.1.1:80\n", TEST_ROLE, getpid(), getppid());
    // One harmless HTTP request to Cloudflare's public address. No DNS, proxy,
    // TLS interception, tokens, AWS state, cookies, or repository content.
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 2; }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return 2; }
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, "1.1.1.1", &address.sin_addr);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno != EINPROGRESS) goto failed;
    struct pollfd pending = {.fd = fd, .events = POLLOUT};
    if (poll(&pending, 1, timeout_seconds * 1000) <= 0) goto failed;
    int error = 0;
    socklen_t error_size = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) < 0 || error != 0) {
        if (error) errno = error;
        goto failed;
    }
    if (fcntl(fd, F_SETFL, flags) < 0) goto failed;
    struct timeval timeout = {.tv_sec = timeout_seconds};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    const char request[] = "GET / HTTP/1.1\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n";
    size_t sent = 0;
    while (sent < sizeof(request) - 1) {
        ssize_t count = send(fd, request + sent, sizeof(request) - 1 - sent, 0);
        if (count <= 0) goto failed;
        sent += (size_t)count;
    }
    char response[256];
    ssize_t count = recv(fd, response, sizeof(response) - 1, 0);
    if (count >= 5 && memcmp(response, "HTTP/", 5) == 0) {
        response[count] = '\0';
        char *newline = strpbrk(response, "\r\n");
        if (newline) *newline = '\0';
        printf("RESULT role=%s pid=%d HTTP_RESPONSE %s\n", TEST_ROLE, getpid(), response);
        close(fd);
        return 0;
    }
failed:
    printf("RESULT role=%s pid=%d NO_HTTP_RESPONSE errno=%d (%s) — correlate with LuLu, not proof of blocking alone\n",
           TEST_ROLE, getpid(), errno, strerror(errno));
    close(fd);
    return 2;
}

static int run_child(const char *role) {
    char path[4096];
    sibling_path(role, path, sizeof(path));
    pid_t child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        execl(path, path, (char *)NULL);
        perror("exec child");
        _exit(1);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static void detached_child(void) {
    // Parent -> intermediate -> detached. Intermediate exits before the network
    // attempt while the selected root stays alive. LuLu may lose the ancestry.
    pid_t intermediate = fork();
    if (intermediate < 0) return;
    if (intermediate == 0) {
        if (fork() == 0) {
            setsid();
            usleep(700000);
            char path[4096];
            sibling_path("detached", path, sizeof(path));
            execl(path, path, (char *)NULL);
            _exit(1);
        }
        _exit(0);
    }
    while (waitpid(intermediate, NULL, 0) < 0 && errno == EINTR) {}
    puts("Detached attempt scheduled; selected root is still alive. Watch its pid/ppid and result.");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGPIPE, SIG_IGN);
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    if (strcmp(TEST_ROLE, "parent") != 0) {
        int result = probe(5);
        if (strcmp(TEST_ROLE, "child") == 0) {
            int grandchild = run_child("grandchild");
            if (grandchild != 0) result = grandchild;
        }
        return result;
    }
    if (argc == 2 && strcmp(argv[1], "--baseline") == 0) {
        int result = probe(5);
        int child = run_child("child");
        return result == 0 && child == 0 ? 0 : 2;
    }
    if (argc != 2 || strcmp(argv[1], "--hold") != 0) {
        fprintf(stderr, "Usage: %s --baseline | --hold\n", argv[0]);
        return 1;
    }
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGUSR1);
    sigaddset(&signals, SIGUSR2);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT);
    sigprocmask(SIG_BLOCK, &signals, NULL);
    printf("READY parent pid=%d ppid=%d; no connection until trigger.\n", getpid(), getppid());
    int phase = 0;
    for (;;) {
        int received = 0;
        if (sigwait(&signals, &received) != 0) return 1;
        if (received == SIGTERM || received == SIGINT) { puts("STOP: test root exiting; lifetime rule should expire."); return 0; }
        if (received == SIGUSR2) { detached_child(); continue; }
        if (phase++ == 0) {
            puts("TRIGGER: parent connection; respond to the LuLu alert within 90 seconds.");
            probe(90);
            puts("Parent request finished. Root remains alive; set passive mode before testing descendants.");
        } else {
            puts("DESCENDANTS: live child and grandchild test.");
            run_child("child");
            puts("Descendant attempts finished; root remains alive.");
        }
    }
}
