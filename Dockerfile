FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN --mount=type=bind,source=gitweb-signatures.patch,target=/tmp/gitweb-signatures.patch \
    apk upgrade --no-cache \
    && apk add --no-cache git-gitweb gpgv highlight lighttpd openssh-keygen perl-cgi \
    && addgroup -g 1001 git \
    && adduser -D -u 1001 -G git -s /sbin/nologin git \
    && sed -i 's|map { "\$_/\$project" }|map { "\$_\$project" }|' /usr/share/gitweb/gitweb.cgi \
    && grep -qF 'map { "$_$project" }' /usr/share/gitweb/gitweb.cgi \
    && git -C /usr/share/gitweb apply --verbose /tmp/gitweb-signatures.patch \
    && grep -qF "'signatures' => {" /usr/share/gitweb/gitweb.cgi \
    && perl -c /usr/share/gitweb/gitweb.cgi

RUN --mount=type=bind,source=highlight-types.pl,target=/tmp/highlight-types.pl \
    --mount=type=bind,source=gpgv-git.pl,target=/tmp/gpgv-git.pl \
    perl /tmp/highlight-types.pl >/etc/gitweb-highlight.pl \
    && install -m 755 /tmp/gpgv-git.pl /usr/local/bin/gpgv-git \
    && perl -c /usr/local/bin/gpgv-git

COPY lighttpd.conf /etc/lighttpd/lighttpd.conf
COPY gitweb.conf /etc/gitweb.conf
COPY static/theme.css /usr/share/gitweb/static/theme.css

ENV GITWEB_SIGNATURES=0
USER 1001:1001
EXPOSE 8080
CMD ["lighttpd", "-D", "-f", "/etc/lighttpd/lighttpd.conf"]
