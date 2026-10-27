FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk add --no-cache git-gitweb highlight lighttpd perl-cgi \
    && addgroup -g 1001 git \
    && adduser -D -u 1001 -G git -s /sbin/nologin git \
    && sed -i 's|map { "\$_/\$project" }|map { "\$_\$project" }|' /usr/share/gitweb/gitweb.cgi \
    && grep -qF 'map { "$_$project" }' /usr/share/gitweb/gitweb.cgi

RUN --mount=type=bind,source=highlight-types.pl,target=/tmp/highlight-types.pl \
    perl /tmp/highlight-types.pl >/etc/gitweb-highlight.pl

COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
COPY gitweb.conf /etc/gitweb.conf
COPY static/theme.css /usr/share/gitweb/static/theme.css

USER 1001:1001
EXPOSE 8080
CMD ["lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
