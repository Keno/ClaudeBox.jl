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
        @test ClaudeBox.entireio_enable_command(state).exec ==
              ["entire", "enable", "--agent", agent, "--local", "--skip-push-sessions", "--telemetry=false", "--yes"]
    end

    state.use_entireio = false
    ClaudeBox.setup_entireio!(_ -> error("Entire must be opt-in"), state)
    state.use_entireio = true

    @testset "Existing Git repository required" begin
        mktempdir() do dir
            calls = Cmd[]
            @test_throws r"--entireio requires an existing Git working tree" ClaudeBox.setup_entireio!(state) do cmd
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
                if first(cmd.exec) == "/bin/sh"
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
