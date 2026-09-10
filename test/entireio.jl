@testset "Entire integration" begin
    options = ClaudeBox.parse_args(["--entireio", "--codex", "--model", "test-model"])
    @test options["entireio"]
    @test options["codex"]
    @test options["claude_args"] == ["--model", "test-model"]
    @test !ClaudeBox.parse_args(String[])["entireio"]

    state = ClaudeBox.initialize_state(pwd(); use_entireio=true)
    @test state.use_entireio
    @test !ClaudeBox.initialize_state(pwd()).use_entireio

    # Match the launcher precedence, including combinations of agent flags.
    for (gemini, opencode, codex, agent) in (
        (false, false, false, "claude-code"),
        (true, false, false, "gemini"),
        (false, true, false, "opencode"),
        (false, false, true, "codex"),
        (true, true, true, "codex"),
    )
        state.use_gemini = gemini
        state.use_opencode = opencode
        state.use_codex = codex
        @test ClaudeBox.entireio_enable_command(state).exec[5:end] ==
              ["entire", "enable", "--agent", agent, "--local", "--skip-push-sessions", "--telemetry=false", "--yes"]
    end

    state.use_entireio = false
    ClaudeBox.setup_entireio!(_ -> error("Entire must be opt-in"), state)
    state.use_entireio = true

    @testset "Sandbox executable lookup" begin
        mktempdir() do root
            repo = joinpath(root, "repository with spaces")
            bin_dir = joinpath(root, "bin")
            mkpath(repo)
            mkpath(bin_dir)
            run(`git init -q $repo`)
            symlink(Sys.which("git"), joinpath(bin_dir, "git"))
            args_file = joinpath(root, "entire-args")
            write(joinpath(bin_dir, "entire"), raw"""
#!/bin/sh
printf '%s\n' "$@" > "$CLAUDEBOX_TEST_ENTIRE_ARGS"
""")
            chmod(joinpath(bin_dir, "entire"), 0o755)
            touch(joinpath(bin_dir, "git-remote-entire"))
            write(joinpath(bin_dir, "arguments"), raw"""
#!/bin/sh
printf '%s\0' "$@"
""")
            chmod(joinpath(bin_dir, "arguments"), 0o755)

            # Match UserNSSandbox's execve semantics without needing permission
            # to create a namespace: execv also does not search PATH.
            exec_script = raw"""
ccall(:execv, Cint, (Cstring, Ptr{Cstring}), ARGS[1], ARGS)
println(stderr, "Failed to run ", ARGS[1], ": ", Libc.errno())
exit(1)
"""
            function direct_exec(cmd; path=bin_dir * ":" * ENV["PATH"])
                child = `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $exec_script $cmd`
                setenv(Cmd(child; dir=repo), Dict(
                    "PATH" => path,
                    "GIT_CONFIG_GLOBAL" => "/dev/null",
                    "GIT_CONFIG_NOSYSTEM" => "1",
                    "CLAUDEBOX_TEST_ENTIRE_ARGS" => args_file,
                ))
            end
            @test !success(pipeline(direct_exec(`git --version`); stdout=devnull, stderr=devnull))
            @test !success(pipeline(direct_exec(`entire enable`); stdout=devnull, stderr=devnull))

            # Exercise the production Git queries and Entire enable command
            # through a launcher that rejects bare executable names.
            scoped_state = ClaudeBox.initialize_state(repo; use_entireio=true)
            scoped_state.local_dir = root
            mounts = Dict(repo => ClaudeBox.Sandbox.MountInfo(repo, ClaudeBox.Sandbox.MountType.ReadWrite))
            ClaudeBox.with_entireio_mounts(scoped_state, mounts, cmd -> read(direct_exec(cmd), String)) do
                ClaudeBox.setup_entireio!(cmd -> run(direct_exec(cmd)), scoped_state)
            end
            @test readlines(args_file) == ["enable", "--agent", "claude-code", "--local", "--skip-push-sessions", "--telemetry=false", "--yes"]

            args = ["a path with spaces", "", "quote'\"", raw"$HOME", raw"$(touch injected)", "`touch injected`", "a;b", "*"]
            command = ClaudeBox.entireio_sandbox_command(Cmd(["arguments"; args]))
            @test split(read(direct_exec(command), String), '\0')[1:end-1] == args
            @test !ispath(joinpath(repo, "injected"))

            # Preserve launch errors, including the actual exit status and
            # stderr, instead of claiming an existing repository is missing.
            stderr_buffer = IOBuffer()
            failure = try
                ClaudeBox.with_entireio_mounts(scoped_state, mounts,
                    cmd -> read(pipeline(direct_exec(cmd; path=""); stderr=stderr_buffer), String)) do
                    error("Must not launch without Git")
                end
                nothing
            catch err
                err
            end
            @test failure isa ProcessFailedException
            if failure isa ProcessFailedException
                @test only(failure.procs).exitcode == 127
            end
            @test occursin("git: not found", String(take!(stderr_buffer)))
        end
    end

    @testset "Invocation-scoped configuration" begin
        mktempdir() do repo
            run(`git init -q $repo`)
            mkpath(joinpath(repo, ".entire"))
            original_settings = "{\"enabled\":false,\"telemetry\":false}\n"
            write(joinpath(repo, ".entire", "settings.local.json"), original_settings)
            original_hook = "#!/bin/sh\nexit 0\n"
            write(joinpath(repo, ".git", "hooks", "pre-commit"), original_hook)

            for (gemini, opencode, codex, config_dir) in (
                (false, false, false, ".claude"),
                (true, false, false, ".gemini"),
                (false, true, false, ".opencode/plugins"),
                (false, false, true, ".codex"),
                (true, true, true, ".codex"),
            )
                state.use_gemini, state.use_opencode, state.use_codex = gemini, opencode, codex
                for workspace_mount in ("/workspace", repo)
                    mounts = Dict(workspace_mount => ClaudeBox.Sandbox.MountInfo(repo, ClaudeBox.Sandbox.MountType.ReadWrite))
                    original_mounts = copy(mounts)
                    read_git(cmd) = replace(read(Cmd(cmd; dir=repo), String), repo => workspace_mount)
                    temporary_source = ""
                    result = ClaudeBox.with_entireio_mounts(state, mounts, read_git) do
                        @test mounts[workspace_mount].type == ClaudeBox.Sandbox.MountType.ReadWrite
                        for path in (".entire", config_dir, ".git/hooks")
                            @test mounts[joinpath(workspace_mount, path)].host_path != joinpath(repo, path)
                        end
                        private_settings = joinpath(mounts[joinpath(workspace_mount, ".entire")].host_path, "settings.local.json")
                        private_hook = joinpath(mounts[joinpath(workspace_mount, ".git/hooks")].host_path, "pre-commit")
                        @test read(private_settings, String) == original_settings
                        @test read(private_hook, String) == original_hook
                        write(private_settings, "{\"enabled\":true}\n")
                        write(private_hook, "#!/bin/sh\nentire hooks git pre-commit\n")
                        @test read(joinpath(repo, ".entire", "settings.local.json"), String) == original_settings
                        @test read(joinpath(repo, ".git", "hooks", "pre-commit"), String) == original_hook
                        @test !haskey(mounts, joinpath(workspace_mount, ".git"))
                        temporary_source = mounts[joinpath(workspace_mount, config_dir)].host_path
                        @test isdir(temporary_source)

                        # A simultaneous launch gets its own copies. Its exit
                        # must not remove or disable the first launch's mounts.
                        concurrent_mounts = copy(original_mounts)
                        ClaudeBox.with_entireio_mounts(state, concurrent_mounts, read_git) do
                            @test concurrent_mounts[joinpath(workspace_mount, config_dir)].host_path != temporary_source
                            @test read(joinpath(concurrent_mounts[joinpath(workspace_mount, ".entire")].host_path, "settings.local.json"), String) == original_settings
                        end
                        @test concurrent_mounts == original_mounts
                        @test isdir(temporary_source)
                        return :invocation_finished
                    end
                    @test result == :invocation_finished
                    @test mounts == original_mounts
                    @test !ispath(temporary_source)
                    @test read(joinpath(repo, ".entire", "settings.local.json"), String) == original_settings
                    @test read(joinpath(repo, ".git", "hooks", "pre-commit"), String) == original_hook

                    # A later invocation without the flag makes no Entire
                    # queries and receives the repository's original mounts.
                    state.use_entireio = false
                    @test ClaudeBox.with_entireio_mounts(() -> mounts == original_mounts, state, mounts,
                                                        _ -> error("Entire must be opt-in"))
                    state.use_entireio = true
                    @test_throws r"agent failed" ClaudeBox.with_entireio_mounts(state, mounts, read_git) do
                        error("agent failed")
                    end
                    @test mounts == original_mounts
                end
            end

            # Resolve the active hooks directory through Git, including a
            # repository's custom core.hooksPath, rather than assuming .git/hooks.
            custom_hooks = joinpath(repo, "custom hooks")
            mkpath(custom_hooks)
            run(`git -C $repo config core.hooksPath $custom_hooks`)
            mounts = Dict(repo => ClaudeBox.Sandbox.MountInfo(repo, ClaudeBox.Sandbox.MountType.ReadWrite))
            ClaudeBox.with_entireio_mounts(state, mounts, cmd -> read(Cmd(cmd; dir=repo), String)) do
                @test mounts[custom_hooks].type == ClaudeBox.Sandbox.MountType.ReadWrite
                @test mounts[custom_hooks].host_path != realpath(custom_hooks)
                @test !haskey(mounts, joinpath(repo, ".git", "hooks"))
            end
            for unsafe_hooks in (repo, joinpath(repo, ".git"))
                run(`git -C $repo config core.hooksPath $unsafe_hooks`)
                @test_throws r"dedicated Git hooks directory" ClaudeBox.with_entireio_mounts(
                    () -> error("Must not isolate the working tree or Git database"), state, mounts,
                    cmd -> read(Cmd(cmd; dir=repo), String))
            end
        end
    end

    @testset "Existing Git repository required" begin
        mktempdir() do dir
            calls = Cmd[]
            @test_throws ProcessFailedException ClaudeBox.setup_entireio!(state) do cmd
                push!(calls, cmd)
                length(calls) == 1 || error("Must reject a non-repository before installing Entire")
                run(Cmd(cmd; dir))
            end
            @test length(calls) == 1
            @test !ispath(joinpath(dir, ".git"))
        end
    end

    @testset "Reuse cached installation" begin
        mktempdir() do dir
            run(`git init -q $dir`)
            state.local_dir = joinpath(dir, "local")
            mkpath(joinpath(state.local_dir, "bin"))
            for binary in ("entire", "git-remote-entire")
                touch(joinpath(state.local_dir, "bin", binary))
            end
            calls = Cmd[]
            ClaudeBox.setup_entireio!(state) do cmd
                push!(calls, cmd)
                if length(calls) == 1
                    run(Cmd(cmd; dir))
                end
            end
            @test length(calls) == 2
            @test calls[end].exec == ClaudeBox.entireio_enable_command(state).exec
        end
    end

    @testset "Checksum-verified installation" begin
        mktempdir() do dir
            release_dir = joinpath(dir, "release files")
            payload_dir = joinpath(dir, "payload")
            install_dir = joinpath(dir, "installed binaries")
            mkpath(release_dir)
            mkpath(payload_dir)
            for binary in ("entire", "git-remote-entire")
                write(joinpath(payload_dir, binary), "#!/bin/sh\nprintf '%s\\n' $binary-fixture\n")
            end
            arch = Sys.ARCH == :x86_64 ? "amd64" : "arm64"
            archive_name = "entire_linux_$(arch).tar.gz"
            archive = joinpath(release_dir, archive_name)
            run(`tar -czf $archive -C $payload_dir entire git-remote-entire`)
            checksum = first(split(read(`sha256sum $archive`, String)))
            checksums_file = joinpath(release_dir, "checksums.txt")
            write(checksums_file, "$checksum  $archive_name\n")
            release_url = "file://" * replace(release_dir, " " => "%20")
            install_cmd = ClaudeBox.entireio_install_command(; release_url, install_dir)

            run(install_cmd)
            @test readchomp(`$(joinpath(install_dir, "entire"))`) == "entire-fixture"
            @test readchomp(`$(joinpath(install_dir, "git-remote-entire"))`) == "git-remote-entire-fixture"

            # A failed checksum must leave an existing installation intact.
            write(joinpath(install_dir, "entire"), "keep this installation")
            write(checksums_file, "$(repeat("0", 64))  $archive_name\n")
            @test_throws ProcessFailedException run(install_cmd)
            @test read(joinpath(install_dir, "entire"), String) == "keep this installation"
        end
    end
end
