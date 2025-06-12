module ClaudeBox

using Sandbox
using JLLPrefixes
using Scratch
using NodeJS_22_jll

export main

# Terminal colors
const GREEN = "\033[32m"
const YELLOW = "\033[33m"
const RED = "\033[31m"
const BLUE = "\033[34m"
const CYAN = "\033[36m"
const RESET = "\033[0m"
const BOLD = "\033[1m"

# Constants
const CLAUDE_SCRATCH_KEY = "claude_code_sandbox_app"
const VERSION = "1.0.0"

# Helper functions for colored output
cprint(color, text) = print(color, text, RESET)
cprintln(color, text) = println(color, text, RESET)

mutable struct AppState
    prefix_dir::String
    nodejs_dir::String
    npm_dir::String
    claude_home_dir::String
    work_dir::String
    claude_installed::Bool
    api_key_set::Bool
end

"""
    main(args=ARGS)

Main entry point for the ClaudeBox application.
"""
function (@main)(args::Vector{String})::Cint
    try
        return _main(args)
    catch e
        if e isa InterruptException
            cprintln(YELLOW, "\nSession interrupted.")
            return 0
        else
            cprintln(RED, "Error: $e")
            return 1
        end
    end
end

function _main(args::Vector{String})::Cint
    # Parse command line arguments
    options = parse_args(args)

    if options["help"]
        print_help()
        return 0
    end

    if options["version"]
        println("ClaudeBox v$VERSION")
        return 0
    end

    # Show banner
    print_banner()

    # Reset if requested
    if options["reset"]
        reset_environment()
    end

    # Initialize application state
    state = initialize_state(options["work_dir"])

    # Check prerequisites
    if !check_prerequisites(state)
        cprintln(YELLOW, "\nProceeding without API key...")
    end

    # Setup environment
    setup_environment!(state)

    # Create and run sandbox
    run_sandbox(state)

    cprintln(GREEN, "\nGoodbye!")
    return 0
end

function parse_args(args::Vector{String})
    options = Dict{String,Any}(
        "help" => false,
        "version" => false,
        "reset" => false,
        "work_dir" => pwd()
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ["--help", "-h"]
            options["help"] = true
        elseif arg in ["--version", "-v"]
            options["version"] = true
        elseif arg == "--reset"
            options["reset"] = true
        elseif arg in ["--work-dir", "-w"]
            if i < length(args)
                i += 1
                dir = expanduser(args[i])
                if !isdir(dir)
                    cprintln(RED, "Error: Directory does not exist: $dir")
                    exit(1)
                end
                options["work_dir"] = abspath(dir)
            else
                cprintln(RED, "Error: --work-dir requires an argument")
                exit(1)
            end
        else
            cprintln(RED, "Unknown option: $arg")
            print_help()
            exit(1)
        end
        i += 1
    end

    return options
end

function print_banner()
    println()
    cprintln(CYAN, "╔════════════════════════════════════════════════╗")
    cprintln(CYAN, "║      🚀 Claude Sandbox Environment v$VERSION      ║")
    cprintln(CYAN, "╚════════════════════════════════════════════════╝")
    println()
end

function print_help()
    println("""
    ClaudeBox - Run claude-code in an isolated environment

    $(BOLD)USAGE:$(RESET)
        claudebox [OPTIONS]

    $(BOLD)OPTIONS:$(RESET)
        -h, --help          Show this help message
        -v, --version       Show version information
        -w, --work-dir DIR  Directory to mount as /workspace (default: current)
        --reset             Reset the sandbox environment

    $(BOLD)ENVIRONMENT:$(RESET)
        ANTHROPIC_API_KEY   Your Anthropic API key (required for claude-code)

    $(BOLD)EXAMPLES:$(RESET)
        # Run with current directory
        claudebox

        # Run with specific directory
        claudebox -w ~/my-project

        # Reset environment
        claudebox --reset

    $(BOLD)INSIDE THE SANDBOX:$(RESET)
        Your files are mounted at: /workspace
        Node.js is available at: /opt/nodejs/bin/node
        NPM is available at: /opt/nodejs/bin/npm
        Claude-code is automatically installed on first run
    """)
end

function initialize_state(work_dir::String)::AppState
    prefix = @get_scratch!(CLAUDE_SCRATCH_KEY)
    nodejs_dir = joinpath(prefix, "nodejs")
    npm_dir = joinpath(prefix, "npm")
    claude_home_dir = joinpath(prefix, "claude_home")

    # Check if claude is installed
    claude_bin = joinpath(npm_dir, "bin", "claude")
    claude_installed = isfile(claude_bin)

    # Check API key
    api_key_set = !isempty(get(ENV, "ANTHROPIC_API_KEY", ""))

    return AppState(prefix, nodejs_dir, npm_dir, claude_home_dir, work_dir, claude_installed, api_key_set)
end

function check_prerequisites(state::AppState)::Bool
    println("Checking prerequisites...")

    if state.api_key_set
        cprintln(GREEN, "  ✓ ANTHROPIC_API_KEY is set")
    else
        cprintln(YELLOW, "  ⚠ ANTHROPIC_API_KEY not set")
        println("    You can use console authentication or set an API key:")
        println("    export ANTHROPIC_API_KEY=your-key")
        println("    Get a key at: https://console.anthropic.com/")
    end

    println()
    return state.api_key_set
end

function reset_environment()
    cprintln(YELLOW, "Resetting sandbox environment...")
    clear_scratchspaces!(@__MODULE__)
    cprintln(GREEN, "✓ Environment reset complete")
    println()
end

function setup_environment!(state::AppState)
    cprint(BLUE, "Setting up environment...")

    # Create directories
    mkpath(state.nodejs_dir)
    mkpath(joinpath(state.npm_dir, "bin"))
    mkpath(joinpath(state.npm_dir, "lib"))
    mkpath(joinpath(state.npm_dir, "cache"))
    mkpath(state.claude_home_dir)

    # Create claude.json file if it doesn't exist
    claude_json_path = joinpath(state.prefix_dir, "claude.json")
    if !isfile(claude_json_path)
        write(claude_json_path, "{}")
    end

    # Check if Node.js is installed
    node_bin = joinpath(state.nodejs_dir, "bin", "node")
    if !isfile(node_bin)
        println()
        cprintln(YELLOW, "  Installing Node.js v22...")
        artifact_paths = collect_artifact_paths(["NodeJS_22_jll"])
        deploy_artifact_paths(state.nodejs_dir, artifact_paths)
        cprintln(GREEN, "  ✓ Node.js installed")
    else
        cprintln(GREEN, " Done!")
    end

    # Check if claude is installed
    claude_bin = joinpath(state.npm_dir, "bin", "claude")
    state.claude_installed = isfile(claude_bin)

    if state.claude_installed
        cprintln(GREEN, "✓ claude-code is already installed")
    else
        # Try to install claude-code automatically
        println()
        cprintln(YELLOW, "Installing claude-code...")
        println("  This may take a few minutes on first run...")

        # Create sandbox config for installation
        config = create_sandbox_config(state)

        success = Sandbox.with_executor() do exe
            try
                # Configure npm to reduce output
                run(exe, config, `/bin/sh -c "echo 'fund=false\naudit=false\nprogress=false' > /opt/npm/.npmrc"`)

                # Install claude-code with output
                run(exe, config, `/opt/nodejs/bin/npm install -g @anthropic-ai/claude-code`)

                # Workaround for https://github.com/anthropics/claude-code/issues/927
                # The UID check gives wrong values in sandboxed environments
                cli_path = "/opt/npm/lib/node_modules/@anthropic-ai/claude-code/claude-code/cli.js"
                run(exe, config, `/bin/sh -c "sed -i 's/process\\.getuid()===0/false/g' $cli_path"`)

                cprintln(GREEN, "✓ claude-code installed successfully!")
                return true
            catch e
                cprintln(RED, "✗ Failed to install claude-code automatically")
                println("  Error: $e")
                println("\n  You can try installing manually inside the sandbox:")
                println("  $(BOLD)npm install -g @anthropic-ai/claude-code$(RESET)")
                return false
            end
        end

        state.claude_installed = success
    end

    println()
end

function create_sandbox_config(state::AppState; stdin=Base.devnull)::Sandbox.SandboxConfig
    # Prepare mounts using MountInfo
    mounts = Dict{String, Sandbox.MountInfo}(
        "/" => Sandbox.MountInfo(Sandbox.debian_rootfs(), Sandbox.MountType.Overlayed),
        "/opt/nodejs" => Sandbox.MountInfo(state.nodejs_dir, Sandbox.MountType.ReadOnly),
        "/opt/npm" => Sandbox.MountInfo(state.npm_dir, Sandbox.MountType.ReadWrite),
        "/workspace" => Sandbox.MountInfo(state.work_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude" => Sandbox.MountInfo(state.claude_home_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude.json" => Sandbox.MountInfo(joinpath(state.prefix_dir, "claude.json"), Sandbox.MountType.ReadWrite)
    )

    # Add resolv.conf for DNS resolution if it exists
    if isfile("/etc/resolv.conf")
        resolv_conf_copy = joinpath(state.prefix_dir, "resolv.conf")
        try
            cp("/etc/resolv.conf", resolv_conf_copy; force=true, follow_symlinks=true)
            mounts["/etc/resolv.conf"] = Sandbox.MountInfo(resolv_conf_copy, Sandbox.MountType.ReadOnly)
        catch
            # If we can't copy resolv.conf, continue without it
        end
    end

    Sandbox.SandboxConfig(
        # Mounts
        mounts,
        # Environment
        Dict(
            "PATH" => "/opt/npm/bin:/opt/nodejs/bin:/usr/bin:/bin",
            "HOME" => "/root",
            "NODE_PATH" => "/opt/npm/lib/node_modules",
            "npm_config_prefix" => "/opt/npm",
            "npm_config_cache" => "/opt/npm/cache",
            "npm_config_userconfig" => "/opt/npm/.npmrc",
            "ANTHROPIC_API_KEY" => get(ENV, "ANTHROPIC_API_KEY", ""),
            "TERM" => get(ENV, "TERM", "xterm-256color"),
            "LANG" => "C.UTF-8",
            "USER" => "root"
        ); stdin
    )
end

function run_sandbox(state::AppState)
    config = create_sandbox_config(state)

    # Print session info
    cprintln(CYAN, "════════════════════════════════════════")
    cprintln(CYAN, "      Starting Sandbox Session")
    cprintln(CYAN, "════════════════════════════════════════")
    println()

    println("📁 Workspace: $(BOLD)/workspace$(RESET) → $(state.work_dir)")
    println("🚪 Exit with: $(BOLD)exit$(RESET) or $(BOLD)Ctrl+D$(RESET)")

    # Always use bash, but prepare to launch claude if appropriate
    if state.claude_installed
        println("\n🤖 Starting $(BOLD)claude$(RESET) interactive session...")
        println("   Type your prompts and claude will respond")
        println("   Use $(BOLD)exit$(RESET) to return to bash shell")
        if !state.api_key_set
            cprintln(YELLOW, "\n⚠  No ANTHROPIC_API_KEY detected - using console authentication")
        end
    else
        println("\n🐚 Starting $(BOLD)bash$(RESET) shell...")
        println("\n📦 Available tools:")
        println("   $(BOLD)node$(RESET)  - Node.js v22")
        println("   $(BOLD)npm$(RESET)   - Node Package Manager")
        println("\n💡 To install claude-code:")
        println("   $(BOLD)npm install -g @anthropic-ai/claude-code$(RESET)")
    end

    cmd = `/bin/bash --login`

    println()

    interactive_config = create_sandbox_config(state; stdin=Base.stdin)

    # Run the sandbox
    Sandbox.with_executor() do exe
        # Create a nice prompt and ensure PATH is set for bash
        if cmd.exec[1] == "/bin/bash"
            # Base bashrc content
            bashrc_content = """
# Claude Sandbox environment
export PS1="\\[\\033[32m\\][sandbox]\\[\\033[0m\\] \\w \\\$ "
export PATH="/opt/npm/bin:/opt/nodejs/bin:/usr/bin:/bin:/usr/local/bin"

# Helpful aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
"""

            # Add auto-launch for claude if installed
            if state.claude_installed
                bashrc_content *= """

# Auto-launch claude
if [ -z "\$CLAUDE_LAUNCHED" ]; then
    export CLAUDE_LAUNCHED=1
    cd /workspace
    claude --dangerously-skip-permissions
    echo ""
    echo "🐚 Returned to bash shell. Run 'claude --dangerously-skip-permissions' to start claude again."
fi
"""
            end

            run(exe, config, `/bin/sh -c "cat > /root/.bashrc << 'EOF'
$bashrc_content
EOF"`)
        end

        run(exe, interactive_config, cmd)
    end
end

end # module ClaudeBox