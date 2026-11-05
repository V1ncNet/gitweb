#!/usr/bin/env bash
# Runs the image like the pod does and checks the web view of bare repositories, including the
# verification of signed commits and tags. Needs docker, git, curl, gpg and ssh-keygen.
set -euo pipefail

image=${1:?usage: smoke.sh <image>}
port=${SMOKE_PORT:-28080}
work=$(mktemp -d)
container=gitweb-smoke-$$
repos=$work/repositories
site=$work/site.conf
broken_site=$work/broken-site.conf
mime_types=$work/mime.types
keys=$work/keys
url=http://127.0.0.1:$port

# Signing settings of the machine running the test, such as commit.gpgsign, must not leak into the repositories.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

cleanup() {
    status=$?
    [ "$status" -eq 0 ] || docker logs "$container" 2>&1 | tail -20
    docker rm -f "$container" >/dev/null 2>&1 || true
    for home in "$keys"/gnupg-*; do
        [ -d "$home" ] && GNUPGHOME=$home gpgconf --kill all >/dev/null 2>&1 || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

create_repository() {
    local path=$1 source=$work/source-$$
    rm -rf "$source"
    git -c init.defaultBranch=main init -q "$source"
    printf 'def hello():\n    return "world"\n' >"$source/hello.py"
    printf '<script>alert(1)</script>\n' >"$source/page.html"
    printf 'export const hello = (): string => "world";\n' >"$source/hello.ts"
    printf 'FROM alpine\nRUN echo hello\n' >"$source/Dockerfile"
    git -C "$source" add hello.py page.html hello.ts Dockerfile
    git -C "$source" -c user.name=Smoke -c user.email=smoke@example.invalid commit -q -m Smoke
    mkdir -p "$(dirname "$repos/$path")"
    git clone -q --bare "$source" "$repos/$path"
    rm -rf "$source"
}

# Throwaway keys: a trusted and a foreign one per format. The trusted ones carry markup in the signer.
create_keys() {
    mkdir -p "$keys"
    for name in trusted foreign; do
        mkdir -m 700 "$keys/gnupg-$name"
        ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$keys/ssh-$name"
    done
    GNUPGHOME=$keys/gnupg-trusted gpg -q --batch --passphrase '' \
        --quick-gen-key 'Smoke <b>PGP</b> <trusted@example.invalid>' ed25519 sign never 2>/dev/null
    GNUPGHOME=$keys/gnupg-foreign gpg -q --batch --passphrase '' \
        --quick-gen-key 'Foreign <foreign@example.invalid>' ed25519 sign never 2>/dev/null
    GNUPGHOME=$keys/gnupg-trusted gpg --armor --export >"$keys/trusted-keys.asc"
    printf 'smoke<b>ssh</b>@example.invalid namespaces="git" %s\n' "$(cat "$keys/ssh-trusted.pub")" \
        >"$keys/allowed_signers"
    chmod 644 "$keys/trusted-keys.asc" "$keys/allowed_signers"
}

# signed.git: commits signed with each key plus an unsigned one, and a signed tag per format.
# Sets commit_<case> and tag_<format> to the object names.
create_signed_repository() {
    local source=$work/source-signed
    git -c init.defaultBranch=main init -q "$source"
    signed() {
        local mode=$1 key=$2
        shift 2
        if [ "$mode" = pgp ]; then
            GNUPGHOME=$keys/gnupg-$key git -C "$source" -c user.name=Smoke -c user.email=smoke@example.invalid \
                -c gpg.format=openpgp -c user.signingkey="$key@example.invalid" "$@"
        else
            git -C "$source" -c user.name=Smoke -c user.email=smoke@example.invalid \
                -c gpg.format=ssh -c user.signingkey="$keys/ssh-$key" "$@"
        fi
    }
    for case in pgp:trusted ssh:trusted none: pgp:foreign ssh:foreign; do
        IFS=: read -r mode key <<<"$case"
        if [ "$mode" = none ]; then
            git -C "$source" -c user.name=Smoke -c user.email=smoke@example.invalid commit -q --allow-empty -m unsigned
            commit_unsigned=$(git -C "$source" rev-parse HEAD)
        else
            signed "$mode" "$key" commit -q -S --allow-empty -m "$mode $key"
            printf -v "commit_${mode}_$key" '%s' "$(git -C "$source" rev-parse HEAD)"
        fi
    done
    signed pgp trusted tag -s -m 'PGP tag' v-pgp
    signed ssh trusted tag -s -m 'SSH tag' v-ssh
    tag_pgp=$(git -C "$source" rev-parse v-pgp)
    tag_ssh=$(git -C "$source" rev-parse v-ssh)
    git clone -q --bare "$source" "$repos/signed.git"
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
create_keys
create_signed_repository
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
for file in hello.ts Dockerfile; do
    fetch "?p=team/nested.git;a=blob;f=$file" | grep -q '<span class="hl ' || fail "$file not highlighted"
done

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

# Signatures. page <action> <object> fetches a page of signed.git, badge <html> <state> <format> checks its badge.
page() { fetch "?p=signed.git;a=$1;h=$2"; }
badge() { grep -q "<span class=\"signature_badge signature_$2\"><span class=\"signature_format\">$3</span>" <<<"$1"; }
key_mounts=(-v "$keys/trusted-keys.asc:/etc/gitweb.d/trusted-keys.asc:ro"
    -v "$keys/allowed_signers:/etc/gitweb.d/allowed_signers:ro")
printf '#!/bin/sh\ntouch /tmp/verification-ran\nexit 2\n' >"$keys/spy"
chmod 755 "$keys/spy"
printf '$feature{"signatures"}{"default"} = [1];\n' >"$work/signatures-on.conf"
printf '$feature{"signatures"}{"default"} = [0];\n' >"$work/signatures-off.conf"
chmod 644 "$work/signatures-on.conf" "$work/signatures-off.conf"

# Off by default: no badge, the tag keeps its raw signature block, and neither gpgv nor ssh-keygen runs.
start_container "${key_mounts[@]}" -v "$keys/spy:/usr/local/bin/gpgv-git:ro" -v "$keys/spy:/usr/bin/ssh-keygen:ro"
off=""
for object in "$commit_pgp_trusted" "$commit_ssh_trusted" "$commit_pgp_foreign" "$commit_ssh_foreign"; do
    off+=$(page commit "$object")$(page commitdiff "$object")
done
off+=$(page tag "$tag_pgp")$(page tag "$tag_ssh")
! grep -q 'signature_\|<td>signature</td>' <<<"$off" || fail "signature shown although the feature is off"
grep -q 'BEGIN&nbsp;PGP&nbsp;SIGNATURE' <<<"$off" || fail "PGP tag without its signature block although the feature is off"
grep -q 'BEGIN&nbsp;SSH&nbsp;SIGNATURE' <<<"$off" || fail "SSH tag without its signature block although the feature is off"
! docker exec "$container" test -e /tmp/verification-ran || fail "verification program ran although the feature is off"

# On through the environment with both key files.
start_container -e GITWEB_SIGNATURES=1 "${key_mounts[@]}"
html=$(page commit "$commit_pgp_trusted")
badge "$html" valid PGP || fail "PGP commit with trusted key not valid"
grep -q 'Smoke &lt;b&gt;PGP&lt;/b&gt; &lt;trusted@example.invalid&gt;' <<<"$html" || fail "PGP signer missing or not escaped"
! grep -q '<b>PGP</b>' <<<"$html" || fail "PGP signer not escaped"
grep -q '<span class="signature_key">key [0-9A-F]\{40\}</span>' <<<"$html" || fail "PGP fingerprint missing"
badge "$(page commitdiff "$commit_pgp_trusted")" valid PGP || fail "PGP commitdiff with trusted key not valid"
html=$(page commit "$commit_ssh_trusted")
badge "$html" valid SSH || fail "SSH commit with trusted key not valid"
grep -q 'smoke&lt;b&gt;ssh&lt;/b&gt;@example.invalid' <<<"$html" || fail "SSH principal missing or not escaped"
! grep -q '<b>ssh</b>' <<<"$html" || fail "SSH principal not escaped"
grep -q '<span class="signature_key">key SHA256:' <<<"$html" || fail "SSH fingerprint missing"
! grep -q 'signature_' <<<"$(page commit "$commit_unsigned")" || fail "unsigned commit shows a signature"
badge "$(page commit "$commit_pgp_foreign")" unknown PGP || fail "PGP commit with foreign key not unknown"
badge "$(page commit "$commit_ssh_foreign")" unknown SSH || fail "SSH commit with foreign key not unknown"
for format in pgp ssh; do
    tag_object=tag_$format
    html=$(page tag "${!tag_object}")
    badge "$html" valid "${format^^}" || fail "${format^^} tag not valid"
    grep -q "${format^^}&nbsp;tag" <<<"$html" || fail "${format^^} tag lost its message"
    ! grep -q 'SIGNATURE-----' <<<"$html" || fail "${format^^} tag still shows its signature block"
done
lists=$(fetch '?p=signed.git;a=log')$(fetch '?p=signed.git;a=shortlog')$(fetch '?p=signed.git;a=tags')
! grep -q 'signature_' <<<"$lists" || fail "list view shows signatures"
[ -z "$(docker exec "$container" ls /tmp)" ] || fail "verification leaves files in /tmp"

# On through the site file without key files: signed commits and tags have unknown keys, no error page.
start_container -v "$work/signatures-on.conf:/etc/gitweb.d/site.conf:ro"
for target in "commit:$commit_pgp_trusted" "commit:$commit_ssh_trusted" "tag:$tag_pgp" "tag:$tag_ssh"; do
    IFS=: read -r action object <<<"$target"
    html=$(page "$action" "$object") || fail "$action $object without key files not served"
    ! grep -q '500 - Internal Server Error' <<<"$html" || fail "$action $object without key files shows an error page"
    grep -q 'signature_badge signature_unknown' <<<"$html" || fail "$action $object without key files not unknown"
done

# The site file wins over the environment.
start_container -e GITWEB_SIGNATURES=1 "${key_mounts[@]}" -v "$work/signatures-off.conf:/etc/gitweb.d/site.conf:ro"
! grep -q 'signature_' <<<"$(page commit "$commit_pgp_trusted")" || fail "site file does not override GITWEB_SIGNATURES"

start_container -e GITWEB_SIGNATURES=yes
invalid=$(curl -sS "$url/")
grep -q 'GITWEB_SIGNATURES must be 0 or 1' <<<"$invalid" || fail "invalid GITWEB_SIGNATURES does not show an error"

echo PASS
