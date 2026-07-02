# ClaudeBox

[![CI](https://github.com/Keno/ClaudeBox.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/Keno/ClaudeBox.jl/actions/workflows/ci.yml)

A Julia application that runs claude-code in an isolated sandbox environment using Linux namespaces.

## Important Notes

⚠️ **This code was largely written by Claude and has not been thoroughly reviewed.** Use at your own risk.

🛡️ **Security Notice**: This sandbox is **NOT** intended to protect against malicious escape attempts. It is designed only to prevent claude from accidentally causing damage to the host system during normal operation.

🎯 **Purpose**: This tool is intended to make it easy for users with Julia installed to run claude-code in a sandboxed environment with minimal setup.

## Features

- 🔒 **Isolated Environment**: Runs claude-code in a sandboxed container
- 📁 **Workspace Mounting**: Your current directory is mounted as `/workspace`
- 📦 **Integrated Node.js**: Includes Node.js v22 via JLL packages
- 💾 **Persistent Storage**: JLL prefixes and npm packages are stored in scratch spaces
- 🚀 **Automatic Setup**: Automatically installs Node.js and claude-code
- 🖥️ **Interactive Session**: Full stdin/stdout/stderr support for interactive commands
- 🔑 **In-session GitHub token refresh**: The host keeps GitHub tokens fresh for long-running sandbox sessions

## Installation

### Option 1: Install via Pkg.Apps (Recommended)

```julia
using Pkg
Pkg.Apps.add(url="https://github.com/Keno/ClaudeBox.jl")
```

This will automatically install the `claudebox` executable to your Julia depot's bin directory.

### Option 2: Manual Installation

1. Clone this repository:
```bash
git clone https://github.com/Keno/ClaudeBox.jl
cd ClaudeBox
```

2. Install dependencies:
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

3. The executable is located at `bin/claudebox`

## Usage

### Basic Usage

Run claude-code with your current directory mounted:
```bash
./bin/claudebox
```

### Mount a Different Directory

```bash
./bin/claudebox -w ~/my-project
```

### Claude Code Profiles

Use a named profile to keep Claude Code login and settings separate, for
example for work and personal accounts:

```bash
./bin/claudebox --profile work
./bin/claudebox --profile personal
```

Profiles use separate `~/.claude` settings and `~/.claude.json` login state
inside the sandbox. Project history remains shared across profiles.

### Codex History

When running with `--codex`, ClaudeBox reuses your shared Codex login,
settings, rules, and plugins from `~/.codex` when available. Prompt history,
session transcripts, and shell snapshots are separated per workspace folder so
work on different projects does not share Codex history.

### Reset Environment

Clear all cached data and reinstall:
```bash
./bin/claudebox --reset
```

Reset only the Julia depot (packages and registries):
```bash
./bin/claudebox --reset-julia
```

Reset everything including Claude settings:
```bash
./bin/claudebox --reset-all
```

### GitHub Authentication with Broader Permissions

By default, GitHub authentication uses minimal permissions. For broader access including repository creation:
```bash
./bin/claudebox --dangerous-github-auth
```

⚠️ **Warning**: This mode grants elevated permissions. Use with caution.

### Help

```bash
./bin/claudebox --help
```

## Requirements

- Julia 1.6 or higher
- Linux with user namespaces support
- Internet connection (for first-time claude-code installation)
- Anthropic API key (set as `ANTHROPIC_API_KEY` environment variable)

## Environment Variables

- `ANTHROPIC_API_KEY`: Your Anthropic API key (required for claude-code)

## Inside the Sandbox

When you run the app, you'll enter a sandboxed environment where:

- Your files are available at `/workspace`
- Various development tools are pre-installed and available
- claude-code is automatically installed on first run

## Personal Claude Sandbox Repository

If you have a repository named `.claude_sandbox` in your GitHub account, ClaudeBox will automatically:

1. Clone or update the repository on each launch
2. Mount it at `/root/.claude_sandbox` in the sandbox
3. Reference any `CLAUDE_SANDBOX.md` file in the default Claude instructions

This allows you to maintain personal configurations, custom instructions, or project templates that Claude will have access to in every session.

To use this feature:
1. Create a repository named `.claude_sandbox` in your GitHub account
2. Add a `CLAUDE_SANDBOX.md` file with your custom instructions
3. ClaudeBox will automatically detect and use it

## GitHub Token Refresh

GitHub OAuth access tokens expire after a few hours, which can interrupt long
sessions. ClaudeBox keeps the long-lived refresh token on the host, refreshes
the access token before it expires, and writes only the current access token to
a small read-only file mounted into the sandbox.

The sandbox's `git` credential helper and `gh` wrapper read that token file each
time they run, so token renewal is transparent during long sessions. This is
wired up automatically whenever GitHub authentication is active; no
configuration is required. The refresh token never enters the sandbox.

## How It Works

1. Uses Sandbox.jl to create isolated Linux namespace containers
2. Deploys Node.js from NodeJS_22_jll using JLLPrefixes.jl
3. Stores persistent data in Julia scratch spaces
4. Mounts your working directory into the sandbox
5. Runs claude-code or bash in the isolated environment

## Troubleshooting

### "No such file or directory" errors
Make sure you're using full paths for executables (e.g., `/bin/echo` instead of `echo`)

### Network issues
The sandbox may have network restrictions. If npm install fails, check your network configuration.

### Permission denied
Ensure your system supports unprivileged user namespaces:
```bash
sysctl kernel.unprivileged_userns_clone
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
