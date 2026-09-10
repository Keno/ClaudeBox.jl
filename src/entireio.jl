# Pin the initial install to the release used to validate the hook integration.
# An already-installed CLI is reused, including one the user upgraded manually.
const ENTIREIO_VERSION = "0.10.6"
const ENTIREIO_RELEASE_URL = "https://github.com/entireio/cli/releases/download/v$ENTIREIO_VERSION"

function entireio_agent(state::AppState)
    state.use_codex && return "codex"
    state.use_opencode && return "opencode"
    state.use_gemini && return "gemini"
    return "claude-code"
end

function entireio_install_command(; release_url::AbstractString=ENTIREIO_RELEASE_URL,
                                   install_dir::AbstractString="/root/.local/bin")
    # Download the release directly: the interactive installer also offers to
    # modify shell startup files. Both binaries live in the existing .local mount.
    script = raw"""
set -eu
release_url=$1
install_dir=$2
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Entire CLI does not support this sandbox architecture" >&2; exit 1 ;;
esac
archive="entire_linux_${arch}.tar.gz"
download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT
curl -fsSL "$release_url/$archive" -o "$download_dir/$archive"
curl -fsSL "$release_url/checksums.txt" -o "$download_dir/checksums.txt"
(cd "$download_dir" && sha256sum --check --ignore-missing checksums.txt)
tar -xzf "$download_dir/$archive" -C "$download_dir" entire git-remote-entire
mkdir -p "$install_dir"
install -m 0755 "$download_dir/entire" "$install_dir/entire"
install -m 0755 "$download_dir/git-remote-entire" "$install_dir/git-remote-entire"
"""
    return `/bin/sh -c $script entireio-install $release_url $install_dir`
end

function entireio_enable_command(state::AppState)
    agent = entireio_agent(state)
    return `entire enable --agent $agent --local --skip-push-sessions --telemetry=false --yes`
end

"""
    setup_entireio!(run_command, state)

Install Entire if necessary and enable recording before launching the agent.
`run_command` executes a command in the configured sandbox's working directory.
"""
function setup_entireio!(run_command::Function, state::AppState)
    state.use_entireio || return

    # --yes can initialize and publish a new repository when invoked outside
    # Git. Require an existing working tree before installing or enabling Entire.
    try
        run_command(`/bin/sh -c "git rev-parse --show-toplevel >/dev/null 2>&1"`)
    catch err
        err isa ProcessFailedException || rethrow()
        error("--entireio requires an existing Git working tree accessible inside the sandbox; use -w to select its root")
    end

    if !all(name -> isfile(joinpath(state.local_dir, "bin", name)), ("entire", "git-remote-entire"))
        cprintln(YELLOW, "Installing Entire CLI v$ENTIREIO_VERSION...")
        run_command(entireio_install_command())
    end

    cprintln(CYAN, "Enabling local Entire recording for $(entireio_agent(state))...")
    run_command(entireio_enable_command(state))
end
