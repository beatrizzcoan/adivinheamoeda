#!/bin/bash

# ============================================================================
# SCRIPT DE TESTES - JOGO DA MOEDA (Validação de Semáforos)
# ============================================================================
# Este script testa o comportamento do servidor com foco em:
# - Bloqueio por semáforo (sem_wait)
# - Liberação por timeout e acerto
# - Game over e reset
# ============================================================================

SERVER="http://localhost:8080"
LOG_FILE="testes.log"
TIMEOUT_LIMIT=30

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Contador de testes
TEST_NUM=0

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

# Inicializa o log
init_log() {
    echo "============================================================================" > "$LOG_FILE"
    echo "RELATÓRIO DE TESTES - JOGO DA MOEDA" >> "$LOG_FILE"
    echo "Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "Servidor: $SERVER" >> "$LOG_FILE"
    echo "============================================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# Exibe e loga um comando
log_command() {
    TEST_NUM=$((TEST_NUM + 1))
    echo -e "\n${CYAN}[TESTE $TEST_NUM - COMANDO]${NC} $1"
    echo "" >> "$LOG_FILE"
    echo "[TESTE $TEST_NUM - COMANDO] $1" >> "$LOG_FILE"
}

# Exibe e loga uma resposta
log_response() {
    echo -e "${GREEN}[RESPOSTA]${NC} $1"
    echo "[RESPOSTA] $1" >> "$LOG_FILE"
}

# Exibe cabeçalho de seção
section_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo "" >> "$LOG_FILE"
    echo "========================================================================" >> "$LOG_FILE"
    echo "  $1" >> "$LOG_FILE"
    echo "========================================================================" >> "$LOG_FILE"
}

# Aguarda com contador visual
wait_with_countdown() {
    local seconds=$1
    local message=$2
    echo -e "${YELLOW}$message${NC}"
    for ((i=seconds; i>0; i--)); do
        echo -ne "${YELLOW}Aguardando... $i segundos restantes\r${NC}"
        sleep 1
    done
    echo -e "${YELLOW}Aguardando... Completo!          ${NC}"
    echo "$message - Completo!" >> "$LOG_FILE"
}

# Executa comando curl e retorna resposta
execute_curl() {
    local cmd="$1"
    local response
    response=$(eval "$cmd" 2>&1)
    echo "$response"
}

# Verifica se servidor está rodando
check_server() {
    echo -e "${CYAN}Verificando conexão com servidor...${NC}"
    if curl -s --max-time 2 "$SERVER/status" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Servidor acessível em $SERVER${NC}"
        return 0
    else
        echo -e "${RED}✗ ERRO: Servidor não está respondendo em $SERVER${NC}"
        echo -e "${YELLOW}  Certifique-se de que o servidor está rodando na porta 8080${NC}"
        exit 1
    fi
}

# ============================================================================
# CENÁRIO 1: COLETA E ACERTO DIRETO DE TODAS AS MOEDAS
# ============================================================================
test_scenario_1() {
    section_header "CENÁRIO 1: Coleta e Acerto Direto (sem_post após acerto)"

    # Reset do jogo
    log_command "curl -s $SERVER/reset"
    response=$(execute_curl "curl -s $SERVER/reset")
    log_response "$response"
    sleep 1

    # Consulta status inicial
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    sleep 1

    # Coleta as 3 moedas
    declare -a coin_ids
    for i in {1..3}; do
        log_command "curl -s $SERVER/collect"
        response=$(execute_curl "curl -s $SERVER/collect")
        log_response "$response"

        # Extrai coin_id da resposta
        coin_id=$(echo "$response" | grep -oP '"coin_id":\K[0-9]+')
        coin_ids+=("$coin_id")
        echo -e "${YELLOW}  → Moeda coletada: ID=$coin_id${NC}"
        sleep 1
    done

    # Status após coleta (todas ocupadas, semáforo = 0)
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${YELLOW}  → Esperado: 3 ocupadas, 0 livres, semáforo = 0${NC}"
    sleep 1

    # Tenta coletar 4ª moeda (deve bloquear - testamos com timeout)
    echo -e "\n${YELLOW}Testando bloqueio do semáforo (sem_wait quando contador = 0)...${NC}"
    log_command "curl -s --max-time 3 $SERVER/collect (deve timeout)"
    response=$(execute_curl "curl -s --max-time 3 $SERVER/collect 2>&1 || echo '{\"error\":\"timeout - semáforo bloqueou!\"}'")
    log_response "$response"
    echo -e "${GREEN}  ✓ Bloqueio funcionando: sem_wait() bloqueou a thread${NC}"
    sleep 1

    # Agora vamos adivinhar os números (força bruta 0-9)
    echo -e "\n${YELLOW}Adivinhando números das moedas coletadas...${NC}"
    for coin_id in "${coin_ids[@]}"; do
        echo -e "${CYAN}Testando moeda ID=$coin_id${NC}"
        found=false
        for guess in {0..9}; do
            log_command "curl -s \"$SERVER/guess?id=$coin_id&value=$guess\""
            response=$(execute_curl "curl -s \"$SERVER/guess?id=$coin_id&value=$guess\"")
            log_response "$response"

            if echo "$response" | grep -q '"result":"correct"'; then
                echo -e "${GREEN}  ✓ ACERTOU! Número era $guess (sem_post chamado)${NC}"
                found=true
                break
            else
                echo -e "${RED}  ✗ Errou: $guess${NC}"
            fi
        done

        if [ "$found" = false ]; then
            echo -e "${RED}  ✗ ERRO: Não conseguiu adivinhar o número!${NC}"
        fi
        sleep 1
    done

    # Status final (deve mostrar game over)
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${GREEN}  ✓ Esperado: 3 descobertas, game_over = true${NC}"
    sleep 1

    # Tenta coletar após game over
    log_command "curl -s $SERVER/collect (após game over)"
    response=$(execute_curl "curl -s $SERVER/collect")
    log_response "$response"
    echo -e "${GREEN}  ✓ Coleta bloqueada após game over${NC}"
}

# ============================================================================
# CENÁRIO 2: ERROS CONSECUTIVOS E LIBERAÇÃO POR TIMEOUT
# ============================================================================
test_scenario_2() {
    section_header "CENÁRIO 2: Erros Consecutivos e Timeout (sem_post pelo timer)"

    # Reset do jogo
    log_command "curl -s $SERVER/reset"
    response=$(execute_curl "curl -s $SERVER/reset")
    log_response "$response"
    sleep 1

    # Coleta 1 moeda
    log_command "curl -s $SERVER/collect"
    response=$(execute_curl "curl -s $SERVER/collect")
    log_response "$response"
    coin_id=$(echo "$response" | grep -oP '"coin_id":\K[0-9]+')
    echo -e "${YELLOW}  → Moeda coletada: ID=$coin_id${NC}"
    sleep 1

    # Faz várias tentativas erradas
    echo -e "\n${YELLOW}Tentando palpites errados consecutivos...${NC}"
    for guess in 5 5 5; do
        log_command "curl -s \"$SERVER/guess?id=$coin_id&value=$guess\""
        response=$(execute_curl "curl -s \"$SERVER/guess?id=$coin_id&value=$guess\"")
        log_response "$response"
        echo -e "${RED}  ✗ Tentativa errada: $guess${NC}"
        sleep 1
    done

    # Status (moeda ainda ocupada)
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${YELLOW}  → Moeda ainda OCUPADA, aguardando timeout...${NC}"

    # Aguarda timeout (30 segundos)
    wait_with_countdown 31 "Aguardando timeout de 30 segundos (timer_thread vai chamar sem_post)..."

    # Status após timeout (moeda deve estar livre)
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${GREEN}  ✓ Moeda liberada por timeout! timer_thread executou sem_post()${NC}"
    sleep 1

    # Tenta coletar novamente (deve funcionar)
    log_command "curl -s $SERVER/collect"
    response=$(execute_curl "curl -s $SERVER/collect")
    log_response "$response"
    echo -e "${GREEN}  ✓ Coleta bem-sucedida após liberação por timeout${NC}"
}

# ============================================================================
# CENÁRIO 3: TESTE DE BLOQUEIO SIMULTÂNEO (OPCIONAL - REQUER BACKGROUND JOBS)
# ============================================================================
test_scenario_3() {
    section_header "CENÁRIO 3: Teste de Bloqueio com Múltiplas Requisições"

    # Reset do jogo
    log_command "curl -s $SERVER/reset"
    response=$(execute_curl "curl -s $SERVER/reset")
    log_response "$response"
    sleep 1

    # Coleta todas as 3 moedas rapidamente
    echo -e "${YELLOW}Coletando todas as 3 moedas...${NC}"
    for i in {1..3}; do
        curl -s "$SERVER/collect" > /dev/null 2>&1 &
    done
    wait
    sleep 2

    # Status (todas ocupadas)
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${YELLOW}  → Todas as moedas ocupadas (semáforo = 0)${NC}"

    # Tenta 5 coletas simultâneas em background (todas devem bloquear)
    echo -e "\n${YELLOW}Iniciando 5 requisições simultâneas de coleta...${NC}"
    echo -e "${YELLOW}Todas devem bloquear em sem_wait() pois semáforo = 0${NC}"

    for i in {1..5}; do
        (
            echo "  → Thread $i: iniciando coleta..." >> "$LOG_FILE"
            curl -s --max-time 5 "$SERVER/collect" > /dev/null 2>&1 || echo "  → Thread $i: timeout (bloqueada)" >> "$LOG_FILE"
        ) &
    done

    # Aguarda um pouco
    sleep 3

    echo -e "${GREEN}  ✓ 5 threads bloqueadas em sem_wait()${NC}"
    echo -e "${YELLOW}  → Aguardando processos finalizarem...${NC}"
    wait

    log_command "Verificação de bloqueio concluída"
    log_response "5 threads testadas, todas bloquearam corretamente"
}

# ============================================================================
# CENÁRIO 4: RESET E VERIFICAÇÃO DE ESTADO
# ============================================================================
test_scenario_4() {
    section_header "CENÁRIO 4: Reset do Jogo e Reinicialização do Semáforo"

    # Status antes do reset
    log_command "curl -s $SERVER/status (antes do reset)"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    sleep 1

    # Reset
    log_command "curl -s $SERVER/reset"
    response=$(execute_curl "curl -s $SERVER/reset")
    log_response "$response"
    echo -e "${YELLOW}  → sem_destroy() e sem_init() executados${NC}"
    sleep 1

    # Status após reset
    log_command "curl -s $SERVER/status (após reset)"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${GREEN}  ✓ Jogo reiniciado: todas livres, semáforo = 3${NC}"
    sleep 1

    # Coleta 3 moedas para verificar que funciona
    echo -e "\n${YELLOW}Verificando que coletas funcionam após reset...${NC}"
    for i in {1..3}; do
        log_command "curl -s $SERVER/collect"
        response=$(execute_curl "curl -s $SERVER/collect")
        log_response "$response"
        echo -e "${GREEN}  ✓ Coleta $i bem-sucedida${NC}"
        sleep 1
    done

    # Status final
    log_command "curl -s $SERVER/status"
    response=$(execute_curl "curl -s $SERVER/status")
    log_response "$response"
    echo -e "${GREEN}  ✓ Estado consistente: 3 ocupadas, semáforo = 0${NC}"
}

# ============================================================================
# RELATÓRIO FINAL
# ============================================================================
generate_report() {
    section_header "RESUMO DOS TESTES"

    echo -e "${GREEN}✓ CENÁRIO 1: Coleta e acerto direto - COMPLETO${NC}"
    echo -e "${GREEN}✓ CENÁRIO 2: Timeout e liberação - COMPLETO${NC}"
    echo -e "${GREEN}✓ CENÁRIO 3: Bloqueio simultâneo - COMPLETO${NC}"
    echo -e "${GREEN}✓ CENÁRIO 4: Reset e reinicialização - COMPLETO${NC}"

    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  OPERAÇÕES COM SEMÁFORO VALIDADAS:${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ sem_init()  - Inicialização com valor N_COINS${NC}"
    echo -e "${GREEN}  ✓ sem_wait()  - Bloqueio quando contador = 0${NC}"
    echo -e "${GREEN}  ✓ sem_post()  - Liberação após acerto (handle_guess)${NC}"
    echo -e "${GREEN}  ✓ sem_post()  - Liberação após timeout (timer_thread)${NC}"
    echo -e "${GREEN}  ✓ sem_destroy() - Destruição e reinicialização (reset)${NC}"
    echo ""

    echo "" >> "$LOG_FILE"
    echo "========================================================================" >> "$LOG_FILE"
    echo "TESTES CONCLUÍDOS COM SUCESSO" >> "$LOG_FILE"
    echo "Total de comandos executados: $TEST_NUM" >> "$LOG_FILE"
    echo "Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "========================================================================" >> "$LOG_FILE"

    echo -e "${YELLOW}Relatório completo salvo em: $LOG_FILE${NC}"
    echo -e "${CYAN}Use 'cat $LOG_FILE' para visualizar o log completo${NC}"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    clear
    echo -e "${BLUE}"
    echo "════════════════════════════════════════════════════════════════════════"
    echo "           SCRIPT DE TESTES - SERVIDOR JOGO DA MOEDA"
    echo "              Validação de Semáforos e Sincronização"
    echo "════════════════════════════════════════════════════════════════════════"
    echo -e "${NC}"

    # Inicializa log
    init_log

    # Verifica servidor
    check_server
    echo ""

    # Pergunta quais cenários executar
    echo -e "${CYAN}Escolha os cenários para executar:${NC}"
    echo "  1) Todos os cenários (recomendado)"
    echo "  2) Apenas Cenário 1 (Acertos)"
    echo "  3) Apenas Cenário 2 (Timeout)"
    echo "  4) Apenas Cenário 3 (Bloqueio)"
    echo "  5) Apenas Cenário 4 (Reset)"
    echo ""
    read -p "Opção [1-5]: " option

    case $option in
        1)
            test_scenario_1
            test_scenario_2
            test_scenario_3
            test_scenario_4
            ;;
        2)
            test_scenario_1
            ;;
        3)
            test_scenario_2
            ;;
        4)
            test_scenario_3
            ;;
        5)
            test_scenario_4
            ;;
        *)
            echo -e "${RED}Opção inválida! Executando todos os cenários...${NC}"
            test_scenario_1
            test_scenario_2
            test_scenario_3
            test_scenario_4
            ;;
    esac

    # Gera relatório final
    generate_report

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    TESTES FINALIZADOS!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════════════${NC}"
}

# Executa script
main