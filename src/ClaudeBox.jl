module ClaudeBox

using Sandbox
using JLLPrefixes
using Scratch
using NodeJS_22_jll
using gh_cli_jll
using Git_jll
using GNUMake_jll
using MozillaCACerts_jll
using juliaup_jll
using ripgrep_jll
using Python_jll
using JSON
using HTTP
using REPL.Terminals: raw!, TTYTerminal

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
    build_tools_dir::String
    juliaup_dir::String
    julia_dir::String
    claude_home_dir::String
    work_dir::String
    claude_installed::Bool
    github_token::String
    github_refresh_token::Union{String, Nothing}
    claude_args::Vector{String}
    keep_bash::Bool
    claude_sandbox_dir::Union{String, Nothing}
    dangerous_github_auth::Bool
end

"""
    main(args=ARGS)

Main entry point for the ClaudeBox application.
"""
function monitor_stdin_for_interrupt(auth_task::Task)
    @async begin
        term = TTYTerminal("", stdin, stdout, stderr)
        raw_mode = raw!(term, true)
        try
            while !istaskdone(auth_task)
                b = read(stdin, 1)
                if b[1] == 0x03  # Ctrl+C
                    schedule(auth_task, InterruptException(), error=true)
                    break
                end
            end
        catch
            # Monitor task ended
        finally
            # Restore terminal settings
            raw!(term, raw_mode)
        end
    end
end

function (@main)(args::Vector{String})::Cint
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
    state = initialize_state(options["work_dir"], options["claude_args"], options["bash"], options["dangerous_github_auth"])

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
                    refresh_response = GitHubAuth.refresh_access_token(state.github_refresh_token; dangerous_mode=state.dangerous_github_auth)
                    if !isnothing(refresh_response)
                        state.github_token = refresh_response.access_token
                        state.github_refresh_token = refresh_response.refresh_token
                        save_github_tokens(state.claude_prefix, state.github_token, state.github_refresh_token, state.dangerous_github_auth)
                        filename = state.dangerous_github_auth ? "github_tokens_dangerous.json" : "github_tokens.json"
                        token_path = joinpath(state.claude_prefix, filename)
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
            if state.dangerous_github_auth
                println("This will authorize DANGEROUS access to your GitHub account")
                println("including repository creation and broader permissions.")
                println("Use with caution!")
            else
                println("This will securely authorize access to your GitHub repositories")
                println("without requiring a full personal access token. The app will only")
                println("have access to repositories you explicitly grant permission to.")
            end
            println()
            println("To skip authentication, use --no-github-auth")
            println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

            # Run authentication in a task so we can interrupt it
            auth_task = @task try
                token_response = GitHubAuth.authenticate(dangerous_mode=state.dangerous_github_auth)
                if GitHubAuth.validate_token(token_response.access_token)
                    state.github_token = token_response.access_token
                    state.github_refresh_token = token_response.refresh_token
                    save_github_tokens(state.claude_prefix, state.github_token, state.github_refresh_token, state.dangerous_github_auth)
                    filename = state.dangerous_github_auth ? "github_tokens_dangerous.json" : "github_tokens.json"
                    token_path = joinpath(state.claude_prefix, filename)
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
                    cprintln(YELLOW, "\nGitHub authentication interrupted. Proceeding without GitHub access.")
                    println()
                elseif isa(e, HTTP.RequestError) && isa(e.error, InterruptException)
                    cprintln(YELLOW, "\nGitHub authentication interrupted. Proceeding without GitHub access.")
                    println()
                else
                    rethrow(e)
                end
            end

            # Start monitor and run authentication
            monitor_stdin_for_interrupt(auth_task)
            schedule(auth_task)
            wait(auth_task)
        end
    end

    # Setup environment
    setup_environment!(state)

    # Handle .claude_sandbox repository if authenticated
    if !isempty(state.github_token)
        handle_claude_sandbox_repo!(state)
    end

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
        "dangerous_github_auth" => false,
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
        elseif arg == "--dangerous-github-auth"
            options["dangerous_github_auth"] = true
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
        --dangerous-github-auth  Use GitHub auth with broader permissions (repo creation, etc)
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
        Git is available at: /opt/build_tools/bin/git
        GitHub CLI is available at: /opt/gh_cli/bin/gh
        GNU Make is available at: /opt/build_tools/bin/make
        ripgrep is available at: /opt/build_tools/bin/rg
        Python is available at: /opt/build_tools/bin/python3
        juliaup is available at: /opt/juliaup/bin/juliaup
        Claude-code is automatically installed on first run
    """)
end

function initialize_state(work_dir::String, claude_args::Vector{String}=String[], keep_bash::Bool=false, dangerous_github_auth::Bool=false)::AppState
    tools_prefix = @get_scratch!(TOOLS_SCRATCH_KEY)
    claude_prefix = @get_scratch!(CLAUDE_SCRATCH_KEY)

    nodejs_dir = joinpath(tools_prefix, "nodejs")
    npm_dir = joinpath(tools_prefix, "npm")
    gh_cli_dir = joinpath(tools_prefix, "gh_cli")
    build_tools_dir = joinpath(tools_prefix, "build_tools")
    juliaup_dir = joinpath(tools_prefix, "juliaup")
    julia_dir = joinpath(tools_prefix, "julia")
    claude_home_dir = joinpath(claude_prefix, "claude_home")

    # Ensure directories exist, otherwise the mount will fail
    for dir in (nodejs_dir, npm_dir, gh_cli_dir, build_tools_dir, juliaup_dir, julia_dir, claude_home_dir)
        mkpath(dir)
    end

    # Check if claude is installed
    claude_bin = joinpath(npm_dir, "bin", "claude")
    claude_installed = isfile(claude_bin)

    # Load existing GitHub tokens if available
    tokens = load_github_tokens(claude_prefix, dangerous_github_auth)

    return AppState(tools_prefix, claude_prefix, nodejs_dir, npm_dir, gh_cli_dir, build_tools_dir, juliaup_dir, julia_dir, claude_home_dir, work_dir, claude_installed, tokens.access_token, tokens.refresh_token, claude_args, keep_bash, nothing, dangerous_github_auth)
end


function reset_tools()
    cprintln(YELLOW, "Resetting tools (keeping Claude settings)...")
    scratch_path = @get_scratch!(TOOLS_SCRATCH_KEY)
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

function handle_claude_sandbox_repo!(state::AppState)
    cprintln(BLUE, "Checking for .claude_sandbox repository...")

    repo_info = GitHubAuth.check_claude_sandbox_repo(state.github_token)
    if isnothing(repo_info)
        state.claude_sandbox_dir = nothing
        return
    end

    cprintln(GREEN, "✓ Found .claude_sandbox repository for $(repo_info.username)")

    # Create directory for the repo
    sandbox_repo_dir = joinpath(state.claude_prefix, "claude_sandbox_repo")

    # Clone or update the repository
    if isdir(joinpath(sandbox_repo_dir, ".git"))
        # Repository exists, update it
        cprintln(YELLOW, "  Updating .claude_sandbox repository...")
        try
            # Set the token for authentication
            run(`git -C $sandbox_repo_dir config credential.helper store`)

            # Create credentials file temporarily
            creds_file = joinpath(state.claude_prefix, "git-credentials")
            write(creds_file, "https://$(repo_info.username):$(state.github_token)@github.com\n")

            withenv("HOME" => state.claude_prefix) do
                run(`git -C $sandbox_repo_dir pull --quiet`)
            end

            rm(creds_file; force=true)
            cprintln(GREEN, "  ✓ Repository updated")
        catch e
            cprintln(YELLOW, "  ⚠ Failed to update repository: $e")
        end
    else
        # Clone the repository
        cprintln(YELLOW, "  Cloning .claude_sandbox repository...")
        try
            mkpath(dirname(sandbox_repo_dir))

            # Clone using token authentication
            clone_url = replace(repo_info.clone_url, "https://github.com/" => "https://$(state.github_token)@github.com/")
            run(`git clone --quiet $clone_url $sandbox_repo_dir`)

            cprintln(GREEN, "  ✓ Repository cloned")
        catch e
            cprintln(RED, "  ✗ Failed to clone repository: $e")
            state.claude_sandbox_dir = nothing
            return
        end
    end

    state.claude_sandbox_dir = sandbox_repo_dir
end

function save_github_tokens(claude_prefix::String, access_token::String, refresh_token::Union{String, Nothing}=nothing, dangerous_mode::Bool=false)
    # Use different files for normal vs dangerous mode
    filename = dangerous_mode ? "github_tokens_dangerous.json" : "github_tokens.json"
    token_file = joinpath(claude_prefix, filename)

    # Load existing tokens to preserve both sets
    all_tokens = Dict{String, Any}()
    for (fname, mode) in [("github_tokens.json", false), ("github_tokens_dangerous.json", true)]
        fpath = joinpath(claude_prefix, fname)
        if isfile(fpath)
            try
                existing = JSON.parsefile(fpath)
                all_tokens[mode ? "dangerous" : "normal"] = existing
            catch
                # Skip invalid files
            end
        end
    end

    # Update the appropriate token set
    key = dangerous_mode ? "dangerous" : "normal"
    all_tokens[key] = Dict(
        "access_token" => access_token,
        "refresh_token" => refresh_token
    )

    # Save to the appropriate file
    write(token_file, JSON.json(all_tokens[key]))
end

function load_github_tokens(claude_prefix::String, dangerous_mode::Bool=false)
    # Use different files for normal vs dangerous mode
    filename = dangerous_mode ? "github_tokens_dangerous.json" : "github_tokens.json"
    token_file = joinpath(claude_prefix, filename)

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

"""
    install_jll_tool(tool_name::String, jll_name::String, bin_path::String, install_dir::String; post_install=nothing)

Install a JLL tool if it's not already installed.

# Arguments
- `tool_name`: Display name of the tool
- `jll_name`: Name of the JLL package
- `bin_path`: Full path to the binary to check for existence
- `install_dir`: Directory to install the tool into
- `post_install`: Optional function to run after installation
"""
function install_jll_tool(tool_name::String, jll_name::String, bin_path::String, install_dir::String; post_install=nothing)
    if !isfile(bin_path)
        cprintln(YELLOW, "  Installing $tool_name...")
        artifact_paths = collect_artifact_paths([jll_name])
        deploy_artifact_paths(install_dir, artifact_paths)
        
        # Run post-install hook if provided
        if !isnothing(post_install)
            post_install()
        end
        
        cprintln(GREEN, "  ✓ $tool_name installed")
        return true
    end
    return false
end

function setup_environment!(state::AppState)
    cprint(BLUE, "Setting up environment...")

    # Create directories
    mkpath(state.nodejs_dir)
    mkpath(joinpath(state.npm_dir, "bin"))
    mkpath(joinpath(state.npm_dir, "lib"))
    mkpath(joinpath(state.npm_dir, "cache"))
    mkpath(state.gh_cli_dir)
    mkpath(state.build_tools_dir)
    mkpath(state.claude_home_dir)

    # Create claude.json file if it doesn't exist
    claude_json_path = joinpath(state.claude_prefix, "claude.json")
    if !isfile(claude_json_path)
        write(claude_json_path, "{}")
    end

    # Create a credential helper script in build_tools
    credential_helper_path = joinpath(state.build_tools_dir, "bin", "git-credential-gh")
    mkpath(dirname(credential_helper_path))
    write(credential_helper_path, """
#!/bin/sh
# Git credential helper that uses GitHub CLI

case "\$1" in
    get)
        echo "username=x-access-token"
        echo "password=\$(gh auth token 2>/dev/null)"
        ;;
    store|erase)
        # Ignore store and erase operations
        exit 0
        ;;
esac
""")
    chmod(credential_helper_path, 0o755)  # Make it executable

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
[credential]
    helper = /opt/build_tools/bin/git-credential-gh
[url "https://github.com/"]
    insteadOf = git@github.com:
[url "https://github.com/"]
    insteadOf = ssh://git@github.com/
""")
    end

    # Check if Node.js is installed
    node_bin = joinpath(state.nodejs_dir, "bin", "node")
    if !install_jll_tool("Node.js v22", "NodeJS_22_jll", node_bin, state.nodejs_dir)
        cprintln(GREEN, " Done!")
    end

    # Check if gh CLI is installed
    gh_bin = joinpath(state.gh_cli_dir, "bin", "gh")
    install_jll_tool("GitHub CLI", "gh_cli_jll", gh_bin, state.gh_cli_dir)

    # Check if Git is installed
    git_bin = joinpath(state.build_tools_dir, "bin", "git")
    install_jll_tool("Git", "Git_jll", git_bin, state.build_tools_dir)

    # Check if GNU Make is installed
    make_bin = joinpath(state.build_tools_dir, "bin", "make")
    gmake_bin = joinpath(state.build_tools_dir, "bin", "gmake")
    if !isfile(make_bin) && !isfile(gmake_bin)
        install_jll_tool("GNU Make", "GNUMake_jll", gmake_bin, state.build_tools_dir) do
            # If gmake exists but make doesn't, create symlink
            if isfile(gmake_bin) && !isfile(make_bin) && !islink(make_bin)
                symlink("gmake", make_bin)
            end
        end
    end

    # Check if juliaup is installed
    juliaup_bin = joinpath(state.juliaup_dir, "bin", "juliaup")
    install_jll_tool("juliaup", "juliaup_jll", juliaup_bin, state.juliaup_dir)

    # Check if ripgrep is installed
    rg_bin = joinpath(state.build_tools_dir, "bin", "rg")
    install_jll_tool("ripgrep", "ripgrep_jll", rg_bin, state.build_tools_dir)

    # Check if Python is installed
    python_bin = joinpath(state.build_tools_dir, "bin", "python3")
    install_jll_tool("Python", "Python_jll", python_bin, state.build_tools_dir)

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

const SANDBOX_PATH = "/opt/npm/bin:/opt/nodejs/bin:/opt/gh_cli/bin:/opt/build_tools/bin:/opt/build_tools/libexec/git-core:/opt/juliaup/bin:/usr/bin:/bin:/usr/local/bin"

function create_sandbox_config(state::AppState; stdin=Base.devnull)::Sandbox.SandboxConfig
    # Prepare mounts using MountInfo
    mounts = Dict{String, Sandbox.MountInfo}(
        "/" => Sandbox.MountInfo(Sandbox.debian_rootfs(), Sandbox.MountType.Overlayed),
        "/opt/nodejs" => Sandbox.MountInfo(state.nodejs_dir, Sandbox.MountType.ReadOnly),
        "/opt/npm" => Sandbox.MountInfo(state.npm_dir, Sandbox.MountType.ReadWrite),
        "/opt/gh_cli" => Sandbox.MountInfo(state.gh_cli_dir, Sandbox.MountType.ReadOnly),
        "/opt/build_tools" => Sandbox.MountInfo(state.build_tools_dir, Sandbox.MountType.ReadOnly),
        "/opt/juliaup" => Sandbox.MountInfo(state.juliaup_dir, Sandbox.MountType.ReadOnly),
        "/workspace" => Sandbox.MountInfo(state.work_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude" => Sandbox.MountInfo(state.claude_home_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude.json" => Sandbox.MountInfo(joinpath(state.claude_prefix, "claude.json"), Sandbox.MountType.ReadWrite),
        "/root/.gitconfig" => Sandbox.MountInfo(joinpath(state.tools_prefix, "gitconfig"), Sandbox.MountType.ReadWrite),
        "/root/.julia" => Sandbox.MountInfo(state.julia_dir, Sandbox.MountType.ReadWrite)
    )

    # Add claude_sandbox repository if available
    if !isnothing(state.claude_sandbox_dir) && isdir(state.claude_sandbox_dir)
        mounts["/root/.claude_sandbox"] = Sandbox.MountInfo(state.claude_sandbox_dir, Sandbox.MountType.ReadWrite)
    end

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
            "HOME" => "/root",
            # Note: We need to set PATH both here and in bashrc, because bash overrides it on login
            "PATH" => SANDBOX_PATH,
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
        println("   $(BOLD)make$(RESET)  - GNU Make build tool")
        println("   $(BOLD)rg$(RESET)    - ripgrep (fast search)")
        println("   $(BOLD)python3$(RESET) - Python interpreter")
        println("\n💡 To install claude-code:")
        println("   $(BOLD)npm install -g @anthropic-ai/claude-code$(RESET)")
    end

    cmd = `/bin/bash --login`

    println()

    interactive_config = create_sandbox_config(state; stdin=Base.stdin)

    # Run the sandbox
    Sandbox.with_executor() do exe
        # Create CLAUDE.md in the sandbox root
        claude_sandbox_section = ""
        if !isnothing(state.claude_sandbox_dir) && isdir(state.claude_sandbox_dir)
            claude_sandbox_section = """

## User Configuration

Your personal .claude_sandbox repository is mounted at `/root/.claude_sandbox`.

If you have a `CLAUDE_SANDBOX.md` file in that directory, it contains user-specific instructions and preferences.
Please check `/root/.claude_sandbox/CLAUDE_SANDBOX.md` for any custom configurations or instructions.
"""
        end

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
  - GNU Make (make) for build automation
  - ripgrep (rg) for fast text searching
  - Python 3 for Python development
  - Standard Unix tools

## Important Notes

- You have full read/write access to `/workspace`
- System directories are read-only or overlayed
- Network access is available
- The environment resets when you exit (except for `/workspace`)

## GitHub Integration

$(if isempty(state.github_token)
    "- No GitHub authentication configured"
elseif state.dangerous_github_auth
    "- GitHub authenticated with **DANGEROUS** permissions (repository creation, etc.)\n- ⚠️  Use caution with these elevated permissions!"
else
    "- GitHub authenticated with standard permissions\n- You can use git and gh commands\n- Repository creation and most admin actions are disabled\n- For broader permissions (repo creation, etc.), ask the user to restart with `claudebox --dangerous-github-auth`"
end)$claude_sandbox_section

## Tips

- Use the workspace directory for all file operations
- Git commits will use the configured user name and email
- The sandbox provides a consistent, clean environment

## Development Notes

- After adding new dependencies to Project.toml, always run `julia +nightly --project=. -e "using Pkg; Pkg.resolve(); Pkg.instantiate()"` to resolve and install them
- Always use Julia nightly (`+nightly`) when resolving dependencies to ensure compatibility
- This ensures all JLL packages and dependencies are properly resolved and installed
"""

        run(exe, config, `/bin/sh -c "mkdir /etc/claude-code && cat > /etc/claude-code/CLAUDE.md << 'EOF'
$claude_md_content
EOF"`)

        # Create a nice prompt and ensure PATH is set for bash
        if cmd.exec[1] == "/bin/bash"
            # Base bashrc content
            bashrc_content = """
# Claude Sandbox environment
export PS1="\\[\\033[32m\\][sandbox]\\[\\033[0m\\] \\w \\\$ "
export PATH="$SANDBOX_PATH"

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
