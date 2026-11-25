# Development

`services/`, `install/` and `targets/` are the sources; after editing embedded
`services/` or `install/` files, run `tools/sync-embedded.py --write`.
`bash tests/run-tests.sh` runs every suite (`--list` names them; give one name
to run one). Root-only target cases skip without root; CI runs with `--strict`.
See [tests/README.md](tests/README.md).

To run CI (`.gitea/workflows/tests.yml`) in Gitea, enable Actions and register
an `act_runner` with an ubuntu-latest style image whose job containers run as
root (`--strict` fails on skipped root-only tests). `.github/workflows/tests.yml`
is the same file for GitHub Actions, where the suites run through `sudo`;
`tests/test-repo.sh` keeps the two identical. The `strata-upstream`,
`maya-upstream`, `xolotl-upstream`, `avalon-upstream`, `kindi-upstream`, `colibri-upstream`, `polystrata-upstream`, `freellmapi-upstream` and
`honcho-upstream` jobs also need GitHub (and PyPI) access.
