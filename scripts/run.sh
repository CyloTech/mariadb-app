#!/bin/bash

# No `set -x`: the trace printed MYSQL_ROOT_PASSWORD and the other install
# values into the container log.

# Track if this is a fresh install (no upgrade needed)
FRESH_INSTALL=0

# ============================================================
# Helper functions for version detection and stepwise upgrade
# ============================================================

# Get the major.minor version from the database data directory
# Reads mysql_upgrade_info which is written by mariadb-upgrade
# Example content: "10.5.8-MariaDB" → returns "10.5"
get_db_version() {
	if [ -f /var/lib/mysql/mysql_upgrade_info ]; then
		head -1 /var/lib/mysql/mysql_upgrade_info | sed 's/-.*//' | awk -F. '{print $1"."$2}'
	else
		echo "unknown"
	fi
}

# Convert version string to a comparable number
# 10.5 → 1005, 10.6 → 1006, 10.11 → 1011, 11.4 → 1104
version_num() {
	echo "$1" | awk -F. '{printf "%d%02d", $1, $2}'
}

# Start an intermediate MariaDB server version to upgrade InnoDB data files,
# then shut it down cleanly. This is required because MariaDB only supports
# upgrading one major version at a time.
run_upgrade_step() {
	local version=$1
	local mariadbd_bin
	local run_mariadb_upgrade=0

	if [ "$version" = "11.4" ]; then
		mariadbd_bin="/usr/sbin/mariadbd"
		run_mariadb_upgrade=1
	else
		mariadbd_bin="/opt/mariadb/${version}/bin/mariadbd"
	fi

	if [ ! -x "$mariadbd_bin" ]; then
		echo "[!] MariaDB ${version} binary not found at ${mariadbd_bin}"
		return 1
	fi

	echo "[i] === Starting MariaDB ${version} for data upgrade ==="

	# Start with --no-defaults to avoid 11.4-specific config options
	# InnoDB and Aria are compiled into the binary, no plugins needed
	# Use an empty plugin-dir to prevent loading incompatible 11.4 plugins
	mkdir -p /tmp/mariadb-empty-plugins
	"$mariadbd_bin" \
		--no-defaults \
		--user=mysql \
		--skip-grant-tables \
		--skip-networking \
		--datadir=/var/lib/mysql \
		--socket=/run/mysqld/mysqld.sock \
		--plugin-dir=/tmp/mariadb-empty-plugins \
		--innodb_flush_method=littlesync \
		--innodb_use_native_aio=OFF \
		--skip-log-bin &

	local server_pid=$!

	# Wait for socket (max 60 seconds)
	local count=0
	while [ ! -S /run/mysqld/mysqld.sock ] && [ $count -lt 60 ]; do
		sleep 1
		count=$((count + 1))
	done

	if [ -S /run/mysqld/mysqld.sock ]; then
		echo "[i] MariaDB ${version} started successfully (PID: ${server_pid})"

		# Only run mariadb-upgrade at the final version (11.4)
		# This updates all system tables to the target version in one pass
		if [ "$run_mariadb_upgrade" = "1" ]; then
			echo "[i] Running mariadb-upgrade to update system tables..."
			mariadb-upgrade --force --socket=/run/mysqld/mysqld.sock 2>&1 || true
		fi

		# Clean shutdown via SIGTERM (InnoDB flushes data, writes clean redo logs)
		echo "[i] Shutting down MariaDB ${version}..."
		kill "$server_pid"
		wait "$server_pid" 2>/dev/null || true
		sleep 1
	else
		echo "[!] MariaDB ${version} failed to start within 60 seconds"
		cat /var/lib/mysql/*.err 2>/dev/null | tail -20
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
		rm -f /run/mysqld/mysqld.sock
		return 1
	fi

	# Clean up stale socket
	rm -f /run/mysqld/mysqld.sock

	echo "[i] === MariaDB ${version} upgrade step complete ==="
}

# ============================================================
# Remove the default test account
#
# Earlier images set MYSQL_DATABASE, MYSQL_USER and MYSQL_PASSWORD to
# "test", so the first start created 'test'@'%' with the password "test"
# and ALL on `test`.*, reachable on the published port. On every start,
# before MariaDB listens on port 3306, this drops 'test'@'%' if it still
# has that password, then drops the `test` database if it holds no tables,
# views, routines or events. A test account with any other password, and
# every other user and database, is left alone.
#
# It uses a private server (no network, no grant checks, its own socket),
# so it needs no root password. A failure is logged and does not stop
# MariaDB from starting.
# ============================================================

# mysql_native_password hash of "test"
DEFAULT_TEST_PASSWORD_HASH='*94BDCEBE19083CE2A1F959FD02F964C7AF4CFC29'
MAINTENANCE_SOCKET=/run/mysqld/appbox-maintenance.sock

maintenance_sql() {
	mariadb --no-defaults --protocol=socket --socket="$MAINTENANCE_SOCKET" \
		--user=root --batch --skip-column-names "$@"
}

remove_default_test_account() {
	local server_log server_pid state matched db_exists db_objects drop_sql notice result
	local waited=0 status=0

	server_log=$(mktemp) || return 1
	rm -f "$MAINTENANCE_SOCKET"

	mariadbd --user=mysql --skip-grant-tables --skip-networking --skip-slave-start \
		--socket="$MAINTENANCE_SOCKET" >"$server_log" 2>&1 &
	server_pid=$!
	# On a stop request, shut the private server down cleanly first.
	trap 'kill "$server_pid" 2>/dev/null; wait "$server_pid"; exit 143' TERM INT

	# Allow time for crash recovery on a large database.
	until mariadb-admin --no-defaults --protocol=socket --socket="$MAINTENANCE_SOCKET" \
		--connect-timeout=5 --silent ping >/dev/null 2>&1; do
		if ! kill -0 "$server_pid" 2>/dev/null || [ "$waited" -ge 900 ]; then
			echo "[!] Could not start MariaDB to check for the default test account; skipping the check"
			tail -n 20 "$server_log"
			status=1
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done

	if [ "$status" = "0" ]; then
		state=$(maintenance_sql 2>&1 <<SQL
SELECT
  (SELECT COUNT(*) FROM mysql.global_priv
    WHERE User = 'test' AND Host = '%'
      AND JSON_VALUE(Priv, '\$.plugin') = 'mysql_native_password'
      AND JSON_VALUE(Priv, '\$.authentication_string') = '${DEFAULT_TEST_PASSWORD_HASH}'),
  (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'test'),
  (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'test')
    + (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'test')
    + (SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'test');
SQL
)
		read -r matched db_exists db_objects <<<"$state"
		if [ -z "$matched" ] || [ -z "$db_exists" ] || [ -z "$db_objects" ] \
			|| [[ "$matched$db_exists$db_objects" == *[!0-9]* ]]; then
			echo "[!] Could not check for the default test account: $(head -n 1 <<<"$state")"
			status=1
		fi
	fi

	if [ "$status" = "0" ] && [ "$matched" = "1" ]; then
		# The user goes first, so a database that cannot be dropped never
		# keeps the account.
		drop_sql="FLUSH PRIVILEGES; DROP USER 'test'@'%';"
		if [ "$db_exists" = "1" ] && [ "$db_objects" = "0" ]; then
			drop_sql="$drop_sql DROP DATABASE \`test\`;"
			notice="[i] Removed the default test account 'test'@'%' and its empty test database"
		elif [ "$db_exists" = "1" ]; then
			notice="[i] Removed the default test account 'test'@'%'; kept the test database because it is not empty"
		else
			notice="[i] Removed the default test account 'test'@'%'"
		fi
		if result=$(maintenance_sql -e "$drop_sql" 2>&1); then
			echo "$notice"
		else
			echo "[!] Could not remove the default test account or its empty test database: $(head -n 1 <<<"$result")"
			status=1
		fi
	fi

	kill "$server_pid" 2>/dev/null
	wait "$server_pid" 2>/dev/null
	trap - TERM INT
	rm -f "$MAINTENANCE_SOCKET" "$server_log"
	return "$status"
}

# ============================================================
# Main startup logic
# ============================================================

# Ensure run directory exists
if [ -d "/run/mysqld" ]; then
	echo "[i] mysqld already present, skipping creation"
	chown -R mysql:mysql /run/mysqld
else
	echo "[i] mysqld not found, creating...."
	mkdir -p /run/mysqld
	chown -R mysql:mysql /run/mysqld
fi

# Initialize or detect existing database
if [ -d /var/lib/mysql/mysql ]; then
	echo "[i] MySQL directory already present, skipping creation"
	chown -R mysql:mysql /var/lib/mysql
else
	echo "[i] MySQL data directory not found, creating initial DBs"
	FRESH_INSTALL=1

	chown -R mysql:mysql /var/lib/mysql

	# --skip-test-db: no sample `test` database, no PUBLIC grants on
	# `test`/`test\_%` and no anonymous ''@localhost users.
	mariadb-install-db --user=mysql --skip-test-db > /dev/null

	if [ "$MYSQL_ROOT_PASSWORD" = "" ]; then
		MYSQL_ROOT_PASSWORD=$(pwgen 16 1)
		echo "[i] MYSQL_ROOT_PASSWORD is empty, so root gets a random password (not logged)"
	fi

	MYSQL_DATABASE=${MYSQL_DATABASE:-""}
	MYSQL_USER=${MYSQL_USER:-""}
	MYSQL_PASSWORD=${MYSQL_PASSWORD:-""}

	tfile=$(mktemp)
	if [ ! -f "$tfile" ]; then
	    return 1
	fi

	cat << EOF > $tfile
USE mysql;
FLUSH PRIVILEGES;
-- Modern syntax for MariaDB 10.4+ (compatible with 11.4 LTS)
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

	if [ "$MYSQL_DATABASE" != "" ]; then
	    echo "[i] Creating database: $MYSQL_DATABASE"
	    echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" >> $tfile

	    # An extra user only when both a name and a password are supplied.
	    if [ "$MYSQL_USER" != "" ] && [ "$MYSQL_PASSWORD" != "" ]; then
		echo "[i] Creating user: $MYSQL_USER"
		echo "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> $tfile
		echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%';" >> $tfile
	    fi
	fi

	mariadbd --user=mysql --bootstrap --verbose=0 < $tfile
	rm -f $tfile
fi

# ============================================================
# Database upgrade (only for existing databases, not fresh installs)
#
# Detects the current database version and walks through the
# LTS upgrade path one major version at a time:
#   old_version → 10.6 → 10.11 → 11.4
#
# Each intermediate step starts that version's mariadbd binary
# to let InnoDB upgrade data file formats, then shuts down cleanly.
# The final step (11.4) also runs mariadb-upgrade to update
# system tables.
# ============================================================

if [ ! -f /etc/app_configured ]; then
	if [ "$FRESH_INSTALL" = "1" ]; then
		echo "[i] Fresh install detected, skipping database upgrade"
	else
		DB_VERSION=$(get_db_version)
		echo "[i] Detected database version: ${DB_VERSION}"

		# If version is unknown, assume very old and go through all steps
		if [ "$DB_VERSION" = "unknown" ]; then
			echo "[i] Could not detect version, assuming upgrade from old version"
			DB_VERSION="0.0"
		fi

		# Build the upgrade path based on current version
		# MariaDB LTS versions: 10.5, 10.6, 10.11, 11.4
		UPGRADE_STEPS=""
		CURRENT_NUM=$(version_num "$DB_VERSION")

		# Step through 10.6 if current version is older
		if [ "$CURRENT_NUM" -lt "$(version_num '10.6')" ]; then
			UPGRADE_STEPS="10.6"
		fi

		# Step through 10.11 if current version is older
		if [ "$CURRENT_NUM" -lt "$(version_num '10.11')" ]; then
			UPGRADE_STEPS="$UPGRADE_STEPS 10.11"
		fi

		# Always finish with 11.4
		if [ "$CURRENT_NUM" -lt "$(version_num '11.4')" ]; then
			UPGRADE_STEPS="$UPGRADE_STEPS 11.4"
		fi

		UPGRADE_STEPS=$(echo "$UPGRADE_STEPS" | xargs)  # trim whitespace

		if [ -n "$UPGRADE_STEPS" ]; then
			echo "[i] Upgrade path: ${DB_VERSION} -> $(echo $UPGRADE_STEPS | sed 's/ / -> /g')"

			UPGRADE_FAILED=0
			for step in $UPGRADE_STEPS; do
				if ! run_upgrade_step "$step"; then
					echo "[!] Upgrade step to ${step} failed!"
					UPGRADE_FAILED=1
					break
				fi
			done

			if [ "$UPGRADE_FAILED" = "1" ]; then
				echo "[!] Stepwise upgrade failed, attempting direct startup with 11.4"
			else
				echo "[i] Database upgrade completed successfully"
			fi
		else
			echo "[i] Database is already at target version, no upgrade needed"
		fi
	fi

	# Mark the installed callback pending if INSTANCE_ID is set, before the
	# configured marker so a crash in between cannot lose it. It is sent in
	# the background below. ${INSTANCE_ID:+set} avoids expanding the ID,
	# which may carry the callback token.
	if [ -n "${INSTANCE_ID:+set}" ]; then
		touch /etc/appbox_callback_pending
	fi

	touch /etc/app_configured
fi

# Every start, before MariaDB listens on port 3306.
remove_default_test_account || true

# Send a pending installed callback in the background so it can never keep
# MariaDB from starting. The helper retries network errors, 408, 429 and 5xx
# and stops on any other status (e.g. 401 once the token was used or cleared).
if [ -f /etc/appbox_callback_pending ]; then
	(
		set +e
		/usr/local/bin/appbox-installed-callback
		rm -f /etc/appbox_callback_pending
	) </dev/null &
fi

exec mariadbd --user=mysql --console
