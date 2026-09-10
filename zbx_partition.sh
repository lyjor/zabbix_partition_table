#!/usr/bin/env bash
#
# zbx_partition.sh
#
# Cria e mantem particoes (PARTITION BY RANGE) nas tabelas de historico/trends
# do Zabbix em MySQL/MariaDB, seguindo a abordagem descrita em:
# https://blog.zabbix.com/pt/particionamento-banco-de-dados-mysql8-zabbix-com-perl/21465/
#
# Compativel com bash 3.2+ (macOS) e bash 4/5 (Linux). Nao usa arrays associativos.
#
# Uso rapido:
#   ./zbx_partition.sh init          --table history --period day   --retention 60 [--yes]
#   ./zbx_partition.sh add-partition --table history --period day   [--yes]
#   ./zbx_partition.sh drop-old      --table history --period day   --retention 60 [--yes]
#   ./zbx_partition.sh maintain      --table history --period day   --retention 60 [--yes]
#   ./zbx_partition.sh maintain-all  [--retention-history 60] [--retention-trends 12] [--yes]
#   ./zbx_partition.sh status        --table history
#   ./zbx_partition.sh status-all
#
# Credenciais (flags tem prioridade sobre variaveis de ambiente):
#   --host / ZBX_DB_HOST      (default: 127.0.0.1)
#   --port / ZBX_DB_PORT      (default: 3306)
#   --user / ZBX_DB_USER      (default: root)
#   --password / ZBX_DB_PASS  (se omitido, sera solicitado interativamente)
#   --database / ZBX_DB_NAME  (default: zabbix)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Configuracao padrao das tabelas Zabbix (tabela:periodo:retencao)
# periodo: day | month  |  retencao: quantidade de dias (day) ou meses (month)
# ---------------------------------------------------------------------------
DEFAULT_TABLE_CONFIG='
history:day:60
history_log:day:60
history_str:day:60
history_text:day:60
history_uint:day:60
history_bin:day:60
trends:month:12
trends_uint:month:12
'

DB_HOST="${ZBX_DB_HOST:-192.168.68.241}"
DB_PORT="${ZBX_DB_PORT:-3306}"
DB_USER="${ZBX_DB_USER:-lyjor}"
DB_PASS="${ZBX_DB_PASS:-debian}"
DB_NAME="${ZBX_DB_NAME:-zabbix}"

TABLE=""
PERIOD=""
RETENTION=""
FUTURE=""
START_DATE=""
ASSUME_YES=0
DRY_RUN=0
FORCE=0
RET_HISTORY_DEFAULT=60
RET_TRENDS_DEFAULT=12
INIT_MISSING=0

MYCNF_FILE=""

cleanup() {
  if [ -n "$MYCNF_FILE" ] && [ -f "$MYCNF_FILE" ]; then
    rm -f "$MYCNF_FILE"
  fi
}
trap cleanup EXIT

die() {
  echo "ERRO: $*" >&2
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------------------
# Portabilidade de datas (GNU date x BSD date)
# ---------------------------------------------------------------------------
is_gnu_date() { date --version >/dev/null 2>&1; }

epoch_for() { # $1 = "YYYY-MM-DD" [$2 = "HH:MM:SS", default 00:00:00]
  local d="$1 ${2:-00:00:00}"
  if is_gnu_date; then
    date -d "$d" +%s
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "$d" +%s
  fi
}

date_from_epoch() { # $1 = epoch -> YYYY-MM-DD
  if is_gnu_date; then
    date -d "@$1" +%Y-%m-%d
  else
    date -r "$1" +%Y-%m-%d
  fi
}

today_date() { date '+%Y-%m-%d'; }

add_days_to_date() { # $1 = YYYY-MM-DD, $2 = n (pode ser negativo)
  if is_gnu_date; then
    date -d "$1 $2 days" +%Y-%m-%d
  else
    date -j -v"$(printf '%+d' "$2")d" -f "%Y-%m-%d" "$1" +%Y-%m-%d
  fi
}

add_months_to_date() { # $1 = YYYY-MM-DD (idealmente dia 01), $2 = n
  if is_gnu_date; then
    date -d "$1 $2 months" +%Y-%m-%d
  else
    date -j -v"$(printf '%+d' "$2")m" -f "%Y-%m-%d" "$1" +%Y-%m-%d
  fi
}

first_of_month() { echo "${1%-*}-01"; }

# ---------------------------------------------------------------------------
# Conexao MySQL/MariaDB
# ---------------------------------------------------------------------------
setup_mysql_cnf() {
  if [ -z "$DB_PASS" ]; then
    read -r -s -p "Senha para ${DB_USER}@${DB_HOST}: " DB_PASS
    echo
  fi
  MYCNF_FILE="$(mktemp)"
  chmod 600 "$MYCNF_FILE"
  {
    echo "[client]"
    echo "host=${DB_HOST}"
    echo "port=${DB_PORT}"
    echo "user=${DB_USER}"
    echo "password=${DB_PASS}"
  } > "$MYCNF_FILE"
}

mysql_cli() {
  mysql --defaults-extra-file="$MYCNF_FILE" --protocol=TCP -N -B "$DB_NAME" "$@"
}

mysql_query() { # $1 = SQL -> imprime resultado tab-separado sem cabecalho
  mysql_cli -e "$1"
}

mysql_exec_file() { # $1 = arquivo .sql
  mysql --defaults-extra-file="$MYCNF_FILE" --protocol=TCP "$DB_NAME" < "$1"
}

test_connection() {
  mysql_query "SELECT 1;" >/dev/null 2>&1 || die "Nao foi possivel conectar em ${DB_HOST}:${DB_PORT} como ${DB_USER} no banco ${DB_NAME}."
}

# ---------------------------------------------------------------------------
# Validacoes
# ---------------------------------------------------------------------------
validate_table_name() {
  case "$1" in
    ''|*[!a-zA-Z0-9_]*) die "Nome de tabela invalido: '$1'" ;;
  esac
}

validate_period() {
  case "$1" in
    day|month) : ;;
    *) die "Periodo invalido: '$1' (use 'day' ou 'month')" ;;
  esac
}

table_exists() {
  local t="$1"
  local n
  n="$(mysql_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='${t}';")"
  [ "$n" = "1" ]
}

table_is_partitioned() {
  local t="$1"
  local n
  n="$(mysql_query "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${t}' AND partition_name IS NOT NULL;")"
  [ "$n" -gt 0 ]
}

confirm() {
  local msg="$1"
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  read -r -p "$msg [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_ddl() {
  # $1 = arquivo sql, $2 = descricao curta para log
  local file="$1" desc="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY-RUN] SQL que seria executado (${desc}):"
    cat "$file"
    return 0
  fi
  log "Executando: ${desc}"
  mysql_exec_file "$file"
  log "Concluido: ${desc}"
}

# ---------------------------------------------------------------------------
# init: converte uma tabela em PARTITION BY RANGE (clock)
# ---------------------------------------------------------------------------
cmd_init() {
  [ -n "$TABLE" ] || die "--table e obrigatorio para 'init'"
  [ -n "$PERIOD" ] || die "--period e obrigatorio para 'init' (day|month)"
  validate_table_name "$TABLE"
  validate_period "$PERIOD"
  table_exists "$TABLE" || die "Tabela '${TABLE}' nao existe em ${DB_NAME}"

  if table_is_partitioned "$TABLE" && [ "$FORCE" -ne 1 ]; then
    die "Tabela '${TABLE}' ja possui particoes. Use 'add-partition'/'maintain', ou --force para recriar (destrutivo)."
  fi

  local future="${FUTURE:-3}"
  local start="$START_DATE"

  if [ -z "$start" ]; then
    local min_clock
    min_clock="$(mysql_query "SELECT MIN(clock) FROM \`${TABLE}\`;")"
    if [ -z "$min_clock" ] || [ "$min_clock" = "NULL" ]; then
      die "Tabela '${TABLE}' esta vazia. Informe --start YYYY-MM-DD para definir a primeira particao."
    fi
    start="$(date_from_epoch "$min_clock")"
  fi

  if [ "$PERIOD" = "month" ]; then
    start="$(first_of_month "$start")"
  fi

  local end
  end="$(today_date)"
  if [ "$PERIOD" = "day" ]; then
    end="$(add_days_to_date "$end" "$future")"
  else
    end="$(first_of_month "$end")"
    end="$(add_months_to_date "$end" "$future")"
  fi

  log "Tabela: ${TABLE} | periodo: ${PERIOD} | inicio: ${start} | fim (com margem futura): ${end}"

  local tmpfile
  tmpfile="$(mktemp)"
  {
    echo "ALTER TABLE \`${TABLE}\` PARTITION BY RANGE (clock) ("
    build_partition_list "$start" "$end" "$PERIOD"
    echo ");"
  } > "$tmpfile"

  echo "----- Preview do particionamento -----"
  wc -l < "$tmpfile" | xargs -I{} echo "Linhas geradas: {}"
  echo "---------------------------------------"

  confirm "Confirma a criacao das particoes iniciais para '${TABLE}'? Isso pode demorar bastante em tabelas grandes." \
    || { log "Operacao cancelada pelo usuario."; rm -f "$tmpfile"; return 1; }

  run_ddl "$tmpfile" "init particionamento de ${TABLE}"
  rm -f "$tmpfile"
}

# gera lista "PARTITION pNNN VALUES LESS THAN (ts) ENGINE = InnoDB," para o range [start,end]
# cada particao cobre um periodo (dia ou mes) iniciando em "cur" e terminando em "cur + 1 periodo"
build_partition_list() {
  local start="$1" end="$2" period="$3"
  local cur="$start"
  local first=1
  local upper upper_epoch pname line
  while :; do
    if [ "$period" = "day" ]; then
      upper="$(add_days_to_date "$cur" 1)"
      pname="p$(echo "$cur" | tr '-' '_')"
    else
      upper="$(add_months_to_date "$cur" 1)"
      pname="p$(echo "${cur%-*}" | tr '-' '_')"
    fi
    upper_epoch="$(epoch_for "$upper")"
    line="PARTITION ${pname} VALUES LESS THAN (${upper_epoch}) ENGINE = InnoDB"
    if [ "$first" -eq 1 ]; then
      printf '%s' "$line"
      first=0
    else
      printf ',\n%s' "$line"
    fi
    if [ "$cur" '>' "$end" ] || [ "$cur" = "$end" ]; then
      break
    fi
    cur="$upper"
  done
  echo
}

# ---------------------------------------------------------------------------
# add-partition: garante particoes futuras (self-heal de lacunas)
# ---------------------------------------------------------------------------
cmd_add_partition() {
  [ -n "$TABLE" ] || die "--table e obrigatorio"
  [ -n "$PERIOD" ] || die "--period e obrigatorio (day|month)"
  validate_table_name "$TABLE"
  validate_period "$PERIOD"
  table_exists "$TABLE" || die "Tabela '${TABLE}' nao existe em ${DB_NAME}"
  table_is_partitioned "$TABLE" || die "Tabela '${TABLE}' ainda nao esta particionada. Rode 'init' primeiro."

  local future="${FUTURE:-3}"
  local max_boundary
  max_boundary="$(mysql_query "SELECT MAX(CAST(partition_description AS UNSIGNED)) FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${TABLE}' AND partition_description REGEXP '^[0-9]+$';")"

  [ -n "$max_boundary" ] && [ "$max_boundary" != "NULL" ] || die "Nao foi possivel determinar a ultima particao de '${TABLE}'."

  local next_start
  next_start="$(date_from_epoch "$max_boundary")"

  local end
  end="$(today_date)"
  if [ "$PERIOD" = "day" ]; then
    end="$(add_days_to_date "$end" "$future")"
  else
    next_start="$(first_of_month "$next_start")"
    end="$(first_of_month "$end")"
    end="$(add_months_to_date "$end" "$future")"
  fi

  if [ "$next_start" '>' "$end" ] || [ "$next_start" = "$end" ]; then
    log "Nenhuma particao nova necessaria para '${TABLE}' (ja coberto ate ${next_start})."
    return 0
  fi

  log "Tabela: ${TABLE} | adicionando particoes de ${next_start} ate ${end}"

  local tmpfile
  tmpfile="$(mktemp)"
  {
    echo "ALTER TABLE \`${TABLE}\` ADD PARTITION ("
    build_partition_list "$next_start" "$end" "$PERIOD"
    echo ");"
  } > "$tmpfile"

  confirm "Confirma adicionar novas particoes em '${TABLE}'?" \
    || { log "Operacao cancelada pelo usuario."; rm -f "$tmpfile"; return 1; }

  run_ddl "$tmpfile" "adicionar particoes em ${TABLE}"
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# drop-old: remove particoes mais antigas que a retencao configurada
# ---------------------------------------------------------------------------
cmd_drop_old() {
  [ -n "$TABLE" ] || die "--table e obrigatorio"
  [ -n "$PERIOD" ] || die "--period e obrigatorio (day|month)"
  [ -n "$RETENTION" ] || die "--retention e obrigatorio (dias para 'day', meses para 'month')"
  validate_table_name "$TABLE"
  validate_period "$PERIOD"
  table_exists "$TABLE" || die "Tabela '${TABLE}' nao existe em ${DB_NAME}"
  table_is_partitioned "$TABLE" || die "Tabela '${TABLE}' ainda nao esta particionada."

  local cutoff_date cutoff_epoch
  if [ "$PERIOD" = "day" ]; then
    cutoff_date="$(add_days_to_date "$(today_date)" "-${RETENTION}")"
  else
    cutoff_date="$(first_of_month "$(today_date)")"
    cutoff_date="$(add_months_to_date "$cutoff_date" "-${RETENTION}")"
  fi
  cutoff_epoch="$(epoch_for "$cutoff_date")"

  log "Tabela: ${TABLE} | removendo particoes com limite <= ${cutoff_date} (epoch ${cutoff_epoch})"

  local rows
  rows="$(mysql_query "SELECT partition_name FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${TABLE}' AND partition_description REGEXP '^[0-9]+$' AND CAST(partition_description AS UNSIGNED) <= ${cutoff_epoch} ORDER BY CAST(partition_description AS UNSIGNED);")"

  if [ -z "$rows" ]; then
    log "Nenhuma particao antiga para remover em '${TABLE}'."
    return 0
  fi

  local droplist
  droplist="$(echo "$rows" | tr '\n' ',' | sed 's/,$//')"

  log "Particoes a remover: ${droplist}"

  local tmpfile
  tmpfile="$(mktemp)"
  echo "ALTER TABLE \`${TABLE}\` DROP PARTITION ${droplist};" > "$tmpfile"

  confirm "Confirma a REMOCAO (destrutiva) das particoes acima em '${TABLE}'?" \
    || { log "Operacao cancelada pelo usuario."; rm -f "$tmpfile"; return 1; }

  run_ddl "$tmpfile" "drop particoes antigas de ${TABLE}"
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# maintain: add-partition + drop-old em uma unica tabela
# ---------------------------------------------------------------------------
cmd_maintain() {
  cmd_add_partition
  if [ -n "$RETENTION" ]; then
    cmd_drop_old
  else
    log "AVISO: --retention nao informado, pulando remocao de particoes antigas para '${TABLE}'."
  fi
}

# ---------------------------------------------------------------------------
# maintain-all / status-all: itera sobre a configuracao padrao de tabelas
# ---------------------------------------------------------------------------
cmd_maintain_all() {
  local rh="${RET_HISTORY_DEFAULT}"
  local rt="${RET_TRENDS_DEFAULT}"
  echo "$DEFAULT_TABLE_CONFIG" | while IFS=':' read -r t p r; do
    [ -z "$t" ] && continue
    case "$t" in
      history*) r="$rh" ;;
      trends*)  r="$rt" ;;
    esac
    if ! table_exists "$t"; then
      log "Tabela '${t}' nao existe, pulando."
      continue
    fi
    if ! table_is_partitioned "$t"; then
      if [ "$INIT_MISSING" -eq 1 ]; then
        log "Tabela '${t}' nao particionada, inicializando (period=${p})..."
        TABLE="$t" PERIOD="$p" RETENTION="$r" cmd_init_wrapper
      else
        log "Tabela '${t}' ainda nao particionada. Rode 'init' ou use --init-missing. Pulando."
      fi
      continue
    fi
    log "Manutencao de '${t}' (period=${p}, retention=${r})"
    TABLE="$t" PERIOD="$p" RETENTION="$r" cmd_add_partition_wrapper
    TABLE="$t" PERIOD="$p" RETENTION="$r" cmd_drop_old_wrapper
  done
}

# wrappers para reutilizar as variaveis globais dentro do loop (subshell-safe)
cmd_init_wrapper()          { TABLE="$TABLE" PERIOD="$PERIOD" RETENTION="$RETENTION" cmd_init; }
cmd_add_partition_wrapper() { cmd_add_partition; }
cmd_drop_old_wrapper()      { cmd_drop_old; }

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  [ -n "$TABLE" ] || die "--table e obrigatorio para 'status'"
  validate_table_name "$TABLE"
  table_exists "$TABLE" || die "Tabela '${TABLE}' nao existe em ${DB_NAME}"

  if ! table_is_partitioned "$TABLE"; then
    echo "${TABLE}: NAO particionada."
    return 0
  fi

  local total oldest newest
  total="$(mysql_query "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${TABLE}' AND partition_name IS NOT NULL;")"
  oldest="$(mysql_query "SELECT MIN(CAST(partition_description AS UNSIGNED)) FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${TABLE}' AND partition_description REGEXP '^[0-9]+$';")"
  newest="$(mysql_query "SELECT MAX(CAST(partition_description AS UNSIGNED)) FROM information_schema.partitions WHERE table_schema='${DB_NAME}' AND table_name='${TABLE}' AND partition_description REGEXP '^[0-9]+$';")"

  echo "${TABLE}: ${total} particoes | mais antiga ate $(date_from_epoch "$oldest") | mais recente ate $(date_from_epoch "$newest")"
}

cmd_status_all() {
  echo "$DEFAULT_TABLE_CONFIG" | while IFS=':' read -r t p r; do
    [ -z "$t" ] && continue
    table_exists "$t" || { echo "${t}: tabela nao existe"; continue; }
    TABLE="$t" cmd_status
  done
}

# ---------------------------------------------------------------------------
# Parsing de argumentos
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || usage
COMMAND="$1"; shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --table) TABLE="$2"; shift 2 ;;
    --period) PERIOD="$2"; shift 2 ;;
    --retention) RETENTION="$2"; shift 2 ;;
    --retention-history) RET_HISTORY_DEFAULT="$2"; shift 2 ;;
    --retention-trends) RET_TRENDS_DEFAULT="$2"; shift 2 ;;
    --future) FUTURE="$2"; shift 2 ;;
    --start) START_DATE="$2"; shift 2 ;;
    --host) DB_HOST="$2"; shift 2 ;;
    --port) DB_PORT="$2"; shift 2 ;;
    --user) DB_USER="$2"; shift 2 ;;
    --password) DB_PASS="$2"; shift 2 ;;
    --database) DB_NAME="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --init-missing) INIT_MISSING=1; shift ;;
    -h|--help) usage ;;
    *) die "Argumento desconhecido: $1" ;;
  esac
done

setup_mysql_cnf
test_connection

case "$COMMAND" in
  init) cmd_init ;;
  add-partition) cmd_add_partition ;;
  drop-old) cmd_drop_old ;;
  maintain) cmd_maintain ;;
  maintain-all) cmd_maintain_all ;;
  status) cmd_status ;;
  status-all) cmd_status_all ;;
  *) usage ;;
esac
