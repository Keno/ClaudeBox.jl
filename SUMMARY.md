# ClaudeSandboxApp - Summary

This is a complete Julia application following the Pkg.jl app format that runs claude-code in an isolated sandbox environment.

## Structure

```
ClaudeSandboxApp/
├── Project.toml          # Package manifest with dependencies
├── src/
│   └── ClaudeSandboxApp.jl  # Main application code
├── bin/
│   └── claude-sandbox    # Executable entry point
├── test/
│   └── runtests.jl       # Test suite
├── README.md             # User documentation
└── SUMMARY.md            # This file
```

## Key Features

1. **Pkg.jl App Format**: Follows Julia's standard application structure
   - Entry point in `bin/claude-sandbox`
   - Main code in `src/ClaudeSandboxApp.jl`
   - `julia_main()` function as the application entry

2. **Sandboxing**: Uses Sandbox.jl to create isolated Linux namespaces
   - Mounts current directory as `/workspace`
   - Provides Debian rootfs environment
   - Isolates file system access

3. **JLL Integration**: Uses JLLPrefixes.jl to deploy Node.js
   - NodeJS_22_jll provides Node.js v22
   - Binaries deployed to scratch space
   - Persistent across sessions

4. **Scratch Spaces**: Uses Scratch.jl for persistent storage
   - Node.js installation cached
   - npm packages cached
   - claude-code installation persisted

## Usage

### Run from the app directory:
```bash
./bin/claude-sandbox
```

### Install system-wide:
```bash
sudo ln -s $(pwd)/bin/claude-sandbox /usr/local/bin/claude-sandbox
```

### Command-line options:
- `-h, --help`: Show help message
- `-v, --version`: Show version (1.0.0)
- `-w, --work-dir DIR`: Mount DIR as /workspace
- `--reset`: Clear all cached data

### Environment:
- `ANTHROPIC_API_KEY`: Required for claude-code

## Implementation Details

1. **Entry Point** (`bin/claude-sandbox`):
   - Sets up Julia environment
   - Loads the app module
   - Calls `julia_main()`

2. **Main Module** (`src/ClaudeSandboxApp.jl`):
   - Parses command-line arguments
   - Initializes scratch spaces
   - Deploys Node.js if needed
   - Creates sandbox configuration
   - Installs claude-code if requested
   - Runs sandboxed session

3. **Sandbox Configuration**:
   - Mounts: `/` (rootfs), `/opt/nodejs`, `/opt/npm`, `/workspace`
   - Environment: PATH, HOME, NODE_PATH, npm configs, API key
   - Executes either claude-code or bash

## Testing

Run tests with:
```bash
julia --project=. test/runtests.jl
```

Tests cover:
- Argument parsing
- State initialization
- Basic functionality

## Dependencies

- Sandbox.jl (main branch) - Containerization
- JLLPrefixes.jl - JLL deployment
- Scratch.jl - Persistent storage
- NodeJS_22_jll - Node.js binaries

All managed through Julia's package system.