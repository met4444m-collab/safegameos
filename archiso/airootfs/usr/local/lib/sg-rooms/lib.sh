# safegamingOS — shared library for the room manager & SafeGuard AV.
# Sourced by /usr/local/bin/sg-* scripts. Requires: sqlite3, coreutils.

SG_ROOT="/var/lib/sg-rooms"
SG_DB="${SG_ROOT}/sg.db"
SG_QUARANTINE="${SG_ROOT}/quarantine"
SG_LOG="/var/log/sg-rooms"
SG_LOCK="/run/lock/sg-rooms"

# ---------------------------------------------------------------------------
# helpers

sg_require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      echo "error: required command '$c' not found" >&2
      exit 1
    }
  done
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//'
}

sg_now() { date +%s; }

# the real desktop user (the one who invoked the sudo'd tool)
real_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    echo "${SUDO_USER}"
  elif [[ -n "${LOGNAME:-}" ]]; then
    echo "${LOGNAME}"
  else
    echo "${USER:-root}"
  fi
}

# ---------------------------------------------------------------------------
# database

sg_ensure_db() {
  mkdir -p "${SG_ROOT}" "${SG_QUARANTINE}" "${SG_LOG}" "${SG_LOCK}"
  touch "${SG_DB}"
  sqlite3 "${SG_DB}" <<'SQL'
CREATE TABLE IF NOT EXISTS rooms(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'browser',
  status TEXT NOT NULL DEFAULT 'running',
  mem TEXT NOT NULL DEFAULT '4G',
  cpu TEXT NOT NULL DEFAULT '200',
  app TEXT NOT NULL DEFAULT '',
  quarantine_path TEXT,
  created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS downloads(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  room TEXT NOT NULL,
  filename TEXT NOT NULL,
  path TEXT NOT NULL,
  source_url TEXT NOT NULL DEFAULT 'unknown',
  size INTEGER NOT NULL DEFAULT 0,
  time INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'new'
);
CREATE TABLE IF NOT EXISTS blocked(
  url TEXT PRIMARY KEY,
  host TEXT NOT NULL,
  virus TEXT NOT NULL DEFAULT 'unknown',
  time INTEGER NOT NULL,
  unblocked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  time INTEGER NOT NULL,
  kind TEXT NOT NULL,
  msg TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS permissions(
  room TEXT NOT NULL,
  kind TEXT NOT NULL,
  granted INTEGER NOT NULL,
  time INTEGER NOT NULL,
  PRIMARY KEY(room, kind)
);
SQL
  [[ -f /etc/hosts.sg-backup ]] || cp /etc/hosts /etc/hosts.sg-backup
}

sg_esc() { echo "$1" | sed "s/'/''/g"; }

sg_event() {
  local kind="$1" msg="$2"
  msg="$(sg_esc "${msg}")"
  sqlite3 "${SG_DB}" "INSERT INTO events(time,kind,msg) VALUES($(sg_now),'${kind}','${msg}');"
  mkdir -p "${SG_LOG}"
  echo "[$(date '+%F %T')] [${kind}] ${msg}" >> "${SG_LOG}/events.log"
}

sg_room_home() { echo "${SG_ROOT}/$1/home"; }

sg_room_exists() {
  [[ -n "$(sqlite3 "${SG_DB}" "SELECT id FROM rooms WHERE id='$1';" 2>/dev/null)" ]]
}

sg_room_status() {
  sqlite3 "${SG_DB}" "SELECT status FROM rooms WHERE id='$1';" 2>/dev/null
}

# ---------------------------------------------------------------------------
# quarantine

sg_room_running() {
  firejail --list 2>/dev/null | grep -q "name:$1\b"
}

sg_quarantine_room() {
  local slug="$1" why="$2"
  local home; home="$(sg_room_home "${slug}")"
  local qdir="${SG_QUARANTINE}/${slug}-$(sg_now)"
  sg_room_running "${slug}" && firejail --shutdown="${slug}" >/dev/null 2>&1
  pkill -f -- "--name=${slug}" >/dev/null 2>&1 || true
  sleep 1
  if [[ -d "${home}" ]]; then
    mkdir -p "${SG_QUARANTINE}"
    mv "${home}" "${qdir}"
    chown -R root:root "${qdir}"
  fi
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='quarantined', quarantine_path='${qdir}' WHERE id='${slug}';"
  sg_event "quarantine" "Комната «${slug}» помещена в карантин: ${why}. Процессы остановлены, данные запечатаны."
  echo "✓ комната «${slug}» в карантине (${qdir})"
}

sg_restore_room() {
  local slug="$1"
  local qdir; qdir="$(sqlite3 "${SG_DB}" "SELECT quarantine_path FROM rooms WHERE id='${slug}';")"
  local user; user="$(real_user)"
  if [[ -z "${qdir}" || ! -d "${qdir}" ]]; then
    echo "error: нет карантинной копии для «${slug}»" >&2
    return 1
  fi
  mv "${qdir}" "$(sg_room_home "${slug}")"
  chown -R "${user}:${user}" "$(sg_room_home "${slug}")"
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='running', quarantine_path=NULL WHERE id='${slug}';"
  sg_event "clean" "Комната «${slug}» восстановлена из карантина."
  echo "✓ комната «${slug}» восстановлена"
}

sg_delete_room() {
  local slug="$1"
  local qdir; qdir="$(sqlite3 "${SG_DB}" "SELECT quarantine_path FROM rooms WHERE id='${slug}';")"
  local home; home="$(sg_room_home "${slug}")"
  sg_room_running "${slug}" && firejail --shutdown="${slug}" >/dev/null 2>&1
  rm -rf "${home}" "${qdir}"
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='deleted', quarantine_path=NULL WHERE id='${slug}';"
  sqlite3 "${SG_DB}" "DELETE FROM permissions WHERE room='${slug}';"
  sg_event "system" "Комната «${slug}» удалена безвозвратно."
  echo "✓ комната «${slug}» удалена"
}

# ---------------------------------------------------------------------------
# URL blocking (hosts file)

url_host() {
  local url="$1"
  url="${url#*://}"
  url="${url%%/*}"
  echo "${url}"
}

sg_block_url() {
  local url="$1" virus="${2:-unknown}"
  local host; host="$(url_host "${url}")"
  if [[ -z "${host}" ]]; then
    echo "error: не удалось извлечь хост из '${url}'" >&2
    return 1
  fi
  if grep -qE "^0\.0\.0\.0[[:space:]]+${host}([[:space:]]|$)" /etc/hosts; then
    echo "ℹ ${host} уже заблокирован"
    return 0
  fi
  printf '0.0.0.0\t%s\t# safegamingOS block\n' "${host}" >> /etc/hosts
  sqlite3 "${SG_DB}" \
    "INSERT OR REPLACE INTO blocked(url,host,virus,time,unblocked) VALUES('$(sg_esc "${url}")','${host}','$(sg_esc "${virus}")',$(sg_now),0);"
  sg_event "block" "URL ${url} заблокирован системно (${virus})."
  echo "✓ заблокирован: ${host} (источник: ${url})"
}

sg_unblock_url() {
  local url="$1"
  local host; host="$(url_host "${url}")"
  sed -i "/# safegamingOS block$/d; /^0\.0\.0\.0[[:space:]]\+${host}[[:space:]]/d" /etc/hosts
  sqlite3 "${SG_DB}" \
    "UPDATE blocked SET unblocked=1 WHERE url='$(sg_esc "${url}")';"
  sg_event "unblock" "URL ${url} разблокирован пользователем (ложное срабатывание?)."
  echo "✓ разблокирован: ${host}"
}

# ---------------------------------------------------------------------------
# permissions (game mode = доступ к экрану/звуку/вводу сессии)

sg_permission_set() {
  local room="$1" kind="$2" granted="${3:-0}"
  [[ "${granted}" == "1" || "${granted}" == "0" ]] || return 1
  sqlite3 "${SG_DB}" \
    "INSERT INTO permissions(room,kind,granted,time) VALUES('$(sg_esc "${room}")','$(sg_esc "${kind}")',${granted},$(sg_now))
     ON CONFLICT(room,kind) DO UPDATE SET granted=${granted}, time=$(sg_now);"
}

sg_permission_get() {
  local room="$1" kind="$2"
  sqlite3 "${SG_DB}" "SELECT granted FROM permissions WHERE room='$(sg_esc "${room}")' AND kind='$(sg_esc "${kind}")';" 2>/dev/null
}

# ---------------------------------------------------------------------------
# download registry (источник загрузки для SafeGuard)

sg_download_record() {
  local file="$1" url="${2:-unknown}" room="${3:-browser}" size="${4:-0}"
  [[ -e "${file}" ]] || return 1
  [[ "${size}" =~ ^[0-9]+$ ]] || size=0
  [[ "${size}" -eq 0 ]] && size=$(stat -c %s "${file}" 2>/dev/null || echo 0)
  sqlite3 "${SG_DB}" \
    "INSERT INTO downloads(room,filename,path,source_url,size,time)
     VALUES('$(sg_esc "${room}")','$(sg_esc "$(basename "${file}")")','$(sg_esc "$(readlink -f "${file}" 2>/dev/null || echo "${file}")")','$(sg_esc "${url}")',${size},$(sg_now));"
  sg_event "track" "Загрузка: ${file} ← ${url} (комната: ${room})."
}

sg_download_find() {
  local file="$1"
  sqlite3 "${SG_DB}" "SELECT room,source_url,status FROM downloads WHERE path='$(sg_esc "$(readlink -f "${file}" 2>/dev/null || echo "${file}")")' ORDER BY id DESC LIMIT 1;" 2>/dev/null
}
