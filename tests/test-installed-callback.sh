#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3; no Docker):
#   - appbox-installed-callback retries network errors, 408, 429 and 5xx,
#     stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token, passes an optional JSON body, and never logs the
#     callback token carried in INSTANCE_ID;
#   - scripts/run.sh execs mariadbd straight away even when the API rejects
#     the callback, sends a pending callback once in the background, clears
#     the pending flag, keeps the token out of its set -x trace, and sends
#     nothing without INSTANCE_ID or on a plain restart. The data directory
#     is a scratch directory that already holds an 11.4 database, so no
#     install or upgrade step runs.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
header_token='headertoken0123456789'

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 1.5
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock

# --- start path ------------------------------------------------------------------

# sandbox_start_script (defined per repo below) writes a copy of the start
# script to $1 with its paths pointed into ${work}, any hard-coded API URL
# pointed at the mock, and its final exec replaced by `exec "$@"`.
# entrypoint_case runs that copy with a fake app as "$@" that records when it
# started, waits for the background callback to finish and checks that:
#   - the app started within 2s whatever the API answered;
#   - the API saw exactly <want_requests> POSTs;
#   - the pending flag (${work}/callback_pending) is gone and no token
#     reached the output.
# Usage: entrypoint_case <label> <codes> <want_requests> <setup function> [VAR=value...]
entrypoint_case() {
    local label=$1 codes=$2 want_requests=$3 setup=$4
    shift 4
    start_mock "${codes}"
    local sandbox="${work}/start-script"
    sandbox_start_script "${sandbox}"
    chmod +x "${sandbox}"
    if ! grep -q '^ *exec "\$@"$' "${sandbox}"; then
        fail "${label}: could not sandbox the start script"
        stop_mock
        return
    fi
    "${setup}"

    local started_at app_at entrypoint_pid waited=0
    started_at=$(date +%s)
    env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 "$@" \
        "${sandbox}" bash -c "date +%s >'${work}/app_started'; sleep 1" \
        >"${work}/output" 2>&1 &
    entrypoint_pid=$!

    # A callback that blocks startup never reaches the app; give up after 10s.
    while [[ ! -f "${work}/app_started" && "${waited}" -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [[ ! -f "${work}/app_started" ]]; then
        pkill -P "${entrypoint_pid}" 2>/dev/null
        kill "${entrypoint_pid}" 2>/dev/null
    fi
    wait "${entrypoint_pid}" 2>/dev/null

    # The background sender outlives the fake app; wait for it to finish.
    waited=0
    while [[ -f "${work}/callback_pending" && "${waited}" -lt 20 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 0.5

    app_at=$(cat "${work}/app_started" 2>/dev/null || echo 0)
    local requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${app_at}" -gt 0 && $((app_at - started_at)) -le 2 && ! -f "${work}/callback_pending" \
        && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "${label} codes=${codes}: app started after $((app_at - started_at))s, requests=${requests}"
    else
        fail "${label} codes=${codes}: app_started=${app_at} start=${started_at} pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no) requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

sandbox_start_script() {
    sed -e "s|/run/mysqld|${work}/run|g" \
        -e "s|/var/lib/mysql|${work}/mysql|g" \
        -e "s|/tmp/mariadb-empty-plugins|${work}/plugins|g" \
        -e "s|/etc/app_configured|${work}/app_configured|g" \
        -e "s|/etc/appbox_callback_pending|${work}/callback_pending|g" \
        -e "s|/usr/local/bin/appbox-installed-callback|${helper}|g" \
        -e "s|https://api\.cylo\.[a-z]*|http://127.0.0.1:${port}|g" \
        -e 's|chown -R mysql:mysql .*|true|' \
        -e 's|^exec mariadbd --user=mysql --console$|exec "$@"|' \
        "${repo_root}/scripts/run.sh" >"$1"
}

# An existing 11.4 database: run.sh skips mariadb-install-db and the upgrade.
existing_db() {
    mkdir -p "${work}/mysql/mysql"
    echo "11.4.9-MariaDB" >"${work}/mysql/mysql_upgrade_info"
}
restart_pending() { existing_db; touch "${work}/app_configured" "${work}/callback_pending"; }
restart() { existing_db; touch "${work}/app_configured"; }

entrypoint_case "run.sh first boot" 200 1 existing_db
entrypoint_case "run.sh first boot" 401 1 existing_db
entrypoint_case "run.sh first boot without INSTANCE_ID" 200 0 existing_db INSTANCE_ID=
entrypoint_case "run.sh restart-pending" 503,200 2 restart_pending
entrypoint_case "run.sh restart" 200 0 restart

if grep -q 'apps/installed' "${repo_root}/scripts/run.sh"; then
    fail "run.sh still calls the installed callback itself"
else
    pass "run.sh only marks the callback pending and hands it to the helper"
fi

exit "${failures}"
