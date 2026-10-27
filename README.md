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

The image is built for `linux/arm64`.

## Releases

Every push to `main` publishes a new patch version to Docker Hub as `vinado/gitweb`. Labelling the merged pull request
with `release:minor` or `release:major` raises that part of the version instead.

## License

[MIT](LICENSE)
