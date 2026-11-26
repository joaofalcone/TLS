#!/usr/bin/env bash
set -euo pipefail

# +--------------------------------------------------------------------------+
# | INSTALATLS - PDV LINUX (VISÃO GERAL)
# | O que faz: Configura e testa o TEF do caixa em TLS (Fiserv) ou GSurf, e
# |            ativa a GSurf. Menu: 1 Cadastrar TLS, 2 Instalar GSurf, 3
# |            Testar TLS, 4 Testar GSurf.
# | Por quê:   Substitui passos manuais por um roteiro único, rápido e
# |            seguro: tudo que é mudado pode ser desfeito se algo falhar.
# +--------------------------------------------------------------------------+

# +--------------------------------------------------------------------------+
# | PERMISSÃO DE ADMINISTRADOR (ROOT)
# | O que faz: Se não estiver como root, reabre o script com sudo.
# | Por quê:   Mexer no serviço do TEF e em /opt/checkout exige root.
# +--------------------------------------------------------------------------+
# Precisa de root (systemctl, /opt/checkout). Sem root, reabre com sudo.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# FD 3 = terminal do operador (as etapas mandam stdout/stderr para o log).
exec 3>&1

# =========================================================
# INSTALATLS — CONFIGURAÇÃO INICIAL / CAMINHOS / CONSTANTES
# =========================================================

PDV_OUT_DB="${PDV_OUT_DB:-/opt/checkout/pdv_out.db}"
DB_IN="${DB_IN:-/opt/checkout/pdv_in.db}"
CONFITLS_INI="${CONFITLS_INI:-/opt/checkout/CONFITLS.INI}"
CONFITLS_BKP_INI="${CONFITLS_BKP_INI:-/opt/checkout/CONFITLS_BKP.INI}"
readonly SERVICE_NAME="clisitef-socket.service"
readonly MYSQL_TABLE="pdvctr"
readonly MYSQL_COL_CNPJ="ctremprcgc"
readonly MYSQL_COL_IDLOJA_TEF="ctrcodemptef"
readonly CNPJ_SH_FIX="03082643000110"
readonly TLS_TABLE="pdvtls"
readonly TLS_COL_CAIXA="tlscaixa"
readonly TLS_COL_TOKEN="tlstoken"
readonly HOST_DEFAULT="127.0.0.1"
readonly PORT_DEFAULT="8765"
readonly OPERADOR="999 HIPCOM"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
FINAL_LOG_FILE="${SCRIPT_DIR}/InstalaTLS.log"
readonly FINAL_LOG_FILE
umask 077

# ---------- proteção contra execução simultânea ----------
# Lock em /run (só root grava): em /tmp (pasta do script no one-liner) um link
# plantado por outro usuário faria o root truncar/criar o arquivo apontado.
# ">>" não trunca, e link é recusado se o lock cair na pasta do script.
if [[ -d /run && ! -L /run && -w /run ]]; then LOCK_FILE="/run/InstalaTLS.lock"; else LOCK_FILE="${SCRIPT_DIR}/.InstalaTLS.lock"; fi
readonly LOCK_FILE
if [[ -L "$LOCK_FILE" ]]; then
  printf 'ERRO FATAL: arquivo de lock é um link (recusado): %s\n' "$LOCK_FILE" >&2
  exit 1
fi
exec 9>>"$LOCK_FILE" 2>/dev/null || {
  printf 'ERRO FATAL: não foi possível criar arquivo de lock: %s\n' "$LOCK_FILE" >&2
  exit 1
}
if ! flock -n 9 2>/dev/null; then
  printf 'ERRO: outra instância do InstalaTLS já está em execução (%s). Aguarde o término antes de reiniciar.\n' "$LOCK_FILE" >&2
  exec 9>&-
  exit 1
fi
# O lock é liberado automaticamente quando o FD 9 é fechado (exit, exec 9>&-, ou fim do processo).
# ---------------------------------------------------------

AUDIT_TMP="$(mktemp "${SCRIPT_DIR}/.InstalaTLS.audit.XXXXXX" 2>/dev/null)" || {
  printf 'ERRO FATAL: mktemp falhou (disco cheio ou /tmp sem escrita?)\n' >&2
  exit 1
}
chmod 600 "$AUDIT_TMP" 2>/dev/null || true
# Register an early minimal EXIT trap so AUDIT_TMP is always removed even if
# the script aborts before the full cleanup() trap is set up below.
trap 'rm -f "${AUDIT_TMP:-}" 2>/dev/null || true' EXIT
# Block signals until the real traps are registered below (after die/cleanup/on_signal
# are defined).  This prevents a signal arriving before the full INT/TERM trap is in
# place from killing the script without cleanup.
trap '' INT TERM
LAST_UI_LOOP_PCT=""
UI_TEST_LABEL="Testando Comunicação"
ORIG_SQLITE_FLAG=""
ORIG_TOKEN_EXISTS=0
ORIG_TOKEN_VALUE=""
ORIG_CONFITLS_EXISTS=0
ORIG_CONFITLS_BACKUP=""
ORIG_CTRL_EXISTS=0
ORIG_CTRL_IS_DIR=0
ORIG_CTRL_BACKUP=""
ROLLBACK_ENABLED=0
SKIP_ROLLBACK=0
LAST_SOCKET_MSG=""
LAST_USEFUL_SOCKET_MSG=""
SQLITE_BUSY_TIMEOUT_MS=3000
SQLITE_RETRY_COUNT=3
SQLITE_RETRY_SLEEP=1
DEBUG_LOG="${DEBUG_LOG:-0}"
TOKEN_ATUAL_BANCO=""
MODO_TESTE_TOKEN_ATUAL=0
MAX_LOOPS=160
SLEEP_SEC=0.25
STATE_HEARTBEAT_EVERY=20
UI_OK=0
MYSQL_HOST=""
MYSQL_PORT=""
MYSQL_PASS=""
IP_BD=""
NOME_BD=""
USUARIO_BD=""
SENHA_B64=""
NUM_CAIXA=""
CNPJ_LOJA=""
IDLOJA_TEF=""
LOJA_EXIBICAO=""
TOKEN_TLS=""
LOG_FINALIZED=0
TEST_RESULT_MSG=""
LAST_STATE_SNAPSHOT=""
FINAL_MODE_TEST_OK=0
FINAL_MODE_TEST_MSG=""
HOST=""
PORT=""
IDTERM=""
IDLOJA=""
PARMS=""
DATAFISC=""
HORAFISC=""
CUPOM=""


# =========================================================
# HELPERS GERAIS / DATA / LOG / FORMATAÇÃO
# =========================================================

# +--------------------------------------------------------------------------+
# | DATA E HORA
# | O que faz: Devolve a data e hora atual.
# | Por quê:   Cada linha do log leva o horário.
# +--------------------------------------------------------------------------+
ts(){ date '+%F %T'; }

# +--------------------------------------------------------------------------+
# | ANOTAR NO LOG
# | O que faz: Escreve uma linha com data e hora no log da execução.
# | Por quê:   Se algo der errado, o log mostra o que aconteceu, passo a
# |            passo.
# +--------------------------------------------------------------------------+
log(){
  # Guard against writing to a nonexistent or empty AUDIT_TMP (e.g., if the
  # file was already removed by cleanup or if mktemp failed and we fell back).
  [[ -n "${AUDIT_TMP:-}" ]] && printf '[%s] %s\n' "$(ts)" "$*" >>"$AUDIT_TMP" || true
}

# +--------------------------------------------------------------------------+
# | LOG DETALHADO (OPCIONAL)
# | O que faz: Escreve no log só quando o modo de depuração estiver ligado.
# | Por quê:   Ajuda o suporte sem encher o log no dia a dia.
# +--------------------------------------------------------------------------+
debug_log(){
  # (( expr )) returns exit code 1 when expr == 0, which would cause set -e to
  # abort the script if debug_log is ever called in a plain statement context.
  # The explicit return 0 makes the function always succeed regardless of
  # DEBUG_LOG value, matching the caller's expectation that a no-op log call
  # cannot fail.
  (( DEBUG_LOG == 1 )) && log "$@"
  return 0
}

# +--------------------------------------------------------------------------+
# | SEPARADOR NO LOG
# | O que faz: Escreve uma linha de traços no log.
# | Por quê:   Separa uma etapa da outra.
# +--------------------------------------------------------------------------+
log_sep(){
  log "----------------------------------------------------------------"
}

# +--------------------------------------------------------------------------+
# | ANOTAR NOME=VALOR
# | O que faz: Escreve no log um par "nome=valor".
# | Por quê:   Registro padronizado e fácil de procurar.
# +--------------------------------------------------------------------------+
log_kv(){
  local k="$1" v="${2:-}"
  log "$k=$v"
}

# +--------------------------------------------------------------------------+
# | ANOTAR VALOR ESCONDIDO
# | O que faz: Igual ao anterior, mas esconde o meio do valor com asteriscos.
# | Por quê:   Token e senha não aparecem inteiros no log.
# +--------------------------------------------------------------------------+
log_kv_masked(){
  local k="$1" v="${2:-}"
  log_kv "$k" "$(mask_secret "$v")"
}

# +--------------------------------------------------------------------------+
# | MAIÚSCULAS
# | O que faz: Converte um texto para letras maiúsculas.
# | Por quê:   Comparar textos sem depender de maiúscula/minúscula.
# +--------------------------------------------------------------------------+
to_upper(){
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# +--------------------------------------------------------------------------+
# | TIRAR ESPAÇOS
# | O que faz: Remove espaços do começo e do fim.
# | Por quê:   Dados lidos do banco às vezes vêm com espaços sobrando.
# +--------------------------------------------------------------------------+
trim(){ sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# +--------------------------------------------------------------------------+
# | DECODIFICAR A SENHA
# | O que faz: Decodifica a senha do banco, que vem guardada em base64.
# | Por quê:   É assim que o PDV guarda a senha do MySQL.
# +--------------------------------------------------------------------------+
decode_b64(){
  local v="$1" out rc
  out="$(printf '%s' "$v" | base64 -d 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    # base64 -d falhou: dado corrompido no banco. Não fazer fallback silencioso —
    # retornar vazio para que a validação downstream (MYSQL_PASS vazio) aborte com
    # mensagem de erro clara em vez de tentar autenticar com dado inválido.
    log "WARN: decode_b64 falhou (rc=${rc}); dado base64 inválido na coluna senha"
    printf ''
    return 1
  fi
  printf '%s' "$out"
}

# Dobra ' e escapa \ (no MySQL a barra também escapa: só dobrar a aspa deixava
# um \' vindo do banco fechar o texto e o resto virar SQL; o mysql aceita vários comandos).
# +--------------------------------------------------------------------------+
# | TEXTO SEGURO PARA O BANCO
# | O que faz: Neutraliza aspas e barras de um texto que vai num comando do
# |            banco.
# | Por quê:   Evita que um valor malicioso vire comando (injeção de SQL).
# +--------------------------------------------------------------------------+
mysql_escape(){
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"
}

# +--------------------------------------------------------------------------+
# | TABELA EXISTE?
# | O que faz: Confere se uma tabela existe no banco local do PDV.
# | Por quê:   Evita erro ao gravar onde não existe.
# +--------------------------------------------------------------------------+
sqlite_has_table() {
  local db="$1" table="$2" out rc
  out="$(sqlite3 "$db" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" \
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;" \
    2>>"$AUDIT_TMP")"
  rc=$?
  (( rc == 0 )) && [[ "$out" == "1" ]]
}

# +--------------------------------------------------------------------------+
# | COMPLETAR COM ZEROS
# | O que faz: Completa um número com zeros à esquerda (ex.: 6 vira 000006).
# | Por quê:   A Fiserv exige caixa e loja com tamanho fixo.
# +--------------------------------------------------------------------------+
pad_left() {
  local s="$1" w="$2"
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  printf "%0${w}d" "$((10#$s))"
}

# +--------------------------------------------------------------------------+
# | LIMPAR MENSAGEM DA CLISITEF
# | O que faz: Remove quebras, espaços e caracteres de controle da mensagem.
# | Por quê:   Mensagem legível e sem sujeira que bagunce o terminal.
# +--------------------------------------------------------------------------+
normalize_socket_message(){
  local msg="${1:-}"
  # Sem caracteres de controle: a mensagem vai para o terminal (ESC injetaria sequências).
  msg="$(printf '%s' "$msg" | tr -d '[:cntrl:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s\n' "$msg"
}

# +--------------------------------------------------------------------------+
# | ESCONDER SEGREDO
# | O que faz: Troca o meio de um valor por asteriscos.
# | Por quê:   Segredo não aparece na tela nem no log.
# +--------------------------------------------------------------------------+
mask_secret(){
  local v="${1:-}"
  if [[ -z "$v" ]] || (( ${#v} <= 4 )); then
    printf '%s' "****"
  else
    printf '%s' "${v:0:2}****${v: -2}"
  fi
}

# +--------------------------------------------------------------------------+
# | LER NÚMERO DA RESPOSTA
# | O que faz: Tira um número de dentro da resposta da CliSiTef.
# | Por quê:   A CliSiTef responde em texto (JSON); precisamos dos números de
# |            resultado.
# +--------------------------------------------------------------------------+
extract_int() { sed -n 's/.*"'"$1"'":[^0-9-]*\(-\{0,1\}[0-9]\+\).*/\1/p'; }
extract_str() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'; }

# +--------------------------------------------------------------------------+
# | APAGAR CÓPIAS SENSÍVEIS
# | O que faz: Apaga os backups temporários (que contêm o token).
# | Por quê:   Não deixar segredo esquecido em disco.
# +--------------------------------------------------------------------------+
cleanup_sensitive_artifacts(){
  if [[ -n "${ORIG_CONFITLS_BACKUP:-}" && -f "${ORIG_CONFITLS_BACKUP:-}" ]]; then
    rm -f "${ORIG_CONFITLS_BACKUP}" 2>/dev/null || true
  fi

  if [[ -n "${ORIG_CTRL_BACKUP:-}" && -d "${ORIG_CTRL_BACKUP:-}" ]]; then
    rm -rf "${ORIG_CTRL_BACKUP}" 2>/dev/null || true
  fi
}

# =========================================================
# LOG DE ETAPAS / CONTROLE DE EXECUÇÃO
# =========================================================

# +--------------------------------------------------------------------------+
# | INÍCIO DE ETAPA NO LOG
# | O que faz: Anota no log o começo de uma etapa.
# | Por quê:   Rastrear o caminho exato da execução.
# +--------------------------------------------------------------------------+
step_enter(){
  log_sep
  log "ENTER: $1"
}

# +--------------------------------------------------------------------------+
# | ETAPA OK NO LOG
# | O que faz: Anota que a etapa terminou bem.
# | Por quê:   Saber até onde deu certo.
# +--------------------------------------------------------------------------+
step_ok(){
  log "OK: $1"
}

# +--------------------------------------------------------------------------+
# | ETAPA COM FALHA NO LOG
# | O que faz: Anota que a etapa falhou.
# | Por quê:   Achar rápido onde parou.
# +--------------------------------------------------------------------------+
step_fail(){
  log "FAIL: $1"
}

# +--------------------------------------------------------------------------+
# | REGISTRAR CONVERSA COM A CLISITEF
# | O que faz: Anota no log o que foi enviado e recebido da CliSiTef.
# | Por quê:   Permite ao suporte ver a conversa exata com o TEF.
# +--------------------------------------------------------------------------+
log_socket_call(){
  local tag="$1"
  local payload="$2"
  local response="$3"

  log "SOCKET_CALL_${tag}_PAYLOAD: $payload"
  log "SOCKET_CALL_${tag}_RESPONSE: $response"
}

# +--------------------------------------------------------------------------+
# | REGISTRAR MUDANÇA DE ESTADO
# | O que faz: Anota o estado da CliSiTef só quando ele muda.
# | Por quê:   Log útil sem milhares de linhas repetidas.
# +--------------------------------------------------------------------------+
state_maybe_log() {
  local loop="$1" res="$2" cmd="$3" tipo="$4" tmin="$5" tmax="$6"
  local cur="res=$res cmd=$cmd tipo=$tipo tmin=$tmin tmax=$tmax"

  if [[ "${cur:-}" != "${LAST_STATE_SNAPSHOT:-}" ]]; then
    LAST_STATE_SNAPSHOT="$cur"
    log "SOCKET_STATE: ($loop) $cur"
  elif (( STATE_HEARTBEAT_EVERY > 0 )) && (( loop % STATE_HEARTBEAT_EVERY == 0 )); then
    log "SOCKET_STATE: ($loop) $cur (heartbeat)"
  fi
}

# =========================================================
# BOOTSTRAP DE DEPENDÊNCIAS
# =========================================================

# +--------------------------------------------------------------------------+
# | INSTALAR O QUE FALTA
# | O que faz: Se faltar sqlite3 ou o cliente MySQL, instala (só na primeira
# |            vez).
# | Por quê:   O script precisa deles para ler e gravar a configuração.
# +--------------------------------------------------------------------------+
bootstrap_dependencies(){
  local missing=0

  command -v sqlite3 >/dev/null 2>&1 || missing=1
  command -v mysql  >/dev/null 2>&1 || missing=1

  if (( missing == 0 )); then
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 || {
    printf 'ERRO: apt-get não encontrado.
' >&2
    exit 1
  }

  export DEBIAN_FRONTEND=noninteractive
  printf '
  Preparando o ambiente para a primeira execução (sqlite3, mysql-client)...
' >&3
  apt-get update -y >>"$AUDIT_TMP" 2>&1 || { printf 'ERRO: apt-get update falhou.
' >&2; exit 1; }
  apt-get install -y sqlite3 mysql-client >>"$AUDIT_TMP" 2>&1 || { printf 'ERRO: falha ao instalar sqlite3/mysql-client.
' >&2; exit 1; }

  command -v sqlite3 >/dev/null 2>&1 || { printf 'ERRO: sqlite3 não instalado.
' >&2; exit 1; }
  command -v mysql   >/dev/null 2>&1 || { printf 'ERRO: mysql-client não instalado.
' >&2; exit 1; }
}

# +--------------------------------------------------------------------------+
# | COMANDO DISPONÍVEL?
# | O que faz: Confere se um programa necessário existe no PDV.
# | Por quê:   Avisar logo no começo em vez de falhar no meio.
# +--------------------------------------------------------------------------+
need_cmd(){
  step_enter "Verificando dependência: $1"
  if command -v "$1" >/dev/null 2>&1; then
    step_ok "Dependência encontrada: $1 -> $(command -v "$1")"
  else
    step_fail "Dependência ausente: $1"
    die "comando ausente: $1"
  fi
}

# =========================================================
# INTERFACE NO TERMINAL (sem janelas, sem login)
# =========================================================
# Tudo que é para o operador vai no FD 3 (terminal). O stdout/stderr das
# etapas continua indo para o log (AUDIT_TMP) via ui_step_min.

C_RST=$'\033[0m'; C_TIT=$'\033[1;97m'; C_OK=$'\033[1;32m'; C_ERR=$'\033[1;31m'
C_AVI=$'\033[1;33m'; C_ROT=$'\033[0;37m'; C_VAL=$'\033[1;33m'; C_PER=$'\033[1;36m'; C_DIC=$'\033[0;90m'
UI_PCT=0
UI_MSG_ATUAL=""

# +--------------------------------------------------------------------------+
# | ESCREVER NA TELA
# | O que faz: Escreve texto direto no terminal do operador.
# | Por quê:   Separa o que é para o operador do que vai para o log.
# +--------------------------------------------------------------------------+
ui_out(){ printf "$@" >&3 2>/dev/null || true; }

# Lê uma linha do operador. Entrada encerrada (terminal fechado/EOF) = sair,
# desfazendo o que estiver pendente (sem isso o menu girava sem fim).
# +--------------------------------------------------------------------------+
# | LER O QUE O OPERADOR DIGITA
# | O que faz: Lê uma linha digitada; se o terminal fechar, encerra
# |            desfazendo o pendente.
# | Por quê:   Sem isso, um terminal fechado deixava o menu girando sem fim.
# +--------------------------------------------------------------------------+
ler(){
  local v=""
  if { exec 4</dev/tty; } 2>/dev/null; then
    IFS= read -r v <&4 || { exec 4<&-; kill -TERM $$; exit 130; }
    exec 4<&-
  else
    IFS= read -r v || { kill -TERM $$; exit 130; }
  fi
  printf '%s' "$v"
}

# +--------------------------------------------------------------------------+
# | PEQUENAS PEÇAS DE TELA
# | O que faz: Título em faixa, campo "Rótulo: valor", mensagens de OK
# |            (verde), erro (vermelho), aviso (amarelo) e dica (cinza).
# | Por quê:   Cores e alinhamento deixam a tela fácil de ler.
# +--------------------------------------------------------------------------+
# Título só em negrito (sem fundo): fundo colorido fica só para a opção selecionada.
ui_titulo(){ ui_out '\n  %s%s%s\n' "$C_TIT" "$1" "$C_RST"; }
ui_campo(){ ui_out '  %s%-14s:%s %s%s%s\n' "$C_ROT" "$1" "$C_RST" "$C_VAL" "${2:-}" "$C_RST"; }
ui_ok(){ log "UI_OK=$1"; ui_out '  %s%s%s\n' "$C_OK" "$1" "$C_RST"; }
ui_erro(){ log "UI_ERRO=$1"; ui_out '  %s%s%s\n' "$C_ERR" "$1" "$C_RST"; }
ui_aviso(){ log "UI_AVISO=$1"; ui_out '  %s%s%s\n' "$C_AVI" "$1" "$C_RST"; }
ui_dica(){ ui_out '  %s%s%s\n' "$C_DIC" "$1" "$C_RST"; }

# +--------------------------------------------------------------------------+
# | ESPERAR ENTER
# | O que faz: Espera o operador apertar Enter.
# | Por quê:   Dá tempo de ler a mensagem.
# +--------------------------------------------------------------------------+
ui_pausa(){
  ui_out '\n  %sEnter para continuar%s ' "$C_DIC" "$C_RST"
  ler >/dev/null
}

C_SEL=$'\033[1;37;46m'

# +--------------------------------------------------------------------------+
# | DESENHAR O MENU
# | O que faz: Desenha as opções, destacando a selecionada, e o rodapé
# |            "Opção: N".
# | Por quê:   O operador vê o que vai escolher antes de confirmar.
# +--------------------------------------------------------------------------+
_ui_menu_desenha(){
  local i
  for (( i=0; i<${#_MK[@]}; i++ )); do
    if (( i == _MSEL )); then
      ui_out '\r\033[K  %s > %s - %s %s\n' "$C_SEL" "${_MK[i]}" "${_MT[i]}" "$C_RST"
    else
      ui_out '\r\033[K    %s%s%s - %s\n' "$C_VAL" "${_MK[i]}" "$C_RST" "${_MT[i]}"
    fi
  done
  ui_out '\r\033[K  %sOpção:%s %s%s%s   %s(número ou setas, Enter confirma)%s\n' \
    "$C_PER" "$C_RST" "$C_VAL" "${_MK[_MSEL]}" "$C_RST" "$C_DIC" "$C_RST"
}

# ui_opcao "1:Texto" "2:Texto" ... -> devolve o número escolhido.
# A opção atual fica destacada; número ou seta muda o destaque; Enter confirma.
# +--------------------------------------------------------------------------+
# | MENU COM SELEÇÃO
# | O que faz: Número ou setas mudam o destaque; só o Enter confirma.
# | Por quê:   Evita escolha errada por engano.
# +--------------------------------------------------------------------------+
ui_opcao(){
  local o i key rest
  _MK=(); _MT=(); _MSEL=0
  for o in "$@"; do _MK+=("${o%%:*}"); _MT+=("${o#*:}"); done

  if { exec 4</dev/tty; } 2>/dev/null; then
    _ui_menu_desenha
    while true; do
      IFS= read -rsn1 key <&4 || { exec 4<&-; kill -TERM $$; exit 130; }
      case "$key" in
        '') break ;;
        $'\e')
          rest=""
          IFS= read -rsn2 -t 0.1 rest <&4 || true
          if [[ -z "$rest" && -n "${UI_ESC:-}" ]]; then
            for (( i=0; i<${#_MK[@]}; i++ )); do
              if [[ "${_MK[i]}" == "$UI_ESC" ]]; then _MSEL=$i; fi
            done
            break
          fi
          if [[ "$rest" == "[A" ]]; then _MSEL=$(( (_MSEL - 1 + ${#_MK[@]}) % ${#_MK[@]} )); fi
          if [[ "$rest" == "[B" ]]; then _MSEL=$(( (_MSEL + 1) % ${#_MK[@]} )); fi
          ;;
        *)
          for (( i=0; i<${#_MK[@]}; i++ )); do
            if [[ "$key" == "${_MK[i]}" ]]; then _MSEL=$i; fi
          done
          ;;
      esac
      ui_out '\033[%dA' $(( ${#_MK[@]} + 1 ))
      _ui_menu_desenha
    done
    exec 4<&-
    log "UI_OPCAO=${_MK[_MSEL]}"
    printf '%s' "${_MK[_MSEL]}"
    return 0
  fi

  # Sem terminal (entrada redirecionada): digita e Enter.
  ui_opcao_linha "$@"
}

# +--------------------------------------------------------------------------+
# | MENU SEM TERMINAL
# | O que faz: Versão simples do menu: digita o número e Enter.
# | Por quê:   Funciona mesmo quando não há terminal interativo.
# +--------------------------------------------------------------------------+
ui_opcao_linha(){
  local o n validos=" " r
  for o in "$@"; do
    n="${o%%:*}"
    validos+="$n "
    ui_out '  %s%s%s - %s\n' "$C_VAL" "$n" "$C_RST" "${o#*:}"
  done
  while true; do
    ui_out '  %sOpção:%s ' "$C_PER" "$C_RST"
    r="$(ler | tr -d '[:space:]')"
    if [[ -n "$r" && "$validos" == *" $r "* ]]; then
      log "UI_OPCAO=$r"
      printf '%s' "$r"
      return 0
    fi
    ui_dica "Digite uma das opções acima."
  done
}

# +--------------------------------------------------------------------------+
# | LINHA DE PROGRESSO
# | O que faz: Redesenha a linha "[ 45%] etapa".
# | Por quê:   Mostra o andamento sem encher a tela.
# +--------------------------------------------------------------------------+
ui_desenha(){
  ui_out '\r\033[K  %s[%3d%%]%s %s' "$C_PER" "$UI_PCT" "$C_RST" "${UI_MSG_ATUAL:-}"
}

# +--------------------------------------------------------------------------+
# | ATUALIZAR ETAPA
# | O que faz: Troca o texto da etapa atual no progresso.
# | Por quê:   O operador vê em que passo está.
# +--------------------------------------------------------------------------+
ui_send(){
  (( UI_OK == 1 )) || return 0
  UI_MSG_ATUAL="$1"
  log "UI_MSG=$1"
  ui_desenha
}

# +--------------------------------------------------------------------------+
# | ATUALIZAR PORCENTAGEM
# | O que faz: Atualiza a porcentagem e o texto do progresso.
# | Por quê:   Indica que o processo está andando.
# +--------------------------------------------------------------------------+
ui_progress(){
  local pct="$1"
  local msg="${2:-}"

  (( UI_OK == 1 )) || return 0

  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi

  UI_PCT="$pct"
  if [[ -n "$msg" ]]; then UI_MSG_ATUAL="$msg"; fi
  log "UI_PROGRESS=${pct}% MSG=${UI_MSG_ATUAL}"
  ui_desenha
}

# +--------------------------------------------------------------------------+
# | COMEÇAR O PROGRESSO
# | O que faz: Mostra o título da ação e inicia o progresso.
# | Por quê:   Início claro de cada ação.
# +--------------------------------------------------------------------------+
ui_start(){
  UI_OK=1
  UI_PCT=0
  UI_MSG_ATUAL="Preparando"
  LAST_UI_LOOP_PCT=""
  ui_titulo "${1:-TLS}"
  ui_dica "Ctrl+C cancela e restaura a configuração anterior."
  ui_desenha
}

# +--------------------------------------------------------------------------+
# | TERMINAR O PROGRESSO
# | O que faz: Leva o progresso a 100% e pula linha.
# | Por quê:   Deixa a tela pronta para o resultado.
# +--------------------------------------------------------------------------+
ui_finish_progress(){
  (( UI_OK == 1 )) || return 0
  UI_PCT=100
  ui_desenha
  ui_out '\n'
  UI_OK=0
}

# +--------------------------------------------------------------------------+
# | EXECUTAR ETAPA
# | O que faz: Executa uma etapa mandando os detalhes técnicos para o log.
# | Por quê:   Tela limpa para o operador; tudo registrado para o suporte.
# +--------------------------------------------------------------------------+
ui_step_min(){
  local msg="$1"; shift
  local rc

  ui_send "$msg"
  log "INICIO: $msg"

  set +e
  "$@" >>"$AUDIT_TMP" 2>&1
  rc=$?
  set -e

  if (( rc == 0 )); then
    log "OK: $msg"
  else
    log "FALHA: $msg (rc=$rc)"
  fi

  return "$rc"
}

# +--------------------------------------------------------------------------+
# | PROGRESSO DURANTE O TESTE
# | O que faz: Avança a porcentagem enquanto o teste roda, mais rápido no
# |            começo.
# | Por quê:   O operador vê que o teste não travou.
# +--------------------------------------------------------------------------+
ui_progress_test_loop(){
  local loop="$1"
  local base="${2:-10}"
  local max_pct="${3:-90}"

  (( UI_OK == 1 )) || return 0
  [[ "$loop" =~ ^[0-9]+$ ]] || return 0
  [[ "$MAX_LOOPS" =~ ^[0-9]+$ ]] || return 0
  (( MAX_LOOPS > 0 )) || return 0

  # Progressão ease-out quadrática: f(t) = 2t − t²  (t = loop/MAX_LOOPS)
  local pct range
  range=$(( max_pct - base ))
  pct=$(( base + range * (2 * loop * MAX_LOOPS - loop * loop) / (MAX_LOOPS * MAX_LOOPS) ))

  if (( pct < base )); then pct="$base"; fi
  if (( pct > max_pct )); then pct="$max_pct"; fi

  if [[ "${LAST_UI_LOOP_PCT:-}" != "$pct" ]]; then
    LAST_UI_LOOP_PCT="$pct"
    ui_progress "$pct" "${UI_TEST_LABEL:-Testando Comunicação}"
  fi
}

# =========================================================
# BANCO / SQLITE / MYSQL
# =========================================================

# +--------------------------------------------------------------------------+
# | GRAVAR NO BANCO LOCAL
# | O que faz: Grava no banco local do PDV, tentando de novo se estiver
# |            ocupado.
# | Por quê:   O PDV pode estar usando o banco no mesmo instante.
# +--------------------------------------------------------------------------+
sqlite_exec_retry(){
  local sql="$1"
  local i

  debug_log "SQLITE_DB=$PDV_OUT_DB"
  debug_log "SQLITE_SQL=<omitida_por_seguranca>"

  # Defensive clamp: SQLITE_RETRY_COUNT=0 would skip the loop entirely and
  # return 1 immediately.  Ensure at least 1 attempt is made.
  local _retry_count="$SQLITE_RETRY_COUNT"
  if [[ ! "$_retry_count" =~ ^[0-9]+$ ]] || (( _retry_count < 1 )); then
    _retry_count=1
  fi

  for (( i=1; i<=_retry_count; i++ )); do
    debug_log "SQLITE_TENTATIVA=${i}/${_retry_count}"
    if sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "$sql" >>"$AUDIT_TMP" 2>&1; then
      return 0
    fi
    debug_log "SQLITE: tentativa ${i} falhou"
    # (( expr )) returns exit code 1 when expr is 0 (i.e. last attempt).
    # The || true prevents set -e from treating the non-sleep case as failure.
    (( i < _retry_count )) && sleep "$SQLITE_RETRY_SLEEP" || true
  done

  return 1
}

# +--------------------------------------------------------------------------+
# | LER DO BANCO LOCAL
# | O que faz: Lê um valor do banco local do PDV, tentando de novo se
# |            ocupado.
# | Por quê:   Mesmo motivo: banco pode estar em uso.
# +--------------------------------------------------------------------------+
sqlite_scalar(){
  local sql="$1" out="" i rc _sq_tmp

  debug_log "SQLITE_DB=$PDV_OUT_DB"
  debug_log "SQLITE_SQL=<omitida_por_seguranca>"

  # Defensive clamp: same as sqlite_exec_retry.
  local _retry_count="$SQLITE_RETRY_COUNT"
  if [[ ! "$_retry_count" =~ ^[0-9]+$ ]] || (( _retry_count < 1 )); then
    _retry_count=1
  fi

  for (( i=1; i<=_retry_count; i++ )); do
    # Capture the sqlite3 exit code directly (not through a pipeline) to avoid
    # the pipeline masking a sqlite3 error behind head's rc=0.
    _sq_tmp="$(mktemp 2>/dev/null)" || _sq_tmp="/dev/null"
    sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "$sql" >"$_sq_tmp" 2>>"$AUDIT_TMP"
    rc=$?
    if (( rc == 0 )); then
      out="$(head -n1 "$_sq_tmp" 2>/dev/null || true)"
      [[ "$_sq_tmp" != "/dev/null" ]] && rm -f "$_sq_tmp" 2>/dev/null || true
      debug_log "SQLITE_RESULT_TAMANHO=${#out}"  # valor omitido: pode ser a senha (base64)
      printf '%s\n' "$out"
      return 0
    fi
    [[ "$_sq_tmp" != "/dev/null" ]] && rm -f "$_sq_tmp" 2>/dev/null || true
    debug_log "SQLITE: tentativa de leitura ${i}/${_retry_count} falhou (rc=${rc})"
    # (( expr )) returns exit code 1 when expr is 0 (i.e. last attempt).
    # The || true prevents set -e from treating the non-sleep case as failure.
    (( i < _retry_count )) && sleep "$SQLITE_RETRY_SLEEP" || true
  done

  return 1
}

# +--------------------------------------------------------------------------+
# | DETALHES DA CONEXÃO (DEPURAÇÃO)
# | O que faz: Anota no log, se a depuração estiver ligada, os dados da
# |            conexão (senha escondida).
# | Por quê:   Ajuda o suporte a achar problema de conexão.
# +--------------------------------------------------------------------------+
_debug_mysql_context(){
  debug_log "MYSQL_HOST=$MYSQL_HOST"
  debug_log "MYSQL_PORT=$MYSQL_PORT"
  debug_log "MYSQL_DB=$NOME_BD"
  debug_log "MYSQL_USER=$USUARIO_BD"
  debug_log "MYSQL_PASS=<oculta>"
  debug_log "MYSQL_SQL=<omitida_por_seguranca>"
}

# SQL vai pela entrada padrão (<<<), não por -e: na linha de comando o token
# ficava visível no "ps" para qualquer usuário local enquanto o mysql rodava.
# +--------------------------------------------------------------------------+
# | COMANDO NO BANCO DA LOJA
# | O que faz: Executa um comando no MySQL. O comando vai pela entrada do
# |            programa, não pela linha de comando.
# | Por quê:   Assim o token não aparece para outros usuários na lista de
# |            processos.
# +--------------------------------------------------------------------------+
mysql_exec(){
  local sql="$1" _mysql_err_tmp _mysql_rc

  _debug_mysql_context

  _mysql_err_tmp="$(mktemp 2>/dev/null)" || _mysql_err_tmp="/dev/null"
  MYSQL_PWD="$MYSQL_PASS" mysql \
    --protocol=TCP \
    --connect-timeout=5 \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$USUARIO_BD" \
    "$NOME_BD" \
    -Ns <<<"$sql" >>"$AUDIT_TMP" 2>"$_mysql_err_tmp"
  _mysql_rc=$?
  if (( _mysql_rc != 0 )); then
    log "MYSQL_EXEC_ERROR (rc=${_mysql_rc}): $(cat "$_mysql_err_tmp" 2>/dev/null)"
  fi
  rm -f "$_mysql_err_tmp" 2>/dev/null || true
  return "$_mysql_rc"
}

# +--------------------------------------------------------------------------+
# | CONSULTA NO BANCO DA LOJA
# | O que faz: Faz uma consulta no MySQL e devolve o primeiro valor.
# | Por quê:   Mesmo cuidado: o token não aparece na lista de processos.
# +--------------------------------------------------------------------------+
mysql_scalar(){
  local sql="$1" out="" _mysql_err_tmp _mysql_rc

  _debug_mysql_context

  _mysql_err_tmp="$(mktemp 2>/dev/null)" || _mysql_err_tmp="/dev/null"
  # Use a temp file for mysql output so we capture mysql's exit code directly
  # rather than the exit code of head (which would mask mysql errors).
  local _mysql_out_tmp
  _mysql_out_tmp="$(mktemp 2>/dev/null)" || _mysql_out_tmp="/dev/null"
  MYSQL_PWD="$MYSQL_PASS" mysql \
    --protocol=TCP \
    --connect-timeout=5 \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$USUARIO_BD" \
    "$NOME_BD" \
    -Ns <<<"$sql" >"$_mysql_out_tmp" 2>"$_mysql_err_tmp"
  _mysql_rc=$?
  out="$(head -n1 "$_mysql_out_tmp" 2>/dev/null || true)"
  if (( _mysql_rc != 0 )); then
    log "MYSQL_SCALAR_ERROR (rc=${_mysql_rc}): $(head -n3 "$_mysql_err_tmp" 2>/dev/null | tr '\n' ' ')"
  fi
  [[ "$_mysql_out_tmp" != "/dev/null" ]] && rm -f "$_mysql_out_tmp" 2>/dev/null || true
  [[ "$_mysql_err_tmp" != "/dev/null" ]] && rm -f "$_mysql_err_tmp" 2>/dev/null || true

  debug_log "MYSQL_RESULT_TAMANHO=${#out}"  # valor omitido: pode ser o token
  printf '%s\n' "$out"
  return "$_mysql_rc"
}

# +--------------------------------------------------------------------------+
# | BANCO LOCAL ÍNTEGRO?
# | O que faz: Faz uma checagem rápida de integridade no banco local do PDV.
# | Por quê:   Nunca gravar num banco corrompido.
# +--------------------------------------------------------------------------+
check_sqlite_integrity(){
  step_enter "Validando integridade do SQLite"

  local r
  if [[ ! -r "$PDV_OUT_DB" ]]; then
    step_fail "PDV_OUT_DB não legível: $PDV_OUT_DB"
    return 1
  fi

  local _sq_int_tmp _sq_int_rc
  _sq_int_tmp="$(mktemp 2>/dev/null)" || _sq_int_tmp="/dev/null"
  sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" "PRAGMA quick_check;" \
    >"$_sq_int_tmp" 2>>"$AUDIT_TMP"
  _sq_int_rc=$?
  # Read first line; any value other than "ok" (including multi-line output)
  # indicates corruption.
  r="$(head -n1 "$_sq_int_tmp" 2>/dev/null || true)"
  [[ "$_sq_int_tmp" != "/dev/null" ]] && rm -f "$_sq_int_tmp" 2>/dev/null || true
  log_kv "SQLITE_INTEGRITY_RESULT" "$r"
  log_kv "SQLITE_INTEGRITY_RC" "$_sq_int_rc"

  if (( _sq_int_rc != 0 )); then
    step_fail "PRAGMA integrity_check falhou com rc=${_sq_int_rc}"
    return 1
  fi

  if [[ "$r" != "ok" ]]; then
    step_fail "Integridade SQLite falhou: $r"
    return 1
  fi

  step_ok "Validando integridade do SQLite"
}

# +--------------------------------------------------------------------------+
# | TABELAS NECESSÁRIAS
# | O que faz: Confere se existem as tabelas de configuração do PDV e do TLS.
# | Por quê:   Sem elas não há onde gravar.
# +--------------------------------------------------------------------------+
check_required_schema(){
  step_enter "Validando estrutura de banco"

  local t

  t="$(sqlite_scalar "SELECT name FROM sqlite_master WHERE type='table' AND name='configuracao_pdv';")"
  log_kv "SQLITE_TABLE_configuracao_pdv" "$t"
  [[ "$t" == "configuracao_pdv" ]] || return 1

  t="$(mysql_scalar "SHOW TABLES LIKE 'pdvctr';")"
  log_kv "MYSQL_TABLE_pdvctr" "$t"
  [[ "$t" == "pdvctr" ]] || return 1

  t="$(mysql_scalar "SHOW TABLES LIKE 'pdvtls';")"
  log_kv "MYSQL_TABLE_pdvtls" "$t"
  [[ "$t" == "pdvtls" ]] || return 1

  step_ok "Validando estrutura de banco"
}

# +--------------------------------------------------------------------------+
# | DADOS DE ACESSO AO BANCO
# | O que faz: Lê do banco local o endereço, usuário, senha e número do
# |            caixa.
# | Por quê:   Precisamos deles para chegar ao banco da loja.
# +--------------------------------------------------------------------------+
step_collect_cfg(){
  step_enter "Coletando configuração do PDV"

  local row

  [[ -r "$PDV_OUT_DB" ]] || {
    step_fail "PDV_OUT_DB sem leitura: $PDV_OUT_DB"
    return 1
  }

  # Seleciona cada coluna individualmente para evitar que um valor com '|'
  # quebre o parse IFS-based. sqlite3 sem separador explícito usa '|', portanto
  # campos com pipe literal corromperiam a linha composta.
  IP_BD="$(sqlite_scalar     "SELECT ip_bd       FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler ip_bd";       return 1; }
  NOME_BD="$(sqlite_scalar   "SELECT nome_bd     FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler nome_bd";     return 1; }
  USUARIO_BD="$(sqlite_scalar "SELECT usuario_bd FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler usuario_bd";  return 1; }
  SENHA_B64="$(sqlite_scalar "SELECT senha       FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler senha";       return 1; }
  NUM_CAIXA="$(sqlite_scalar "SELECT numero_caixa FROM configuracao_pdv LIMIT 1;")" || { step_fail "Falha ao ler numero_caixa"; return 1; }

  log "ROW_BRUTA=<omitida_por_seguranca>"
  [[ -n "$IP_BD" && -n "$NOME_BD" && -n "$USUARIO_BD" && -n "$SENHA_B64" && -n "$NUM_CAIXA" ]] || {
    step_fail "Um ou mais campos obrigatórios estão vazios em configuracao_pdv"
    return 1
  }

  IP_BD="$(printf '%s' "$IP_BD" | trim)"
  NOME_BD="$(printf '%s' "$NOME_BD" | trim)"
  USUARIO_BD="$(printf '%s' "$USUARIO_BD" | trim)"
  SENHA_B64="$(printf '%s' "$SENHA_B64" | trim)"
  NUM_CAIXA="$(printf '%s' "$NUM_CAIXA" | trim)"

  log_kv "IP_BD_RAW" "$IP_BD"
  log_kv "NOME_BD" "$NOME_BD"
  log_kv "USUARIO_BD" "$USUARIO_BD"
  log_kv "SENHA_B64" "<oculta>"  # nem parte da senha vai ao log (2+2 letras revelavam boa parte)
  log_kv "NUM_CAIXA" "$NUM_CAIXA"

  if [[ "$IP_BD" == *:* ]]; then
    MYSQL_HOST="${IP_BD%:*}"
    MYSQL_PORT="${IP_BD##*:}"
  else
    MYSQL_HOST="$IP_BD"
    MYSQL_PORT="3306"
  fi

  [[ -n "$MYSQL_HOST" ]] || {
    step_fail "MYSQL_HOST vazio"
    return 1
  }
  [[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] || MYSQL_PORT="3306"

  MYSQL_PASS="$(decode_b64 "$SENHA_B64")" || {
    step_fail "Falha ao decodificar senha base64 (dado corrompido em configuracao_pdv)"
    return 1
  }

  [[ -n "$NOME_BD" ]] || return 1
  [[ -n "$USUARIO_BD" ]] || return 1
  [[ -n "$MYSQL_PASS" ]] || return 1
  [[ "$NUM_CAIXA" =~ ^[0-9]+$ ]] || return 1

  log_kv "MYSQL_HOST" "$MYSQL_HOST"
  log_kv "MYSQL_PORT" "$MYSQL_PORT"
  log_kv "MYSQL_PASS" "<oculta>"

  step_ok "Coletando configuração do PDV"
}

# +--------------------------------------------------------------------------+
# | IDENTIFICAÇÃO DA LOJA
# | O que faz: Busca CNPJ, código Fiserv e nome da loja.
# | Por quê:   A Fiserv reconhece o PDV por esses dados.
# +--------------------------------------------------------------------------+
step_collect_identification(){
  step_enter "Coletando identificação do PDV"

  local loja_raw="" _raw_cnpj="" _raw_idloja=""

  _raw_cnpj="$(mysql_scalar "SELECT ${MYSQL_COL_CNPJ} FROM ${MYSQL_TABLE} LIMIT 1;")" || {
    step_fail "Falha ao consultar ${MYSQL_COL_CNPJ} em ${MYSQL_TABLE}"
    return 1
  }
CNPJ_LOJA="$(printf '%s' "$_raw_cnpj" | tr -dc '0-9')"

if [[ "$CNPJ_LOJA" =~ ^[0-9]+$ ]] && (( ${#CNPJ_LOJA} < 14 )); then
  log_kv "CNPJ_LOJA_NORMALIZADO_DE" "$CNPJ_LOJA"
  CNPJ_LOJA="$(pad_left "$CNPJ_LOJA" 14)" || return 1
  log_kv "CNPJ_LOJA_NORMALIZADO_PARA" "$CNPJ_LOJA"
fi

  _raw_idloja="$(mysql_scalar "SELECT ${MYSQL_COL_IDLOJA_TEF} FROM ${MYSQL_TABLE} LIMIT 1;")" || {
    step_fail "Falha ao consultar ${MYSQL_COL_IDLOJA_TEF} em ${MYSQL_TABLE}"
    return 1
  }
  IDLOJA_TEF="$(printf '%s' "$_raw_idloja" | tr -dc '0-9')"

  loja_raw="$(mysql_scalar "SELECT lojfantas FROM hiploj LIMIT 1;" || true)"

  LOJA_EXIBICAO="$(printf '%s' "$loja_raw" \
    | sed 's/[[:cntrl:]]//g; s/[[:space:]]*(.*$//; s/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | tr '[:lower:]' '[:upper:]')"

  [[ -n "${CNPJ_LOJA:-}" ]] || {
    step_fail "CNPJ_LOJA vazio"
    return 1
  }

  [[ -n "${IDLOJA_TEF:-}" ]] || {
    step_fail "IDLOJA_TEF vazio"
    return 1
  }

  log_kv "CNPJ_LOJA" "$CNPJ_LOJA"
  log_kv "IDLOJA_TEF" "$IDLOJA_TEF"

  if [[ -n "$LOJA_EXIBICAO" ]]; then
    log_kv "LOJA_EXIBICAO" "$LOJA_EXIBICAO"
  else
    log "LOJA_EXIBICAO=<vazia>"
  fi

  step_ok "Coletando identificação do PDV"
}

# +--------------------------------------------------------------------------+
# | LER O TOKEN ATUAL
# | O que faz: Busca o token TLS gravado para este caixa.
# | Por quê:   Mostrar no menu e usar no Testar TLS.
# +--------------------------------------------------------------------------+
step_collect_existing_token(){
  step_enter "Verificando token atual no banco"

  # A missing token row is not an error — use || true so the script continues.
  # IMPORTANT: if MySQL is down here, mysql_scalar returns rc!=0 and emits a
  # MYSQL_SCALAR_ERROR log line; the || true suppresses the exit but the TOKEN
  # will be empty.  We distinguish "no row" from "MySQL error" via the logged
  # rc in mysql_scalar.  The operator must check MYSQL_SCALAR_ERROR in the log
  # if TOKEN_ATUAL_BANCO is unexpectedly empty.
  local _raw_token
  _raw_token="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;" 2>/dev/null || true)"
  TOKEN_ATUAL_BANCO="$(printf '%s' "${_raw_token:-}" | tr -d '[:space:]')"

  if [[ -n "$TOKEN_ATUAL_BANCO" ]]; then
    log "TOKEN_ATUAL_ENCONTRADO_MASKED=$(mask_secret "$TOKEN_ATUAL_BANCO")"
  else
    # Log explicitly whether this is "row not found" or potentially a MySQL
    # connectivity problem (MYSQL_SCALAR_ERROR will appear above this line if
    # the latter).
    log "TOKEN_ATUAL_ENCONTRADO=<nenhum> (linha ausente ou falha de conexão — ver MYSQL_SCALAR_ERROR acima se houver)"
  fi

  step_ok "Verificando token atual no banco"
}

# =========================================================
# SNAPSHOT / ROLLBACK / LIMPEZA
# =========================================================

# capture_original_state
#
# Tira snapshot atômico de todos os artefatos que serão modificados pelo fluxo.
# DEVE ser chamada antes de qualquer escrita. Se falhar em qualquer passo,
# o rollback não pode ser considerado seguro — por isso a função retorna 1 e
# o chamador chama die(), que executa run_rollback() apenas se ROLLBACK_ENABLED=1.
# Como ROLLBACK_ENABLED só é definido no final desta função (após snapshot completo),
# um die() anterior ao snapshot não executa rollback. Esse invariante é intencional.
#
# Artefatos capturados:
#   ORIG_SQLITE_FLAG      — valor de habilita_tef_confiTLS em configuracao_pdv
#   ORIG_TOKEN_EXISTS/VALUE — linha em pdvtls para o caixa atual
#   ORIG_CONFITLS_BACKUP  — cópia de CONFITLS.INI (se existir)
#   ORIG_CTRL_BACKUP      — cópia de NaoExcluirControleCliSiTef (se existir)
#
# Nota: NaoExcluirControleCliSiTef é capturado mas NÃO restaurado no rollback
# por regra operacional (step_reset_tls_control é unidirecional).
# +--------------------------------------------------------------------------+
# | FOTO DE ANTES
# | O que faz: Guarda como estavam a chave TLS, o token, o CONFITLS.INI e o
# |            controle.
# | Por quê:   É isso que permite desfazer tudo se algo falhar.
# +--------------------------------------------------------------------------+
capture_original_state(){
  step_enter "Capturando estado original do sistema"

  local ctrl="/opt/checkout/clisitef/NaoExcluirControleCliSiTef"

  # CRÍTICO: se sqlite_scalar falhar (BUSY, LOCKED, coluna ausente), abortar
  # imediatamente — sem snapshot completo não há rollback seguro.
  ORIG_SQLITE_FLAG="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")" || {
    step_fail "Falha ao ler habilita_tef_confiTLS do SQLite durante snapshot (BUSY/LOCKED?)"
    return 1
  }
  if [[ -z "${ORIG_SQLITE_FLAG:-}" ]]; then
    step_fail "ORIG_SQLITE_FLAG vazio após leitura SQLite bem-sucedida (coluna ausente ou NULL?); snapshot inválido"
    return 1
  fi
  log_kv "ORIG_SQLITE_FLAG" "${ORIG_SQLITE_FLAG}"

  # CRÍTICO: se MySQL estiver inacessível durante snapshot, abortar.
  # Usar || true aqui causaria rollback que apaga token em vez de restaurá-lo.
  local _orig_token_raw
  if ! _orig_token_raw="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;")"; then
    step_fail "Falha ao consultar token original no MySQL durante snapshot (MySQL inacessível?); snapshot inválido"
    return 1
  fi
  ORIG_TOKEN_VALUE="$(printf '%s' "${_orig_token_raw:-}" | tr -d '[:space:]')"
  if [[ -n "${ORIG_TOKEN_VALUE:-}" ]]; then
    ORIG_TOKEN_EXISTS=1
    log_kv_masked "ORIG_TOKEN_VALUE_MASKED" "$ORIG_TOKEN_VALUE"
  else
    ORIG_TOKEN_EXISTS=0
  fi
  log_kv "ORIG_TOKEN_EXISTS" "$ORIG_TOKEN_EXISTS"

  if [[ -f "$CONFITLS_INI" ]]; then
    ORIG_CONFITLS_EXISTS=1
    ORIG_CONFITLS_BACKUP="$(mktemp "${SCRIPT_DIR}/.CONFITLS.INI.backup.XXXXXX" 2>/dev/null)" || {
      step_fail "Falha ao criar backup temporário de CONFITLS.INI (disco cheio?)"
      return 1
    }
    cp -a "$CONFITLS_INI" "$ORIG_CONFITLS_BACKUP" || {
      rm -f "$ORIG_CONFITLS_BACKUP" 2>/dev/null || true
      ORIG_CONFITLS_BACKUP=""
      step_fail "Falha ao copiar CONFITLS.INI para backup"
      return 1
    }
    chmod 600 "$ORIG_CONFITLS_BACKUP" 2>/dev/null || true
    log_kv "ORIG_CONFITLS_BACKUP" "$ORIG_CONFITLS_BACKUP"
  else
    ORIG_CONFITLS_EXISTS=0
  fi
  log_kv "ORIG_CONFITLS_EXISTS" "$ORIG_CONFITLS_EXISTS"

  if [[ -e "$ctrl" ]]; then
    ORIG_CTRL_EXISTS=1
    ORIG_CTRL_BACKUP="$(mktemp -d "${SCRIPT_DIR}/.tls_ctrl_backup.XXXXXX" 2>/dev/null)" || {
      step_fail "Falha ao criar diretório de backup para controle TLS (disco cheio?)"
      return 1
    }
    if [[ -d "$ctrl" ]]; then
      ORIG_CTRL_IS_DIR=1
      cp -a "$ctrl" "${ORIG_CTRL_BACKUP}/" || {
        rm -rf "$ORIG_CTRL_BACKUP" 2>/dev/null || true
        ORIG_CTRL_BACKUP=""
        step_fail "Falha ao copiar diretório de controle TLS para backup"
        return 1
      }
      log_kv "ORIG_CTRL_TYPE" "diretorio"
    else
      ORIG_CTRL_IS_DIR=0
      cp -a "$ctrl" "${ORIG_CTRL_BACKUP}/" || {
        rm -rf "$ORIG_CTRL_BACKUP" 2>/dev/null || true
        ORIG_CTRL_BACKUP=""
        step_fail "Falha ao copiar arquivo de controle TLS para backup"
        return 1
      }
      log_kv "ORIG_CTRL_TYPE" "arquivo"
    fi
    log_kv "ORIG_CTRL_BACKUP" "$ORIG_CTRL_BACKUP"
  else
    ORIG_CTRL_EXISTS=0
  fi
  log_kv "ORIG_CTRL_EXISTS" "$ORIG_CTRL_EXISTS"

  ROLLBACK_ENABLED=1
  step_ok "Capturando estado original do sistema"
}

# restore_original_state
#
# Restaura todos os artefatos capturados por capture_original_state.
# Executa sob set +e: cada passo falho é logado como WARN mas não interrompe
# os passos subsequentes — é melhor restaurar parcialmente do que parar no
# primeiro erro e deixar o sistema em estado misto.
# INT/TERM são bloqueados durante a restauração para evitar reentrada.
# +--------------------------------------------------------------------------+
# | VOLTAR COMO ESTAVA
# | O que faz: Restaura chave, token e CONFITLS.INI e reinicia o serviço do
# |            TEF.
# | Por quê:   Se algo falhar no meio, o PDV volta a funcionar como antes.
# +--------------------------------------------------------------------------+
restore_original_state(){
  step_enter "Restaurando estado original do sistema"

  # Block INT/TERM for the duration of the restore so a signal arriving while
  # restoring does not partially re-enter rollback or skip remaining steps.
  trap '' INT TERM

  # Note: ROLLBACK_ENABLED is cleared by run_rollback() before calling here;
  # this check guards direct calls.
  local token_esc=""
  local _rc_sqlite=0 _rc_mysql=0 _rc_conf=0 _rc_svc=0

  # Run all restore steps under set +e so a single failure does not skip the
  # remaining steps.
  set +e

  if [[ -n "${ORIG_SQLITE_FLAG:-}" ]]; then
    # Validate that the captured flag is a safe integer before embedding in SQL.
    local _flag_val
    if [[ "$ORIG_SQLITE_FLAG" =~ ^[0-9]+$ ]]; then
      _flag_val="$ORIG_SQLITE_FLAG"
    else
      log "WARN: ORIG_SQLITE_FLAG tem valor inesperado ('${ORIG_SQLITE_FLAG}'); restaurando para 0"
      _flag_val="0"
    fi
    sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=${_flag_val};"
    _rc_sqlite=$?
    log_kv "RESTORE_SQLITE_FLAG_ALVO" "$_flag_val"
    log_kv "RESTORE_SQLITE_RC" "$_rc_sqlite"
    if (( _rc_sqlite != 0 )); then
      log "WARN: falha ao restaurar flag SQLite durante rollback (rc=${_rc_sqlite})"
    else
      # Confirm the value was actually written: rc=0 does not guarantee
      # the table had any rows (UPDATE affecting 0 rows returns rc=0 in SQLite).
      local _sqlite_confirm
      _sqlite_confirm="$(sqlite3 "$PDV_OUT_DB" ".timeout ${SQLITE_BUSY_TIMEOUT_MS}" \
        "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;" 2>/dev/null || true)"
      log_kv "RESTORE_SQLITE_FLAG_CONFIRMADO" "${_sqlite_confirm:-<leitura_falhou>}"
      if [[ "${_sqlite_confirm:-}" != "${_flag_val}" ]]; then
        log "WARN: RESTORE_SQLITE_FLAG_MISMATCH: esperado=${_flag_val} atual=${_sqlite_confirm:-<vazio>}"
        _rc_sqlite=1
      fi
    fi
  fi

  if (( ORIG_TOKEN_EXISTS == 1 )); then
    token_esc="$(mysql_escape "$ORIG_TOKEN_VALUE")"
    # Guard: NUM_CAIXA must be a valid integer before embedding in SQL.
    if [[ "${NUM_CAIXA:-}" =~ ^[0-9]+$ ]]; then
      # Verifica ROW_COUNT após UPDATE: rc=0 com 0 linhas afetadas ainda é
      # uma falha de rollback — o token não foi restaurado.
      mysql_exec "UPDATE ${TLS_TABLE} SET ${TLS_COL_TOKEN}='${token_esc}' WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};"
      _rc_mysql=$?
      if (( _rc_mysql == 0 )); then
        local _upd_rows
        _upd_rows="$(mysql_scalar "SELECT ROW_COUNT();")" || _upd_rows=""
        if [[ "${_upd_rows:-0}" == "0" ]]; then
          log "WARN: UPDATE token retornou rc=0 mas ROW_COUNT()=0; token pode não ter sido restaurado (linha ausente?)"
        fi
      fi
    else
      log "WARN: NUM_CAIXA inválido ('${NUM_CAIXA:-}') durante rollback de token; UPDATE ignorado"
      _rc_mysql=1
    fi
    log_kv "RESTORE_TOKEN" "original"
    log_kv "RESTORE_MYSQL_RC" "$_rc_mysql"
    (( _rc_mysql != 0 )) && log "WARN: falha ao restaurar token MySQL durante rollback (rc=${_rc_mysql})"
  else
    if [[ "${NUM_CAIXA:-}" =~ ^[0-9]+$ ]]; then
      mysql_exec "DELETE FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};"
      _rc_mysql=$?
    else
      log "WARN: NUM_CAIXA inválido ('${NUM_CAIXA:-}') durante rollback de token; DELETE ignorado"
      _rc_mysql=1
    fi
    log_kv "RESTORE_TOKEN" "deleted"
    log_kv "RESTORE_MYSQL_RC" "$_rc_mysql"
    (( _rc_mysql != 0 )) && log "WARN: falha ao deletar token MySQL durante rollback (rc=${_rc_mysql})"
  fi

  if (( ORIG_CONFITLS_EXISTS == 1 )) && [[ -f "${ORIG_CONFITLS_BACKUP:-}" ]]; then
    # Use an atomic rename so a disk-full condition cannot leave CONFITLS_INI
    # in a zero-byte or truncated state.
    local _tmp_restore_ini
    _tmp_restore_ini="$(mktemp "${CONFITLS_INI}.restoreXXXXXX" 2>/dev/null)" || _tmp_restore_ini=""
    if [[ -n "$_tmp_restore_ini" ]]; then
      cp -a "$ORIG_CONFITLS_BACKUP" "$_tmp_restore_ini" && \
        mv -f "$_tmp_restore_ini" "$CONFITLS_INI"
      _rc_conf=$?
      [[ -f "$_tmp_restore_ini" ]] && rm -f "$_tmp_restore_ini" 2>/dev/null || true
    else
      cp -a "$ORIG_CONFITLS_BACKUP" "$CONFITLS_INI"
      _rc_conf=$?
    fi
    chmod 0644 "$CONFITLS_INI" 2>/dev/null || true
    log_kv "RESTORE_CONFITLS" "restaurado"
    log_kv "RESTORE_CONFITLS_RC" "$_rc_conf"
    (( _rc_conf != 0 )) && log "WARN: falha ao restaurar CONFITLS.INI durante rollback (rc=${_rc_conf})"
  else
    rm -f "$CONFITLS_INI" 2>/dev/null || true
    log "RESTORE_CONFITLS=removido"
  fi

  # Controle TLS não é restaurado no rollback por regra operacional.
  log "RESTORE_CTRL=ignorado_por_regra"

  # Restart service; _restart_service uses a 60-second timeout guard.
  _restart_service
  _rc_svc=$?
  log_kv "RESTORE_SERVICE" "restart"
  log_kv "RESTORE_SERVICE_RC" "$_rc_svc"
  if (( _rc_svc != 0 )); then
    log "WARN: falha ao reiniciar ${SERVICE_NAME} durante rollback (rc=${_rc_svc})"
  else
    # Verify the service actually reached active state after restart.
    # rc!=0 from _restart_service only means systemctl restart failed;
    # rc=0 does NOT guarantee the service is running (it could have exited
    # immediately after being started). Poll is_active for up to 10 seconds.
    local _svc_active=0
    local _svc_check
    for _svc_check in 1 2 3 4 5 6 7 8 9 10; do
      if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        _svc_active=1
        break
      fi
      sleep 1
    done
    if (( _svc_active == 0 )); then
      log "WARN: ${SERVICE_NAME} não ficou ativo após rollback-restart (10 s de espera esgotados)"
      _rc_svc=1
    else
      log "RESTORE_SERVICE_ACTIVE=1"
    fi
  fi

  # Emit a single aggregated rollback-result line so operators can grep for
  # ROLLBACK_RESULT without reading individual WARN lines.
  local _any_fail=0
  (( _rc_sqlite != 0 )) && _any_fail=1
  (( _rc_mysql  != 0 )) && _any_fail=1
  (( _rc_conf   != 0 )) && _any_fail=1
  (( _rc_svc    != 0 )) && _any_fail=1
  if (( _any_fail == 1 )); then
    log "ROLLBACK_RESULT=PARCIAL (sqlite_rc=${_rc_sqlite} mysql_rc=${_rc_mysql} conf_rc=${_rc_conf} svc_rc=${_rc_svc})"
  else
    log "ROLLBACK_RESULT=COMPLETO"
  fi

  set -e

  # Restore signal handlers now that the critical restore section is done.
  trap on_signal INT TERM

  if (( _any_fail == 1 )); then
    # Log as failure so the audit trail is accurate, but do not propagate the
    # error — caller uses "|| true" so partial rollback does not abort die().
    step_fail "Restaurando estado original do sistema (rollback parcial)"
  else
    step_ok "Restaurando estado original do sistema"
  fi
}

# +--------------------------------------------------------------------------+
# | DESFAZER (UMA VEZ SÓ)
# | O que faz: Chama a restauração, garantindo que ela rode uma única vez.
# | Por quê:   Desfazer duas vezes poderia bagunçar o estado.
# +--------------------------------------------------------------------------+
run_rollback(){
  # Guard against running twice in the same process.
  (( ROLLBACK_ENABLED == 1 )) || {
    log "ROLLBACK: já executado ou não habilitado, ignorando chamada duplicada"
    return 0
  }

  log_sep
  log "INICIANDO ROLLBACK"

  # Disable before executing so a recursive call (e.g. from a trap inside
  # restore) cannot re-enter.
  ROLLBACK_ENABLED=0

  restore_original_state || true

  log "ROLLBACK_CONCLUIDO"
}

# Salva o log da execução (sempre) em InstalaTLS.log ao lado do script.
# +--------------------------------------------------------------------------+
# | SALVAR O LOG
# | O que faz: Move o log desta execução para InstalaTLS.log.
# | Por quê:   O suporte consegue ver depois tudo o que foi feito.
# +--------------------------------------------------------------------------+
save_final_log(){
  if (( LOG_FINALIZED == 1 )); then return 0; fi
  LOG_FINALIZED=1
  [[ -n "${AUDIT_TMP:-}" && -f "${AUDIT_TMP:-}" ]] || return 0
  if mv -f "$AUDIT_TMP" "$FINAL_LOG_FILE" 2>/dev/null || { cp -a "$AUDIT_TMP" "$FINAL_LOG_FILE" 2>/dev/null && rm -f "$AUDIT_TMP" 2>/dev/null; }; then
    chmod 600 "$FINAL_LOG_FILE" 2>/dev/null || true
  else
    rm -f "$AUDIT_TMP" 2>/dev/null || true
  fi
}

# +--------------------------------------------------------------------------+
# | LIMPEZA AO SAIR
# | O que faz: Salva o log, apaga temporários sensíveis, libera a trava e
# |            limpa segredos da memória.
# | Por quê:   Nada sensível fica para trás.
# +--------------------------------------------------------------------------+
cleanup(){
  trap '' INT TERM EXIT

  save_final_log
  cleanup_sensitive_artifacts

  exec 9>&- 2>/dev/null || true

  MYSQL_PASS=""
  SENHA_B64=""
  TOKEN_TLS=""
  TOKEN_ATUAL_BANCO=""
  ORIG_TOKEN_VALUE=""
}

# +--------------------------------------------------------------------------+
# | CTRL+C OU FECHAMENTO
# | O que faz: Se o script for interrompido, desfaz o que estava pendente e
# |            sai.
# | Por quê:   Interromper nunca deixa o PDV pela metade.
# +--------------------------------------------------------------------------+
on_signal(){
  trap '' INT TERM
  log "SINAL: interrupção recebida (INT/TERM)"
  set +e
  if (( UI_OK == 1 )); then ui_out '
'; UI_OK=0; fi
  ui_aviso "Cancelado."
  if (( ROLLBACK_ENABLED == 1 && SKIP_ROLLBACK == 0 )); then
    log "SINAL: iniciando rollback por sinal"
    ui_dica "Restaurando a configuração anterior..."
    run_rollback || true
    ui_aviso "A configuração anterior foi restaurada."
  fi
  ui_dica "Log: ${FINAL_LOG_FILE}"
  exit 130
}

trap cleanup EXIT
trap on_signal INT TERM
trap '' PIPE

# die MSG...
# Erro fatal (fora do menu): desfaz o que estiver pendente, mostra e sai.
# +--------------------------------------------------------------------------+
# | ERRO GRAVE
# | O que faz: Desfaz o pendente, mostra o erro e encerra.
# | Por quê:   Erro sem volta termina com o PDV no estado anterior.
# +--------------------------------------------------------------------------+
die(){
  set +e
  log "ERRO_FATAL: $*"
  log "ERRO_CONTEXTO: ROLLBACK_ENABLED=${ROLLBACK_ENABLED} SKIP_ROLLBACK=${SKIP_ROLLBACK}"
  if (( UI_OK == 1 )); then ui_out '
'; UI_OK=0; fi
  if (( ROLLBACK_ENABLED == 1 )); then run_rollback; fi
  ui_erro "Erro: $*"
  ui_dica "Log: ${FINAL_LOG_FILE}"
  exit 1
}

# =========================================================
# CONTEXTO TLS / ESCRITA / SERVIÇO / MODO
# =========================================================

# +--------------------------------------------------------------------------+
# | PREPARAR DADOS DO TESTE
# | O que faz: Junta identificação, terminal, loja e parâmetros que a
# |            CliSiTef precisa.
# | Por quê:   O teste só funciona com esses dados completos.
# +--------------------------------------------------------------------------+
step_finalize_tls_context(){
  step_enter "Finalizando contexto TLS"

  step_collect_identification || {
    step_fail "Falha ao coletar identificação do PDV"
    return 1
  }

  pick_socket_host_port || {
    step_fail "Falha ao configurar socket"
    return 1
  }

  derive_idterm || {
    step_fail "Falha ao derivar IDTERM"
    return 1
  }

  derive_idloja_fmt || {
    step_fail "Falha ao formatar IDLOJA"
    return 1
  }

  derive_parmsclient || {
    step_fail "Falha ao montar PARMSCLIENT"
    return 1
  }

  DATAFISC="$(date +%Y%m%d)"
  HORAFISC="$(date +%H%M%S)"
  CUPOM="$HORAFISC"

  log_kv "CACHE_NUM_CAIXA" "$NUM_CAIXA"
  log_kv "CACHE_CNPJ_LOJA" "$CNPJ_LOJA"
  log_kv "CACHE_IDLOJA_TEF" "$IDLOJA_TEF"
  log_kv "CACHE_IDTERM" "$IDTERM"
  log_kv "CACHE_IDLOJA" "$IDLOJA"
  log_kv "CACHE_PARMS" "$PARMS"
  log_kv "CACHE_DATAFISC" "$DATAFISC"
  log_kv "CACHE_HORAFISC" "$HORAFISC"
  log_kv "CACHE_CUPOM" "$CUPOM"

  step_ok "Finalizando contexto TLS"
}

# +--------------------------------------------------------------------------+
# | LIGAR A CHAVE TLS
# | O que faz: Marca no banco local do PDV que o TEF usa TLS.
# | Por quê:   No Linux é essa chave que muda o modo do TEF.
# +--------------------------------------------------------------------------+
step_set_flag_tls(){
  step_enter "Habilitando flag TLS no SQLite"

  local res
  sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=1;" || {
    step_fail "UPDATE habilita_tef_confiTLS"
    return 1
  }

  res="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "habilita_tef_confiTLS" "$res"

  [[ "$res" == "1" ]] || {
    step_fail "Flag TLS não confirmada"
    return 1
  }

  step_ok "Habilitando flag TLS no SQLite"
}

# +--------------------------------------------------------------------------+
# | GRAVAR O TOKEN NO BANCO
# | O que faz: Apaga o token antigo deste caixa e grava o novo, numa única
# |            operação.
# | Por quê:   Um token correto por caixa; se falhar, nada fica pela metade.
# +--------------------------------------------------------------------------+
step_write_mysql(){
  step_enter "Gravando token no MySQL"

  local cnt token_esc

  cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};")" || {
    step_fail "Falha ao consultar registros em pdvtls (MySQL inacessível?)"
    return 1
  }
  cnt="${cnt:-0}"
  [[ "$cnt" =~ ^[0-9]+$ ]] || {
    step_fail "COUNT inválido em pdvtls"
    return 1
  }

  log_kv "PDVTLS_COUNT" "$cnt"
  token_esc="$(mysql_escape "$TOKEN_TLS")"
  log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

  if (( cnt > 1 )); then
    log "WARN: registros duplicados em pdvtls para caixa ${NUM_CAIXA}"
  fi

  log "AÇÃO: saneando pdvtls para caixa ${NUM_CAIXA} em transação"
  log_kv "MYSQL_TRANSACTION_CAIXA" "$NUM_CAIXA"
  log_kv "MYSQL_TRANSACTION_TABELA" "$TLS_TABLE"

  local _mysql_rc
  set +e
  mysql_exec "
START TRANSACTION;
DELETE FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA};
INSERT INTO ${TLS_TABLE} (tlsloja, ${TLS_COL_CAIXA}, ${TLS_COL_TOKEN})
VALUES (0, ${NUM_CAIXA}, '${token_esc}');
COMMIT;
"
  _mysql_rc=$?
  set -e

  log_kv "MYSQL_TRANSACTION_RC" "$_mysql_rc"

  if (( _mysql_rc != 0 )); then
    log 'AÇÃO_FALHOU: erro durante saneamento/INSERT em pdvtls'
    set +e
    mysql_exec "ROLLBACK;" || true
    set -e
    step_fail "Gravando token no MySQL"
    return 1
  fi

  local verify_cnt
  verify_cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} AND ${TLS_COL_TOKEN}='${token_esc}';")" || {
    step_fail "Falha ao validar token gravado em pdvtls"
    return 1
  }
  verify_cnt="${verify_cnt:-0}"
  log_kv "MYSQL_POST_INSERT_VERIFY_COUNT" "$verify_cnt"

  if [[ ! "$verify_cnt" =~ ^[0-9]+$ ]] || (( verify_cnt < 1 )); then
    log 'AÇÃO_FALHOU: verificação pós-INSERT não encontrou o token em pdvtls'
    step_fail "Gravando token no MySQL (verificação pós-commit)"
    return 1
  fi

  log "AÇÃO_CONCLUÍDA: saneamento + INSERT pdvtls verificado"
  step_ok "Gravando token no MySQL"
}
# +--------------------------------------------------------------------------+
# | GRAVAR O CONFITLS.INI
# | O que faz: Grava o arquivo com o endereço da Fiserv e o token, de forma
# |            segura.
# | Por quê:   É ele que faz a CliSiTef usar TLS.
# +--------------------------------------------------------------------------+
write_confitls_ini(){
  step_enter "Gerando CONFITLS.INI"

  local tmp_ini
  local _confitls_dir
  _confitls_dir="$(dirname "$CONFITLS_INI")"
  if [[ ! -d "$_confitls_dir" ]]; then
    step_fail "Diretório de CONFITLS.INI não existe: $_confitls_dir"
    return 1
  fi
  tmp_ini="$(mktemp "${CONFITLS_INI}.XXXXXX" 2>/dev/null)" || {
    step_fail "Não foi possível criar arquivo temporário para CONFITLS.INI (disco cheio ou sem permissão?)"
    return 1
  }
  chmod 0644 "$tmp_ini" 2>/dev/null || true

  cat > "$tmp_ini" <<EOF
[ConfiguracaoTLS]
TipoComunicacaoExterna=TLSGWP
URLTLS=tls-prod.fiservapp.com
TokenRegistro=$TOKEN_TLS
EOF

  mv -f "$tmp_ini" "$CONFITLS_INI" || {
    rm -f "$tmp_ini" 2>/dev/null || true
    step_fail "Falha ao mover arquivo temporário para $CONFITLS_INI"
    return 1
  }

  log_kv "CONFITLS_INI" "$CONFITLS_INI"
  log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

  step_ok "Gerando CONFITLS.INI"
}

# +--------------------------------------------------------------------------+
# | CONFERIR TUDO
# | O que faz: Confere token no banco, chave TLS e o CONFITLS.INI.
# | Por quê:   Só testar com a configuração perfeita.
# +--------------------------------------------------------------------------+
validate_all(){
  step_enter "Validando gravações finais"

  local cnt flag token_esc conf_token conf_secao conf_tipo conf_url

  token_esc="$(mysql_escape "$TOKEN_TLS")"

  # Captura explícita do rc: sem || {}, falha de conexão MySQL abortaria via set -e
  # sem mensagem de erro útil.
  cnt="$(mysql_scalar "SELECT COUNT(*) FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} AND ${TLS_COL_TOKEN}='${token_esc}';")" || {
    step_fail "Falha ao consultar pdvtls na validação (MySQL inacessível?)"
    return 1
  }
  cnt="${cnt:-0}"
  log_kv "VALIDATE_PDVTLS_COUNT" "$cnt"

  [[ "$cnt" =~ ^[0-9]+$ ]] || {
    step_fail "COUNT inválido na validação MySQL"
    return 1
  }

  (( cnt >= 1 )) || {
    step_fail "Token não encontrado em pdvtls"
    return 1
  }

  if (( cnt > 1 )); then
    log "WARN: VALIDATE_PDVTLS_DUPLICATES encontrados: cnt=$cnt para caixa=${NUM_CAIXA}"
  fi

  flag="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "VALIDATE_SQLITE_FLAG" "$flag"

  [[ "$flag" == "1" ]] || {
    step_fail "Flag TLS não está em 1"
    return 1
  }

  [[ -f "$CONFITLS_INI" ]] || {
    step_fail "CONFITLS.INI não existe"
    return 1
  }

  conf_secao="$(grep -Fx '[ConfiguracaoTLS]' "$CONFITLS_INI" | head -n1 || true)"
  conf_tipo="$(sed -n 's/^TipoComunicacaoExterna=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  conf_url="$(sed -n 's/^URLTLS=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  conf_token="$(sed -n 's/^TokenRegistro=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"

  log_kv "VALIDATE_CONFITLS_SECAO_OK" "$([[ "$conf_secao" == "[ConfiguracaoTLS]" ]] && echo 1 || echo 0)"
  log_kv "VALIDATE_CONFITLS_TIPO" "$conf_tipo"
  log_kv "VALIDATE_CONFITLS_URL" "$conf_url"
  log_kv "VALIDATE_CONFITLS_TOKEN_MASKED" "$(mask_secret "$conf_token")"

  [[ "$conf_secao" == "[ConfiguracaoTLS]" ]] || {
    step_fail "Seção do CONFITLS.INI inválida"
    return 1
  }

  [[ "$conf_tipo" == "TLSGWP" ]] || {
    step_fail "TipoComunicacaoExterna inválido no CONFITLS.INI"
    return 1
  }

  [[ "$conf_url" == "tls-prod.fiservapp.com" ]] || {
    step_fail "URLTLS inválida no CONFITLS.INI"
    return 1
  }

  [[ "$conf_token" == "$TOKEN_TLS" ]] || {
    step_fail "Token do CONFITLS.INI diferente do token atual"
    return 1
  }

  step_ok "Validando gravações finais"
}

# Run systemctl restart $SERVICE_NAME with a 60-second timeout guard.
# Returns the exit code of systemctl / timeout.
# +--------------------------------------------------------------------------+
# | REINICIAR O SERVIÇO DO TEF
# | O que faz: Reinicia o serviço da CliSiTef, com limite de tempo.
# | Por quê:   A CliSiTef só lê a configuração nova ao reiniciar.
# +--------------------------------------------------------------------------+
_restart_service(){
  log "AÇÃO: systemctl restart $SERVICE_NAME"
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 systemctl restart "$SERVICE_NAME" >>"$AUDIT_TMP" 2>&1
  else
    systemctl restart "$SERVICE_NAME" >>"$AUDIT_TMP" 2>&1
  fi
}

# +--------------------------------------------------------------------------+
# | REINICIAR E ESPERAR
# | O que faz: Reinicia o serviço e espera ele ficar ativo.
# | Por quê:   Testar antes de o serviço subir daria erro falso.
# +--------------------------------------------------------------------------+
restart_and_wait_service(){
  step_enter "Reiniciando serviço TEF"

  local active_state sub_state
  log_kv "SERVICE_NAME" "$SERVICE_NAME"

  local _svc_restart_rc
  _restart_service
  _svc_restart_rc=$?
  if (( _svc_restart_rc != 0 )); then
    step_fail "Falha no systemctl restart (rc=${_svc_restart_rc})"
    return 1
  fi

  for _ in {1..20}; do
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      active_state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
      sub_state="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
      log_kv "SERVICE_ACTIVE_STATE" "$active_state"
      log_kv "SERVICE_SUB_STATE" "$sub_state"
      step_ok "Reiniciando serviço TEF"
      return 0
    fi

    if systemctl is-failed --quiet "$SERVICE_NAME"; then
      log "SERVICE: estado failed"
      systemctl status "$SERVICE_NAME" --no-pager >>"$AUDIT_TMP" 2>&1 || true
      step_fail "Reiniciando serviço TEF"
      return 1
    fi

    sleep 1
  done

  active_state="$(systemctl show -p ActiveState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
  sub_state="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>>"$AUDIT_TMP" || true)"
  log_kv "SERVICE_ACTIVE_STATE_FINAL" "$active_state"
  log_kv "SERVICE_SUB_STATE_FINAL" "$sub_state"
  systemctl status "$SERVICE_NAME" --no-pager >>"$AUDIT_TMP" 2>&1 || true

  step_fail "Reiniciando serviço TEF"
  return 1
}

# +--------------------------------------------------------------------------+
# | PREPARAR O TLS PARA TESTE
# | O que faz: Confere a configuração e reinicia o serviço.
# | Por quê:   Garante que o teste use a configuração nova.
# +--------------------------------------------------------------------------+
step_prepare_tls_runtime_for_test(){
  step_enter "Preparando ambiente TLS para teste"

  validate_all || {
    step_fail "Validação final do ambiente TLS falhou"
    return 1
  }

  restart_and_wait_service || {
    step_fail "Falha ao reiniciar serviço TEF"
    return 1
  }

  step_ok "Preparando ambiente TLS para teste"
}

# +--------------------------------------------------------------------------+
# | ZERAR O CONTROLE DA CLISITEF
# | O que faz: Apaga o controle que a CliSiTef cria no registro TLS.
# | Por quê:   Com token novo, ela precisa se registrar de novo na Fiserv.
# +--------------------------------------------------------------------------+
step_reset_tls_control(){
  step_enter "Removendo controle TLS anterior"

  local ctrl="/opt/checkout/clisitef/NaoExcluirControleCliSiTef"

  if [[ -e "$ctrl" ]]; then
    log_kv "TLS_CONTROL_ANTES" "$ctrl"

    if [[ -d "$ctrl" ]]; then
      log "TLS_CONTROL_TIPO=diretorio"
      rm -rf "$ctrl" >>"$AUDIT_TMP" 2>&1 || {
        step_fail "Não foi possível remover diretório de controle TLS anterior"
        return 1
      }
      log "TLS_CONTROL_REMOVIDO_TIPO=diretorio"
    else
      log "TLS_CONTROL_TIPO=arquivo"
      rm -f "$ctrl" >>"$AUDIT_TMP" 2>&1 || {
        step_fail "Não foi possível remover arquivo de controle TLS anterior"
        return 1
      }
      log "TLS_CONTROL_REMOVIDO_TIPO=arquivo"
    fi
  else
    log "TLS_CONTROL_INEXISTENTE=1"
  fi

  if [[ -e "$ctrl" ]]; then
    step_fail "Controle TLS ainda existe após remoção"
    return 1
  fi

  step_ok "Removendo controle TLS anterior"
}

# +--------------------------------------------------------------------------+
# | REINICIAR DEPOIS DE ZERAR
# | O que faz: Reinicia o serviço e espera ele responder.
# | Por quê:   A CliSiTef precisa recarregar sem o controle antigo.
# +--------------------------------------------------------------------------+
step_restart_socket_after_control_reset(){
  step_enter "Reiniciando serviço socket após remover controle"

  local _svc_ctrl_rc
  _restart_service
  _svc_ctrl_rc=$?
  if (( _svc_ctrl_rc != 0 )); then
    step_fail "Falha ao reiniciar serviço socket após remover controle (rc=${_svc_ctrl_rc})"
    return 1
  fi

  wait_socket_ready "$HOST_DEFAULT" "$PORT_DEFAULT" 60 0.25 || {
    step_fail "Socket não ficou disponível após reinício"
    return 1
  }

  step_ok "Reiniciando serviço socket após remover controle"
}

# +--------------------------------------------------------------------------+
# | PREPARAR TOKEN NOVO
# | O que faz: Confere, reinicia, zera o controle e reinicia de novo.
# | Por quê:   Sequência exigida para a CliSiTef registrar um token novo.
# +--------------------------------------------------------------------------+
step_prepare_tls_runtime_for_new_token(){
  step_enter "Preparando ambiente TLS para novo token"

  step_prepare_tls_runtime_for_test || {
    step_fail "Falha na preparação base do ambiente TLS"
    return 1
  }

  step_reset_tls_control || {
    step_fail "Falha ao remover controle TLS anterior"
    return 1
  }

  step_restart_socket_after_control_reset || {
    step_fail "Falha ao subir socket após reset do controle"
    return 1
  }

  step_ok "Preparando ambiente TLS para novo token"
}

# +--------------------------------------------------------------------------+
# | MONTAR TLS COM O TOKEN ATUAL
# | O que faz: Liga a chave TLS, recria o CONFITLS.INI se preciso e reinicia.
# | Por quê:   Deixa o PDV pronto para testar o TLS que já existe.
# +--------------------------------------------------------------------------+
step_prepare_tls_for_existing_token_test(){
  step_enter "Preparando ambiente TLS para testar token atual"

  local flag="" token_banco="" conf_token="" conf_tipo="" conf_url="" conf_secao=""

  local _raw_tb=""
  _raw_tb="$(mysql_scalar "SELECT ${TLS_COL_TOKEN} FROM ${TLS_TABLE} WHERE tlsloja=0 AND ${TLS_COL_CAIXA}=${NUM_CAIXA} LIMIT 1;")" || {
    step_fail "Falha ao ler token do banco para validação"
    return 1
  }
  token_banco="$(printf '%s' "$_raw_tb" | tr -d '[:space:]')"

  [[ "$token_banco" =~ ^[0-9]{4}(-[0-9]{4}){3}$ ]] || {
    step_fail "Token do banco em formato inválido"
    return 1
  }

  TOKEN_TLS="$token_banco"
  log_kv_masked "TOKEN_BANCO_MASKED" "$TOKEN_TLS"

  flag="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "CHECK_TLS_FLAG_ATUAL" "$flag"

  if [[ "$flag" != "1" ]]; then
    log "AÇÃO: habilitando modo TLS"
    step_set_flag_tls || {
      step_fail "Falha ao habilitar modo TLS"
      return 1
    }
  fi

  if [[ -f "$CONFITLS_INI" ]]; then
    conf_secao="$(grep -Fx '[ConfiguracaoTLS]' "$CONFITLS_INI" | head -n1 || true)"
    conf_tipo="$(sed -n 's/^TipoComunicacaoExterna=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
    conf_url="$(sed -n 's/^URLTLS=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
    conf_token="$(sed -n 's/^TokenRegistro=//p' "$CONFITLS_INI" | head -n1 | tr -d '[:space:]')"
  else
    conf_secao=""
    conf_tipo=""
    conf_url=""
    conf_token=""
  fi

  log_kv "CHECK_CONFITLS_EXISTE" "$([[ -f "$CONFITLS_INI" ]] && echo 1 || echo 0)"
  log_kv "CHECK_CONFITLS_SECAO_OK" "$([[ "$conf_secao" == "[ConfiguracaoTLS]" ]] && echo 1 || echo 0)"
  log_kv "CHECK_CONFITLS_TIPO" "$conf_tipo"
  log_kv "CHECK_CONFITLS_URL" "$conf_url"
  log_kv "CHECK_CONFITLS_TOKEN_MASKED" "$(mask_secret "$conf_token")"

  if [[ ! -f "$CONFITLS_INI" || "$conf_secao" != "[ConfiguracaoTLS]" || "$conf_tipo" != "TLSGWP" || "$conf_url" != "tls-prod.fiservapp.com" || "$conf_token" != "$TOKEN_TLS" ]]; then
    log "AÇÃO: recriando CONFITLS.INI com conteúdo íntegro"
    write_confitls_ini || {
      step_fail "Falha ao recriar CONFITLS.INI"
      return 1
    }
  fi

  step_prepare_tls_runtime_for_test || return 1

  step_ok "Preparando ambiente TLS para testar token atual"
}

# +--------------------------------------------------------------------------+
# | LIGAR O MODO GSURF
# | O que faz: Guarda o CONFITLS.INI como backup, esvazia, desliga a chave
# |            TLS e reinicia.
# | Por quê:   Coloca o PDV em GSurf; o backup permite voltar ao TLS.
# +--------------------------------------------------------------------------+
step_switch_to_gsurf(){
  step_enter "Retornando modo de transação para GSurf"

  local res tmp_bkp tmp_ini

  # CONFITLS.INI já vazio (PDV já em GSurf): não sobrescreve o backup bom.
  if [[ -s "$CONFITLS_INI" ]]; then
  # Atomically write CONFITLS_BKP.INI (copy of current or empty sentinel).
  tmp_bkp="$(mktemp "${CONFITLS_BKP_INI}.XXXXXX")" || {
    step_fail "Falha ao criar temporário para CONFITLS_BKP.INI"
    return 1
  }
  chmod 0644 "$tmp_bkp" 2>/dev/null || true

  if [[ -f "$CONFITLS_INI" ]]; then
    cp -a "$CONFITLS_INI" "$tmp_bkp" || {
      rm -f "$tmp_bkp" 2>/dev/null || true
      step_fail "Falha ao copiar CONFITLS.INI para temporário de backup"
      return 1
    }
  fi
  # tmp_bkp is either a copy of CONFITLS_INI or an empty file (sentinel).

  mv -f "$tmp_bkp" "$CONFITLS_BKP_INI" || {
    rm -f "$tmp_bkp" 2>/dev/null || true
    step_fail "Falha ao mover temporário para $CONFITLS_BKP_INI"
    return 1
  }
  chmod 0644 "$CONFITLS_BKP_INI" 2>/dev/null || true
  log "CONFITLS_BKP_GERADO=$CONFITLS_BKP_INI"
  else
    log "CONFITLS_BKP_MANTIDO=1 (CONFITLS.INI vazio ou ausente)"
  fi

  # Atomically replace CONFITLS.INI with an empty file.
  tmp_ini="$(mktemp "${CONFITLS_INI}.XXXXXX")" || {
    step_fail "Falha ao criar temporário para CONFITLS.INI vazio"
    return 1
  }
  chmod 0644 "$tmp_ini" 2>/dev/null || true
  mv -f "$tmp_ini" "$CONFITLS_INI" || {
    rm -f "$tmp_ini" 2>/dev/null || true
    step_fail "Falha ao substituir CONFITLS.INI por arquivo vazio"
    return 1
  }
  chmod 0644 "$CONFITLS_INI" 2>/dev/null || true
  log "CONFITLS_INI_LIMPO=1"

  sqlite_exec_retry "UPDATE configuracao_pdv SET habilita_tef_confiTLS=0;" || {
    step_fail "UPDATE habilita_tef_confiTLS=0"
    return 1
  }

  res="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;")"
  log_kv "habilita_tef_confiTLS" "$res"

  [[ "$res" == "0" ]] || {
    step_fail "Flag GSurf não confirmada"
    return 1
  }

  restart_and_wait_service || {
    step_fail "Falha ao reiniciar serviço TEF no modo GSurf"
    return 1
  }

  step_ok "Retornando modo de transação para GSurf"
}

# =========================================================
# SOCKET / TESTE DE COMUNICAÇÃO
# =========================================================

NC_CLOSE_MODE=""
NC_TIMEOUT_SEC="${NC_TIMEOUT_SEC:-10}"

# +--------------------------------------------------------------------------+
# | MENSAGEM PASSAGEIRA
# | O que faz: Diz se a mensagem da CliSiTef é só de passagem.
# | Por quê:   Mostrar no fim só a mensagem que importa.
# +--------------------------------------------------------------------------+
is_transient_socket_message(){
  local msg="${1:-}"

  [[ -z "$msg" ]] && return 0

  case "$msg" in
    "Conectando Servidor") return 0 ;;
    "Servidor Conectado") return 0 ;;
    "v."*"Selecione a opcao desejada") return 0 ;;
    "1:Teste de comunicacao"*) return 0 ;;
  esac

  return 1
}

# +--------------------------------------------------------------------------+
# | ENDEREÇO DA CLISITEF
# | O que faz: Define onde a CliSiTef escuta (127.0.0.1:8765).
# | Por quê:   É por ali que o script conversa com o TEF.
# +--------------------------------------------------------------------------+
pick_socket_host_port() {
  step_enter "Configurando socket SiTef"
  HOST="${HOST:-$HOST_DEFAULT}"
  PORT="${PORT:-$PORT_DEFAULT}"
  log_kv "HOST" "$HOST"
  log_kv "PORT" "$PORT"
  step_ok "Configurando socket SiTef"
}

# +--------------------------------------------------------------------------+
# | CÓDIGO DO TERMINAL
# | O que faz: Monta o código do terminal (ex.: CK000006).
# | Por quê:   Formato que a Fiserv exige.
# +--------------------------------------------------------------------------+
derive_idterm() {
  step_enter "Derivando IDTERM"
  local ck
  ck="$(pad_left "$NUM_CAIXA" 6)" || return 1
  IDTERM="CK${ck}"
  log_kv "IDTERM" "$IDTERM"
  step_ok "Derivando IDTERM"
}

# +--------------------------------------------------------------------------+
# | CÓDIGO DA LOJA
# | O que faz: Monta o código Fiserv com 8 dígitos.
# | Por quê:   Formato que a Fiserv exige.
# +--------------------------------------------------------------------------+
derive_idloja_fmt() {
  step_enter "Formatando IDLOJA"
  [[ -n "${IDLOJA_TEF:-}" && "$IDLOJA_TEF" =~ ^[0-9]+$ ]] || return 1
  IDLOJA="$(pad_left "$IDLOJA_TEF" 8)"
  log_kv "IDLOJA" "$IDLOJA"
  step_ok "Formatando IDLOJA"
}

# +--------------------------------------------------------------------------+
# | PARÂMETROS DA LOJA
# | O que faz: Monta o CNPJ da loja e o da software house no formato da
# |            CliSiTef.
# | Por quê:   A Fiserv identifica quem está conectando.
# +--------------------------------------------------------------------------+
derive_parmsclient() {
  step_enter "Montando PARMSCLIENT"
  [[ -n "${CNPJ_LOJA:-}" && "$CNPJ_LOJA" =~ ^[0-9]{14}$ ]] || return 1
  PARMS="[ParmsClient=1=${CNPJ_LOJA};2=${CNPJ_SH_FIX}]"
  log_kv "PARMS" "$PARMS"
  step_ok "Montando PARMSCLIENT"
}

# +--------------------------------------------------------------------------+
# | DADOS DO TESTE COMPLETOS?
# | O que faz: Confere se todos os dados do teste estão preenchidos.
# | Por quê:   Não começar um teste fadado a falhar.
# +--------------------------------------------------------------------------+
validate_collected() {
  step_enter "Validando dados do teste TLS"
  [[ -n "${HOST:-}" && -n "${PORT:-}" ]] || return 1
  [[ -n "${IDLOJA:-}" && -n "${IDTERM:-}" && -n "${PARMS:-}" ]] || return 1
  [[ -n "${TOKEN_TLS:-}" ]] || return 1
  step_ok "Validando dados do teste TLS"
}

# +--------------------------------------------------------------------------+
# | OPERADOR DO TESTE
# | O que faz: Garante que exista o operador 999 HIPCOM no PDV.
# | Por quê:   A CliSiTef exige um operador para fazer o teste.
# +--------------------------------------------------------------------------+
ensure_operador_fiscal() {
  step_enter "Garantindo fiscal/operador HIPCOM"

  local db="$1"
  [[ -f "$db" ]] || return 1
  sqlite_has_table "$db" "fiscal"   || return 1
  sqlite_has_table "$db" "operador" || return 1

  local attempt
  for ((attempt=1; attempt<=8; attempt++)); do
    if sqlite3 "$db" ".timeout 5000" >>"$AUDIT_TMP" 2>&1 <<'SQL'
BEGIN IMMEDIATE;
INSERT INTO fiscal (codigo, codigoLoja, nome, senha, permiteLeituraX, permiteClienteRestricao, permiteLimiteTrocoUltrapassado, permiteDesconto, permiteCancelarItem, permiteLimiteCompraUltrapassada, percentualDescontoMaximo, permiteCancelarCupom, permiteCancelarUltimoCupom)
SELECT '999', 0, 'HIPCOM', '123789', 1, 1, 0, 0, 1, 0, 0.00, 1, 1 WHERE NOT EXISTS (SELECT 1 FROM fiscal WHERE codigo='999' AND codigoLoja=0 AND nome='HIPCOM');
INSERT INTO operador (codigo, nome, senha, loja, cpf)
SELECT '999', 'HIPCOM', '989', 0, NULL WHERE NOT EXISTS (SELECT 1 FROM operador WHERE codigo='999' AND loja=0 AND nome='HIPCOM');
COMMIT;
SQL
    then
      step_ok "Garantindo fiscal/operador HIPCOM"
      return 0
    fi
    log "WARN: tentativa ${attempt}/8 falhou ao garantir fiscal/operador"
    sleep 0.5
  done

  step_fail "Garantindo fiscal/operador HIPCOM"
  return 1
}

# +--------------------------------------------------------------------------+
# | AJUSTE DO NC
# | O que faz: Descobre qual opção do programa nc encerra a conexão.
# | Por quê:   Versões diferentes do Linux usam opções diferentes.
# +--------------------------------------------------------------------------+
detect_nc_close_mode(){
  local nc_help
  nc_help="$(nc -h 2>&1 || true)"
  NC_CLOSE_MODE=""
  if printf '%s\n' "$nc_help" | grep -qE '(^|[[:space:]])-N([[:space:]]|,|$)'; then
    NC_CLOSE_MODE="-N"
  elif printf '%s\n' "$nc_help" | grep -qE '(^|[[:space:]])-q([[:space:]]|,|$)'; then
    NC_CLOSE_MODE="-q 0"
  fi
  log "NC_CLOSE_MODE=${NC_CLOSE_MODE:-(vazio - sem flag de fechamento automatico)}"
}

# +--------------------------------------------------------------------------+
# | MANDAR COMANDO À CLISITEF
# | O que faz: Envia um comando à CliSiTef e devolve a resposta.
# | Por quê:   É a forma de conversar com o TEF no Linux.
# +--------------------------------------------------------------------------+
jcall() {
  local host="$1" port="$2" method="$3" id="$4" params="$5"
  local payload out rc
  payload='{"method":"'"$method"'","id":"'"$id"'","params":'"$params"'}'

  # shellcheck disable=SC2086
  # Separate stdout from stderr so nc diagnostic messages do not get parsed as
  # JSON.  A /dev/null fallback for mktemp protects against disk-full.
  local _nc_err_tmp
  _nc_err_tmp="$(mktemp 2>/dev/null)" || _nc_err_tmp="/dev/null"
  out="$(printf '%s' "$payload" | nc -w "${NC_TIMEOUT_SEC}" ${NC_CLOSE_MODE} "${host}" "${port}" 2>"$_nc_err_tmp")"
  rc=$?
  if (( rc != 0 )); then
    local _nc_err_msg
    _nc_err_msg="$(head -n3 "$_nc_err_tmp" 2>/dev/null | tr '\n' ' ')"
    [[ "$_nc_err_tmp" != "/dev/null" ]] && rm -f "$_nc_err_tmp" 2>/dev/null || true
    log "JCALL_ERROR: method=${method} id=${id} rc=${rc} stderr=${_nc_err_msg}"
    printf 'nc_fail: %s' "$_nc_err_msg"
    return 2
  fi
  [[ "$_nc_err_tmp" != "/dev/null" ]] && rm -f "$_nc_err_tmp" 2>/dev/null || true

  # Guard: rc==0 but empty response is still a failure for JSON callers.
  if [[ -z "$out" ]]; then
    log "JCALL_EMPTY_RESPONSE: method=${method} id=${id} rc=0 but output was empty"
    printf 'nc_fail: empty response'
    return 2
  fi

  printf '%s' "$out"
}

# +--------------------------------------------------------------------------+
# | ATALHOS DA CONVERSA COM A CLISITEF
# | O que faz: Escrever uma resposta, limpar o buffer e ler a mensagem atual
# |            da CliSiTef.
# | Por quê:   São os passos usados para responder às perguntas da CliSiTef.
# +--------------------------------------------------------------------------+
set_buf0() { local h="$1" p="$2"; jcall "$h" "$p" "setString" "set0" '{"index":0,"value":"'"$3"'"}' >/dev/null || true; }
clr_buf()  { local h="$1" p="$2"; jcall "$h" "$p" "clearBuffer" "clr" '{}' >/dev/null || true; }
buf_get0() { local h="$1" p="$2"; jcall "$h" "$p" "bufferGet" "bg0" '{"index":0}' | extract_str result | head -n1 || true; }

# +--------------------------------------------------------------------------+
# | ENCERRAR A TRANSAÇÃO DE TESTE
# | O que faz: Avisa a CliSiTef que o teste terminou.
# | Por quê:   Não deixar a CliSiTef presa numa transação aberta.
# +--------------------------------------------------------------------------+
finaliza() {
  local h="$1" p="$2" confirma="$3"
  log "SOCKET: finalizaFuncaoSiTefInterativo(confirma=$confirma)"

  jcall "$h" "$p" "finalizaFuncaoSiTefInterativo" "fin" \
'{"horaFiscal":"'"$HORAFISC"'","confirma":'"$confirma"',"dataFiscal":"'"$DATAFISC"'","paramAdic":"","cupomFiscal":"'"$CUPOM"'"}' >/dev/null || true
}

# +--------------------------------------------------------------------------+
# | PREPARAR O TESTE
# | O que faz: Monta os dados do teste e garante o operador.
# | Por quê:   Tudo pronto antes de chamar a CliSiTef.
# +--------------------------------------------------------------------------+
prepare_test_context(){
  step_enter "Preparando contexto do teste TLS"

  pick_socket_host_port || return 1
  derive_idterm || return 1
  derive_idloja_fmt || return 1
  derive_parmsclient || return 1

  DATAFISC="$(date +%Y%m%d)"
  HORAFISC="$(date +%H%M%S)"
  CUPOM="$HORAFISC"

  ensure_operador_fiscal "$DB_IN" || return 1
  validate_collected || return 1

  step_ok "Preparando contexto do teste TLS"
}

# +--------------------------------------------------------------------------+
# | ESPERAR A CLISITEF RESPONDER
# | O que faz: Tenta conectar a cada 0,25 s até a CliSiTef aceitar.
# | Por quê:   Começar assim que ela estiver pronta, sem espera
# |            desnecessária.
# +--------------------------------------------------------------------------+
wait_socket_ready(){
  step_enter "Aguardando socket SiTef ficar disponível"

  local host="$1" port="$2" tries="${3:-30}" delay="${4:-1}"
  local i

  for ((i=1; i<=tries; i++)); do
    if nc -z -w "${NC_TIMEOUT_SEC}" "$host" "$port" >/dev/null 2>&1; then
      log "SOCKET_READY: disponível em $host:$port na tentativa $i/$tries"
      step_ok "Aguardando socket SiTef ficar disponível"
      return 0
    fi

    log "SOCKET_READY: indisponível em $host:$port na tentativa $i/$tries"
    sleep "$delay"
  done

  step_fail "Aguardando socket SiTef ficar disponível"
  return 1
}

# Resolve TEST_RESULT_MSG from the last useful or raw socket message.
# Accepts an optional fallback string as $1.
# +--------------------------------------------------------------------------+
# | MELHOR MENSAGEM DO TESTE
# | O que faz: Escolhe a mensagem mais útil recebida no teste.
# | Por quê:   Mostrar o motivo real quando dá erro.
# +--------------------------------------------------------------------------+
_resolve_test_result_msg(){
  local fallback="${1:-Falha na comunicação TLS}"
  if [[ -n "$LAST_USEFUL_SOCKET_MSG" ]]; then
    TEST_RESULT_MSG="$LAST_USEFUL_SOCKET_MSG"
  elif [[ -n "$LAST_SOCKET_MSG" ]]; then
    TEST_RESULT_MSG="$LAST_SOCKET_MSG"
  else
    TEST_RESULT_MSG="$fallback"
  fi
}

# run_test_once MODO HOST PORT [INITIAL_PCT]
#
# Executa um ciclo completo de teste SiTef no modo informado (TLS ou GSURF).
# Define TEST_RESULT_MSG com a mensagem final do socket.
# Define SKIP_ROLLBACK=1 quando o resultado é definitivo (res<0 ou timeout) —
# sinaliza ao die() que o rollback não deve ser executado e que o operador
# deve decidir entre manter TLS ou voltar para GSurf.
#
# Códigos de retorno:
#   0  — sucesso (res=0, TEST_RESULT_MSG="Servidor Ativo")
#  10  — socket indisponível antes do teste
#  11  — configuraIntSiTefInterativoEx falhou
#  12  — iniciaFuncaoSiTefInterativo falhou
#  13  — 5 leituras inválidas consecutivas do socket
#  21  — resultado negativo (res<0) do servidor
#  40  — timeout (MAX_LOOPS esgotado)

# +--------------------------------------------------------------------------+
# | O TESTE DE COMUNICAÇÃO EM SI
# | O que faz: Configura a CliSiTef, inicia o "Teste de comunicação" e
# |            responde sozinho às perguntas até o resultado.
# | Por quê:   É a prova real de que o PDV fala com a Fiserv ou com a GSurf.
# +--------------------------------------------------------------------------+
run_test_once() {
  local modo="$1"
  local host="$2" port="$3"
  local initial_pct="${4:-5}"
  local socket_ready_pct=$(( initial_pct + 5 ))

  step_enter "Executando teste real de comunicação ${modo}"
  ui_progress "$initial_pct" "${UI_TEST_LABEL:-Testando Comunicação}"

  LAST_SOCKET_MSG=""
  LAST_USEFUL_SOCKET_MSG=""
  SKIP_ROLLBACK=0
  LAST_UI_LOOP_PCT=""

  log_kv "MAX_LOOPS" "$MAX_LOOPS"
  log_kv "SLEEP_SEC" "$SLEEP_SEC"
  log_kv "NC_TIMEOUT_SEC" "$NC_TIMEOUT_SEC"
  log_kv "TEST_TIMEOUT_MIN_ESTIMADO_SEG" "$(echo "$MAX_LOOPS $SLEEP_SEC" | awk '{printf "%d", $1 * $2}')"
  log_kv "TEST_TIMEOUT_MAX_ESTIMADO_SEG" "$(echo "$MAX_LOOPS $SLEEP_SEC $NC_TIMEOUT_SEC" | awk '{printf "%d", $1 * ($2 + $3)}')"

  if ! wait_socket_ready "$host" "$port" 40 0.25; then
    log "SOCKET: indisponível em $host:$port após aguardar readiness"
    TEST_RESULT_MSG="Socket não responde"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 10
  fi

  log "SOCKET: porta respondeu em $host:$port"
  ui_progress "$socket_ready_pct" "${UI_TEST_LABEL:-Testando Comunicação}"

  local cfg_payload
  cfg_payload='{"reservado":0,"parametrosAdicionais":"'"$PARMS"'","idTerminal":"'"$IDTERM"'","ipSiTef":"'"$host"'","idLoja":"'"$IDLOJA"'"}'

  local CFG_REPLY cfg_success cfg_result
  CFG_REPLY="$(jcall "$host" "$port" "configuraIntSiTefInterativoEx" "cfg" "$cfg_payload" || true)"
  log_socket_call "CONFIGURA" "$cfg_payload" "$CFG_REPLY"

  cfg_success="$(printf '%s\n' "$CFG_REPLY" | sed -n 's/.*"success":\([^,}]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  cfg_result="$(printf '%s\n' "$CFG_REPLY" | extract_int result | head -n1 || true)"

  [[ "$cfg_success" == "true" && "$cfg_result" == "0" ]] || {
    log "SOCKET_CONFIGURA_INVALIDA=1"
    log "SOCKET_CONFIGURA_SUCCESS=$cfg_success"
    log "SOCKET_CONFIGURA_RESULT=$cfg_result"
    TEST_RESULT_MSG="Falha ao configurar comunicação SiTef"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 11
  }

  local ini_payload
  ini_payload='{"funcao":110,"horaFiscal":"'"$HORAFISC"'","paramAdic":"{DevolveStringQRCode=1}","cupomFiscal":"'"$CUPOM"'","valor":"0","dataFiscal":"'"$DATAFISC"'","operador":"'"$OPERADOR"'"}'

  local INI_REPLY ini_success ini_result
  INI_REPLY="$(jcall "$host" "$port" "iniciaFuncaoSiTefInterativo" "ini" "$ini_payload" || true)"
  log_socket_call "INICIA" "$ini_payload" "$INI_REPLY"

  ini_success="$(printf '%s\n' "$INI_REPLY" | sed -n 's/.*"success":\([^,}]*\).*/\1/p' | head -n1 | tr -d '[:space:]')"
  ini_result="$(printf '%s\n' "$INI_REPLY" | extract_int result | head -n1 || true)"

  [[ "$ini_success" == "true" && "$ini_result" =~ ^-?[0-9]+$ ]] || {
    log "SOCKET_INICIA_INVALIDA=1"
    log "SOCKET_INICIA_SUCCESS=$ini_success"
    log "SOCKET_INICIA_RESULT=$ini_result"
    TEST_RESULT_MSG="Falha ao iniciar função SiTef"
    ui_finish_progress
    step_fail "Executando teste real de comunicação ${modo}"
    return 12
  }

  local cmd=0 tipo=0 tmin=0 tmax=0
  local selected_menu_test=0
  local loops=0
  local invalid_reads=0
  local gsurf_retry_visual=0
  local loop_base_pct="$socket_ready_pct"
  local loop_max_pct=90

  if [[ "$modo" == "GSURF" ]]; then
    loop_max_pct=95
  else
    loop_max_pct=85
  fi

  LAST_STATE_SNAPSHOT=""

  local i cont_payload cont_reply res msg
  local next_res next_cmd next_tipo next_tmin next_tmax

  for ((i=1; i<=MAX_LOOPS; i++)); do
    loops="$i"

    ui_progress_test_loop "$loops" "$loop_base_pct" "$loop_max_pct"
    sleep "$SLEEP_SEC"

    cont_payload='{"tamMaximo":{"value":'"${tmax:-0}"'},"comando":{"value":'"${cmd:-0}"'},"tamMinimo":{"value":'"${tmin:-0}"'},"continua":0,"tamBuffer":1024,"tipoCampo":{"value":'"${tipo:-0}"'}}'

    cont_reply="$(jcall "$host" "$port" "continuaFuncaoSiTefInterativo" "cont" "$cont_payload" || true)"
    log_socket_call "CONTINUA_LOOP_${loops}" "$cont_payload" "$cont_reply"

    next_res="$(printf '%s\n' "$cont_reply" | extract_int result | head -n1 || true)"
    next_cmd="$(printf '%s\n' "$cont_reply" | extract_int comando | head -n1 || true)"
    next_tipo="$(printf '%s\n' "$cont_reply" | extract_int tipoCampo | head -n1 || true)"
    next_tmin="$(printf '%s\n' "$cont_reply" | extract_int tamMinimo | head -n1 || true)"
    next_tmax="$(printf '%s\n' "$cont_reply" | extract_int tamMaximo | head -n1 || true)"

    if [[ -z "${next_res:-}" || -z "${next_cmd:-}" || -z "${next_tipo:-}" ]]; then
      invalid_reads=$(( invalid_reads + 1 ))
      log "SOCKET_INVALID_READ_COUNT=$invalid_reads"

      # Mensagem de retry visual — exclusiva para modo GSURF, nas 3 primeiras
      # respostas inválidas/vazias. Não afeta a lógica real do teste.
      if [[ "$modo" == "GSURF" ]]; then
        gsurf_retry_visual=$(( gsurf_retry_visual + 1 ))
        log "GSURF_RETRY_VISUAL=$gsurf_retry_visual"
        if (( gsurf_retry_visual <= 3 )); then
          ui_send "${gsurf_retry_visual} Teste falhou, testando a comunicação novamente..."
        fi
      fi

      if (( invalid_reads >= 5 )); then
        SKIP_ROLLBACK=1
        TEST_RESULT_MSG="Resposta inválida do socket"
        log "SOCKET_RESULT_FINAL=ERRO"
        log "SOCKET_RESULT_FINAL_RES=invalid_read"
        log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
        log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"
        finaliza "$host" "$port" 0
        ui_finish_progress
        step_fail "Executando teste real de comunicação ${modo}"
        return 13
      fi

      continue
    fi

    invalid_reads=0
    res="$next_res"
    cmd="${next_cmd:-0}"
    tipo="${next_tipo:-0}"
    tmin="${next_tmin:-0}"
    tmax="${next_tmax:-0}"

    state_maybe_log "$loops" "${res:-<vazio>}" "${cmd:-<vazio>}" "${tipo:-<vazio>}" "${tmin:-<vazio>}" "${tmax:-<vazio>}"
    log "SOCKET_LOOP_${loops}_STATE: res=${res:-<vazio>} cmd=${cmd:-<vazio>} tipo=${tipo:-<vazio>} tmin=${tmin:-<vazio>} tmax=${tmax:-<vazio>}"

    msg="$(buf_get0 "$host" "$port" || true)"
    msg="${msg:-}"
    msg="$(normalize_socket_message "$msg")"
    log "SOCKET_LOOP_${loops}_MSG: ${msg:-<vazia>}"

    if [[ -n "${msg:-}" ]]; then
      LAST_SOCKET_MSG="$msg"
      log "SOCKET_MSG: $msg"

      if ! is_transient_socket_message "$msg"; then
        LAST_USEFUL_SOCKET_MSG="$msg"
        log "SOCKET_LAST_USEFUL_MSG_AT_LOOP_${loops}: $LAST_USEFUL_SOCKET_MSG"
      elif [[ "$msg" == *"127.0.0.1"* || "$msg" == *"tls-prod.fiservapp.com"* ]]; then
        LAST_USEFUL_SOCKET_MSG="$msg"
        log "SOCKET_LAST_USEFUL_MSG_AT_LOOP_${loops}: $LAST_USEFUL_SOCKET_MSG"
      fi

      if [[ "$selected_menu_test" == "0" ]] && printf '%s\n' "$msg" | grep -q '1:Teste de comunicacao'; then
        log "SOCKET_DECISAO: selecionou menu 'Teste de comunicacao' (opção 1)"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "1"
        selected_menu_test=1
        continue
      fi

      if printf '%s\n' "$msg" | grep -qiE '^Confirma o teste de comunicacao .*fiservapp\.com'; then
        log "SOCKET_MARCO: confirmação do teste TLS detectada"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "0"
        log "SOCKET_DECISAO: confirmação TLS enviada (opção 0)"
        continue
      fi

      if printf '%s\n' "$msg" | grep -qiE '^Confirma o teste de comunicacao .*127\.0\.0\.1'; then
        log "SOCKET_MARCO: confirmação do teste GSURF detectada"
        clr_buf "$host" "$port"
        set_buf0 "$host" "$port" "0"
        log "SOCKET_DECISAO: confirmação GSURF enviada (opção 0)"
        continue
      fi
    fi

    if [[ -n "${res:-}" && "$res" =~ ^-?[0-9]+$ ]]; then
      if (( res == 0 )); then
        log "SOCKET_RESULT_FINAL=SUCESSO"
        log "SOCKET_RESULT_FINAL_RES=$res"
        finaliza "$host" "$port" 1
        TEST_RESULT_MSG="Servidor Ativo"
        ui_finish_progress
        step_ok "Executando teste real de comunicação ${modo}"
        return 0
      fi

      if (( res < 0 )); then
        SKIP_ROLLBACK=1
        log "SOCKET_RESULT_FINAL=ERRO"
        log "SOCKET_RESULT_FINAL_RES=$res"
        log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
        log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"

        finaliza "$host" "$port" 0
        _resolve_test_result_msg "Falha na comunicação TLS"
        ui_finish_progress
        step_fail "Executando teste real de comunicação ${modo}"
        return 21
      fi
    fi
  done

  SKIP_ROLLBACK=1
  log "SOCKET_FINAL: Timeout (MAX_LOOPS=$MAX_LOOPS)"
  log "SOCKET_LAST_USEFUL_MSG=$LAST_USEFUL_SOCKET_MSG"
  log "SOCKET_LAST_MSG=$LAST_SOCKET_MSG"

  finaliza "$host" "$port" 0
  _resolve_test_result_msg "Timeout"
  ui_finish_progress
  step_fail "Executando teste real de comunicação ${modo}"
  return 40
}
# +--------------------------------------------------------------------------+
# | TESTE TLS COMPLETO
# | O que faz: Prepara e executa o teste em modo TLS.
# | Por quê:   Atalho usado pelas opções de TLS.
# +--------------------------------------------------------------------------+
run_integrated_tls_test(){
  local initial_pct="${1:-5}"
  step_enter "Executando teste integrado TLS"
  prepare_test_context || return 1
  run_test_once "TLS" "$HOST" "$PORT" "$initial_pct"
}

# +--------------------------------------------------------------------------+
# | TESTE DO MODO ESCOLHIDO
# | O que faz: Testa o modo (TLS ou GSurf) e confere se a resposta bate.
# | Por quê:   Confirmar que o modo realmente funciona.
# +--------------------------------------------------------------------------+
step_validate_final_mode(){
  local modo="$1"
  local host_teste="127.0.0.1"
  local esperado=""
  local msg=""

  FINAL_MODE_TEST_OK=0
  FINAL_MODE_TEST_MSG=""

  step_enter "Validando modo final escolhido"

  case "$modo" in
    GSURF) esperado="127.0.0.1" ;;
    TLS)   esperado="tls-prod.fiservapp.com" ;;
    *)
      step_fail "Modo final inválido: $modo"
      FINAL_MODE_TEST_MSG="Modo final inválido"
      return 1
      ;;
  esac

  LAST_SOCKET_MSG=""
  LAST_USEFUL_SOCKET_MSG=""
  TEST_RESULT_MSG=""

  prepare_test_context || {
    step_fail "Falha ao preparar contexto para validação final"
    FINAL_MODE_TEST_MSG="Falha ao preparar contexto"
    return 1
  }

  if ! run_test_once "$modo" "$host_teste" "$PORT_DEFAULT" 65; then
    msg="${LAST_USEFUL_SOCKET_MSG:-${LAST_SOCKET_MSG:-${TEST_RESULT_MSG:-Sem retorno}}}"
    FINAL_MODE_TEST_MSG="$msg"
    log "VALIDACAO_FINAL_RC_FALHOU: modo=${modo} msg=${msg}"
    step_fail "Falha ao validar modo final escolhido"
    return 1
  fi

  # run_test_once retornou 0 (res=0): TEST_RESULT_MSG é "Servidor Ativo".
  # NÃO usar LAST_USEFUL_SOCKET_MSG aqui — pode ser mensagem intermediária
  # desatualizada (ex.: "Sem conexao Servidor") que não reflete o resultado final.
  msg="${TEST_RESULT_MSG:-Servidor Ativo}"
  log "VALIDACAO_FINAL_RC_OK: modo=${modo} msg=${msg}"

  case "$modo" in
    GSURF)
      [[ "$msg" == *"127.0.0.1"* || "$msg" == "Servidor Ativo" || "$msg" == "Sem conexao Servidor" ]] || {
        FINAL_MODE_TEST_MSG="$msg"
        step_fail "Modo GSurf não confirmado"
        return 1
      }
      ;;
    TLS)
      [[ "$msg" == *"tls-prod.fiservapp.com"* || "$msg" == "Servidor Ativo" ]] || {
        FINAL_MODE_TEST_MSG="$msg"
        step_fail "Modo TLS não confirmado"
        return 1
      }
      ;;
  esac

  FINAL_MODE_TEST_OK=1
  FINAL_MODE_TEST_MSG="$msg"

  log_kv "VALIDACAO_FINAL_MODO" "$modo"
  log_kv "VALIDACAO_FINAL_ESPERADO" "$esperado"
  log_kv "VALIDACAO_FINAL_MSG" "$msg"

  step_ok "Validando modo final escolhido"
}

# =========================================================
# MENU / AÇÕES
# =========================================================

# TLS = flag habilita_tef_confiTLS=1 e CONFITLS.INI com conteúdo; senão GSurf.
# +--------------------------------------------------------------------------+
# | MODO ATUAL
# | O que faz: Diz se o PDV está em TLS ou GSurf.
# | Por quê:   Mostrar no menu e saber o que manter.
# +--------------------------------------------------------------------------+
modo_atual(){
  local flag
  flag="$(sqlite_scalar "SELECT habilita_tef_confiTLS FROM configuracao_pdv LIMIT 1;" 2>/dev/null || true)"
  if [[ "$flag" == "1" && -s "$CONFITLS_INI" ]]; then
    printf 'TLS'
  else
    printf 'GSURF'
  fi
}

# +--------------------------------------------------------------------------+
# | NOME DO MODO
# | O que faz: Escreve "TLS" ou "GSurf".
# | Por quê:   Texto amigável.
# +--------------------------------------------------------------------------+
nome_modo(){ if [[ "$1" == "TLS" ]]; then printf 'TLS'; else printf 'GSurf'; fi; }

# +--------------------------------------------------------------------------+
# | TELA DE IDENTIFICAÇÃO
# | O que faz: Mostra loja, caixa, Fiserv, CNPJ, token e modo.
# | Por quê:   Conferir que é o PDV certo antes de mexer.
# +--------------------------------------------------------------------------+
mostrar_pdv(){
  step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
  ui_titulo "InstalaTLS - PDV Linux"
  ui_campo "Loja" "${LOJA_EXIBICAO:--}"
  ui_campo "Caixa" "${NUM_CAIXA:--}"
  ui_campo "Fiserv" "${IDLOJA:--}"
  ui_campo "CNPJ" "${CNPJ_LOJA:--}"
  ui_campo "Token" "${TOKEN_ATUAL_BANCO:-nenhum}"
  ui_campo "Modo atual" "$(nome_modo "$(modo_atual)")"
  ui_out '\n'
}

# Zera o estado de uma ação antes de tirar um snapshot novo.
# +--------------------------------------------------------------------------+
# | ZERAR PARA NOVA AÇÃO
# | O que faz: Limpa o estado da ação anterior.
# | Por quê:   Cada ação começa limpa, sem sobra da anterior.
# +--------------------------------------------------------------------------+
nova_acao(){
  cleanup_sensitive_artifacts
  ORIG_SQLITE_FLAG=""; ORIG_TOKEN_EXISTS=0; ORIG_TOKEN_VALUE=""
  ORIG_CONFITLS_EXISTS=0; ORIG_CONFITLS_BACKUP=""
  ORIG_CTRL_EXISTS=0; ORIG_CTRL_IS_DIR=0; ORIG_CTRL_BACKUP=""
  ROLLBACK_ENABLED=0; SKIP_ROLLBACK=0
  TEST_RESULT_MSG=""; LAST_SOCKET_MSG=""; LAST_USEFUL_SOCKET_MSG=""
  FINAL_MODE_TEST_OK=0; FINAL_MODE_TEST_MSG=""
  log_sep
  log "NOVA_ACAO: $1"
}

# Falha ao montar o ambiente (antes do teste): desfaz tudo e volta ao menu.
# +--------------------------------------------------------------------------+
# | FALHA ANTES DO TESTE
# | O que faz: Desfaz o que a ação mudou, mostra o erro e volta ao menu.
# | Por quê:   Erro na montagem nunca deixa o PDV quebrado.
# +--------------------------------------------------------------------------+
acao_falhou(){
  local msg="$1" restaurou=0
  log "ACAO_FALHOU: $msg"
  if (( ROLLBACK_ENABLED == 1 )); then
    ui_send "Restaurando configuração anterior"
    run_rollback || true
    restaurou=1
  fi
  ui_finish_progress
  ui_erro "$msg"
  if (( restaurou == 1 )); then ui_aviso "A configuração anterior foi restaurada."; fi
  ui_pausa
}

# +--------------------------------------------------------------------------+
# | DICA PARA CADA FALHA DE COMUNICAÇÃO
# | O que faz: Diz, em uma frase, o que conferir quando o teste TLS ou GSurf
# |            falha, conforme a mensagem recebida.
# | Por quê:   O operador sabe o que corrigir sem consultar o suporte.
# +--------------------------------------------------------------------------+
dica_falha(){
  local modo="$1" msg="${2:-}"
  if [[ "$modo" == "TLS" ]]; then
    case "$msg" in
      *[Ss]ocket*|*configurar*|*iniciar*) printf '%s' "Confira o serviço do TEF (systemctl status ${SERVICE_NAME}) e teste de novo." ;;
      *[Tt]oken*|*[Rr]egistro*) printf '%s' "Confira o token TLS com a Fiserv e cadastre de novo (opção 1 - Cadastrar TLS)." ;;
      *) printf '%s' "Confira a internet do PDV e a liberação de saída para tls-prod.fiservapp.com na porta 443; se estiver liberado, confira o token (opção 1)." ;;
    esac
    return 0
  fi
  printf '%s' "Confira o serviço ${GSURF_SERVICO} (systemctl status ${GSURF_SERVICO}) e, se preciso, rode a opção 2 - Instalar GSurf."
}

# +--------------------------------------------------------------------------+
# | MOSTRAR O RESULTADO
# | O que faz: Mostra OK ou falha (com o motivo e a dica em amarelo) e abre o
# |            menu depois do teste.
# | Por quê:   O operador decide o próximo passo sabendo o resultado.
# +--------------------------------------------------------------------------+
fim_teste(){
  local modo="$1" ok="$2" msg="${3:-}"
  ROLLBACK_ENABLED=0
  ui_finish_progress
  log "RESULTADO_FINAL: modo=${modo} ok=${ok} msg=${msg}"
  ui_titulo "Resultado | $(nome_modo "$modo")"
  if [[ "$ok" == "1" ]]; then
    ui_ok "Comunicação OK | ${msg:-Servidor Ativo}"
  else
    ui_erro "Falha no teste de comunicação $(nome_modo "$modo") | ${msg:-Sem retorno}"
    ui_aviso "$(dica_falha "$modo" "$msg")"
  fi
  pos_teste "$modo"
}

# +--------------------------------------------------------------------------+
# | DEIXAR EM TLS
# | O que faz: Coloca o PDV em TLS, se ainda não estiver.
# | Por quê:   Sair no modo escolhido.
# +--------------------------------------------------------------------------+
manter_tls(){
  if [[ "$(modo_atual)" == "TLS" ]]; then return 0; fi
  step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
  if [[ -z "${TOKEN_ATUAL_BANCO:-}" ]]; then
    ui_erro "Nenhum token cadastrado para este caixa. Use Cadastrar TLS."
    return 1
  fi
  ui_dica "Montando ambiente TLS..."
  if ! ui_step_min "Montando ambiente TLS" step_prepare_tls_for_existing_token_test; then
    ui_erro "Falha ao montar o ambiente TLS."
    return 1
  fi
  return 0
}

# +--------------------------------------------------------------------------+
# | DEIXAR EM GSURF
# | O que faz: Coloca o PDV em GSurf, se ainda não estiver.
# | Por quê:   Sair no modo escolhido.
# +--------------------------------------------------------------------------+
manter_gsurf(){
  if [[ "$(modo_atual)" == "GSURF" ]]; then return 0; fi
  ui_dica "Montando ambiente GSurf..."
  if ! ui_step_min "Montando ambiente GSurf" step_switch_to_gsurf; then
    ui_erro "Falha ao montar o ambiente GSurf."
    return 1
  fi
  return 0
}

# +--------------------------------------------------------------------------+
# | SAÍDA NORMAL
# | O que faz: Mostra o modo final e onde está o log, e encerra.
# | Por quê:   Fechamento claro e registrado.
# +--------------------------------------------------------------------------+
sair(){
  ui_ok "PDV em modo $(nome_modo "$(modo_atual)")."
  ui_dica "Log: ${FINAL_LOG_FILE}"
  exit 0
}

# +--------------------------------------------------------------------------+
# | MENU DEPOIS DO TESTE
# | O que faz: Oferece: 1 mudar para o outro modo (testando na hora), 2 voltar
# |            ao menu inicial ou 3 deixar como está e sair.
# | Por quê:   Decisão final do operador.
# +--------------------------------------------------------------------------+
pos_teste(){
  local modo="$1" outro op
  if [[ "$modo" == "TLS" ]]; then outro="GSURF"; else outro="TLS"; fi
  while true; do
    ui_out '\n'
    op="$(ui_opcao "1:Mudar para $(nome_modo "$outro")" "2:Voltar para o menu inicial" "3:Deixar como $(nome_modo "$modo") e sair")"
    case "$op" in
      1) mudar_modo "$modo" "$outro"; return 0 ;;
      2) return 0 ;;
      3) if [[ "$modo" == "TLS" ]]; then manter_tls && sair; else manter_gsurf && sair; fi ;;
    esac
  done
}

# +--------------------------------------------------------------------------+
# | MENU FINAL
# | O que faz: Depois de mudar de modo: 1 volta ao menu principal; 2 (ou Esc)
# |            sai.
# | Por quê:   Fechamento rápido depois que o PDV já está no modo certo.
# +--------------------------------------------------------------------------+
menu_final(){
  local op
  ui_out '\n'
  op="$(UI_ESC=2 ui_opcao "1:Voltar para o menu principal" "2:Sair [ou pressione Esc]")"
  if [[ "$op" == "2" ]]; then sair; fi
  return 0
}

# +--------------------------------------------------------------------------+
# | MUDAR DE MODO COM TESTE
# | O que faz: Monta o outro modo e testa na hora. Se passar, avisa que o PDV
# |            está no modo novo. Se falhar, diz onde falhou, dá a dica e
# |            volta sozinho para o modo que estava funcionando.
# | Por quê:   O PDV nunca fica num modo que não comunica.
# +--------------------------------------------------------------------------+
mudar_modo(){
  local de="$1" para="$2" ok=0 msg="" etapa=""
  log_sep
  log "MUDAR_MODO: ${de} -> ${para}"
  nova_acao "mudar_${para}"

  if [[ "$para" == "TLS" ]]; then
    step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
    if [[ -z "${TOKEN_ATUAL_BANCO:-}" ]]; then
      etapa="montar o ambiente TLS"; msg="nenhum token cadastrado para este caixa"
    else
      TOKEN_TLS="$TOKEN_ATUAL_BANCO"
      UI_TEST_LABEL="Testando comunicação TLS"
      ui_start "Mudar para TLS"
      ui_progress 8 "Montando ambiente TLS"
      if ! ui_step_min "Montando ambiente TLS" step_prepare_tls_for_existing_token_test; then
        etapa="montar o ambiente TLS"; msg="falha ao gravar ou reiniciar o serviço do TEF"
      elif ui_step_min "Testando comunicação TLS" run_integrated_tls_test 20; then
        ok=1
      else
        etapa="teste de comunicação TLS"; msg="${TEST_RESULT_MSG:-Sem retorno}"
      fi
    fi
  else
    step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
    TOKEN_TLS="${TOKEN_ATUAL_BANCO:-GSURF}"
    UI_TEST_LABEL="Testando comunicação GSurf"
    ui_start "Mudar para GSurf"
    ui_progress 10 "Montando ambiente GSurf"
    if ! ui_step_min "Montando ambiente GSurf" step_switch_to_gsurf; then
      etapa="montar o ambiente GSurf"; msg="falha ao gravar ou reiniciar o serviço do TEF"
    else
      ui_progress 20 "Testando comunicação GSurf"
      ui_step_min "Testando comunicação GSurf" step_validate_final_mode GSURF || true
      if [[ "${FINAL_MODE_TEST_OK:-0}" == "1" ]]; then ok=1
      else etapa="teste de comunicação GSurf"; msg="${FINAL_MODE_TEST_MSG:-Sem retorno}"; fi
    fi
  fi
  ui_finish_progress
  log "RESULTADO_FINAL: modo=${para} ok=${ok} etapa=${etapa} msg=${msg} (mudanca)"

  if [[ "$ok" == "1" ]]; then
    ui_ok "PDV em modo de comunicação $(nome_modo "$para"). Testes realizados com sucesso."
    menu_final
    return 0
  fi

  ui_erro "Falha ao mudar para $(nome_modo "$para") | Onde: ${etapa} | ${msg}"
  ui_aviso "$(dica_falha "$para" "$msg")"
  if [[ "$de" == "TLS" ]]; then
    if manter_tls; then ui_aviso "PDV mantido em modo de comunicação TLS, que está funcionando."; fi
  else
    if manter_gsurf; then ui_aviso "PDV mantido em modo de comunicação GSurf, que está funcionando."; fi
  fi
  menu_final
  return 0
}

# =========================================================
# INSTALAR GSURF (/gsurf/instalador pede login, senha e OTP)
# =========================================================

readonly GSURF_DIR="/gsurf"
readonly GSURF_SERVICO="libssl.service"

# +--------------------------------------------------------------------------+
# | OPÇÃO 2 - INSTALAR GSURF
# | O que faz: Roda o instalador da GSurf (pede login, senha e OTP) e ativa o
# |            serviço libssl.
# | Por quê:   Junta numa opção os comandos que eram digitados à mão.
# +--------------------------------------------------------------------------+
acao_instalar_gsurf(){
  local rc
  ui_titulo "Instalar GSurf"
  if [[ ! -f "${GSURF_DIR}/instalador" ]]; then
    ui_erro "Instalador não encontrado: ${GSURF_DIR}/instalador"
    ui_aviso "Copie o instalador da GSurf para ${GSURF_DIR} e rode de novo."
    ui_pausa
    return 0
  fi
  # Roda como root: link, ou arquivo/pasta de outro dono ou gravável por outros,
  # deixaria um usuário comum trocar o instalador. Fica root e sem escrita alheia.
  if [[ -L "$GSURF_DIR" || -L "${GSURF_DIR}/instalador" ]]; then
    ui_erro "O instalador em ${GSURF_DIR} é um link e não foi executado."
    ui_pausa
    return 0
  fi
  if [[ ! -O "$GSURF_DIR" || ! -O "${GSURF_DIR}/instalador" ]]; then
    chown root:root "$GSURF_DIR" "${GSURF_DIR}/instalador" 2>>"$AUDIT_TMP" || true
  fi
  chmod 0755 "$GSURF_DIR" "${GSURF_DIR}/instalador" 2>/dev/null || true
  log_sep
  log "NOVA_ACAO: instalar_gsurf"
  ui_out '  %sInforme login, senha e OTP quando o instalador pedir.%s\n\n' "$C_PER" "$C_RST"

  set +e
  # 9>&-: o instalador (ou serviço que ele deixe rodando) não herda o lock.
  ( cd "$GSURF_DIR" && ./instalador ) </dev/tty >&3 2>&3 9>&-
  rc=$?
  set -e
  log "GSURF_INSTALADOR_RC=${rc}"
  ui_out '\n'
  if (( rc != 0 )); then
    ui_erro "O instalador terminou com erro (código ${rc})."
    ui_aviso "Confira login, senha e OTP e rode Instalar GSurf de novo."
    ui_pausa
    return 0
  fi

  ui_dica "Ativando o serviço ${GSURF_SERVICO}..."
  if ! { systemctl daemon-reload && systemctl enable "$GSURF_SERVICO" && systemctl stop "$GSURF_SERVICO" && systemctl start "$GSURF_SERVICO"; } >>"$AUDIT_TMP" 2>&1; then
    ui_erro "Falha ao ativar o serviço ${GSURF_SERVICO}."
    ui_aviso "Veja: systemctl status ${GSURF_SERVICO}"
    ui_pausa
    return 0
  fi
  sleep 1
  if systemctl is-active --quiet "$GSURF_SERVICO"; then
    ui_ok "GSurf instalado e ${GSURF_SERVICO} ativo. Testando a comunicação..."
    acao_testar_gsurf
    return 0
  fi
  systemctl status "$GSURF_SERVICO" --no-pager >>"$AUDIT_TMP" 2>&1 || true
  ui_erro "O serviço ${GSURF_SERVICO} não ficou ativo."
  ui_aviso "Veja: systemctl status ${GSURF_SERVICO}"
  ui_pausa
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 1 - CADASTRAR TLS
# | O que faz: Pede o token, liga a chave TLS, grava token e CONFITLS.INI,
# |            reinicia e testa.
# | Por quê:   É a instalação do TLS no caixa, com teste no final.
# +--------------------------------------------------------------------------+
acao_cadastrar(){
  local t=""
  ui_titulo "Cadastrar TLS"
  while true; do
    ui_out '  %sToken (0000-0000-0000-0000) ou Enter para voltar:%s ' "$C_PER" "$C_RST"
    t="$(ler | tr -d '[:space:]')"
    if [[ -z "$t" ]]; then return 0; fi
    if [[ "$t" =~ ^[0-9]{4}(-[0-9]{4}){3}$ ]]; then break; fi
    log_kv_masked "TOKEN_INVALIDO_FORMATO_MASKED" "$t"
    ui_erro "Token no formato inválido, tente novamente."
  done

  nova_acao "cadastrar_tls"
  TOKEN_TLS="$t"
  log_kv_masked "TOKEN_TLS_MASKED" "$TOKEN_TLS"

  UI_TEST_LABEL="Testando comunicação TLS"
  ui_start "Cadastrar TLS"
  ui_progress 2 "Capturando estado original"
  ui_step_min "Capturando estado original" capture_original_state || { acao_falhou "Falha ao capturar o estado original."; return 0; }
  ui_progress 5 "Ajustando modo TLS"
  ui_step_min "Ajustando modo TLS" step_set_flag_tls || { acao_falhou "Falha ao ajustar o modo TLS."; return 0; }
  ui_progress 15 "Registrando token"
  ui_step_min "Registrando token" step_write_mysql || { acao_falhou "Falha ao gravar o token no banco."; return 0; }
  ui_progress 22 "Gerando CONFITLS.INI"
  ui_step_min "Gerando CONFITLS.INI" write_confitls_ini || { acao_falhou "Falha ao gerar o CONFITLS.INI."; return 0; }
  ui_progress 28 "Reiniciando serviço TEF"
  ui_step_min "Reiniciando serviço TEF" step_prepare_tls_runtime_for_new_token || { acao_falhou "Falha ao montar o ambiente TLS."; return 0; }
  ui_progress 33 "Serviço reiniciado"

  if ui_step_min "Testando comunicação TLS" run_integrated_tls_test 35; then
    fim_teste TLS 1 "${TEST_RESULT_MSG:-Servidor Ativo}"
  else
    fim_teste TLS 0 "${TEST_RESULT_MSG:-Falha ao preparar o teste}"
  fi
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 3 - TESTAR TLS
# | O que faz: Monta o TLS com o token do banco e testa.
# | Por quê:   Confirma se o TLS deste caixa funciona.
# +--------------------------------------------------------------------------+
acao_testar_tls(){
  step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
  if [[ -z "${TOKEN_ATUAL_BANCO:-}" ]]; then
    ui_erro "Nenhum token cadastrado para este caixa. Use Cadastrar TLS."
    ui_pausa
    return 0
  fi

  nova_acao "testar_tls"
  TOKEN_TLS="$TOKEN_ATUAL_BANCO"

  UI_TEST_LABEL="Testando comunicação TLS"
  ui_start "Testar TLS"
  ui_progress 3 "Capturando estado original"
  ui_step_min "Capturando estado original" capture_original_state || { acao_falhou "Falha ao capturar o estado original."; return 0; }
  ui_progress 8 "Montando ambiente TLS"
  ui_step_min "Montando ambiente TLS" step_prepare_tls_for_existing_token_test || { acao_falhou "Falha ao montar o ambiente TLS."; return 0; }

  if ui_step_min "Testando comunicação TLS" run_integrated_tls_test 20; then
    fim_teste TLS 1 "${TEST_RESULT_MSG:-Servidor Ativo}"
  else
    fim_teste TLS 0 "${TEST_RESULT_MSG:-Falha ao preparar o teste}"
  fi
}

# +--------------------------------------------------------------------------+
# | OPÇÃO 4 - TESTAR GSURF
# | O que faz: Coloca em GSurf e testa.
# | Por quê:   Confirma se a GSurf deste caixa funciona.
# +--------------------------------------------------------------------------+
acao_testar_gsurf(){
  nova_acao "testar_gsurf"
  # O teste valida TOKEN_TLS preenchido (no fluxo antigo o GSurf vinha depois do TLS).
  step_collect_existing_token >>"$AUDIT_TMP" 2>&1 || true
  TOKEN_TLS="${TOKEN_ATUAL_BANCO:-GSURF}"

  UI_TEST_LABEL="Testando comunicação GSurf"
  ui_start "Testar GSurf"
  ui_progress 3 "Capturando estado original"
  ui_step_min "Capturando estado original" capture_original_state || { acao_falhou "Falha ao capturar o estado original."; return 0; }
  ui_progress 10 "Montando ambiente GSurf"
  ui_step_min "Montando ambiente GSurf" step_switch_to_gsurf || { acao_falhou "Falha ao montar o ambiente GSurf."; return 0; }
  ui_progress 20 "Testando comunicação GSurf"

  ui_step_min "Testando comunicação GSurf" step_validate_final_mode GSURF || true
  fim_teste GSURF "${FINAL_MODE_TEST_OK:-0}" "${FINAL_MODE_TEST_MSG:-Sem retorno}"
}

# +--------------------------------------------------------------------------+
# | INÍCIO DA EXECUÇÃO
# | O que faz: Instala o que falta, confere os programas, lê os dados do PDV
# |            e mostra o menu até o operador sair.
# | Por quê:   É o roteiro principal: tudo começa aqui.
# +--------------------------------------------------------------------------+
# =========================================================
# MAIN
# =========================================================

log_sep
log "INICIO DA EXECUÇÃO DO INSTALATLS"
log_kv "SCRIPT_DIR" "$SCRIPT_DIR"
log_kv "PDV_OUT_DB" "$PDV_OUT_DB"
log_kv "DB_IN" "$DB_IN"
log_kv "SERVICE_NAME" "$SERVICE_NAME"
log_kv "USUARIO_EXECUCAO" "$(id -un)"
log_kv "UID_EXECUCAO" "$(id -u)"

bootstrap_dependencies

for c in sqlite3 mysql base64 systemctl awk sed tr head id find mktemp chmod mv rm nc grep cut date; do
  need_cmd "$c"
done

detect_nc_close_mode

ui_dica "Lendo dados do PDV..."
check_sqlite_integrity || die "Falha de integridade no banco SQLite"
ui_step_min "Coletando dados básicos do PDV" step_collect_cfg || die "Falha ao ler os dados do PDV"
ui_step_min "Validando estrutura de banco" check_required_schema || die "Estrutura de banco inválida ou incompleta"
ui_step_min "Coletando contexto TLS" step_finalize_tls_context || die "Falha ao coletar o contexto TLS"

while true; do
  mostrar_pdv
  OPCAO="$(ui_opcao "1:Cadastrar TLS" "2:Instalar GSurf" "3:Testar TLS" "4:Testar GSurf" "0:Sair")"
  case "$OPCAO" in
    1) acao_cadastrar ;;
    2) acao_instalar_gsurf ;;
    3) acao_testar_tls ;;
    4) acao_testar_gsurf ;;
    0) sair ;;
  esac
done
