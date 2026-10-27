#!/usr/bin/env bash
# Runs the image like the pod does and checks the web view of two bare repositories.
set -euo pipefail

image=${1:?usage: smoke.sh <image>}
port=${SMOKE_PORT:-28080}
work=$(mktemp -d)
container=gitweb-smoke-$$
repos=$work/repositories
site=$work/site.conf
broken_site=$work/broken-site.conf
mime_types=$work/mime.types
url=http://127.0.0.1:$port

cleanup() {
    status=$?
    [ "$status" -eq 0 ] || docker logs "$container" 2>&1 | tail -20
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

create_repository() {
    local path=$1 source=$work/source-$$
    rm -rf "$source"
    git -c init.defaultBranch=main init -q "$source"
    printf 'def hello():\n    return "world"\n' >"$source/hello.py"
    printf '<script>alert(1)</script>\n' >"$source/page.html"
    git -C "$source" add hello.py page.html
    git -C "$source" -c user.name=Smoke -c user.email=smoke@example.invalid commit -q -m Smoke
    mkdir -p "$(dirname "$repos/$path")"
    git clone -q --bare "$source" "$repos/$path"
    rm -rf "$source"
}

start_container() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name "$container" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
        --user 1001:1001 -p "127.0.0.1:$port:8080" -v "$repos:/srv/repositories:ro" "$@" "$image" >/dev/null
    for _ in $(seq 30); do
        curl -fs "$url/" >/dev/null 2>&1 && return
        sleep 1
    done
}

fetch() { curl -fsS "$url/$1"; }
fail() { echo "FAIL: $1"; exit 1; }

create_repository top.git
create_repository team/nested.git
cat >"$site" <<'EOF'
our $site_name = "Smoke Site";
our @git_base_url_list = ('git@example.org:');
EOF
printf 'our $site_name = "Broken"\nour @git_base_url_list = (;\n' >"$broken_site"
printf 'text/html html htm\n' >"$mime_types"
chmod 644 "$site" "$broken_site" "$mime_types"

start_container
summary=$(fetch '?p=team/nested.git;a=summary') || fail "summary without site file not served"
grep -q '<title>gitweb - team/nested.git/summary</title>' <<<"$summary" || fail "default site name missing"
! grep -q 'metadata_url' <<<"$summary" || fail "clone link without site file"

start_container -v "$broken_site:/etc/gitweb.d/site.conf:ro"
broken=$(curl -sS "$url/")
grep -q '500 - Internal Server Error' <<<"$broken" || fail "broken site file does not show the error page"
grep -q 'syntax error at /etc/gitweb.d/site.conf' <<<"$broken" || fail "error page does not name the site file"

start_container -v "$site:/etc/gitweb.d/site.conf:ro" -v "$mime_types:/etc/mime.types:ro"

index=$(fetch '')
grep -q 'top.git' <<<"$index" || fail "project list lacks top.git"
grep -q 'team/nested.git' <<<"$index" || fail "project list lacks team/nested.git"
grep -q '<title>Smoke Site</title>' <<<"$index" || fail "site name from site file missing"

blob=$(fetch '?p=team/nested.git;a=blob;f=hello.py')
grep -q '<span class="hl ' <<<"$blob" || fail "no highlighted code"

grep -q '<meta name="viewport"' <<<"$index" || fail "no viewport meta"
grep -q 'theme.css' <<<"$index" || fail "no theme.css link"
curl -fsS "$url/static/theme.css" >/dev/null || fail "theme.css not served"

summary=$(fetch '?p=team/nested.git;a=summary')
! grep -qi 'gravatar' <<<"$index$summary$blob" || fail "gravatar reference"
! grep -Eq '(src|href|action)="https?://' <<<"$index$summary$blob" || fail "absolute link to a foreign host"
grep -q '<td>git@example.org:team/nested.git</td>' <<<"$summary" || fail "clone link is not git@example.org:team/nested.git"
! grep -q 'git@example.org:/' <<<"$summary" || fail "clone link has an absolute path"

! grep -Eq 'a=(snapshot|blame)|st=(grep|pickaxe)' <<<"$summary$blob" || fail "link to a disabled feature"
status() { curl -s -o /dev/null -w '%{http_code}' "$url/?p=team/nested.git;$1"; }
[ "$(status 'a=commit;h=HEAD')" = 200 ] || fail "commit page not served"
for action in 'a=snapshot;h=HEAD;sf=tgz' 'a=search;st=grep;s=hello;h=HEAD' 'a=search;st=pickaxe;s=hello;h=HEAD' \
    'a=blame;f=hello.py;hb=HEAD'; do
    [ "$(status "$action")" = 403 ] || fail "feature not disabled: $action"
done

headers=$(curl -fsS -o /dev/null -D - "$url/?p=team/nested.git;a=blob_plain;f=page.html;hb=HEAD")
grep -qi '^content-type: text/plain' <<<"$headers" || grep -qi '^content-disposition: attachment' <<<"$headers" ||
    fail "blob_plain serves repository HTML neither as text/plain nor as attachment"

! docker exec "$container" touch /srv/repositories/x 2>/dev/null || fail "repositories are writable"

echo PASS
