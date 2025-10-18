# Relatório: Jogo da Moeda - Semáforos em C

**Disciplina:** Sistemas Operacionais  
**Tema:** Sincronização com Semáforos POSIX  

---

## Autores:
- [Beatriz Coan] (https://github.com/beatrizzcoan)
- [Hugo Z. Bonome] (https://github.com/HugoBonome)

## 1. Visão Geral

Implementação de um servidor HTTP multi-thread que demonstra o uso de **semáforos POSIX** para controle de recursos limitados. O sistema simula um jogo onde jogadores competem por 3 moedas, cada uma com um número secreto (0-9).

**Regras:**
- 3 moedas disponíveis simultaneamente
- 30 segundos para adivinhar o número
- Acerto: moeda descoberta
- Timeout: moeda liberada automaticamente

---

## 2. Arquitetura

```
Cliente HTTP → Thread → Semáforo → Recurso (Moeda)
```

**Mecanismos de sincronização:**
```c
sem_t coins_sem;              // Controla 3 moedas disponíveis
pthread_mutex_t coins_lock;   // Protege array de moedas
```

**Estados da moeda:**
```c
STATE_FREE (0) → STATE_OCCUPIED (1) → STATE_DISCOVERED (2)
```

---

## 3. Operações com Semáforos

### 3.1 Inicialização
```c
sem_init(&coins_sem, 0, N_COINS);  // Contador = 3
```

### 3.2 Coleta de Moeda (sem_wait)
```c
static void handle_collect(int client_fd) {
    sem_wait(&coins_sem);  // Decrementa ou BLOQUEIA se = 0
    
    // Marca moeda como OCCUPIED
    coins[i].state = STATE_OCCUPIED;
    
    // Cria timer de 30 segundos
    pthread_create(&tid, NULL, timer_thread, &i);
}
```

**Comportamento:**
| Contador | Ação | Resultado |
|----------|------|-----------|
| 3 → 2, 2 → 1, 1 → 0 | Decrementa | Continua ✅ |
| 0 → 0 | **BLOQUEIA** | Thread suspensa ⏸️ |

### 3.3 Liberação por Acerto (sem_post)
```c
if (val == coins[id].secret_number) {
    coins[id].state = STATE_DISCOVERED;
    sem_post(&coins_sem);  // Incrementa, acorda thread bloqueada
}
```

### 3.4 Liberação por Timeout (sem_post)
```c
void *timer_thread(void *arg) {
    sleep(30);  // Aguarda 30s
    
    if (coins[id].state == STATE_OCCUPIED) {
        coins[id].state = STATE_FREE;
        sem_post(&coins_sem);  // Libera recurso
    }
}
```

### 3.5 Reset
```c
sem_destroy(&coins_sem);
sem_init(&coins_sem, 0, N_COINS);  // Recria com contador = 3
```

---

## 4. Problema Resolvido: Race Condition

**❌ Sem semáforo:**
```c
// Duas threads podem pegar a mesma moeda!
if (coins[i].state == FREE) {
    coins[i].state = OCCUPIED;  // RACE CONDITION
}
```

**✅ Com semáforo:**
```c
sem_wait(&coins_sem);  // Garante exclusão mútua
// Apenas UMA thread por vez
coins[i].state = OCCUPIED;
```

---

## 5. Testes Realizados

### Cenário 1: Bloqueio
```bash
curl /collect  # contador: 3 → 2
curl /collect  # contador: 2 → 1
curl /collect  # contador: 1 → 0
curl /collect  # ⏸️ BLOQUEIA! (sem_wait com contador = 0)
```

### Cenário 2: Liberação por Acerto
```bash
curl "/guess?id=0&value=7"  # Acerto!
# sem_post() → contador: 0 → 1
# Thread bloqueada é acordada
```

### Cenário 3: Liberação por Timeout
```bash
curl /collect  # Coleta moeda
# ... aguarda 30s ...
# Timer chama sem_post() automaticamente
curl /status   # Moeda voltou para FREE
```

---

## 6. Resultados

**Operações validadas:**

✅ `sem_init()` - Inicialização com contador = 3  
✅ `sem_wait()` - Bloqueio quando contador = 0  
✅ `sem_post()` - Liberação e despertar de threads  
✅ `sem_destroy()` - Limpeza e reinicialização  

**Vantagens dos semáforos:**
- Bloqueio eficiente (sem busy-waiting)
- Sincronização automática entre threads
- Prevenção de race conditions
- Código mais limpo e legível

---

## 7. Conclusão

O projeto demonstrou com sucesso o uso de **semáforos POSIX** para:
- Controlar acesso a recursos limitados (3 moedas)
- Bloquear threads quando recursos esgotam
- Liberar recursos de forma automática e segura
- Prevenir condições de corrida

**Aplicações práticas:** Pools de conexões, limitadores de taxa, controle de workers em servidores.

---

## 8. Compilação e Execução

```bash
# Compilar
gcc -o servidor servidor.c -pthread

# Executar servidor
./servidor

# Testar (outro terminal)
curl http://localhost:8080/collect
curl "http://localhost:8080/guess?id=0&value=5"
curl http://localhost:8080/status
```

**Endpoints disponíveis:**
- `/collect` - Coletar moeda (sem_wait)
- `/guess?id=X&value=Y` - Adivinhar número (sem_post se acertar)
- `/status` - Consultar estado
- `/reset` - Reiniciar jogo
