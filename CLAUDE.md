# CLAUDE.md

Guidance for coding agents working in this repository. The README covers what the image is and how to use it.

## Layout

| Path | Purpose |
|-|-|
| `Dockerfile` | Alpine with `git-gitweb`, `gpgv`, `highlight`, `lighttpd`, `openssh-keygen` and `perl-cgi`. Creates user `git` (1001:1001), patches `gitweb.cgi`, installs `gpgv-git` and generates `/etc/gitweb-highlight.pl`. Sets `GITWEB_SIGNATURES=0` |
| `lighttpd.conf` | Serves `gitweb.cgi` as CGI on port 8080 and static files from the document root `/usr/share/gitweb`, logs to `stderr`. Hands `GITWEB_SIGNATURES` to the CGI |
| `gitweb.conf` | Installed as `/etc/gitweb.conf`, which gitweb reads by default. Sets project root, neutral site name, stylesheet, `$prevent_xss`, features and the Git configuration for signature checks, turns `GITWEB_SIGNATURES` into the `signatures` default, then loads the generated highlight map and the optional site file |
| `gitweb-signatures.patch` | Unified diff against Alpine's `gitweb.cgi`, applied with `git apply` during the build. Adds the feature `signatures`: badge with the verification result on the commit, commitdiff and tag pages |
| `gpgv-git.pl` | Installed as `/usr/local/bin/gpgv-git`, Git's OpenPGP program. Runs `gpgv` against `/etc/gitweb.d/trusted-keys.asc` |
| `highlight-types.pl` | Runs during the build and prints `%highlight_ext` and `%highlight_basename` entries for every syntax the installed `highlight` knows |
| `static/theme.css` | Installed as `/usr/share/gitweb/static/theme.css`, served at `/static/theme.css`. Layout for phones and desktop plus dark mode on top of gitweb's own stylesheet |
| `tests/smoke.sh` | Starts the image like the pod does, without and with a site file, and checks pages of two bare repositories over HTTP. Signs a third repository with throwaway PGP and SSH keys and checks the signature badges in every way to switch them on |
| `tests/screenshots.mjs` | Playwright screenshots of the main pages at 390 and 1440 pixels, light and dark, with layout assertions. Optionally a signed commit and tag |
| `.github/workflows/deploy.yml` | Smoke test, release and push to Docker Hub, zizmor and dependency review on pull requests |
| `.github/workflows/scan.yml` | Daily Trivy scan of `vinado/gitweb:1` |
| `.github/dependabot.yml` | Weekly updates of Docker and actions with seven days of cooldown, grouped into one pull request per ecosystem because every merge to `main` releases |

## Testing locally

```sh
docker build --platform linux/arm64 -t local/gw:test .
tests/smoke.sh local/gw:test
nix shell nixpkgs#zizmor --command zizmor .github/workflows/
```

The image exists for `linux/arm64` only. `smoke.sh` listens on port `28080`, override it with `SMOKE_PORT`. It needs
`gpg` and `ssh-keygen` on the host to sign the test repository and ignores the host's global and system Git
configuration. Fetch missing tools ad hoc with `nix shell nixpkgs#<tool>`.

`tests/screenshots.mjs` needs a running container with real repositories mounted, a Playwright installation outside
the repository and these environment variables. The script names no repositories itself:

```sh
GITWEB_URL=http://127.0.0.1:28090 \
PLAYWRIGHT_MODULE=/path/to/node_modules/playwright/index.mjs \
GW_TREE_PROJECT=team/app.git GW_TREE_PATH=src/model \
GW_BLOB_PROJECT=team/tools.git GW_BLOB_PATH=scripts/check.py GW_LONG_BLOB_PATH=config/settings.yml \
GW_COMMIT_PROJECT=team/app.git GW_COMMIT=1a2b3c4 \
    node tests/screenshots.mjs /path/to/screenshots
```

| Variable | Page |
|-|-|
| `GW_TREE_PROJECT`, `GW_TREE_PATH` | Tree of a subdirectory |
| `GW_BLOB_PROJECT`, `GW_BLOB_PATH` | File that `highlight` colors, for example Python or shell, and its history |
| `GW_LONG_BLOB_PATH` | File in `GW_BLOB_PROJECT` with lines longer than 120 characters |
| `GW_COMMIT_PROJECT`, `GW_COMMIT` | Summary, heads, log, shortlog, commit and commitdiff, ideally a commit with long lines and removed lines |

Optionally, on a container started with `GITWEB_SIGNATURES=1` and the key files, `GW_SIGNED_PROJECT` with
`GW_SIGNED_COMMIT` and/or `GW_SIGNED_TAG` add the pages `signed-commit` and `signed-tag`. They fail without a badge, if
the badge reaches past the viewport, has no mark besides its color or has a light background in dark mode.

At 390 and at 1440 pixels it fails if a page scrolls sideways or if a dark page, code block, added or removed diff
line or chunk header has a light background. It also fails if the highlighted file keeps its light syntax colors in
dark mode. Body text must be at least 16 pixels on the phone and at least gitweb's default of 13 pixels on the desktop.
Look at the screenshots too.

## Runtime constraints

- The container runs as UID and GID `1001` with a read-only root filesystem and no capabilities. Only `/tmp` is
  writable.
- `lighttpd` listens on port `8080`. The repositories are mounted read-only at `/srv/repositories`.
- The image has no authentication. A login proxy in front of it provides that.

## Why things are as they are

- `gitweb` joins the base URL and the project with a `/`. `git@example.org:` plus `team/x.git` would become the
  absolute path `git@example.org:/team/x.git`. The `Dockerfile` therefore rewrites `map { "$_/$project" }` in
  `gitweb.cgi` to `map { "$_$project" }`, and the build fails if the pattern no longer matches. The smoke test asserts
  the resulting clone link.
- The base URL `git@example.org:~` would clone, but `git-lfs-transfer` does not resolve `~`, so `git lfs pull` fails.
  `cloneurl` files are out, because they would live on the repositories volume.
- The features `snapshot`, `pickaxe`, `grep` and `blame` are switched off explicitly, because Alpine's `gitweb.cgi`
  enables `snapshot`, `pickaxe` and `grep` by default. That shrinks the attack surface behind the login. The smoke test
  expects status 403 for each of them.
- `$prevent_xss = 1` makes `blob_plain` send repository HTML and SVG as plain text instead of rendering it inline.
  The image has no `/etc/mime.types`, so gitweb would fall back to `text/plain` even without the setting. The smoke
  test therefore mounts a `mime.types` that maps `html` to `text/html`, requests an HTML file through `blob_plain` and
  expects `text/plain` or an attachment. With `$prevent_xss = 0` the same request returns `text/html` and fails.
- The page loads nothing from other hosts. `avatar` is off to avoid Gravatar, and `$logo_url` points to `/`, so no link
  leaves the site either. The smoke test checks for absolute URLs.
- User `git` has the same UID as the owner of the repositories. Git otherwise rejects them as "dubious ownership".
- `static/theme.css` is plain CSS and only overrides `gitweb.css`, so gitweb updates keep working. Colors, spacing,
  sizes and fonts are custom properties on `:root`. The rules contain no literal colors, lengths or font sizes. Dark
  mode redefines the colors under `prefers-color-scheme` without a toggle. Syntax colors target `.hl.<class>`, because
  `highlight` emits `<span class="hl …">` and `gitweb.css` styles the bare classes.
- On phones the shortlog, history, search, heads, tags and diff file lists are laid out as grid or flex rows. Chromium
  then exposes those tables as layout tables without cells, which is accepted because they have no header row anyway.
- gitweb's built-in `%highlight_ext` only knows a few old file types, so `.ts`, `.rs`, `.yml` and many more stayed
  plain. `highlight-types.pl` reads `highlight --list-scripts=langs` during the build, because that list already
  resolves extensions claimed by several languages the way the `highlight` CLI does. The first language that claims an
  extension wins, so `.ms`, `.pas` and `.v` go to MiniScript, Delphi and Verilog as on the CLI. A language name maps to
  itself only where no other language claims it as an extension. `.make` maps to `makefile`. `txt` and `text` stay
  plain. Basenames come from the `Filenames` entries of `/etc/highlight/filetypes.conf` plus `Dockerfile`,
  `Containerfile`, `Jenkinsfile` and the Makefile names. gitweb's own `Makefile => 'make'` points to a syntax that
  `highlight` 4 no longer has. Generating at build time keeps the request path free of extra work and follows
  `highlight` upgrades automatically. The build fails if TypeScript is missing from the list or if `filetypes.conf`
  yields no `Filenames`. The smoke test checks `hello.ts` and a `Dockerfile`.
- Signature verification is a patch, not subs redefined in `gitweb.conf`. The config is evaluated with `do` after
  gitweb has compiled, so redefining `git_commit` or wrapping `git_print_authorship_rows` would work, but a copied sub
  goes stale silently on a `git-gitweb` update, and a wrapper notices a changed call site only at runtime, if ever.
  `git apply` refuses any hunk whose context no longer matches, without fuzz, so the build fails instead. The smoke
  test catches the rest: a badge that no longer appears.
- `gitweb-signatures.patch` is made against `gitweb/gitweb.perl` of the Git version Alpine ships, with the
  substitutions of gitweb's `generate-gitweb-cgi.sh` for `prefix=/usr`. To refresh it, apply it to the new
  `gitweb.cgi` from the image, resolve the rejects and write the diff with `diff -u --label a/gitweb.cgi --label
  b/gitweb.cgi`.
- The feature `signatures` is off by default. Off, gitweb starts no `gpgv` and no `ssh-keygen`, and the pages are
  unchanged. That includes the tag page, which keeps showing the raw signature block in the comment, as unpatched
  gitweb does. Dropping the block without verifying it would hide that the tag is signed and replace it with nothing.
  On, the block gives way to the badge. The smoke test mounts a spy over both programs to prove they stay idle.
- Only the commit, commitdiff and tag pages verify. Every check starts `git`, which starts `gpgv` or `ssh-keygen` and
  writes a temporary file, so a log page with 100 signed commits would start 200 processes per request.
- `parse_commit_text` records the format from the `gpgsig` header, so unsigned commits cost no extra process. Signed
  commits run `git log -1 --format=%G?…`. Tags have no `%G?`, `%(signature)` of `for-each-ref` reads commits only, so
  the patch runs `git verify-tag --raw` and parses its output the way `gpg-interface.c` does.
- `gpgv` instead of `gpg` with a `GNUPGHOME` in `/tmp`. `gpg` would need a fresh home per request, because CGI requests
  run in parallel, plus an import of the keys, a trust database and ownertrust, and it brings `dirmngr` and keyserver
  code. `gpgv` has no state, no agent and no network code. Every key in its keyring is trusted. It reads only binary
  keyrings, not from a pipe, and rejects Git's `--keyid-format=long` and `--verify`. `gpgv-git` therefore drops
  both, decodes the armored keys into a keyring of its own in `/tmp` (one file per call, removed afterwards) and adds
  `TRUST_FULLY` after a good signature, so Git reports `G` instead of `U`.
- Git's `check_signature` starts at trust level `undefined`, so a good signature without a trust line is `U`. SSH
  gives `G` for a principal from the allowed signers file and `U` for any other key. Without
  `gpg.ssh.allowedSignersFile` Git does not verify SSH at all and reports `N`, as if unsigned, so `gitweb.conf` always
  sets it, and a missing file yields `U`. A missing PGP key yields `E`. The badge maps `G` to "Good signature", `U` to
  "Good signature, unknown key", `E` and `N` to "Unknown key, not verified", `B` to "Bad signature" and `X`, `Y`, `R`
  to an expired signature, an expired or a revoked key. An SSH key outside its `valid-after`/`valid-before` window
  fails `ssh-keygen` and shows as bad.
- The Git configuration for verification is passed with `-c` from `@signature_git_config`, never through a gitconfig
  in a home directory, which the read-only root filesystem would not allow anyway. `-c` also beats a
  `gpg.openpgp.program` or `gpg.ssh.program` in a repository's own config. `log.showSignature` is overridden with
  `--no-show-signature`.
- Nothing fetches keys. `gpgv` cannot, and `ssh-keygen -Y` only reads the allowed signers file. Unknown keys stay
  unknown, so the page still loads nothing from other hosts.
- lighttpd's `mod_cgi` starts the CGI with the request variables only, not with the container environment, not even
  `PATH`. `lighttpd.conf` therefore reads `env.GITWEB_SIGNATURES` and adds it with `mod_setenv`. lighttpd refuses to
  start if a variable named with `env.` is missing, so the `Dockerfile` sets `GITWEB_SIGNATURES=0`. `gitweb.conf`
  treats unset or empty as 0 and dies with "GITWEB_SIGNATURES must be 0 or 1" on any other value than 0 and 1.
- Signer, principal and key are escaped with `esc_html`. A PGP user ID is chosen by whoever made the key, and the
  smoke test signs with a key and a principal containing `<b>`.
- The `Dockerfile` runs `apk upgrade` before `apk add`, so a rebuild picks up fixed versions of packages the base image
  already ships, such as `libcrypto3` and `musl`.

## Site file

- The image contains no deployment details. `gitweb.conf` sets the site name "gitweb" and no clone URL base, so
  without a site file the summary page shows no clone link.
- `gitweb.conf` ends by evaluating `/etc/gitweb.d/site.conf` with Perl's `do` if the file exists, after the generated
  highlight map. It can set or override any gitweb variable, typically `$site_name` and `@git_base_url_list`, and
  also entries of the highlight map. In Kubernetes a ConfigMap is mounted there.
- A syntax error or an unreadable file makes gitweb show its page "500 - Internal Server Error" with the Perl message
  instead of serving the defaults silently. gitweb still answers with HTTP status 200, so the deployment has to catch
  a broken file itself, for example with `perl -c` on the ConfigMap or an exec probe that greps the page.
- gitweb's `read_config_file` dies on a set `$!` after evaluating `/etc/gitweb.conf`, before it looks at `$@`. The `-e`
  test leaves `ENOENT` in `$!` when the file is missing, and `do` can leave a stale value. `include_config_file` in
  `gitweb.conf` therefore collects the error first, resets `$!` and only then dies, so the message naming the file
  comes through.
- `gitweb.conf` sets `$feature{'signatures'}{'default'}` from `GITWEB_SIGNATURES` before it loads the site file. So
  `$feature{'signatures'}{'default'} = [1];` in the site file switches verification on and `[0]` switches it off, even
  against `GITWEB_SIGNATURES=1`.
- Keys are mounted, the image contains none. `/etc/gitweb.d/trusted-keys.asc` holds ASCII-armored OpenPGP public keys,
  several blocks in a row are fine. `/etc/gitweb.d/allowed_signers` uses the format of `ssh-keygen -Y`, one
  `principal namespaces="git" key` per line. A missing file makes signatures of that format "unknown", not an error.
  In Kubernetes the site file and both key files can be keys of one ConfigMap mounted at `/etc/gitweb.d`.
- `tests/smoke.sh` checks the default site name and the missing clone link without a site file. With a broken site
  file it expects the error page and the file name. With its own valid site file it checks the site name and the exact
  clone link `git@example.org:team/nested.git`. For signatures it checks the feature off with both key files and spies
  on `gpgv-git` and `ssh-keygen`, on through `GITWEB_SIGNATURES=1` with both key files, on through the site file
  without key files, the site file's `[0]` against `GITWEB_SIGNATURES=1` and an invalid value.

## Releases

- Every push to `main` releases the next patch version. The label `release:minor` or `release:major` on the merged
  pull request raises that part and resets the lower ones to 0.
- Pushes that only touch `README.md`, `CLAUDE.md`, `.github/workflows/scan.yml` or `.github/dependabot.yml` do not
  release (the `paths-ignore` of `deploy.yml`). Every other push to `main` does, including pushes that only touch
  `tests/`.
- `deploy.yml` looks up the pull request of the pushed commit and retries up to five times while GitHub has not linked
  it yet. An API error fails the step. Without a pull request the release is a patch.
- The workflow pushes `vinado/gitweb` with the tags `<major>`, `<major>.<minor>`, `<version>` and `latest`, then tags
  the commit `v<version>`. `latest` comes from the default flavor `latest=auto` of the docker metadata action, which
  also omits the `<major>` tag while the major version is 0. The first pull request carries `release:major`, so
  `v1.0.0` and the tag `1` exist when `scan.yml` reaches `main`.
- `scan.yml` fails on fixable high or critical findings and sorts them by the Trivy result class. Findings of class
  `os-pkgs` start `deploy.yml` by `workflow_dispatch`, which rebuilds the latest tag with fixed Alpine packages. Every
  other finding, such as one in a language package (`lang-pkgs`), survives a rebuild. The `scan` job opens the issue
  "Vulnerabilities a rebuild cannot fix" for those, listing CVE, package, installed and fixed version. It needs
  `issues: write` for that. At most one such issue is open. A later scan updates it and closes it once no finding
  outside `os-pkgs` remains. A mixed result starts the rebuild and updates the issue. A scan error fails the run
  without a rebuild and leaves the issue as it is. The `follow-up` job re-enables `scan.yml` on every run, so GitHub
  does not disable it after 60 days without commits. It needs `actions: write` for that.

## Conventions

- Commit messages follow the seven rules by Chris Beams and are written in English.
- Workflows pin actions to a commit with the version in a trailing comment and must pass zizmor. Values reach `run:`
  through `env:`, never through `${{ }}`.
- Images are pinned by tag and digest in the `Dockerfile`.
