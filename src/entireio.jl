# Pin the initial install to the release used to validate the hook integration.
# An already-installed CLI is reused, including one the user upgraded manually.
const ENTIREIO_VERSION = "0.10.6"
const ENTIREIO_RELEASE_URL = "https://github.com/entireio/cli/releases/download/v$ENTIREIO_VERSION"

# UserNSSandbox uses execve, which does not search PATH. Start an absolute shell
# and let it resolve the program, keeping every argument out of shell source.
function entireio_sandbox_command(cmd::Cmd)
    script = raw"""
exec "$@"
"""
    return `/bin/sh -c $script claudebox-entireio $cmd`
end

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
    return entireio_sandbox_command(`entire enable --agent $agent --local --skip-push-sessions --telemetry=false --yes`)
end

function entireio_agent_config_dir(state::AppState)
    state.use_codex && return ".codex"
    state.use_opencode && return joinpath(".opencode", "plugins")
    state.use_gemini && return ".gemini"
    return ".claude"
end

# Resolve a sandbox path through its most specific mount, then bind a private
# copy. Explicit bind mounts also work beneath a workspace volume in Docker,
# where image-based overlays would be hidden by that volume.
function isolate_entireio_dir!(mounts, path::String, session_dir::String)
    parents = filter(collect(keys(mounts))) do parent
        parent == "/" || path == parent || startswith(path, parent * "/")
    end
    parent = parents[argmax(length.(parents))]
    mount = mounts[parent]
    mount.type == Sandbox.MountType.Overlayed && return
    source = normpath(joinpath(mount.host_path, relpath(path, parent)))
    if ispath(source) && !isdir(source)
        error("--entireio requires a directory at $path")
    end
    private_dir = mktempdir(session_dir)
    if isdir(source)
        cp(realpath(source), private_dir; force=true, follow_symlinks=false)
    end
    mounts[path] = Sandbox.MountInfo(private_dir, Sandbox.MountType.ReadWrite)
end

"""
    with_entireio_mounts(f, state, mounts, read_command)

Keep Entire's settings and hook installation private to this sandbox invocation.
The workspace and Git database stay writable, so recorded checkpoints persist.
`read_command` resolves Git paths inside the sandbox, including core.hooksPath.
"""
function with_entireio_mounts(f::Function, state::AppState, mounts, read_command::Function)
    state.use_entireio || return f()

    # Preserve Git/launcher failures rather than labelling all of them as a
    # missing repository (e.g. a missing executable or unsafe ownership).
    repo_root = chomp(read_command(entireio_sandbox_command(`git rev-parse --show-toplevel`)))
    hooks_dir = chomp(read_command(entireio_sandbox_command(`git rev-parse --path-format=absolute --git-path hooks`)))
    git_dirs = split(chomp(read_command(entireio_sandbox_command(`git rev-parse --path-format=absolute --git-common-dir --git-dir`))), '\n')
    if any((repo_root, git_dirs...)) do persistent_path
        persistent_path == hooks_dir || startswith(persistent_path, hooks_dir * "/")
    end
        error("--entireio requires a dedicated Git hooks directory; core.hooksPath must not contain the working tree or Git database")
    end
    original_mounts = copy(mounts)
    mktempdir() do session_dir
        try
            for path in (joinpath(repo_root, ".entire"),
                         joinpath(repo_root, entireio_agent_config_dir(state)),
                         hooks_dir)
                isolate_entireio_dir!(mounts, String(path), session_dir)
            end
            return f()
        finally
            empty!(mounts)
            merge!(mounts, original_mounts)
        end
    end
end

"""
    setup_entireio!(run_command, state)

Install Entire if necessary and enable recording before launching the agent.
Call inside `with_entireio_mounts` so the settings and hooks do not reach the host.
`run_command` executes a command in the configured sandbox's working directory.
"""
function setup_entireio!(run_command::Function, state::AppState)
    state.use_entireio || return

    # --yes can initialize and publish a new repository when invoked outside
    # Git. Require an existing working tree before installing or enabling Entire.
    run_command(`/bin/sh -c "git rev-parse --show-toplevel >/dev/null"`)

    if !all(name -> isfile(joinpath(state.local_dir, "bin", name)), ("entire", "git-remote-entire"))
        cprintln(YELLOW, "Installing Entire CLI v$ENTIREIO_VERSION...")
        run_command(entireio_install_command())
    end

    cprintln(CYAN, "Enabling Entire recording for this invocation ($(entireio_agent(state)))...")
    run_command(entireio_enable_command(state))
end
