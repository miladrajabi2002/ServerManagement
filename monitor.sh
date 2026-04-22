#!/usr/bin/env bash

set -u
set -o pipefail

PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php8.3-fpm}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"
DB_SERVICE="${DB_SERVICE:-mariadb}"
CACHE_SERVICE="${CACHE_SERVICE:-dragonfly}"
APP_DB_USER="${APP_DB_USER:-v2board}"
NGINX_ACCESS_LOG="${NGINX_ACCESS_LOG:-/var/log/nginx/access.log}"
NGINX_ERROR_LOG="${NGINX_ERROR_LOG:-/var/log/nginx/error.log}"
PHP_FPM_LOG="${PHP_FPM_LOG:-/var/log/php8.3-fpm.log}"
MYSQL_ERROR_LOG="${MYSQL_ERROR_LOG:-/var/log/mysql/error.log}"
LARAVEL_LOG_DIR="${LARAVEL_LOG_DIR:-/var/www/html/storage/logs}"
PHP_FPM_STATUS_URL="${PHP_FPM_STATUS_URL:-http://127.0.0.1/status}"
LIVE_REFRESH="${LIVE_REFRESH:-2}"
LOG_TAIL_WINDOW="${LOG_TAIL_WINDOW:-5000}"

DISK_WARN="${DISK_WARN:-80}"
MEM_WARN="${MEM_WARN:-90}"
PHP_WORKERS_WARN="${PHP_WORKERS_WARN:-180}"
NGINX_CONN_WARN="${NGINX_CONN_WARN:-500}"

if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  CYAN="$(tput setaf 6)"
  BOLD="$(tput bold)"
  DIM="$(tput dim)"
  RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

ok()   { printf "%b[OK] %s%b\n" "$GREEN" "$1" "$RESET"; }
warn() { printf "%b[WARN] %s%b\n" "$YELLOW" "$1" "$RESET"; }
crit() { printf "%b[CRIT] %s%b\n" "$RED" "$1" "$RESET"; }
info() { printf "%b[INFO] %s%b\n" "$CYAN" "$1" "$RESET"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }
file_exists() { [ -f "$1" ]; }
safe_run() { "$@" 2>/dev/null; }
count_lines() { awk 'END { print NR+0 }'; }

line() {
  printf "%b======================================================================%b\n" "$BLUE$BOLD" "$RESET"
}

section() {
  printf "\n%b== %s ==%b\n" "$BLUE$BOLD" "$1" "$RESET"
}

subsection() {
  printf "\n%b-- %s --%b\n" "$CYAN$BOLD" "$1" "$RESET"
}

header() {
  clear
  line
  printf "%bSERVER MONITORING DASHBOARD%b\n" "$BOLD" "$RESET"
  printf "%s\n" "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  line
}

service_state() {
  local svc="$1"
  if ! cmd_exists systemctl; then
    echo "unknown"
    return
  fi
  systemctl is-active "$svc" 2>/dev/null || echo "unknown"
}

service_status_line() {
  local svc="$1"
  local state
  state="$(service_state "$svc")"
  case "$state" in
    active) ok "$svc is active" ;;
    inactive) warn "$svc is inactive" ;;
    failed) crit "$svc has failed" ;;
    activating) info "$svc is activating" ;;
    *) warn "$svc status unknown" ;;
  esac
}

get_load_all() {
  awk '{print $1, $2, $3}' /proc/loadavg
}

get_load_1m() {
  awk '{print $1}' /proc/loadavg
}

get_cpu_count() {
  nproc 2>/dev/null || echo 1
}

health_score=100
deduct_score() {
  local points="${1:-0}"
  health_score=$((health_score - points))
  [ "$health_score" -lt 0 ] && health_score=0
}

show_hardware() {
  section "SYSTEM OVERVIEW"

  subsection "CPU"
  safe_run lscpu | grep -E "Model name|CPU\(s\)|Core\(s\)|Thread\(s\)"

  subsection "Memory"
  safe_run free -h

  subsection "Disk"
  safe_run df -h /

  subsection "Network"
  if cmd_exists ip; then
    safe_run ip -br a
  else
    echo "ip command not found"
  fi
}

show_services() {
  section "SERVICE HEALTH"

  service_status_line "$PHP_FPM_SERVICE"
  service_status_line "$NGINX_SERVICE"
  service_status_line "$DB_SERVICE"
  service_status_line "$CACHE_SERVICE"

  echo "PHP-FPM workers: $(pgrep -fc 'php-fpm')"
  echo "Nginx ESTABLISHED(:80/:443): $(ss -Htn state established '( sport = :80 or sport = :443 )' 2>/dev/null | wc -l)"
}

show_database_stats() {
  section "DATABASE METRICS"
  if ! cmd_exists mysql; then
    echo "mysql client not available"
    return
  fi

  mysql -N -e "
SELECT
  (SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='${APP_DB_USER}') AS active_connections,
  (SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='${APP_DB_USER}' AND COMMAND='Sleep') AS sleeping_connections,
  (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Aborted_clients') AS aborted_clients,
  (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Connections') AS total_connections,
  (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Threads_running') AS threads_running,
  (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Questions') AS questions;
" 2>/dev/null | awk '
BEGIN {
  print "active_conn | sleeping_conn | aborted_clients | total_conn | threads_running | questions"
  print "-----------+---------------+-----------------+------------+-----------------+----------"
}
{
  printf "%-10s | %-13s | %-15s | %-10s | %-15s | %-8s\n", $1, $2, $3, $4, $5, $6
}'

  [ "${PIPESTATUS[0]}" -ne 0 ] && echo "database query failed"
}

show_nginx_traffic_stats() {
  section "NGINX TRAFFIC ANALYTICS"

  if ! file_exists "$NGINX_ACCESS_LOG"; then
    echo "Log file not found: $NGINX_ACCESS_LOG"
    return
  fi

  local window
  window="$LOG_TAIL_WINDOW"

  subsection "Request Summary (last ${window} lines)"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk '
BEGIN {
  total=0; s2=0; s3=0; s4=0; s5=0; bytes=0
}
{
  total++
  code=$9+0
  b=$10
  if (b ~ /^[0-9]+$/) bytes += b
  if (code >=200 && code <300) s2++
  else if (code >=300 && code <400) s3++
  else if (code >=400 && code <500) s4++
  else if (code >=500 && code <600) s5++
}
END {
  if (total==0) total=1
  printf "Total Requests: %d\n", total
  printf "2xx: %d (%.2f%%)\n", s2, (s2*100/total)
  printf "3xx: %d (%.2f%%)\n", s3, (s3*100/total)
  printf "4xx: %d (%.2f%%)\n", s4, (s4*100/total)
  printf "5xx: %d (%.2f%%)\n", s5, (s5*100/total)
  printf "Transfer: %.2f MB\n", (bytes/1024/1024)
}'

  subsection "Top 10 Endpoints"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk '{print $7}' | sort | uniq -c | sort -rn | head -10

  subsection "Top 10 Client IPs"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk '{print $1}' | sort | uniq -c | sort -rn | head -10

  subsection "Top 10 4xx Endpoints"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk '($9 ~ /^4/) {print $7}' | sort | uniq -c | sort -rn | head -10

  subsection "Top 10 5xx Endpoints"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk '($9 ~ /^5/) {print $7}' | sort | uniq -c | sort -rn | head -10

  subsection "Top Suspicious User Agents"
  tail -n "$window" "$NGINX_ACCESS_LOG" | awk -F'"' '{print $6}' | grep -iE "bot|crawler|spider|scraper|scan|sqlmap|nmap" | sort | uniq -c | sort -rn | head -10 || true
}

show_error_summaries() {
  section "ERROR INSIGHTS"

  summarize_log() {
    local file="$1"
    local regex="$2"
    local title="$3"
    subsection "$title"
    if ! file_exists "$file"; then
      echo "Log file not found: $file"
      return
    fi

    local total
    total="$(tail -n 2000 "$file" | grep -iE "$regex" | wc -l)"
    echo "Matches in last 2000 lines: $total"
    echo "Recent matches:"
    tail -n 400 "$file" | grep -iE "$regex" | tail -n 20 || echo "No recent matches"
  }

  summarize_log "$PHP_FPM_LOG" "error|warning|fatal|critical" "PHP-FPM"
  summarize_log "$NGINX_ERROR_LOG" "error|crit|alert|emerg" "Nginx Error"
  summarize_log "$MYSQL_ERROR_LOG" "error|warning|critical|aborted" "MariaDB"

  subsection "Laravel (today)"
  local laravel_log
  laravel_log="${LARAVEL_LOG_DIR}/laravel-$(date +%Y-%m-%d).log"
  if file_exists "$laravel_log"; then
    echo "Errors in last 2000 lines: $(tail -n 2000 "$laravel_log" | grep -ciE 'error|exception|fatal')"
    echo "Warnings in last 2000 lines: $(tail -n 2000 "$laravel_log" | grep -ciE 'warning')"
    echo "Top repeated exception lines:"
    tail -n 2000 "$laravel_log" | grep -iE 'exception|error|fatal' | sed 's/^\[[^]]*\] [^:]*\.[A-Z]*: //' | sort | uniq -c | sort -rn | head -10 || true
  else
    echo "No Laravel log found for today: $laravel_log"
  fi
}

show_php_fpm_status() {
  section "PHP-FPM STATUS"
  if cmd_exists curl; then
    curl -s "$PHP_FPM_STATUS_URL" 2>/dev/null | grep -E "pool:|process manager|start time|accepted conn|listen queue|max listen queue|idle processes|active processes|total processes|max active processes" || echo "status endpoint unavailable"
  else
    echo "curl not available"
  fi
}

show_security_view() {
  section "SECURITY SIGNALS"

  subsection "Failed SSH Logins (last 30)"
  if file_exists /var/log/auth.log; then
    grep "Failed password" /var/log/auth.log | tail -30 || true
  elif file_exists /var/log/secure; then
    grep "Failed password" /var/log/secure | tail -30 || true
  else
    echo "No auth log found"
  fi

  subsection "Top Scan-like Paths"
  if file_exists "$NGINX_ACCESS_LOG"; then
    tail -n "$LOG_TAIL_WINDOW" "$NGINX_ACCESS_LOG" | awk '($7 ~ /(wp-admin|wp-login|\.env|\.git|phpmyadmin|boaform|cgi-bin|vendor\/phpunit|HNAP1)/) {print $7}' | sort | uniq -c | sort -rn | head -15
  else
    echo "Access log unavailable"
  fi
}

show_health_warnings() {
  section "HEALTH SCORE"

  local disk_usage mem_usage load load_int cpu_count php_workers nginx_conn
  disk_usage="$(df / | tail -1 | awk '{print $5}' | tr -d '%')"
  mem_usage="$(free | awk '/Mem:/ {print int($3/$2*100)}')"
  load="$(get_load_1m)"
  load_int="$(echo "$load" | cut -d. -f1)"
  cpu_count="$(get_cpu_count)"
  php_workers="$(pgrep -fc 'php-fpm')"
  nginx_conn="$(ss -Htn state established '( sport = :80 or sport = :443 )' 2>/dev/null | wc -l)"

  if [ "$disk_usage" -gt "$DISK_WARN" ]; then
    crit "Disk usage: ${disk_usage}%"
    deduct_score 15
  else
    ok "Disk usage: ${disk_usage}%"
  fi

  if [ "$mem_usage" -gt "$MEM_WARN" ]; then
    crit "Memory usage: ${mem_usage}%"
    deduct_score 20
  else
    ok "Memory usage: ${mem_usage}%"
  fi

  if [ "$load_int" -gt "$cpu_count" ]; then
    warn "Load ($load) > CPU cores ($cpu_count)"
    deduct_score 15
  else
    ok "Load: $load"
  fi

  if [ "$php_workers" -gt "$PHP_WORKERS_WARN" ]; then
    warn "High PHP-FPM workers: $php_workers"
    deduct_score 10
  else
    ok "PHP-FPM workers: $php_workers"
  fi

  if [ "$nginx_conn" -gt "$NGINX_CONN_WARN" ]; then
    warn "High Nginx connections: $nginx_conn"
    deduct_score 10
  else
    ok "Nginx connections: $nginx_conn"
  fi

  for svc in "$PHP_FPM_SERVICE" "$NGINX_SERVICE" "$DB_SERVICE" "$CACHE_SERVICE"; do
    state="$(service_state "$svc")"
    if [ "$state" = "failed" ] || [ "$state" = "inactive" ]; then
      deduct_score 20
    fi
  done

  if [ "$health_score" -ge 90 ]; then
    ok "Overall score: ${health_score}/100"
  elif [ "$health_score" -ge 70 ]; then
    warn "Overall score: ${health_score}/100"
  else
    crit "Overall score: ${health_score}/100"
  fi
}

show_summary() {
  section "EXECUTIVE SUMMARY"
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Load: $(get_load_all)"
  echo "Memory Usage: $(free | awk '/Mem:/ {print int($3/$2*100)}')%"
  echo "Disk Usage: $(df / | tail -1 | awk '{print $5}')"
  echo "PHP-FPM: $(service_state "$PHP_FPM_SERVICE")"
  echo "Nginx: $(service_state "$NGINX_SERVICE")"
  echo "MariaDB: $(service_state "$DB_SERVICE")"
  echo "Cache: $(service_state "$CACHE_SERVICE")"
}

run_snapshot() {
  header
  show_hardware
  show_services
  show_database_stats
  show_php_fpm_status
  show_nginx_traffic_stats
  show_error_summaries
  show_security_view
  show_health_warnings
  show_summary
  line
}

run_logs_mode() {
  header
  show_nginx_traffic_stats
  show_error_summaries
  show_security_view
  line
}

live_once() {
  header

  section "LIVE"
  echo "Load Average: $(get_load_all) (cores: $(get_cpu_count))"
  echo "RAM: $(free -h | awk '/Mem:/ {print $3" / "$2" ("int($3/$2*100)"%)"}')"
  echo "Disk(/): $(df -h / | awk 'END {print $3" / "$2" ("$5")"}')"

  section "SERVICES"
  echo "PHP-FPM workers: $(pgrep -fc 'php-fpm')"
  echo "Nginx ESTABLISHED: $(ss -Htn state established '( sport = :80 or sport = :443 )' 2>/dev/null | wc -l)"
  echo "Nginx listening: $([ "$(ss -Htl '( sport = :80 or sport = :443 )' 2>/dev/null | wc -l)" -gt 0 ] && echo "UP" || echo "DOWN")"
  echo "Horizon workers: $(pgrep -fc 'horizon:work')"

  if cmd_exists mysql; then
    db_conn="$(mysql -N -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='${APP_DB_USER}'" 2>/dev/null | head -n1)"
    echo "DB connections for ${APP_DB_USER}: ${db_conn:-N/A}"
  else
    echo "DB connections: N/A"
  fi

  section "RECENT LOG SIGNALS"
  if file_exists "$NGINX_ACCESS_LOG"; then
    echo "Nginx 5xx (last 1000): $(tail -n 1000 "$NGINX_ACCESS_LOG" | awk '($9 ~ /^5/) {c++} END {print c+0}')"
    echo "Nginx 4xx (last 1000): $(tail -n 1000 "$NGINX_ACCESS_LOG" | awk '($9 ~ /^4/) {c++} END {print c+0}')"
    echo "Top 3 IPs (last 1000):"
    tail -n 1000 "$NGINX_ACCESS_LOG" | awk '{print $1}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "  - %s requests from %s\n", $1, $2}'
  else
    echo "Nginx access log unavailable"
  fi

  if file_exists "$PHP_FPM_LOG"; then
    echo "PHP errors (last 300 lines): $(tail -n 300 "$PHP_FPM_LOG" | grep -ciE 'error|fatal')"
  else
    echo "PHP log unavailable"
  fi

  line
}

run_live() {
  while true; do
    live_once
    sleep "$LIVE_REFRESH"
  done
}

usage() {
  cat <<EOF
Usage: $0 [snapshot|live|logs]

Modes:
  snapshot   Full monitoring report
  live       Live dashboard refresh loop
  logs       Deep log analytics report

Env examples:
  LOG_TAIL_WINDOW=10000 $0 logs
  PHP_FPM_SERVICE=php8.2-fpm $0 snapshot
EOF
}

main() {
  local mode="${1:-snapshot}"
  case "$mode" in
    snapshot) run_snapshot ;;
    live) run_live ;;
    logs) run_logs_mode ;;
    -h|--help|help) usage ;;
    *)
      echo "Unknown mode: $mode"
      usage
      exit 1
      ;;
  esac
}

main "$@"
