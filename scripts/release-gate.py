#!/usr/bin/env python3
"""Release gate for the MySQL (MariaDB) image. Run on the builder with the
exact built image reference; it exits 0 only when every scenario passes and
the authenticated registry reports the release tag absent.

One MariaDB server container runs at a time, on the default bridge with no
published ports. Clients connect from a separate container, so logins are
remote ones that match '%' hosts, as they would on the published port.

  image    no MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD defaults, the root
           default is unchanged, the server is the tagged version and the
           callback unit test passes.
  fresh    new image on an empty volume: no test account, no test database
           and no anonymous users, root works with the install password,
           the installed callback is sent once, and no password, token or
           shell trace reaches the log. A test@% with another password
           survives a restart; once its password is "test", the next
           restart removes it.
  upgrade  current live image on an empty volume (creates test/test, which
           logs in remotely), customer data and users added, then the new
           image on the same volume: test@% and the empty test database
           are gone; root, the customer user, test@localhost, test2@% and
           the data are intact; one notice line; a restart changes nothing.
  keep     current live image with a table in `test`: after the new image,
           test@% is gone but the test database and its table are kept.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
import uuid

spec = importlib.util.spec_from_file_location('registry_check', Path(__file__).with_name('registry-check.py'))
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)
if len(sys.argv) != 2 or sys.argv[1] != registry.EXPECTED:
    raise SystemExit('Usage: release-gate.py ' + registry.EXPECTED)
image = sys.argv[1]
version = image.rsplit(':', 1)[1]
repo_root = Path(__file__).resolve().parent.parent
run_id = 'mariadb-release-gate-' + uuid.uuid4().hex[:12]
label = 'appbox.release-gate=' + run_id
containers = []
volumes = []
root_password = secrets.token_hex(16)
app_password = secrets.token_hex(16)
other_password = secrets.token_hex(16)
callback_token = secrets.token_hex(24)
secret_values = (root_password, app_password, other_password, callback_token)
instance_id = '900000074'
callbacks = []
rejected_callbacks = []
NOTICE = "Removed the default test account 'test'@'%'"
NOTICE_DB_DROPPED = '[i] ' + NOTICE + ' and its empty test database'
NOTICE_DB_KEPT = '[i] ' + NOTICE + '; kept the test database because it is not empty'
DEFAULT_HASH = '*94BDCEBE19083CE2A1F959FD02F964C7AF4CFC29'


def redact(text):
    for value in secret_values:
        text = text.replace(value, '[redacted]')
    return text


def command(args, timeout=300, check=True, env=None):
    p = subprocess.run(args, capture_output=True, timeout=timeout, env=env)
    if check and p.returncode:
        # Never print the arguments or the container environment.
        raise RuntimeError('Builder command failed: ' + redact(p.stderr.decode(errors='replace'))[-1500:])
    return p


class Callback(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        if self.path == '/v1/apps/installed/' + instance_id and \
                self.headers.get('X-Cylo-Callback-Token') == callback_token:
            callbacks.append(time.time())
            self.send_response(200)
        else:
            rejected_callbacks.append(self.path)
            self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


gateway = json.loads(command(['docker', 'network', 'inspect', 'bridge']).stdout)[0]['IPAM']['Config'][0]['Gateway']
callback_server = http.server.ThreadingHTTPServer((gateway, 0), Callback)
threading.Thread(target=callback_server.serve_forever, daemon=True).start()
callback_base = 'http://' + gateway + ':' + str(callback_server.server_port)


def volume(suffix):
    name = run_id + '-' + suffix
    command(['docker', 'volume', 'create', '--label', label, name])
    volumes.append(name)
    return name


def remove_volume(name):
    command(['docker', 'volume', 'rm', name])
    volumes.remove(name)


def start_server(suffix, selected_image, data_volume, callback=False):
    name = run_id + '-' + suffix
    env = dict(os.environ, MYSQL_ROOT_PASSWORD=root_password)
    # volume-nocopy: Appbox bind-mounts an empty host directory, so the
    # image's own /var/lib/mysql must not be copied into the volume.
    args = ['docker', 'run', '-d', '--name', name, '--label', label, '--init',
            '--network', 'bridge',
            '--mount', 'type=volume,src=' + data_volume + ',dst=/var/lib/mysql,volume-nocopy=true',
            '-e', 'MYSQL_ROOT_PASSWORD', '-e', 'PUID=1000', '-e', 'PGID=1000']
    if callback:
        env['CALLBACK_TOKEN'] = callback_token
        args += ['-e', 'INSTANCE_ID=' + instance_id, '-e', 'CALLBACK_TOKEN',
                 '-e', 'APPBOX_CALLBACK_BASE=' + callback_base]
    args.append(selected_image)
    command(args, env=env)
    containers.append(name)
    return name


def stop_server(name, require_clean=True):
    command(['docker', 'stop', '--time', '180', name], timeout=240)
    code = command(['docker', 'inspect', '--format', '{{.State.ExitCode}}', name]).stdout.decode().strip()
    if require_clean:
        assert code == '0', 'Server did not shut down cleanly (exit ' + code + ')'
    command(['docker', 'rm', name])
    containers.remove(name)


def restart_server(name):
    command(['docker', 'restart', '--time', '180', name], timeout=240)


def server_ip(name):
    ip = command(['docker', 'inspect', '--format', '{{(index .NetworkSettings.Networks "bridge").IPAddress}}',
                  name]).stdout.decode().strip()
    assert ip, 'Server has no bridge address'
    return ip


def start_client():
    # One long-lived client container (it only sleeps; no server runs in it),
    # so each query is a cheap `docker exec` instead of a new container.
    name = run_id + '-client'
    command(['docker', 'run', '-d', '--name', name, '--label', label, '--network', 'bridge',
             '--entrypoint', 'sleep', image, 'infinity'])
    containers.append(name)
    return name


def sql(name, user, password, statement, check=True):
    env = dict(os.environ, MYSQL_PWD=password)
    p = command(['docker', 'exec', '-e', 'MYSQL_PWD', client, 'mariadb', '--no-defaults', '--protocol=tcp',
                 '-h', server_ip(name), '-P', '3306', '-u', user, '--connect-timeout=10',
                 '--batch', '--skip-column-names', '-e', statement],
                timeout=300, check=False, env=env)
    if check and p.returncode:
        raise RuntimeError('SQL as ' + user + ' failed: ' + redact(p.stderr.decode(errors='replace'))[-800:])
    return p


def query(name, statement):
    return sql(name, 'root', root_password, statement).stdout.decode().strip()


def logs(name):
    p = command(['docker', 'logs', name])
    return (p.stdout + p.stderr).decode(errors='replace')


def wait_ready(name, timeout=900):
    started = time.monotonic()
    last = ''
    while time.monotonic() - started < timeout:
        running = command(['docker', 'inspect', '--format', '{{.State.Running}}', name]).stdout.decode().strip()
        if running != 'true':
            last = 'container stopped'
            break
        try:
            p = sql(name, 'root', root_password, 'SELECT VERSION()', check=False)
        except subprocess.TimeoutExpired:
            last = 'client timed out'
            continue
        if p.returncode == 0:
            return p.stdout.decode().strip(), round(time.monotonic() - started)
        last = redact(p.stderr.decode(errors='replace')).strip()[-300:]
        time.sleep(3)
    tail = '\n'.join(line for line in redact(logs(name)).splitlines()[-60:]
                     if 'password' not in line.lower())
    print(tail, flush=True)
    raise RuntimeError('Server not ready: ' + last)


def wait_callbacks(count, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and len(callbacks) < count:
        time.sleep(1)
    time.sleep(3)
    assert len(callbacks) == count, 'Expected %d installed callbacks, got %d' % (count, len(callbacks))
    assert not rejected_callbacks, 'Callback with a wrong path or token'


def test_login_refused(name):
    p = sql(name, 'test', 'test', 'SELECT CURRENT_USER()', check=False)
    # 1045, or 1698 when another 'test' account exists for a different host;
    # both are SQLSTATE 28000 access denied.
    if p.returncode == 0 or not re.search(rb'ERROR (1045|1698) \(28000\): Access denied', p.stderr):
        script_lines = [line for line in redact(logs(name)).splitlines() if line.startswith(('[i]', '[!]'))]
        print('\n'.join(script_lines[-40:]), flush=True)
        raise AssertionError('test/test login was not refused (exit %d, output %r, error %r)' % (
            p.returncode, p.stdout.decode(errors='replace').strip(), redact(p.stderr.decode(errors='replace')).strip()))


def count(name, statement):
    return int(query(name, statement))


def test_user_count(name):
    return count(name, "SELECT COUNT(*) FROM mysql.global_priv WHERE User = 'test' AND Host = '%'")


def test_db_count(name):
    return count(name, "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'test'")


def check_log(name, notices):
    text = logs(name)
    for value in secret_values:
        assert value not in text, 'A password or token reached the container log'
    assert not any(line.startswith('+ ') for line in text.splitlines()), 'Shell trace in the container log'
    assert 'with password' not in text, 'Password message in the container log'
    found = [line for line in text.splitlines() if NOTICE in line]
    assert found == notices, 'Unexpected test-account notices: %r' % found


def users(name):
    return query(name, "SELECT CONCAT(User, '@', Host) FROM mysql.global_priv ORDER BY 1").splitlines()


def check_image():
    # The unit test allows the app 2s to start; a busy builder can miss that
    # once, so a failure is retried one time before it fails the gate.
    for attempt in (1, 2):
        unit = subprocess.run(['bash', str(repo_root / 'tests' / 'test-installed-callback.sh')],
                              capture_output=True, timeout=600)
        if unit.returncode == 0:
            break
        print(unit.stdout.decode(errors='replace')[-3000:], flush=True)
        if attempt == 2:
            raise RuntimeError('tests/test-installed-callback.sh failed twice')
        print('Callback unit test failed once; retrying', flush=True)
    print('PASS callback unit test', flush=True)
    details = json.loads(command(['docker', 'image', 'inspect', image]).stdout)[0]
    assert details['Architecture'] == 'amd64' and details['Os'] == 'linux'
    env = dict(item.split('=', 1) for item in details['Config']['Env'])
    assert not {'MYSQL_DATABASE', 'MYSQL_USER', 'MYSQL_PASSWORD'} & env.keys(), 'Test defaults still in the image'
    assert env.get('MYSQL_ROOT_PASSWORD') == 'mysqlr00t', 'Root password default changed'
    out = command(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'sh', image, '-c',
                   'mariadbd --version; /opt/mariadb/10.6/bin/mariadbd --version; '
                   '/opt/mariadb/10.11/bin/mariadbd --version; test -x /usr/local/bin/appbox-installed-callback'
                   ]).stdout.decode()
    assert 'Ver ' + version + '-MariaDB' in out, 'Server is not MariaDB ' + version
    assert 'Ver 10.6.' in out and 'Ver 10.11.' in out, 'Upgrade binaries missing'
    print('PASS image: no test defaults, root default unchanged, MariaDB', version, 'with 10.6/10.11 upgrade binaries',
          flush=True)


def scenario_fresh():
    data = volume('fresh')
    sent = len(callbacks)
    fresh = start_server('fresh', image, data, callback=True)
    found, seconds = wait_ready(fresh)
    assert found.startswith(version + '-MariaDB'), found
    test_login_refused(fresh)
    assert test_user_count(fresh) == 0 and test_db_count(fresh) == 0
    assert count(fresh, "SELECT COUNT(*) FROM mysql.global_priv WHERE User = ''") == 0, 'Anonymous users present'
    assert users(fresh) == ['mariadb.sys@localhost', 'mysql@localhost', 'root@%', 'root@localhost'], users(fresh)
    wait_callbacks(sent + 1)
    check_log(fresh, [])
    print('PASS fresh install: ready in %ss; no test account, test database or anonymous user; root works; '
          'one callback; no secrets or trace in the log' % seconds, flush=True)

    query(fresh, "CREATE USER 'test'@'%' IDENTIFIED BY '" + other_password + "'; CREATE DATABASE `test`")
    restart_server(fresh)
    wait_ready(fresh)
    assert test_user_count(fresh) == 1 and test_db_count(fresh) == 1, 'Non-default test account was touched'
    check_log(fresh, [])
    query(fresh, "ALTER USER 'test'@'%' IDENTIFIED BY 'test'")
    assert sql(fresh, 'test', 'test', 'SELECT 1', check=False).returncode == 0, 'Control login failed'
    restart_server(fresh)
    wait_ready(fresh)
    test_login_refused(fresh)
    assert test_user_count(fresh) == 0 and test_db_count(fresh) == 0
    wait_callbacks(sent + 1)
    check_log(fresh, [NOTICE_DB_DROPPED])
    stop_server(fresh)
    remove_volume(data)
    print('PASS restart: a test@% with another password is kept; with the password "test" it and the empty '
          'test database are removed on the next start; no further callback', flush=True)


def scenario_upgrade():
    data = volume('upgrade')
    base = start_server('upgrade-current', registry.CURRENT, data)
    found, seconds = wait_ready(base)
    p = sql(base, 'test', 'test', 'SELECT CURRENT_USER()')
    assert p.stdout.decode().strip() == 'test@%', 'Baseline test login did not reproduce'
    assert query(base, "SELECT JSON_VALUE(Priv, '$.authentication_string') FROM mysql.global_priv "
                       "WHERE User = 'test' AND Host = '%'") == DEFAULT_HASH
    query(base, "CREATE DATABASE appdb; "
                "CREATE TABLE appdb.items (id INT PRIMARY KEY, label VARCHAR(64)) ENGINE=InnoDB; "
                "INSERT INTO appdb.items VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma'); "
                "CREATE USER 'appuser'@'%' IDENTIFIED BY '" + app_password + "'; "
                "GRANT ALL ON appdb.* TO 'appuser'@'%'; "
                "CREATE USER 'test'@'localhost' IDENTIFIED BY 'test'; "
                "CREATE USER 'test2'@'%' IDENTIFIED BY 'test'")
    checksum = query(base, 'CHECKSUM TABLE appdb.items')
    users_before = users(base)
    stop_server(base, require_clean=False)
    print('PASS baseline %s (ready in %ss): test/test logs in remotely as test@%%; customer data added'
          % (found, seconds), flush=True)

    sent = len(callbacks)
    upgraded = start_server('upgrade-new', image, data, callback=True)
    found, seconds = wait_ready(upgraded)
    assert found.startswith(version + '-MariaDB'), found
    test_login_refused(upgraded)
    assert test_user_count(upgraded) == 0 and test_db_count(upgraded) == 0
    assert users(upgraded) == [u for u in users_before if u != 'test@%'], users(upgraded)
    assert query(upgraded, "SELECT JSON_VALUE(Priv, '$.authentication_string') FROM mysql.global_priv "
                           "WHERE User = 'test2' AND Host = '%'") == DEFAULT_HASH, 'test2@% changed'
    assert query(upgraded, 'CHECKSUM TABLE appdb.items') == checksum, 'Customer data changed'
    assert sql(upgraded, 'appuser', app_password, 'SELECT COUNT(*) FROM appdb.items').stdout.decode().strip() == '3'
    assert query(upgraded, 'SELECT 1') == '1'
    wait_callbacks(sent + 1)
    check_log(upgraded, [NOTICE_DB_DROPPED])
    print('PASS upgrade from the current image: ready in %ss; test@%% and the empty test database removed; root, '
          'appuser, test@localhost, test2@%% and appdb intact; one notice; callback sent' % seconds, flush=True)

    restart_server(upgraded)
    wait_ready(upgraded)
    assert query(upgraded, 'CHECKSUM TABLE appdb.items') == checksum
    assert users(upgraded) == [u for u in users_before if u != 'test@%']
    wait_callbacks(sent + 1)
    check_log(upgraded, [NOTICE_DB_DROPPED])
    stop_server(upgraded)
    remove_volume(data)
    print('PASS restart after upgrade: nothing else removed, data intact, no notice or callback', flush=True)


def scenario_keep():
    data = volume('keep')
    base = start_server('keep-current', registry.CURRENT, data)
    wait_ready(base)
    query(base, "CREATE TABLE test.keepme (id INT PRIMARY KEY, note VARCHAR(64)); "
                "INSERT INTO test.keepme VALUES (1, 'keep')")
    stop_server(base, require_clean=False)
    kept = start_server('keep-new', image, data)
    wait_ready(kept)
    test_login_refused(kept)
    assert test_user_count(kept) == 0, 'test@% not removed'
    assert test_db_count(kept) == 1 and query(kept, 'SELECT note FROM test.keepme') == 'keep', 'test data lost'
    check_log(kept, [NOTICE_DB_KEPT])
    stop_server(kept)
    remove_volume(data)
    print('PASS test database with a table: test@% removed, test database and table kept', flush=True)


try:
    aio_used = int(Path('/proc/sys/fs/aio-nr').read_text())
    aio_max = int(Path('/proc/sys/fs/aio-max-nr').read_text())
    if aio_max - aio_used < 20000:
        raise RuntimeError('Not enough free AIO contexts on the builder (%d of %d used)' % (aio_used, aio_max))
    check_image()
    client = start_client()
    scenario_fresh()
    scenario_upgrade()
    scenario_keep()
except Exception as error:
    print('FAIL release gate: ' + type(error).__name__ + ': ' + redact(str(error)), flush=True)
    raise
finally:
    for name in list(reversed(containers)):
        try:
            found = command(['docker', 'inspect', '--format', '{{index .Config.Labels "appbox.release-gate"}}',
                             name]).stdout.decode().strip()
            if found != run_id:
                raise RuntimeError('Container cleanup identity mismatch')
            command(['docker', 'rm', '-f', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in list(volumes):
        try:
            found = command(['docker', 'volume', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}',
                             name]).stdout.decode().strip()
            if found != run_id:
                raise RuntimeError('Volume cleanup identity mismatch')
            command(['docker', 'volume', 'rm', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    callback_server.shutdown()

registry.require_absent(image)
print('PASS all release gates for', image, flush=True)
