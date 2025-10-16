#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <semaphore.h>
#include <time.h>
#include <ctype.h>
#include <errno.h>

#define PORT 8080
#define N_COINS 3
#define TIME_LIMIT 30
#define BUF_SIZE 4096

#define STATE_FREE 0
#define STATE_OCCUPIED 1
#define STATE_DISCOVERED 2

typedef struct {
    int id;
    int state;
    int secret_number;
    pthread_t timer_tid;
} Coin;

Coin coins[N_COINS];
sem_t coins_sem;
pthread_mutex_t coins_lock = PTHREAD_MUTEX_INITIALIZER;

int game_over = 0;
pthread_mutex_t game_lock = PTHREAD_MUTEX_INITIALIZER;

/* ========================= UTILITÁRIOS ========================= */
static void url_decode(char *dst, const char *src) {
    char a, b;
    while (*src) {
        if ((*src == '%') && ((a = src[1]) && (b = src[2])) &&
            isxdigit(a) && isxdigit(b)) {
            char hex[3] = {a, b, 0};
            *dst++ = (char) strtol(hex, NULL, 16);
            src += 3;
        } else if (*src == '+') {
            *dst++ = ' ';
            src++;
        } else {
            *dst++ = *src++;
        }
    }
    *dst = '\0';
}

static void init_coins() {
    srand((unsigned)time(NULL));
    pthread_mutex_lock(&coins_lock);
    for (int i = 0; i < N_COINS; ++i) {
        coins[i].id = i;
        coins[i].state = STATE_FREE;
        coins[i].secret_number = rand() % 10;
    }
    pthread_mutex_unlock(&coins_lock);
    sem_init(&coins_sem, 0, N_COINS);
    pthread_mutex_lock(&game_lock);
    game_over = 0;
    pthread_mutex_unlock(&game_lock);
}

/* ========================= THREAD TEMPORIZADORA ========================= */
void *timer_thread(void *arg) {
    int id = *(int*)arg;
    free(arg);
    sleep(TIME_LIMIT);

    pthread_mutex_lock(&coins_lock);
    if (coins[id].state == STATE_OCCUPIED) {
        coins[id].state = STATE_FREE;
        sem_post(&coins_sem);
        printf("[timer] Tempo expirou! Moeda %d liberada.\n", id);
    }
    pthread_mutex_unlock(&coins_lock);
    return NULL;
}

/* ========================= HTTP AUXILIARES ========================= */
static void send_response(int client_fd, const char *content_type, const char *body) {
    char header[512];
    int len = snprintf(header, sizeof(header),
                       "HTTP/1.1 200 OK\r\n"
                       "Content-Type: %s\r\n"
                       "Content-Length: %zu\r\n"
                       "Connection: close\r\n\r\n",
                       content_type, strlen(body));
    send(client_fd, header, len, 0);
    send(client_fd, body, strlen(body), 0);
}

static void send_404(int client_fd) {
    const char *body = "{\"error\":\"Not found\"}\n";
    send_response(client_fd, "application/json", body);
}

static char *get_query_value(const char *query, const char *key) {
    if (!query || !key) return NULL;
    size_t klen = strlen(key);
    const char *p = query;
    while (p && *p) {
        const char *eq = strchr(p, '=');
        if (!eq) break;
        size_t keylen = eq - p;
        if (keylen == klen && strncmp(p, key, klen) == 0) {
            const char *valstart = eq + 1;
            const char *amp = strchr(valstart, '&');
            size_t vlen = amp ? (size_t)(amp - valstart) : strlen(valstart);
            char *raw = malloc(vlen + 1);
            memcpy(raw, valstart, vlen);
            raw[vlen] = '\0';
            char *decoded = malloc(vlen + 1);
            url_decode(decoded, raw);
            free(raw);
            return decoded;
        }
        const char *next = strchr(p, '&');
        if (!next) break;
        p = next + 1;
    }
    return NULL;
}

/* ========================= HANDLERS ========================= */
static void handle_collect(int client_fd) {
    pthread_mutex_lock(&game_lock);
    int over = game_over;
    pthread_mutex_unlock(&game_lock);
    if (over) {
        send_response(client_fd, "application/json",
                      "{\"msg\":\"Fim de jogo! Todas as moedas descobertas.\"}\n");
        return;
    }

    printf("[collect] tentando sem_wait() (bloqueante)\n");
    sem_wait(&coins_sem);
    printf("[collect] passou sem_wait()\n");

    pthread_mutex_lock(&coins_lock);
    int found = -1;
    for (int i = 0; i < N_COINS; ++i) {
        if (coins[i].state == STATE_FREE) {
            coins[i].state = STATE_OCCUPIED;
            found = i;
            break;
        }
    }
    pthread_mutex_unlock(&coins_lock);

    if (found == -1) {
        sem_post(&coins_sem);
        send_response(client_fd, "application/json",
                      "{\"error\":\"Estado inconsistente\"}\n");
        return;
    }

    int *arg = malloc(sizeof(int));
    *arg = found;
    pthread_t tid;
    pthread_create(&tid, NULL, timer_thread, arg);
    pthread_detach(tid);

    char body[256];
    snprintf(body, sizeof(body),
             "{\"msg\":\"Moeda coletada!\",\"coin_id\":%d,\"time_limit\":%d}\n",
             found, TIME_LIMIT);
    send_response(client_fd, "application/json", body);
}

static void handle_guess(int client_fd, const char *query) {
    char *id_s = get_query_value(query, "id");
    char *value_s = get_query_value(query, "value");

    if (!id_s || !value_s) {
        send_response(client_fd, "application/json",
                      "{\"result\":\"invalid or unavailable\"}\n");
        free(id_s); free(value_s);
        return;
    }

    int id = atoi(id_s);
    int val = atoi(value_s);
    free(id_s); free(value_s);

    if (id < 0 || id >= N_COINS) {
        send_response(client_fd, "application/json",
                      "{\"result\":\"invalid or unavailable\"}\n");
        return;
    }

    pthread_mutex_lock(&coins_lock);
    int state = coins[id].state;
    int secret = coins[id].secret_number;
    if (state != STATE_OCCUPIED) {
        pthread_mutex_unlock(&coins_lock);
        send_response(client_fd, "application/json",
                      "{\"result\":\"invalid or unavailable\"}\n");
        return;
    }

    if (val == secret) {
        coins[id].state = STATE_DISCOVERED;
        pthread_mutex_unlock(&coins_lock);
        sem_post(&coins_sem);

        // verificar se o jogo terminou
        pthread_mutex_lock(&coins_lock);
        int all = 1;
        for (int i = 0; i < N_COINS; i++)
            if (coins[i].state != STATE_DISCOVERED) all = 0;
        pthread_mutex_unlock(&coins_lock);
        pthread_mutex_lock(&game_lock);
        game_over = all;
        pthread_mutex_unlock(&game_lock);

        if (all)
            send_response(client_fd, "application/json",
                          "{\"result\":\"correct\",\"msg\":\"Voce acertou! Fim de jogo!\"}\n");
        else
            send_response(client_fd, "application/json",
                          "{\"result\":\"correct\",\"msg\":\"Voce acertou!\"}\n");
    } else {
        pthread_mutex_unlock(&coins_lock);
        send_response(client_fd, "application/json",
                      "{\"result\":\"wrong\",\"msg\":\"Tente novamente!\"}\n");
    }
}

static void handle_status(int client_fd) {
    pthread_mutex_lock(&coins_lock);
    char body[1024];
    int offset = snprintf(body, sizeof(body), "{\"coins\":[");
    for (int i = 0; i < N_COINS; ++i) {
        offset += snprintf(body + offset, sizeof(body) - offset,
                           "{\"id\":%d,\"state\":%d}", coins[i].id, coins[i].state);
        if (i < N_COINS - 1) offset += snprintf(body + offset, sizeof(body) - offset, ",");
    }
    offset += snprintf(body + offset, sizeof(body) - offset, "]}");
    pthread_mutex_unlock(&coins_lock);

    send_response(client_fd, "application/json", body);
}

static void handle_reset(int client_fd) {
    pthread_mutex_lock(&coins_lock);
    for (int i = 0; i < N_COINS; ++i) {
        coins[i].state = STATE_FREE;
        coins[i].secret_number = rand() % 10;
    }
    pthread_mutex_unlock(&coins_lock);

    sem_destroy(&coins_sem);
    sem_init(&coins_sem, 0, N_COINS);

    pthread_mutex_lock(&game_lock);
    game_over = 0;
    pthread_mutex_unlock(&game_lock);

    send_response(client_fd, "application/json", "{\"msg\":\"Jogo reiniciado\"}\n");
}

/* ========================= INTERFACE HTML ========================= */
static void handle_index(int client_fd) {
    const char *html =
"<!DOCTYPE html><html><head><meta charset='utf-8'><title>Jogo da Moeda</title>"
"<style>body{font-family:sans-serif;text-align:center;background:#fafafa;margin-top:30px}"
"button{margin:5px;padding:8px 16px;font-size:16px}#coins{margin-top:20px}</style></head>"
"<body><h1>Jogo Adivinhe a Moeda</h1>"
"<div id='status'>Carregando...</div>"
"<div><button onclick='collect()'>Coletar moeda</button></div>"
"<div><input id='id' type='number' placeholder='ID'> "
"<input id='val' type='number' placeholder='Valor (0-9)'> "
"<button onclick='guess()'>Adivinhar</button></div>"
"<div><button onclick='reset()'>Reiniciar jogo</button></div>"
"<script>"
"async function update(){"
" let r=await fetch('/status');"
" let d=await r.json();"
" let html='<h3>Moedas:</h3><ul>';"
" d.coins.forEach(c=>{"
"  let s=c.state==0?'LIVRE':c.state==1?'OCUPADA':'DESCOBERTA';"
"  html+=`<li>Moeda ${c.id}: ${s}</li>`;"
" });"
" html+='</ul>'; document.getElementById('status').innerHTML=html;"
"}"
"async function collect(){let r=await fetch('/collect');alert(await r.text());update();}"
"async function guess(){let id=document.getElementById('id').value;"
"let v=document.getElementById('val').value;"
"let r=await fetch(`/guess?id=${id}&value=${v}`);alert(await r.text());update();}"
"async function reset(){let r=await fetch('/reset');alert(await r.text());update();}"
"setInterval(update,3000);update();"
"</script></body></html>";
    send_response(client_fd, "text/html", html);
}

/* ========================= CONEXÃO CLIENTE ========================= */
static void handle_client(int client_fd) {
    char buf[BUF_SIZE];
    int r = recv(client_fd, buf, sizeof(buf) - 1, 0);
    if (r <= 0) { close(client_fd); return; }
    buf[r] = '\0';

    char method[8], path[256];
    if (sscanf(buf, "%7s %255s", method, path) != 2) {
        send_404(client_fd);
        close(client_fd);
        return;
    }

    char *qmark = strchr(path, '?');
    char *query = NULL;
    if (qmark) { *qmark = '\0'; query = qmark + 1; }

    if (strcmp(method, "GET") != 0) {
        send_404(client_fd);
        close(client_fd);
        return;
    }

    if (strcmp(path, "/") == 0 || strcmp(path, "/index.html") == 0) handle_index(client_fd);
    else if (strcmp(path, "/collect") == 0) handle_collect(client_fd);
    else if (strcmp(path, "/guess") == 0) handle_guess(client_fd, query);
    else if (strcmp(path, "/status") == 0) handle_status(client_fd);
    else if (strcmp(path, "/reset") == 0) handle_reset(client_fd);
    else send_404(client_fd);

    close(client_fd);
}

/* Thread wrapper */
void *conn_thread(void *arg) {
    int fd = *(int*)arg;
    free(arg);
    handle_client(fd);
    return NULL;
}

/* ========================= MAIN ========================= */
int main(void) {
    init_coins();

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); exit(1); }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(server_fd); exit(1);
    }
    if (listen(server_fd, 16) < 0) {
        perror("listen"); close(server_fd); exit(1);
    }

    printf("Servidor rodando na porta %d\n", PORT);
    while (1) {
        struct sockaddr_in client;
        socklen_t clen = sizeof(client);
        int client_fd = accept(server_fd, (struct sockaddr*)&client, &clen);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        pthread_t tid;
        int *pclient = malloc(sizeof(int));
        *pclient = client_fd;
        pthread_create(&tid, NULL, conn_thread, pclient);
        pthread_detach(tid);
    }

    close(server_fd);
    return 0;
}
