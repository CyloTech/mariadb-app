# ============================================================
# Build stages: Intermediate MariaDB LTS binaries for stepwise
# database upgrades from older versions (10.3+)
#
# Upgrade path: old_version → 10.6 → 10.11 → 11.4
# ============================================================

FROM ubuntu:22.04 AS mariadb-10-6
RUN apt-get update && apt-get install -y curl gnupg && \
    curl -fsSL 'https://mariadb.org/mariadb_release_signing_key.asc' | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://deb.mariadb.org/10.6/ubuntu jammy main" > /etc/apt/sources.list.d/mariadb.list && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

FROM ubuntu:24.04 AS mariadb-10-11
RUN apt-get update && apt-get install -y curl gnupg && \
    curl -fsSL 'https://mariadb.org/mariadb_release_signing_key.asc' | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/10.11/repo/ubuntu noble main" > /etc/apt/sources.list.d/mariadb.list && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

# ============================================================
# Final image with MariaDB 11.4 LTS
# ============================================================

FROM ubuntu:24.04

ENV MYSQL_ROOT_PASSWORD="mysqlr00t"
ENV MYSQL_DATABASE test
ENV MYSQL_USER test
ENV MYSQL_PASSWORD test

# Install MariaDB 11.4 LTS (latest long-term support release)
RUN apt-get update && \
    apt-get install -y software-properties-common curl gnupg && \
    curl -fsSL 'https://mariadb.org/mariadb_release_signing_key.asc' | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu noble main" > /etc/apt/sources.list.d/mariadb.list && \
    apt-get update && \
    apt-get install -y \
        mariadb-server \
        pwgen

# Copy intermediate version server binaries for stepwise upgrades
# These enable automatic database upgrades from MariaDB 10.3+ to 11.4
# Since all stages use ubuntu:24.04, system libraries are compatible
COPY --from=mariadb-10-6 /usr/sbin/mariadbd /opt/mariadb/10.6/bin/mariadbd
COPY --from=mariadb-10-11 /usr/sbin/mariadbd /opt/mariadb/10.11/bin/mariadbd

ADD scripts/run.sh /scripts/run.sh
RUN chmod -R 755 /scripts

# Sends POST /v1/apps/installed/${INSTANCE_ID} for run.sh. It retries network
# errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod 755 /usr/local/bin/appbox-installed-callback

ADD sources/my.cnf /etc/mysql/my.cnf

# Clean up APT when done.
RUN apt autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

EXPOSE 3306

ENTRYPOINT ["/scripts/run.sh"]
