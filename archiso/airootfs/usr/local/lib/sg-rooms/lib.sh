# safegamingOS — shared library for the room manager & SafeGuard AV.
# Sourced by /usr/local/bin/sg-* scripts. Requires: sqlite3, coreutils, tar.

SG_ROOT="/var/lib/sg-rooms"
SG_DB="${SG_ROOT}/sg.db"
SG_QUARANTINE="${SG_ROOT}/quarantine"
SG_SNAPSHOTS="${SG_ROOT}/snapshots"
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

# true, если установленный firejail поддерживает опцию (страховка от старых версий)
fj_supports() {
  firejail --help 2>/dev/null | grep -qE -- "--${1}([[:space:]=]|$)"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\+/-/g; s/^-//; s/-$//'
}

sg_now() { date +%s; }

# the real desktop user (the one who invoked the sudo'd / pkexec'd tool)
# pkexec exports PKEXEC_UID; sudo exports SUDO_USER.
real_user() {
  if [[ -n "${PKEXEC_UID:-}" && "${PKEXEC_UID}" =~ ^[0-9]+$ ]]; then
    id -un "${PKEXEC_UID}" 2>/dev/null || echo "${PKEXEC_UID}"
  elif [[ -n "${SUDO_USER:-}" ]]; then
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
  mkdir -p "${SG_ROOT}" "${SG_QUARANTINE}" "${SG_SNAPSHOTS}" "${SG_LOG}" "${SG_LOCK}"
  chmod 700 "${SG_ROOT}" "${SG_QUARANTINE}" "${SG_SNAPSHOTS}" "${SG_LOG}" "${SG_LOCK}"
  touch "${SG_DB}"
  chmod 600 "${SG_DB}"
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

sg_room_type() {
  sqlite3 "${SG_DB}" "SELECT type FROM rooms WHERE id='$(sg_esc "$1")';" 2>/dev/null
}

# ---------------------------------------------------------------------------
# per-room UID (полная файловая/процессная изоляция)
#
# Типы комнат с доступом к сессии рабочего стола (звук/порталы/экран):
# browser/games/streaming работают от имени пользователя сессии — это
# осознанный продукт-трейдофф (им нужен PipeWire-сокет, сессионная шина и
# экран). ВСЕ остальные комнаты получают собственного системного
# пользователя sgroom-<slug>: чужие /proc, /dev/shm, сокеты /run/user и
# файлы других UID для них физически закрыты ядром, а не чёрными списками.

sg_session_types() { echo "browser games streaming"; }

# Имя системного пользователя комнаты — УНИКАЛЬНО для полного slug.
# Раньше имя усекалось до 24 символов: две комнаты с общим префиксом из
# 24 символов получали ОДНОГО пользователя, и изоляция ядром между ними
# молча исчезала (общий /proc, чужие файлы открыты по UID, hidepid=2 не
# разделяет). Теперь: sgroom-<первые 12 символов slug>-<8 hex md5(slug)> —
# коллизия практически невозможна, длина 28 <= 32 (лимит имён пользователей).
sgroom_username() {
  local slug="$1" head hash
  head="$(printf '%s' "${slug}" | cut -c1-12)"
  hash="$(printf '%s' "${slug}" | md5sum | cut -c1-8)"
  printf 'sgroom-%s-%s' "${head}" "${hash}"
}

sg_room_user() {
  local slug="$1" type="${2:-general}"
  local st; st="$(sg_session_types)"
  case " ${st} " in
    *" ${type} "*) echo "$(real_user)" ;;
    *) sgroom_username "${slug}" ;;
  esac
}

sg_ensure_room_user() {
  local user="$1" home="$2"
  [[ -n "${user}" && "${user}" != "root" ]] || return 0
  if ! id -u "${user}" >/dev/null 2>&1; then
    if ! useradd --system --shell /usr/bin/bash --home-dir "${home}" \
        --no-create-home --key USERGROUPS_ENAB=no "${user}" >/dev/null 2>&1; then
      echo "error: не удалось создать пользователя комнаты «${user}» (имя занято?)" >&2
      return 1
    fi
    sg_event "system" "Создан пользователь комнаты «${user}» (per-room UID)."
  fi
  return 0
}

sg_remove_room_user() {
  local slug="$1"
  local u; u="$(sgroom_username "${slug}")"
  if id -u "${u}" >/dev/null 2>&1; then
    userdel "${u}" >/dev/null 2>&1 || true
  fi
}

sg_room_exists() {
  [[ -n "$(sqlite3 "${SG_DB}" "SELECT id FROM rooms WHERE id='$1';" 2>/dev/null)" ]]
}

sg_room_status() {
  sqlite3 "${SG_DB}" "SELECT status FROM rooms WHERE id='$1';" 2>/dev/null
}

# стандартные комнаты «из коробки» (создаются при настройке, idempotent)
sg_default_rooms() {
  local now; now="$(sg_now)"
  sqlite3 "${SG_DB}" <<SQL
INSERT OR IGNORE INTO rooms(id,name,type,status,mem,cpu,app,created) VALUES
 ('browser','browser','browser','ready','4G','200','firefox',${now}),
 ('games','games','games','ready','8G','400','prismlauncher',${now}),
 ('streaming','streaming','streaming','ready','8G','400','obs',${now});
SQL
  # сеть «из коробки»: браузер/игры/стрим — с сетью (продукт требует интернет),
  # все остальные комнаты по умолчанию запускаются БЕЗ сети.
  sqlite3 "${SG_DB}" <<SQL
INSERT OR IGNORE INTO permissions(room,kind,granted,time) VALUES
 ('browser','net',1,${now}),
 ('games','net',1,${now}),
 ('streaming','net',1,${now});
SQL
}

# ---------------------------------------------------------------------------
# snapshots (откат комнаты за секунды)

sg_snapshot_create() {
  local slug="$1" label="${2:-manual}"
  local home; home="$(sg_room_home "${slug}")"
  [[ -d "${home}" ]] || { echo "error: нет дома комнаты «${slug}»" >&2; return 1; }
  mkdir -p "${SG_SNAPSHOTS}"
  local file="${SG_SNAPSHOTS}/${slug}-${label}-$(date +%Y%m%d-%H%M%S).tar.zst"
  # кэши исключаем: они пересоздаются, а снапшот остаётся быстрым и лёгким
  tar --zstd -C "$(dirname "${home}")" -cf "${file}" "$(basename "${home}")" \
      --exclude='.cache' --exclude='.local/share/Trash' \
      --exclude='.config/google-chrome' --exclude='.config/chromium' 2>/dev/null
  chmod 600 "${file}"
  sg_event "snapshot" "Снапшот комнаты «${slug}»: ${file}"
  echo "✓ снапшот: ${file}"
}

sg_snapshot_list() {
  local slug="$1"
  local snaps; snaps="$(ls -1t "${SG_SNAPSHOTS}"/"${slug}"-*.tar.zst 2>/dev/null)"
  if [[ -z "${snaps}" ]]; then
    echo "(нет снапшотов для «${slug}» — создайте: sudo sg-rooms snapshot ${slug})"
    return 0
  fi
  local f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && printf '%s  %s\n' "$(du -h "${f}" 2>/dev/null | cut -f1)" "${f}"
  done <<< "${snaps}"
}

sg_snapshot_restore() {
  local slug="$1" snap="${2:-}"
  if [[ -z "${snap}" ]]; then
    snap="$(ls -1t "${SG_SNAPSHOTS}"/"${slug}"-*.tar.zst 2>/dev/null | head -n1)"
  fi
  [[ -n "${snap}" && -f "${snap}" ]] || { echo "error: снапшот не найден" >&2; return 1; }
  local home; home="$(sg_room_home "${slug}")"
  sg_room_running "${slug}" && firejail --shutdown="${slug}" >/dev/null 2>&1
  pkill -f -- "--name=${slug} " >/dev/null 2>&1 || true
  sleep 1
  local user; user="$(real_user)"
  rm -rf "${home}"
  mkdir -p "$(dirname "${home}")"
  tar --zstd -C "$(dirname "${home}")" -xf "${snap}"
  local ruser; ruser="$(sg_room_user "${slug}" "$(sg_room_type "${slug}")")"
  sg_ensure_room_user "${ruser}" "${home}" >/dev/null 2>&1 || true
  chown -R "${ruser}:${ruser}" "${home}" 2>/dev/null || true
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='running', quarantine_path=NULL WHERE id='$(sg_esc "${slug}")';"
  sg_event "restore" "Комната «${slug}» откачена к снапшоту ${snap}."
  echo "✓ комната «${slug}» откачена к ${snap}"
}

sg_snapshot_prune() {
  local slug="$1" keep="${2:-5}"
  ls -1t "${SG_SNAPSHOTS}"/"${slug}"-*.tar.zst 2>/dev/null \
    | tail -n +$((keep + 1)) \
    | while IFS= read -r f; do [[ -n "${f}" ]] && rm -f "${f}"; done
}

# авто-снапшот: один раз в день на комнату, храним 5 последних
sg_snapshot_auto() {
  local slug="$1"
  local today; today="$(date +%Y%m%d)"
  local home; home="$(sg_room_home "${slug}")"
  [[ -d "${home}" ]] || return 0
  ls "${SG_SNAPSHOTS}"/"${slug}"-auto-"${today}"-*.tar.zst >/dev/null 2>&1 && return 0
  sg_snapshot_create "${slug}" "auto" >/dev/null 2>&1 || true
  sg_snapshot_prune "${slug}" 5
}

# ---------------------------------------------------------------------------
# quarantine

# Точное совпадение имени песочницы: в cmdline имя всегда стоит как
# "--name=<slug> " (дальше идёт следующий аргумент). Раньше префиксное
# совпадение ("--name=a" ловило и "--name=a-b") позволяло карантину
# комнаты «a» убивать процессы комнаты «a-b» — межкомнатный DoS.
sg_room_running() {
  firejail --list 2>/dev/null | grep -qE -- "name:${1}[[:space:]]"
}

# Вымести остатки комнаты с хостовых разделяемых каталогов (страховка к тому,
# что firejail по умолчанию монтирует комнате ПРИВАТНЫЙ tmpfs на /dev/shm —
# файлы комнаты физически не попадают на хост; этот свип ловит гипотетический
# случай утечки, например через bind-дыру).
#
# Трогаем ТОЛЬКО файлы владельца комнаты (per-room UID sgroom-*): /dev/shm и
# /run/user десктоп-сессии принадлежат пользователю сессии, и их мы не
# трогаем ни при каких условиях. У session-комнат (browser/games/streaming)
# отдельного UID нет — свип для них no-op.
sg_cleanup_room_artifacts() {
  local slug="$1"
  local user; user="$(sg_room_user "${slug}" "$(sg_room_type "${slug}")")"
  local session_user; session_user="$(real_user)"
  [[ -n "${user}" && "${user}" != "root" && "${user}" != "${session_user}" ]] || return 0
  local uid; uid="$(id -u "${user}" 2>/dev/null)"
  [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ ]] || return 0
  # файлы per-room UID в /dev/shm (обычно их там нет — shm приватный)
  find /dev/shm -maxdepth 1 -user "${user}" -delete 2>/dev/null
  # каталог /run/user/<uid> комнаты, если вдруг создан (logind его не создаёт)
  rm -rf "/run/user/${uid}" 2>/dev/null || true
  sg_event "system" "Очищены остатки комнаты «${slug}» с /dev/shm и /run/user (UID ${uid})."
}

sg_quarantine_room() {
  local slug="$1" why="$2"
  local home; home="$(sg_room_home "${slug}")"
  local qdir="${SG_QUARANTINE}/${slug}-$(sg_now)"
  # страховка перед карантином: снапшот, чтобы откат был возможен
  sg_snapshot_create "${slug}" "pre-quarantine" >/dev/null 2>&1 || true
  sg_room_running "${slug}" && firejail --shutdown="${slug}" >/dev/null 2>&1
  pkill -f -- "--name=${slug} " >/dev/null 2>&1 || true
  sleep 1
  sg_cleanup_room_artifacts "${slug}"
  if [[ -d "${home}" ]]; then
    mkdir -p "${SG_QUARANTINE}"
    mv "${home}" "${qdir}"
    chown -R root:root "${qdir}"
  fi
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='quarantined', quarantine_path='$(sg_esc "${qdir}")' WHERE id='$(sg_esc "${slug}")';"
  sg_event "quarantine" "Комната «${slug}» помещена в карантин: ${why}. Процессы остановлены, данные запечатаны."
  echo "✓ комната «${slug}» в карантине (${qdir})"
}

sg_restore_room() {
  local slug="$1"
  local qdir; qdir="$(sqlite3 "${SG_DB}" "SELECT quarantine_path FROM rooms WHERE id='$(sg_esc "${slug}")';")"
  local user; user="$(real_user)"
  if [[ -z "${qdir}" || ! -d "${qdir}" ]]; then
    echo "error: нет карантинной копии для «${slug}»" >&2
    return 1
  fi
  mv "${qdir}" "$(sg_room_home "${slug}")"
  local ruser; ruser="$(sg_room_user "${slug}" "$(sg_room_type "${slug}")")"
  sg_ensure_room_user "${ruser}" "$(sg_room_home "${slug}")" >/dev/null 2>&1 || true
  chown -R "${ruser}:${ruser}" "$(sg_room_home "${slug}")"
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='running', quarantine_path=NULL WHERE id='$(sg_esc "${slug}")';"
  sg_event "clean" "Комната «${slug}» восстановлена из карантина."
  echo "✓ комната «${slug}» восстановлена"
}

sg_delete_room() {
  local slug="$1"
  local qdir; qdir="$(sqlite3 "${SG_DB}" "SELECT quarantine_path FROM rooms WHERE id='$(sg_esc "${slug}")';")"
  local home; home="$(sg_room_home "${slug}")"
  sg_room_running "${slug}" && firejail --shutdown="${slug}" >/dev/null 2>&1
  pkill -f -- "--name=${slug} " >/dev/null 2>&1 || true
  sleep 1
  sg_cleanup_room_artifacts "${slug}"
  rm -rf "${home}" "${qdir}"
  sg_remove_room_user "${slug}"
  sqlite3 "${SG_DB}" \
    "UPDATE rooms SET status='deleted', quarantine_path=NULL WHERE id='$(sg_esc "${slug}")';"
  sqlite3 "${SG_DB}" "DELETE FROM permissions WHERE room='$(sg_esc "${slug}")';"
  sg_event "system" "Комната «${slug}» удалена безвозвратно."
  echo "✓ комната «${slug}» удалена"
}

# ---------------------------------------------------------------------------
# URL blocking (hosts file)

# Извлечь хост из URL и СТРОГО проверить его. Хост попадает в /etc/hosts,
# поэтому без валидации URL с сайта злоумышленника (источник загрузки,
# записанный sg-track и блокируемый антивирусом!) мог содержать перевод
# строки/пробелы и дописать ПРОИЗВОЛЬНЫЕ строки в hosts при блокировке:
# перенаправление любого домена на IP атакующего (фишинг/MITM) или DoS
# блокировкой любых сайтов. Теперь: только [a-z0-9.-], без пробелов и
# переводов строк; при недопустимом хосте возвращает 1 (блокировка
# отклоняется, в hosts ничего не пишется).
url_host() {
  local url="$1" host
  url="${url#*://}"
  url="${url%%/*}"
  host="$(printf '%s' "${url}" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
  [[ -n "${host}" ]] || return 1
  [[ "${host}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  printf '%s' "${host}"
}

sg_block_url() {
  local url="$1" virus="${2:-unknown}"
  local host
  host="$(url_host "${url}")" || {
    echo "error: недопустимый хост в URL '${url}' — блокировка отклонена" >&2
    return 1
  }
  # Блокируем И IPv4 (0.0.0.0), И IPv6 (::): раньше блокировался только IPv4,
  # и хост с AAAA-записью оставался доступен по IPv6 (заблокированный вирусный
  # источник реально дотягивался). Обе строки помечаем # safegamingOS block.
  if ! grep -qE "^0\.0\.0\.0[[:space:]]+${host}([[:space:]]|$)" /etc/hosts; then
    printf '0.0.0.0\t%s\t# safegamingOS block\n' "${host}" >> /etc/hosts
  fi
  if ! grep -qE "^::[[:space:]]+${host}([[:space:]]|$)" /etc/hosts; then
    printf '::\t%s\t# safegamingOS block\n' "${host}" >> /etc/hosts
  fi
  sqlite3 "${SG_DB}" \
    "INSERT OR REPLACE INTO blocked(url,host,virus,time,unblocked) VALUES('$(sg_esc "${url}")','${host}','$(sg_esc "${virus}")',$(sg_now),0);"
  sg_event "block" "URL ${url} заблокирован системно (${virus})."
  echo "✓ заблокирован: ${host} (источник: ${url})"
}

sg_unblock_url() {
  local url="$1"
  local host
  host="$(url_host "${url}")" || {
    echo "error: недопустимый хост в URL '${url}'" >&2
    return 1
  }
  # Удаляем ТОЛЬКО строки блокировки ЭТОГО хоста (IPv4 и IPv6). Раньше sed
  # вычищал ВСЕ строки с "# safegamingOS block" — разблокировка одной ссылки
  # молча снимала блокировку со ВСЕХ вирусных источников.
  sed -i -E \
    -e "/^0\.0\.0\.0[[:space:]]+${host}([[:space:]]|$)/d" \
    -e "/^::[[:space:]]+${host}([[:space:]]|$)/d" \
    /etc/hosts
  sqlite3 "${SG_DB}" \
    "UPDATE blocked SET unblocked=1 WHERE url='$(sg_esc "${url}")';"
  sg_event "unblock" "URL ${url} разблокирован пользователем (ложное срабатывание?)."
  echo "✓ разблокирован: ${host}"
}

# ---------------------------------------------------------------------------
# сеть комнаты: permission kind='net'; без сети комната не может ни скачать,
# ни отправить данные наружу (вирус не «улетит» на сервер).
# По умолчанию сеть есть только у комнат, которым она нужна из коробки.

sg_net_default() {
  case "${1:-general}" in
    browser|games|streaming) echo 1 ;;
    *) echo 0 ;;
  esac
}

sg_net_get() {
  local slug="$1" type="${2:-general}"
  local v; v="$(sg_permission_get "${slug}" net)"
  [[ -n "${v}" ]] || v="$(sg_net_default "${type}")"
  echo "${v}"
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

# Лучший-effort извлечение URL источника загрузки из профиля Firefox комнаты.
# Firefox пишет историю загрузок в places.sqlite (moz_downloads.source)
# асинхронно — ждём до TRIES попыток с паузой, чтобы застать запись.
# Возвращает URL или пустую строку (тогда остаётся 'unknown').
sg_track_auto_url() {
  local slug="$1" filename="$2" tries="${3:-8}"
  [[ -n "${filename}" && ${#filename} -ge 2 ]] || return 1
  local home db url i
  home="$(sg_room_home "${slug}")"
  db="$(find "${home}/.mozilla/firefox" -maxdepth 2 -name 'places.sqlite' 2>/dev/null | head -n1)"
  [[ -n "${db}" ]] || return 1
  local fn_lc; fn_lc="$(printf '%s' "${filename}" | tr '[:upper:]' '[:lower:]')"
  for ((i=0; i<tries; i++)); do
    [[ ${i} -gt 0 ]] && sleep 3
    url="$(sqlite3 -readonly -separator $'\t' "${db}" \
      "SELECT d.source FROM moz_downloads d WHERE instr(lower(d.source), lower('$(sg_esc "${filename}")')) > 0 ORDER BY d.dateAdded DESC LIMIT 1;" 2>/dev/null)"
    if [[ -n "${url}" ]]; then
      printf '%s' "${url}"
      return 0
    fi
    # Firefox переименовывает дубликаты: 'file (1).zip' — ищем без суффикса
    local base; base="${filename%% *}"
    if [[ -n "${base}" && ${#base} -ge 2 ]]; then
      url="$(sqlite3 -readonly -separator $'\t' "${db}" \
        "SELECT d.source FROM moz_downloads d WHERE instr(lower(d.source), lower('$(sg_esc "${base}")')) > 0 ORDER BY d.dateAdded DESC LIMIT 1;" 2>/dev/null)"
      [[ -n "${url}" ]] && { printf '%s' "${url}"; return 0; }
    fi
  done
  return 1
}
