# Contributing to Virtual Office

Thanks for your interest in contributing! This project welcomes contributions of all kinds — bug fixes, features, documentation, and ideas.

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run the tests (`Get-ChildItem tests/Test-*.ps1 | ForEach-Object { pwsh -File $_ }`)
5. Commit and push
6. Open a Pull Request

## Contributor License Agreement

By submitting a pull request or otherwise contributing to this project, you agree to the following:

- Your contributions are licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**, consistent with the project's license.
- You grant the project author (**Josh Xu**) a perpetual, worldwide, non-exclusive, royalty-free, irrevocable right to use, modify, sublicense, and relicense your contributions under any license, including proprietary licenses.
- You represent that you have the legal right to make these contributions and grant these rights.

This allows the project author to offer dual licensing (e.g., commercial licenses) without requiring individual approval from every contributor.

## Guidelines

- **ASCII only** in PowerShell (.ps1) files
- **Atomic writes** for all state files (write .tmp, then rename)
- **No secrets** — never commit credentials, tokens, or API keys
- Run existing tests before submitting — don't break what works
