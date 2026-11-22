#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *option(int argc, char **argv, const char *name) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            return argv[i + 1];
        }
    }
    return "";
}

static void start(const char *tools, const char *model) {
    printf("{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"%s\","
           "\"tools\":%s,\"mcp_servers\":[]}\n", model, tools);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char input[64001];
    size_t size = fread(input, 1, sizeof(input) - 1, stdin);
    input[size] = '\0';

    const char *denied = option(argc, argv, "--disallowed-tools");
    if (!strstr(denied, "read_file") || !strstr(denied, "run_terminal_command") ||
        !strstr(denied, "web_search") || !strstr(denied, "update_goal") ||
        !strstr(denied, "CallMcpTool") || !strstr(denied, "Agent") ||
        strcmp(option(argc, argv, "--max-turns"), "1") != 0 ||
        strcmp(option(argc, argv, "--permission-mode"), "dontAsk") != 0 ||
        strcmp(option(argc, argv, "--prompt-file"), "/dev/stdin") != 0 ||
        strcmp(option(argc, argv, "--output-format"), "streaming-messages-json") != 0 ||
        strcmp(option(argc, argv, "--system-prompt-override"), "") == 0 ||
        strcmp(option(argc, argv, "--reasoning-effort"), "low") != 0 ||
        strcmp(option(argc, argv, "--model"), "grok-4.7-build-fast") != 0 ||
        getenv("TEXTREAM_GROK_FIXTURE_SECRET") != NULL || getenv("XAI_API_KEY") != NULL) {
        return 8;
    }
    for (int i = 1; i < argc; i++) {
        if (strstr(argv[i], "exclusively-in-stdin-1db5") != NULL) {
            return 9;
        }
    }
    const char *grokHome = getenv("GROK_HOME");
    char path[1024];
    snprintf(path, sizeof(path), "%s/auth.json", grokHome == NULL ? "" : grokHome);
    struct stat info;
    if (lstat(path, &info) != 0 || !S_ISLNK(info.st_mode)) {
        return 10;
    }
    char cwd[1024];
    if (getcwd(cwd, sizeof(cwd)) == NULL || strcmp(cwd, option(argc, argv, "--cwd")) != 0) {
        return 11;
    }
    if (strstr(input, "exclusively-in-stdin-1db5") &&
        (!strstr(input, "Respond using complete sentences.") ||
         !strstr(input, "<textream_input>\nexclusively-in-stdin-1db5\n</textream_input>"))) {
        return 16;
    }

    if (strstr(input, "missing sign-in fixture")) {
        puts("{\"type\":\"error\",\"message\":\"Not signed in. Run grok login; private fixture detail.\"}");
        return 1;
    }
    if (strstr(input, "rate-limit fixture")) {
        puts("{\"type\":\"error\",\"message\":\"Provider rate limit; private fixture detail.\"}");
        return 1;
    }
    if (strstr(input, "unapproved model fixture")) {
        start("[]", "different-model");
        return 3;
    }
    if (strstr(input, "enabled tool fixture")) {
        start("[\"read_file\"]", "grok-4.7-build-fast");
        return 3;
    }

    start("[]", "grok-4.7-build-fast");
    if (strstr(input, "malformed fixture")) {
        puts("malformed stdout");
        return 0;
    }
    if (strstr(input, "unsupported tool output fixture")) {
        puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\"}}}");
        return 0;
    }
    if (strstr(input, "isolation-fixture:")) {
        FILE *login = fopen(path, "r");
        if (login == NULL) { return 17; }
        char contents[8] = {0};
        size_t length = fread(contents, 1, sizeof(contents) - 1, login);
        fclose(login);
        if (length != 2 || strcmp(contents, "{}") != 0 || fopen(path, "a") != NULL) { return 18; }
        char *host = strstr(input, "isolation-fixture:") + strlen("isolation-fixture:");
        char *end = strchr(host, '\n');
        if (end != NULL) { *end = '\0'; }
        if (fopen(host, "r") != NULL) { return 12; }
        if (fopen(host, "a") != NULL) { return 13; }
        pid_t child = fork();
        if (child == 0) { _exit(0); }
        if (child > 0) { waitpid(child, NULL, 0); return 14; }
        if (errno != EPERM && errno != EACCES) { return 15; }
        execl("/usr/bin/true", "true", (char *)NULL);
        if (errno != EPERM && errno != EACCES) { return 19; }
        puts("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"The process isolation succeeded.\"}");
        return 0;
    }
    if (strstr(input, "hold fixture")) {
        signal(SIGTERM, SIG_IGN);
        printf("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\","
               "\"delta\":{\"type\":\"text_delta\",\"text\":\"%d\"}}}\n", getpid());
        sleep(30);
        return 0;
    }
    if (strstr(input, "standalone early sentence fixture")) {
        puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"{\\\"part\\\":\\\"short\\\",\\\"kind\\\":\\\"supplemental\\\",\\\"text\\\":\\\"This short answer \"}}}");
        usleep(60000);
        puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"appears before the process ends.\\\",\\\"sources\\\":[]}\\n\"}}}");
        usleep(700000);
        puts("{\"type\":\"result\",\"subtype\":\"success\"}");
        return 0;
    }
    if (strstr(input, "result-only fixture")) {
        puts("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"The final result supplies the answer.\"}");
        return 0;
    }
    if (strstr(input, "result-then-linger fixture")) {
        signal(SIGTERM, SIG_IGN);
        printf("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"%d\"}\n", (int)getpid());
        sleep(30);
        return 0;
    }
    puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Ignored reasoning.\"}}}");
    puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"The answer\"}}}");
    puts("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" is complete.\"}}}");
    puts("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"The answer is complete.\"}]}}");
    puts("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"The answer is complete.\"}");
    return 0;
}
