FROM alpine:3.7

ENV MYSQL_ROOT_PASSWORD="mysqlr00t"
ENV MYSQL_DATABASE test
ENV MYSQL_USER test
ENV MYSQL_PASSWORD test

RUN apk --update add mariadb mariadb-client pwgen curl && \
    rm -f /var/cache/apk/*

ADD scripts/run.sh /scripts/run.sh
RUN mkdir /scripts/pre-exec.d && \
    mkdir /scripts/pre-init.d && \
    chmod -R 755 /scripts

ADD sources/my.cnf /etc/mysql/my.cnf

EXPOSE 3306

VOLUME ["/var/lib/mysql"]

ENTRYPOINT ["/scripts/run.sh"]
