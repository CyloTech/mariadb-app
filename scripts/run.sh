#!/bin/bash

set -x

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

	mariadb-install-db --user=mysql > /dev/null

	if [ "$MYSQL_ROOT_PASSWORD" = "" ]; then
		MYSQL_ROOT_PASSWORD=$(pwgen 16 1)
		echo "[i] MySQL root Password: $MYSQL_ROOT_PASSWORD"
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

	    if [ "$MYSQL_USER" != "" ]; then
		echo "[i] Creating user: $MYSQL_USER with password $MYSQL_PASSWORD"
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
	# the background below. ${INSTANCE_ID:+set} keeps the ID (which may carry
	# the callback token) out of the set -x trace.
	if [ -n "${INSTANCE_ID:+set}" ]; then
		touch /etc/appbox_callback_pending
	fi

	touch /etc/app_configured
fi

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
