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

## Moving from Newman

Current Rill can run supported imported requests and native workflow checks. It does not execute arbitrary Postman pre-request/test JavaScript, accept `--env-var` overrides or accept separate certificate/key file arguments for collection runs. A successful imported request run does not establish that the original scripted suite passed.

Direct file execution and explicit compatibility are [roadmap priorities](https://github.com/alby-raju/Rill/blob/main/ROADMAP.md). Keep Newman as the reference for suites depending on unsupported scripting. See the authoritative [CLI reference](https://github.com/alby-raju/Rill/blob/main/docs/CLI.md) and `rill --help` for supported options.
