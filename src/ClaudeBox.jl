module ClaudeBox

using Sandbox
using JLLPrefixes
using Scratch
using NodeJS_22_jll
using gh_cli_jll
using Git_jll
using MozillaCACerts_jll
using juliaup_jll
using JSON
using HTTP

include("github_auth.jl")
using .GitHubAuth

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
const TOOLS_SCRATCH_KEY = "claude_code_sandbox_tools"
const CLAUDE_SCRATCH_KEY = "claude_code_sandbox_settings"
const VERSION = "1.0.0"

# Helper functions for colored output
cprint(color, text) = print(color, text, RESET)
cprintln(color, text) = println(color, text, RESET)

mutable struct AppState
    tools_prefix::String
    claude_prefix::String
    nodejs_dir::String
    npm_dir::String
    gh_cli_dir::String
    git_dir::String
    juliaup_dir::String
    julia_dir::String
    claude_home_dir::String
    work_dir::String
    claude_installed::Bool
    github_token::String
    github_refresh_token::Union{String, Nothing}
    claude_args::Vector{String}
    keep_bash::Bool
end

"""
    main(args=ARGS)

Main entry point for the ClaudeBox application.
"""
function (@main)(args::Vector{String})::Cint
    # Enable Ctrl+C handling
    Base.exit_on_sigint(false)
    
    try
        return _main(args)
    catch e
        if e isa InterruptException
            cprintln(YELLOW, "\nSession interrupted.")
            return 0
        else
            cprintln(RED, "Error: $e")
            Base.display_error(stderr, e, catch_backtrace())
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
        reset_tools()
    elseif options["reset_all"]
        reset_all()
    end

    # Initialize application state
    state = initialize_state(options["work_dir"], options["claude_args"], options["bash"])

    # Handle GitHub authentication (enabled by default)
    if !options["no_github_auth"]
        # Check if existing token is valid
        if !isempty(state.github_token)
            if GitHubAuth.validate_token(state.github_token; silent=true)
                cprintln(GREEN, "✓ Using existing valid GitHub token")
            else
                # Try to refresh the token if we have a refresh token
                if !isnothing(state.github_refresh_token) && !isempty(state.github_refresh_token)
                    cprintln(YELLOW, "Access token expired, attempting to refresh...")
                    refresh_response = GitHubAuth.refresh_access_token(state.github_refresh_token)
                    if !isnothing(refresh_response)
                        state.github_token = refresh_response.access_token
                        state.github_refresh_token = refresh_response.refresh_token
                        save_github_tokens(state.claude_prefix, state.github_token, state.github_refresh_token)
                        token_path = joinpath(state.claude_prefix, "github_tokens.json")
                        cprintln(GREEN, "✓ GitHub token refreshed successfully")
                        cprintln(CYAN, "   Token location: $(token_path)")
                    else
                        cprintln(YELLOW, "Failed to refresh token, requesting new authentication...")
                        state.github_token = ""
                        state.github_refresh_token = nothing
                    end
                else
                    cprintln(YELLOW, "Existing GitHub token is invalid, requesting new authentication...")
                    state.github_token = ""
                    state.github_refresh_token = nothing
                end
            end
        end

        # Authenticate if we don't have a valid token
        if isempty(state.github_token)
            println("\n🔐 $(BOLD)GitHub Authentication$(RESET)")
            println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            println("This will securely authorize access to your GitHub repositories")
            println("without requiring a full personal access token. The app will only")
            println("have access to repositories you explicitly grant permission to.")
            println()
            println("To skip authentication, use --no-github-auth")
            println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

            try
                token_response = GitHubAuth.authenticate()
                if GitHubAuth.validate_token(token_response.access_token)
                    state.github_token = token_response.access_token
                    state.github_refresh_token = token_response.refresh_token
                    save_github_tokens(state.claude_prefix, state.github_token, state.github_refresh_token)
                    token_path = joinpath(state.claude_prefix, "github_tokens.json")
                    cprintln(GREEN, "✓ GitHub authenticated and token saved")
                    cprintln(YELLOW, "\n⚠️  Warning: Your GitHub token has been persisted to disk.")
                    println("   Token location: $(token_path)")
                    println("   It will be automatically used in future sessions.")
                    println("   Use --reset-all to remove the stored token.")
                    println()
                else
                    cprintln(RED, "Failed to authenticate with GitHub")
                    return 1
                end
            catch e
                if isa(e, InterruptException)
                    cprintln(YELLOW, "\nGitHub authentication skipped. Proceeding without GitHub access.")
                    println()
                elseif isa(e, HTTP.RequestError) && isa(e.error, InterruptException)
                    cprintln(YELLOW, "\nGitHub authentication interrupted. Proceeding without GitHub access.")
                    println()
                else
                    rethrow(e)
                end
            end
        end
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
        "reset_all" => false,
        "work_dir" => pwd(),
        "no_github_auth" => false,
        "bash" => false,
        "claude_args" => String[]
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
        elseif arg == "--reset-all"
            options["reset_all"] = true
        elseif arg == "--no-github-auth"
            options["no_github_auth"] = true
        elseif arg == "--bash"
            options["bash"] = true
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
            # Collect unrecognized arguments to pass to claude
            push!(options["claude_args"], arg)
            # If this looks like a flag with a value, grab the next arg too
            if startswith(arg, "-") && i < length(args) && !startswith(args[i+1], "-")
                i += 1
                push!(options["claude_args"], args[i])
            end
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
        --reset             Reset tools (Node.js, npm, git, gh) but keep Claude settings
        --reset-all         Reset everything including Claude settings
        --no-github-auth    Skip GitHub authentication (enabled by default)
        --bash              Keep bash shell open after claude exits

    Unrecognized flags are passed through to the claude command.

    $(BOLD)EXAMPLES:$(RESET)
        # Run with current directory
        claudebox

        # Run with specific directory
        claudebox -w ~/my-project

        # Reset environment
        claudebox --reset

        # Pass arguments to claude
        claudebox --model claude-3-sonnet-20240229
        claudebox --continue

    $(BOLD)INSIDE THE SANDBOX:$(RESET)
        Your files are mounted at: /workspace
        Node.js is available at: /opt/nodejs/bin/node
        NPM is available at: /opt/nodejs/bin/npm
        Git is available at: /opt/git/bin/git
        GitHub CLI is available at: /opt/gh_cli/bin/gh
        juliaup is available at: /opt/juliaup/bin/juliaup
        Claude-code is automatically installed on first run
    """)
end

function initialize_state(work_dir::String, claude_args::Vector{String}=String[], keep_bash::Bool=false)::AppState
    tools_prefix = @get_scratch!(TOOLS_SCRATCH_KEY)
    claude_prefix = @get_scratch!(CLAUDE_SCRATCH_KEY)

    nodejs_dir = joinpath(tools_prefix, "nodejs")
    npm_dir = joinpath(tools_prefix, "npm")
    gh_cli_dir = joinpath(tools_prefix, "gh_cli")
    git_dir = joinpath(tools_prefix, "git")
    juliaup_dir = joinpath(tools_prefix, "juliaup")
    julia_dir = joinpath(tools_prefix, "julia")
    claude_home_dir = joinpath(claude_prefix, "claude_home")

    # Ensure directories exist, otherwise the mount will fail
    for dir in (nodejs_dir, npm_dir, gh_cli_dir, git_dir, juliaup_dir, julia_dir, claude_home_dir)
        mkpath(dir)
    end

    # Check if claude is installed
    claude_bin = joinpath(npm_dir, "bin", "claude")
    claude_installed = isfile(claude_bin)

    # Load existing GitHub tokens if available
    tokens = load_github_tokens(claude_prefix)

    return AppState(tools_prefix, claude_prefix, nodejs_dir, npm_dir, gh_cli_dir, git_dir, juliaup_dir, julia_dir, claude_home_dir, work_dir, claude_installed, tokens.access_token, tokens.refresh_token, claude_args, keep_bash)
end


function reset_tools()
    cprintln(YELLOW, "Resetting tools (keeping Claude settings)...")
    scratch_path = scratch_dir(TOOLS_SCRATCH_KEY)
    if isdir(scratch_path)
        rm(scratch_path; recursive=true, force=true)
    end
    cprintln(GREEN, "✓ Tools reset complete")
    println()
end

function reset_all()
    cprintln(YELLOW, "Resetting everything (tools and Claude settings)...")
    clear_scratchspaces!(@__MODULE__)
    cprintln(GREEN, "✓ Full reset complete")
    println()
end

function save_github_tokens(claude_prefix::String, access_token::String, refresh_token::Union{String, Nothing}=nothing)
    token_file = joinpath(claude_prefix, "github_tokens.json")
    tokens = Dict(
        "access_token" => access_token,
        "refresh_token" => refresh_token
    )
    write(token_file, JSON.json(tokens))
end

function load_github_tokens(claude_prefix::String)
    token_file = joinpath(claude_prefix, "github_tokens.json")
    if isfile(token_file)
        try
            tokens = JSON.parsefile(token_file)
            return (
                access_token = get(tokens, "access_token", ""),
                refresh_token = get(tokens, "refresh_token", nothing)
            )
        catch
            # Invalid JSON file
            return (access_token = "", refresh_token = nothing)
        end
    end
    
    return (access_token = "", refresh_token = nothing)
end

function setup_environment!(state::AppState)
    cprint(BLUE, "Setting up environment...")

    # Create directories
    mkpath(state.nodejs_dir)
    mkpath(joinpath(state.npm_dir, "bin"))
    mkpath(joinpath(state.npm_dir, "lib"))
    mkpath(joinpath(state.npm_dir, "cache"))
    mkpath(state.gh_cli_dir)
    mkpath(state.git_dir)
    mkpath(state.claude_home_dir)

    # Create claude.json file if it doesn't exist
    claude_json_path = joinpath(state.claude_prefix, "claude.json")
    if !isfile(claude_json_path)
        write(claude_json_path, "{}")
    end

    # Create a global gitconfig with SSL settings and user info
    gitconfig_path = joinpath(state.tools_prefix, "gitconfig")
    if !isfile(gitconfig_path) || !isempty(state.github_token)
        # Get user info from GitHub if we have a token
        user_name = "Sandbox User"
        user_email = "sandbox@localhost"

        if !isempty(state.github_token)
            user_info = GitHubAuth.get_user_info(state.github_token)
            if !isnothing(user_info.name) && !isempty(user_info.name)
                user_name = user_info.name
            elseif !isnothing(user_info.login) && !isempty(user_info.login)
                user_name = user_info.login
            end

            if !isnothing(user_info.email) && !isempty(user_info.email)
                user_email = user_info.email
            elseif !isnothing(user_info.login) && !isempty(user_info.login)
                user_email = "$(user_info.login)@users.noreply.github.com"
            end
        end

        write(gitconfig_path, """
[http]
    sslCAInfo = /etc/ssl/certs/ca-certificates.crt
[user]
    name = $user_name
    email = $user_email
""")
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

    # Check if gh CLI is installed
    gh_bin = joinpath(state.gh_cli_dir, "bin", "gh")
    if !isfile(gh_bin)
        cprintln(YELLOW, "  Installing GitHub CLI...")
        artifact_paths = collect_artifact_paths(["gh_cli_jll"])
        deploy_artifact_paths(state.gh_cli_dir, artifact_paths)
        cprintln(GREEN, "  ✓ GitHub CLI installed")
    end

    # Check if Git is installed
    git_bin = joinpath(state.git_dir, "bin", "git")
    if !isfile(git_bin)
        cprintln(YELLOW, "  Installing Git...")
        artifact_paths = collect_artifact_paths(["Git_jll"])
        deploy_artifact_paths(state.git_dir, artifact_paths)
        cprintln(GREEN, "  ✓ Git installed")
    end

    # Check if juliaup is installed
    juliaup_bin = joinpath(state.juliaup_dir, "bin", "juliaup")
    if !isfile(juliaup_bin)
        cprintln(YELLOW, "  Installing juliaup...")
        artifact_paths = collect_artifact_paths(["juliaup_jll"])
        deploy_artifact_paths(state.juliaup_dir, artifact_paths)
        cprintln(GREEN, "  ✓ juliaup installed")
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
                cli_path = "/opt/npm/lib/node_modules/@anthropic-ai/claude-code/cli.js"
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
        "/opt/gh_cli" => Sandbox.MountInfo(state.gh_cli_dir, Sandbox.MountType.ReadOnly),
        "/opt/git" => Sandbox.MountInfo(state.git_dir, Sandbox.MountType.ReadOnly),
        "/opt/juliaup" => Sandbox.MountInfo(state.juliaup_dir, Sandbox.MountType.ReadOnly),
        "/workspace" => Sandbox.MountInfo(state.work_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude" => Sandbox.MountInfo(state.claude_home_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude.json" => Sandbox.MountInfo(joinpath(state.claude_prefix, "claude.json"), Sandbox.MountType.ReadWrite),
        "/root/.gitconfig" => Sandbox.MountInfo(joinpath(state.tools_prefix, "gitconfig"), Sandbox.MountType.ReadWrite),
        "/root/.julia" => Sandbox.MountInfo(state.julia_dir, Sandbox.MountType.ReadWrite)
    )

    # Add resolv.conf for DNS resolution if it exists
    if isfile("/etc/resolv.conf")
        resolv_conf_copy = joinpath(state.tools_prefix, "resolv.conf")
        try
            cp("/etc/resolv.conf", resolv_conf_copy; force=true, follow_symlinks=true)
            mounts["/etc/resolv.conf"] = Sandbox.MountInfo(resolv_conf_copy, Sandbox.MountType.ReadOnly)
        catch
            # If we can't copy resolv.conf, continue without it
        end
    end

    # Add CA certificates for HTTPS connections
    cacert_file = MozillaCACerts_jll.cacert
    if isfile(cacert_file)
        # Copy the certificate to scratch space
        ssl_certs_dir = joinpath(state.tools_prefix, "ssl_certs")
        mkpath(ssl_certs_dir)
        cacert_copy = joinpath(ssl_certs_dir, "ca-certificates.crt")
        cp(cacert_file, cacert_copy; force=true)

        # Also create a ca-bundle.crt symlink (some tools look for this)
        ca_bundle_link = joinpath(ssl_certs_dir, "ca-bundle.crt")
        rm(ca_bundle_link; force=true)
        symlink("ca-certificates.crt", ca_bundle_link)

        # Mount the directory
        mounts["/etc/ssl/certs"] = Sandbox.MountInfo(ssl_certs_dir, Sandbox.MountType.ReadOnly)
    end

    Sandbox.SandboxConfig(
        # Mounts
        mounts,
        # Environment
        Dict(
            # Note: PATH is set in bashrc instead - passing it here gets overwritten by the sandbox
            "HOME" => "/root",
            "NODE_PATH" => "/opt/npm/lib/node_modules",
            "npm_config_prefix" => "/opt/npm",
            "npm_config_cache" => "/opt/npm/cache",
            "npm_config_userconfig" => "/opt/npm/.npmrc",
            "ANTHROPIC_API_KEY" => get(ENV, "ANTHROPIC_API_KEY", ""),
            "GITHUB_TOKEN" => state.github_token,
            "TERM" => get(ENV, "TERM", "xterm-256color"),
            "LANG" => "C.UTF-8",
            "USER" => "root",
            "SSL_CERT_FILE" => "/etc/ssl/certs/ca-certificates.crt",
            "SSL_CERT_DIR" => "/etc/ssl/certs",
            "GIT_SSL_CAINFO" => "/etc/ssl/certs/ca-certificates.crt",
            "JULIA_DEPOT_PATH" => "/root/.julia",
            "GIT_SSL_CAPATH" => "/etc/ssl/certs",
            "CURL_CA_BUNDLE" => "/etc/ssl/certs/ca-certificates.crt"
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
        if state.keep_bash
            println("   Use $(BOLD)exit$(RESET) to return to bash shell")
        else
            println("   Use $(BOLD)exit$(RESET) to leave the sandbox")
        end
    else
        println("\n🐚 Starting $(BOLD)bash$(RESET) shell...")
        println("\n📦 Available tools:")
        println("   $(BOLD)node$(RESET)  - Node.js v22")
        println("   $(BOLD)npm$(RESET)   - Node Package Manager")
        println("   $(BOLD)git$(RESET)   - Git version control")
        println("   $(BOLD)gh$(RESET)    - GitHub CLI")
        println("\n💡 To install claude-code:")
        println("   $(BOLD)npm install -g @anthropic-ai/claude-code$(RESET)")
    end

    cmd = `/bin/bash --login`

    println()

    interactive_config = create_sandbox_config(state; stdin=Base.stdin)

    # Run the sandbox
    Sandbox.with_executor() do exe
        # Create CLAUDE.md in the sandbox root
        claude_md_content = """
# ClaudeBox Sandbox Environment

You are running inside a ClaudeBox sandbox - a secure, isolated environment.

## Environment Details

- **Workspace**: Your files are mounted at `/workspace`
- **Isolation**: This is a sandboxed environment with limited system access
- **Tools Available**:
  - Node.js and npm for JavaScript development
  - Git for version control
  - GitHub CLI (gh) for GitHub operations
  - Standard Unix tools

## Important Notes

- You have full read/write access to `/workspace`
- System directories are read-only or overlayed
- Network access is available
- The environment resets when you exit (except for `/workspace`)

## GitHub Integration

$(isempty(state.github_token) ? "- No GitHub authentication configured" : "- GitHub authenticated - you can use git and gh commands")

## Tips

- Use the workspace directory for all file operations
- Git commits will use the configured user name and email
- The sandbox provides a consistent, clean environment
"""

        run(exe, config, `/bin/sh -c "cat > /CLAUDE.md << 'EOF'
$claude_md_content
EOF"`)

        # Create a nice prompt and ensure PATH is set for bash
        if cmd.exec[1] == "/bin/bash"
            # Base bashrc content
            bashrc_content = """
# Claude Sandbox environment
export PS1="\\[\\033[32m\\][sandbox]\\[\\033[0m\\] \\w \\\$ "
export PATH="/opt/npm/bin:/opt/nodejs/bin:/opt/gh_cli/bin:/opt/git/bin:/opt/git/libexec/git-core:/opt/juliaup/bin:/usr/bin:/bin:/usr/local/bin"

# Helpful aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
"""

            # Add auto-launch for claude if installed
            if state.claude_installed
                # Prepare claude args as a shell-escaped string
                claude_args_str = ""
                if !isnothing(state.claude_args) && !isempty(state.claude_args)
                    claude_args_str = " " * join(["\$(printf '%q' '$arg')" for arg in state.claude_args], " ")
                end

                if state.keep_bash
                    bashrc_content *= """

# Auto-launch claude
if [ -z "\$CLAUDE_LAUNCHED" ]; then
    export CLAUDE_LAUNCHED=1
    cd /workspace
    claude --dangerously-skip-permissions$claude_args_str
    echo ""
    echo "🐚 Returned to bash shell. Run 'claude --dangerously-skip-permissions' to start claude again."
fi
"""
                else
                    bashrc_content *= """

# Auto-launch claude and exit
if [ -z "\$CLAUDE_LAUNCHED" ]; then
    export CLAUDE_LAUNCHED=1
    cd /workspace
    claude --dangerously-skip-permissions$claude_args_str
    exit
fi
"""
                end
            end

            run(exe, config, `/bin/sh -c "cat > /root/.bashrc << 'EOF'
$bashrc_content
EOF"`)
        end

        run(exe, interactive_config, cmd)
    end
end

end # module ClaudeBox
