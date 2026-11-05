# CLI quick start

The installed macOS app includes the CLI at `/Applications/Rill.app/Contents/Helpers/rill`. No separate download is needed.

## Enable the command in every zsh terminal

Run once:

```sh
grep -qxF "alias rill='/Applications/Rill.app/Contents/Helpers/rill'" ~/.zshrc ||
  echo "alias rill='/Applications/Rill.app/Contents/Helpers/rill'" >> ~/.zshrc
source ~/.zshrc
rill --version
rill --help
```

This alias is for interactive zsh sessions. In scripts and CI, use the explicit executable path or install a CLI binary on PATH when standalone distribution becomes available. Adjust the app path if installed elsewhere.

## Find saved collections and run one

```sh
rill list
rill search "Smoke"
rill run-collection "Smoke" --detail
```

Replace `Smoke` with a real collection name or ID. These commands send actual requests to the configured endpoints. By default the CLI uses the desktop workspace. For automation, export and use a separate native workspace file:

```sh
rill run-collection "Smoke" \
  --workspace ./workspace.json \
  --environment "Local" \
  --detail \
  --report ./results.json --report-format json
```

The environment is a saved name/ID, not an environment-file path. Report files are exclusive unless `--overwrite` is supplied. Ctrl+C cancels a run. Exit statuses include 0 success, 2 configuration/input, 3 runtime, 4 checks failed and 130 cancellation.

## Run a collection file in 0.4.5

Run offline preflight first, then send requests if the file is supported.

```sh
rill preflight ./collection.json --environment-file ./environment.json --json
rill run ./collection.json --environment-file ./environment.json \
  --env-var region=local --report ./file-results.json --report-format json
```

Postman v2 file runs support exact nested folder selection, explicit globals, JSON/CSV iteration data, and file-based TLS. For a native workspace file, use `rill run ./workspace.json --format native --collection "Smoke"`. Native runs support saved Rill workflow checks; the Postman file path checks for HTTP 2xx and blocks foreign scripts before sending traffic. Use the [CLI reference](https://github.com/alby-raju/Rill/blob/main/docs/CLI.md) for syntax, precedence, TLS scope, and unsupported inputs.
