# ClaudeBox

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

## Installation

### Option 1: Install via Pkg.Apps (Recommended)

```julia
using Pkg
Pkg.Apps.add(url="<repository-url>")
```

This will automatically install the `claudebox` executable to your Julia depot's bin directory.

### Option 2: Manual Installation

1. Clone this repository:
```bash
git clone <repository-url>
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

### Reset Environment

Clear all cached data and reinstall:
```bash
./bin/claudebox --reset
```

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
- Node.js is available at `/opt/nodejs/bin/node`
- NPM is available at `/opt/nodejs/bin/npm`
- claude-code is available at `/opt/npm/bin/claude` (after installation)

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