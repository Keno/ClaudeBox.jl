module ClaudeBox

using Sandbox
using JLLPrefixes
using BinaryBuilder2
using BinaryBuilderToolchains
using Scratch
using MozillaCACerts_jll
using JSON
using HTTP
using REPL.Terminals: raw!, TTYTerminal

include("github_auth.jl")
using .GitHubAuth


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
    toolchain_dir::String
    juliaup_dir::String
    julia_dir::String
    claude_home_dir::String
    gemini_home_dir::String
    work_dir::String
    claude_installed::Bool
    gemini_installed::Bool
    github_token::String
    github_refresh_token::Union{String, Nothing}
    claude_args::Vector{String}
    keep_bash::Bool
    claude_sandbox_dir::Union{String, Nothing}
    dangerous_github_auth::Bool
    use_gemini::Bool
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
    state = initialize_state(options["work_dir"], options["claude_args"], options["bash"], options["dangerous_github_auth"], options["gemini"])

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
        "gemini" => false,
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
        elseif arg == "--gemini"
            options["gemini"] = true
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
        --gemini            Use gemini instead of claude

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
        less is available at: /opt/build_tools/bin/less
        procps is available at: /opt/build_tools/bin/ps
        curl is available at: /opt/build_tools/bin/curl
        juliaup is available at: /opt/juliaup/bin/juliaup
        BB2 Toolchain (GCC, Binutils, etc.) is available at: /opt/bb-*
        Claude-code is automatically installed on first run
    """)
end

function initialize_state(work_dir::String, claude_args::Vector{String}=String[], keep_bash::Bool=false, dangerous_github_auth::Bool=false, use_gemini::Bool=false)::AppState
    tools_prefix = @get_scratch!(TOOLS_SCRATCH_KEY)
    claude_prefix = @get_scratch!(CLAUDE_SCRATCH_KEY)

    nodejs_dir = joinpath(tools_prefix, "nodejs")
    npm_dir = joinpath(tools_prefix, "npm")
    gh_cli_dir = joinpath(tools_prefix, "gh_cli")
    build_tools_dir = joinpath(tools_prefix, "build_tools")
    toolchain_dir = joinpath(tools_prefix, "toolchain")
    juliaup_dir = joinpath(tools_prefix, "juliaup")
    julia_dir = joinpath(tools_prefix, "julia")
    claude_home_dir = joinpath(claude_prefix, "claude_home")
    gemini_home_dir = joinpath(claude_prefix, "gemini_home")

    # Ensure directories exist, otherwise the mount will fail
    for dir in (nodejs_dir, npm_dir, gh_cli_dir, build_tools_dir, toolchain_dir, juliaup_dir, julia_dir, claude_home_dir, gemini_home_dir)
        mkpath(dir)
    end

    # Check if claude and gemini are installed
    claude_bin = joinpath(npm_dir, "bin", "claude")
    claude_installed = isfile(claude_bin)

    gemini_bin = joinpath(npm_dir, "bin", "gemini")
    gemini_installed = isfile(gemini_bin)

    # Load existing GitHub tokens if available
    tokens = load_github_tokens(claude_prefix, dangerous_github_auth)

    return AppState(tools_prefix, claude_prefix, nodejs_dir, npm_dir, gh_cli_dir, build_tools_dir, toolchain_dir, juliaup_dir, julia_dir, claude_home_dir, gemini_home_dir, work_dir, claude_installed, gemini_installed, tokens.access_token, tokens.refresh_token, claude_args, keep_bash, nothing, dangerous_github_auth, use_gemini)
end

"""
    build_cli_command(state::AppState, extra_args::Vector{String}=String[]; use_full_path::Bool=false)

Build the CLI command based on the application state.
Returns a Cmd object that can be executed directly.
"""
function build_cli_command(state::AppState, extra_args::Vector{String}=String[]; use_full_path::Bool=false)
    # Determine which CLI to use
    cli_name = state.use_gemini ? "gemini" : "claude"

    # Build the executable path
    cli_executable = use_full_path ? "/opt/npm/bin/$cli_name" : cli_name

    # Combine all arguments
    all_args = vcat(state.claude_args, extra_args)

    # Build the command using Julia's command syntax
    if state.use_gemini
        # Always run gemini in yolo mode
        return `$cli_executable --yolo $all_args`
    else
        # Claude needs the permissions flag
        return `$cli_executable --dangerously-skip-permissions $all_args`
    end
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
        # Create platform with glibc target and host arch
        platform = Base.BinaryPlatforms.HostPlatform()
        platform["target_libc"] = "glibc"
        platform["target_arch"] = string(Base.BinaryPlatforms.arch(platform))
        delete!(platform.tags, "julia_version")

        artifact_paths = collect_artifact_paths([jll_name]; platform=platform)
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

"""
    are_all_build_tools_installed(state::AppState) -> Bool

Check if all required build tools are installed in the expected locations.
"""
function are_all_build_tools_installed(state::AppState)
    git_bin = joinpath(state.build_tools_dir, "bin", "git")
    make_bin = joinpath(state.build_tools_dir, "bin", "make")
    rg_bin = joinpath(state.build_tools_dir, "bin", "rg")
    python_bin = joinpath(state.build_tools_dir, "bin", "python3")
    less_bin = joinpath(state.build_tools_dir, "bin", "less")
    ps_bin = joinpath(state.build_tools_dir, "bin", "ps")
    clang_bin = joinpath(state.build_tools_dir, "tools", "clang")
    # Binutils provides many tools, we'll check for a few key ones
    ar_bin = joinpath(state.build_tools_dir, "bin", "ar")
    nm_bin = joinpath(state.build_tools_dir, "bin", "nm")
    objdump_bin = joinpath(state.build_tools_dir, "bin", "objdump")
    ld_bin = joinpath(state.build_tools_dir, "bin", "ld")
    # LLD provides the LLVM linker
    lld_bin = joinpath(state.build_tools_dir, "tools", "lld")
    # CURL provides the curl command-line tool
    curl_bin = joinpath(state.build_tools_dir, "bin", "curl")
    # GCC provides the GNU compiler
    gcc_bin = joinpath(state.build_tools_dir, "bin", "gcc")

    return isfile(git_bin) && isfile(make_bin) && isfile(rg_bin) &&
           isfile(python_bin) && isfile(less_bin) && isfile(ps_bin) && isfile(clang_bin) &&
           isfile(ar_bin) && isfile(nm_bin) && isfile(objdump_bin) && isfile(ld_bin) && isfile(lld_bin) && isfile(curl_bin) &&
           isfile(gcc_bin)
end

function bb2_target_spec()
    # Create a basic build environment using BB2 approach
    host_platform = BinaryBuilderToolchains.BBHostPlatform()
    platform = BinaryBuilderToolchains.CrossPlatform(host_platform, host_platform)

    # Create BuildTargetSpec for the host
    return BinaryBuilder2.BuildTargetSpec(
        "bb2",
        platform,
        [BinaryBuilderToolchains.CToolchain(;lock_microarchitecture=false), HostToolsToolchain(platform)],  # Use default CToolchain
        [],  # No additional dependencies
        Set([:host, :default])
    )
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
    sslCAInfo = /opt/bb2-tools/etc/certs/ca-certificates.crt
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

    # Check if all build tools are installed
    # Install all build tools together to avoid file conflicts
    if !are_all_build_tools_installed(state)
        cprintln(YELLOW, "  Installing build tools...")

        # Remove the entire build tools directory to ensure clean installation
        if isdir(state.build_tools_dir)
            rm(state.build_tools_dir; recursive=true, force=true)
        end
        mkpath(state.build_tools_dir)

        # Collect build tool artifacts (excluding toolchain components)
        build_tools_jlls = ["ripgrep_jll", "Python_jll", "less_jll", "procps_jll", "CURL_jll"]

        # Collect all build tool artifacts together
        platform = Base.BinaryPlatforms.HostPlatform()
        delete!(platform.tags, "julia_version")
        artifact_paths = collect_artifact_paths(build_tools_jlls; platform)
        deploy_artifact_paths(state.build_tools_dir, artifact_paths)

        cprintln(GREEN, "  ✓ Build tools installed")
    end

    # Set up BinaryBuilder2 toolchain
    if isempty(readdir(joinpath(state.toolchain_dir)))
        cprintln(YELLOW, "  Setting up BB2 toolchain...")

        target_spec = bb2_target_spec()

        # Apply toolchains to get sources and environment
        env = Dict{String,String}()
        source_trees = Dict{String,Vector{BinaryBuilder2.BinaryBuilderSources.AbstractSource}}()
        env, source_trees = BinaryBuilder2.apply_toolchains(target_spec, env, source_trees)

        # Deploy toolchain sources
        for (idx, (prefix, sources)) in enumerate(source_trees)
            if startswith(prefix, "/opt/")
                deploy_path = joinpath(state.toolchain_dir, string(idx, "-", lstrip(prefix, '/')))

                BinaryBuilder2.BinaryBuilderSources.prepare(sources)
                BinaryBuilder2.BinaryBuilderSources.deploy(sources, deploy_path)
            end
        end

        cprintln(GREEN, "  ✓ BB2 toolchain installed")
    end

    # Create a credential helper script in build_tools (after build tools are installed)
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

    # Check if juliaup is installed (separate from build tools)
    juliaup_bin = joinpath(state.juliaup_dir, "bin", "juliaup")
    if install_jll_tool("juliaup", "juliaup_jll", juliaup_bin, state.juliaup_dir)
        # juliaup was just installed, set up nightly as default and install General registry
        cprintln(YELLOW, "  Setting up Julia nightly and General registry...")

        # Create sandbox config for Julia setup
        config = create_sandbox_config(state)

        success = Sandbox.with_executor() do exe
            try
                # First add nightly channel
                run(exe, config, `/opt/juliaup/bin/juliaup add nightly`)

                # Then set it as default
                run(exe, config, `/opt/juliaup/bin/juliaup default nightly`)

                # Install the General registry using nightly Julia
                run(exe, config, `/opt/juliaup/bin/julia +nightly -e "using Pkg; Pkg.Registry.add(\"General\")"`)

                cprintln(GREEN, "  ✓ Julia nightly set as default and General registry installed")
                return true
            catch e
                cprintln(YELLOW, "  ⚠ Failed to set up Julia nightly or General registry")
                println("    Error: $e")
                println("    You can set it up manually in the sandbox:")
                println("    $(BOLD)juliaup add nightly$(RESET)")
                println("    $(BOLD)juliaup default nightly$(RESET)")
                println("    $(BOLD)julia +nightly -e \"using Pkg; Pkg.Registry.add(\\\"General\\\")\"$(RESET)")
                return false
            end
        end
    end

    # Check if claude is installed
    claude_bin = joinpath(state.npm_dir, "bin", "claude")
    state.claude_installed = isfile(claude_bin)

    # Check if gemini is installed
    gemini_bin = joinpath(state.npm_dir, "bin", "gemini")
    state.gemini_installed = isfile(gemini_bin)

    # Check and install both CLIs if needed
    clis_to_install = Tuple{String, String, Bool}[]

    if !state.claude_installed
        push!(clis_to_install, ("claude-code", "@anthropic-ai/claude-code", true))
    end

    if !state.gemini_installed
        push!(clis_to_install, ("gemini", "@google/gemini-cli", false))
    end

    if isempty(clis_to_install)
        cprintln(GREEN, "✓ All CLIs are already installed")
    else
        # Create sandbox config for installation
        config = create_sandbox_config(state)

        for (cli_name, npm_package, needs_workaround) in clis_to_install
            println()
            cprintln(YELLOW, "Installing $cli_name...")

            success = Sandbox.with_executor() do exe
                try
                    # Configure npm to reduce output
                    run(exe, config, `/bin/sh -c "echo 'fund=false\naudit=false\nprogress=false' > /opt/npm/.npmrc"`)

                    # Install the CLI with output
                    run(exe, config, `/opt/nodejs/bin/npm install -g $npm_package`)

                    # Workaround for https://github.com/anthropics/claude-code/issues/927
                    # The UID check gives wrong values in sandboxed environments
                    # Only apply this for claude-code, not gemini
                    if needs_workaround
                        cli_path = "/opt/npm/lib/node_modules/@anthropic-ai/claude-code/cli.js"
                        run(exe, config, `/bin/sh -c "sed -i 's/process\\.getuid()===0/false/g' $cli_path"`)
                    end

                    cprintln(GREEN, "✓ $cli_name installed successfully!")
                    return true
                catch e
                    cprintln(RED, "✗ Failed to install $cli_name automatically")
                    println("  Error: $e")
                    println("\n  You can try installing manually inside the sandbox:")
                    println("  $(BOLD)npm install -g $npm_package$(RESET)")
                    return false
                end
            end

            # Update the appropriate installation status
            if cli_name == "claude-code"
                state.claude_installed = success
            else
                state.gemini_installed = success
            end
        end
    end

    println()
end

const SANDBOX_PATH = "/opt/npm/bin:/opt/nodejs/bin:/opt/gh_cli/bin:/opt/build_tools/bin:/opt/build_tools/tools:/opt/build_tools/libexec/git-core:/opt/bb2-x86_64-linux-gnu/wrappers:/opt/bb2-tools/wrappers:/opt/bb2-tools/bin:/opt/juliaup/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

function create_sandbox_config(state::AppState; stdin=Base.devnull, stdout=Base.stdout, stderr=Base.stderr)::Sandbox.SandboxConfig
    # Get host platform for debian rootfs
    host_platform = Base.BinaryPlatforms.HostPlatform()

    # Prepare mounts using MountInfo, following BinaryBuilder2 pattern
    mounts = Dict{String, Sandbox.MountInfo}(
        "/" => Sandbox.MountInfo(Sandbox.debian_rootfs(; platform=host_platform), Sandbox.MountType.Overlayed),
        "/opt/nodejs" => Sandbox.MountInfo(state.nodejs_dir, Sandbox.MountType.ReadOnly),
        "/opt/npm" => Sandbox.MountInfo(state.npm_dir, Sandbox.MountType.ReadWrite),
        "/opt/gh_cli" => Sandbox.MountInfo(state.gh_cli_dir, Sandbox.MountType.ReadOnly),
        "/opt/build_tools" => Sandbox.MountInfo(state.build_tools_dir, Sandbox.MountType.ReadOnly),
        "/opt/juliaup" => Sandbox.MountInfo(state.juliaup_dir, Sandbox.MountType.ReadOnly),
        "/workspace" => Sandbox.MountInfo(state.work_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude" => Sandbox.MountInfo(state.claude_home_dir, Sandbox.MountType.ReadWrite),
        "/root/.claude.json" => Sandbox.MountInfo(joinpath(state.claude_prefix, "claude.json"), Sandbox.MountType.ReadWrite),
        "/root/.gemini" => Sandbox.MountInfo(state.gemini_home_dir, Sandbox.MountType.ReadWrite),
        "/root/.gitconfig" => Sandbox.MountInfo(joinpath(state.tools_prefix, "gitconfig"), Sandbox.MountType.ReadWrite),
        "/root/.julia" => Sandbox.MountInfo(state.julia_dir, Sandbox.MountType.ReadWrite)
    )

    # Add claude_sandbox repository if available
    if !isnothing(state.claude_sandbox_dir) && isdir(state.claude_sandbox_dir)
        mounts["/root/.claude_sandbox"] = Sandbox.MountInfo(state.claude_sandbox_dir, Sandbox.MountType.ReadWrite)
    end

    # Map external .claude/projects directory for the current work_dir
    # Convert work_dir path to claude projects directory name (replace / with -)
    work_dir_name = replace(state.work_dir, "/" => "-")
    external_claude_projects = expanduser("~/.claude/projects/$work_dir_name")

    # Check if the external claude projects directory exists
    if isdir(external_claude_projects)
        # Mount it to the corresponding location inside the sandbox
        mounts["/root/.claude/projects/$work_dir_name"] = Sandbox.MountInfo(external_claude_projects, Sandbox.MountType.ReadWrite)
        cprintln(CYAN, "📁 Mounting external Claude project directory: $external_claude_projects")
    end

    # Map external .gemini directory if it exists (overrides the sandbox gemini directory)
    external_gemini_dir = expanduser("~/.gemini")
    if isdir(external_gemini_dir)
        mounts["/root/.gemini"] = Sandbox.MountInfo(external_gemini_dir, Sandbox.MountType.ReadWrite)
        cprintln(CYAN, "📁 Mounting external Gemini configuration: $external_gemini_dir")
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

    # Create environment following BB2 pattern
    env = Dict{String,String}(
        "HOME" => "/root",
        "PATH" => SANDBOX_PATH,
        "NODE_PATH" => "/opt/npm/lib/node_modules",
        "npm_config_prefix" => "/opt/npm",
        "npm_config_cache" => "/opt/npm/cache",
        "npm_config_userconfig" => "/opt/npm/.npmrc",
        "ANTHROPIC_API_KEY" => get(ENV, "ANTHROPIC_API_KEY", ""),
        "GOOGLE_API_KEY" => get(ENV, "GOOGLE_API_KEY", ""),
        "GEMINI_API_KEY" => get(ENV, "GEMINI_API_KEY", ""),
        "GITHUB_TOKEN" => state.github_token,
        "TERM" => get(ENV, "TERM", "xterm-256color"),
        "TERMINFO" => "/lib/terminfo",
        "LANG" => "C.UTF-8",
        "USER" => "root",
        "WORKSPACE" => "/workspace",
        "JULIA_DEPOT_PATH" => "/root/.julia",
    )

    # Add toolchain environment variables if toolchain is installed
    if !isempty(readdir(state.toolchain_dir))
        # Get toolchain environment from BB2
        # Create the same target spec to get consistent environment
        target_spec = bb2_target_spec()

        # Get toolchain environment
        toolchain_env = Dict{String,String}()
        source_trees = Dict{String,Vector{BinaryBuilder2.BinaryBuilderSources.AbstractSource}}()
        env, source_trees = BinaryBuilder2.apply_toolchains(target_spec, env, source_trees)

        for (idx, (prefix, srcs)) in enumerate(source_trees)
            # Strip leading slashes so that `joinpath()` works as expected,
            # prefix with `idx` so that we can overlay multiple disparate folders
            # onto eachother in the sandbox, without clobbering each directory on
            # the host side.
            host_path = joinpath(state.toolchain_dir, string(idx, "-", lstrip(prefix, '/')))
            mounts[prefix] = MountInfo(host_path, MountType.Overlayed)
        end
    end

    # https://github.com/JuliaLang/NetworkOptions.jl/issues/41
    env["JULIA_SSL_CA_ROOTS_PATH"] = env["SSL_CERT_FILE"]

    # Create SandboxConfig following BB2 pattern
    Sandbox.SandboxConfig(
        mounts,
        env;
        hostname = "claudebox",
        persist = true,
        pwd = "/workspace",
        stdin = stdin,
        stdout = stdout,
        stderr = stderr,
        verbose = false,
        multiarch = [host_platform]
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

    # Always use bash, but prepare to launch claude/gemini if appropriate
    cli_installed = state.use_gemini ? state.gemini_installed : state.claude_installed
    if cli_installed
        cli_name = state.use_gemini ? "gemini" : "claude"
        println("\n🤖 Starting $(BOLD)$cli_name$(RESET) interactive session...")
        println("   Type your prompts and $cli_name will respond")
        if state.keep_bash
            println("   Use $(BOLD)exit$(RESET) to return to bash shell")
        else
            println("   Use $(BOLD)exit$(RESET) to leave the sandbox")
        end
    else
        println("\n🐚 Starting $(BOLD)bash$(RESET) shell...")
        if state.use_gemini
            println("\n💡 To install gemini:")
            println("   $(BOLD)npm install -g @google/gemini-cli$(RESET)")
        else
            println("\n💡 To install claude-code:")
            println("   $(BOLD)npm install -g @anthropic-ai/claude-code$(RESET)")
        end
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
  - Julia (nightly) via juliaup for Julia development
  - less for file viewing and pagination
  - procps utilities (ps, pgrep, top, etc.) for process management
  - BinaryBuilder2 Toolchain (GCC, Binutils, Glibc, etc.) for compiling C/C++ code
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

            # Add auto-launch for the selected CLI if installed
            cli_installed = state.use_gemini ? state.gemini_installed : state.claude_installed
            if cli_installed
                # Use the command builder to create the command
                cli_cmd = build_cli_command(state; use_full_path=false)

                # Convert to shell string for bash
                full_command = Base.shell_escape(cli_cmd)

                # Get cli name and base command for display
                cli_name = state.use_gemini ? "gemini" : "claude"
                base_command = state.use_gemini ? cli_name : "$cli_name --dangerously-skip-permissions"

                if state.keep_bash
                    cmd = `$cmd -c "$full_command; echo \"🐚 Returned to bash shell. Run '$base_command' to start $cli_name again.\"; exec /bin/bash --login"`
                else
                    cmd = `$cmd -c $full_command`
                end
            end

            run(exe, config, `/bin/sh -c "cat > /root/.bashrc << 'EOF'
$bashrc_content
EOF"`)
        end
        # Upgrade libstd++/libatomic
        # NOTE: Be careful - if this goes into bashrc, claude may rerun it while node.js is running. cp overrides the file in-place, so if this is done while
        # node is running, it'll fail with SIGBUS.
        run(exe, config, `/bin/sh -c "cp /opt/bb2-x86_64-linux-gnu/gcc/x86_64-linux-gnu/lib64/libstdc++.so.6 /lib/x86_64-linux-gnu/; cp /opt/bb2-x86_64-linux-gnu/gcc/x86_64-linux-gnu/lib64/libatomic.so.1 /lib/x86_64-linux-gnu/"`)

        run(exe, interactive_config, cmd)
    end
end

end # module ClaudeBox
