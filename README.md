# gitweb

A read-only web view of bare Git repositories. The image runs gitweb behind lighttpd, with syntax highlighting and a
theme for phones, desktop and dark mode.

## Usage

```sh
docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --user 1001:1001 -p 8080:8080 \
    -v /path/to/repositories:/srv/repositories:ro vinado/gitweb:latest
```

- Mount the bare repositories read-only at `/srv/repositories`. Nested directories work.
- The web server listens on port `8080`.
- The container runs as UID and GID `1001`. The repositories need to belong to the same user, otherwise Git refuses to
  read them.
- The root filesystem can be read-only. Only `/tmp` has to be writable.
- Site name and clone links come from an optional Perl file mounted at `/etc/gitweb.d/site.conf`, for example
  `our $site_name = "Example"; our @git_base_url_list = ('git@example.org:');`. Without it the site is called "gitweb"
  and shows no clone links.
- The image has no login. Put it behind a proxy that authenticates your users.

## Signed commits and tags

gitweb can verify OpenPGP and SSH signatures and show the result as a badge on the commit, commitdiff and tag pages.
List views such as log and shortlog never verify. The feature is off by default. Switch it on with the environment
variable `GITWEB_SIGNATURES=1`:

```sh
docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --user 1001:1001 -p 8080:8080 -e GITWEB_SIGNATURES=1 \
    -v /path/to/repositories:/srv/repositories:ro \
    -v /path/to/trusted-keys.asc:/etc/gitweb.d/trusted-keys.asc:ro \
    -v /path/to/allowed_signers:/etc/gitweb.d/allowed_signers:ro vinado/gitweb:latest
```

Or in the site file, which wins over the variable, so `[0]` there switches it off again:

```perl
$feature{'signatures'}{'default'} = [1];
```

`GITWEB_SIGNATURES` accepts `0` and `1`. Any other value makes every page show an error naming the variable.

The image contains no keys. Mount the ones you trust:

- `/etc/gitweb.d/trusted-keys.asc`: OpenPGP public keys, ASCII-armored, as many as you like, for example from
  `gpg --armor --export alice@example.org bob@example.org > trusted-keys.asc`.
- `/etc/gitweb.d/allowed_signers`: SSH keys in the format of `ssh-keygen -Y` and Git's `gpg.ssh.allowedSignersFile`,
  for example `alice@example.org namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…`.

A signature made with a key that is not in these files, or a format whose file is missing, shows as "unknown key".
gitweb never fetches keys from a keyserver.

The image is built for `linux/arm64`.

## Releases

Every push to `main` publishes a new patch version to Docker Hub as `vinado/gitweb`. Labelling the merged pull request
with `release:minor` or `release:major` raises that part of the version instead.

## License

[MIT](LICENSE)
