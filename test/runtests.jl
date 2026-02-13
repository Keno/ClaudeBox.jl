using Test
using ClaudeBox
using ClaudeBox.Sandbox

# Check if running in CI (JULIA_PKGTEST is set by GitHub Actions)
const IS_CI = haskey(ENV, "JULIA_PKGTEST") || haskey(ENV, "CI")

@testset "ClaudeBox Tests" begin
    @testset "Argument Parsing" begin
        # Test help parsing
        options = ClaudeBox.parse_args(String["--help"])
        @test options["help"] == true

        # Test version parsing
        options = ClaudeBox.parse_args(String["--version"])
        @test options["version"] == true

        # Test reset parsing
        options = ClaudeBox.parse_args(String["--reset"])
        @test options["reset"] == true

        # Test work directory parsing
        options = ClaudeBox.parse_args(String["-w", "/tmp"])
        @test options["work_dir"] == "/tmp"

        # Test default work directory
        options = ClaudeBox.parse_args(String[])
        @test options["work_dir"] == pwd()

        # Test gemini parsing
        options = ClaudeBox.parse_args(String["--gemini"])
        @test options["gemini"] == true

        # Test gemini default is false
        options = ClaudeBox.parse_args(String[])
        @test options["gemini"] == false

        # Test opencode parsing
        options = ClaudeBox.parse_args(String["--opencode"])
        @test options["opencode"] == true

        # Test opencode default is false
        options = ClaudeBox.parse_args(String[])
        @test options["opencode"] == false

        # Test codex parsing
        options = ClaudeBox.parse_args(String["--codex"])
        @test options["codex"] == true

        # Test codex default is false
        options = ClaudeBox.parse_args(String[])
        @test options["codex"] == false
    end

    @testset "State Initialization" begin
        # Test state creation
        state = ClaudeBox.initialize_state(pwd())
        @test state isa ClaudeBox.AppState
        @test isdir(state.tools_prefix)
        @test isdir(state.claude_prefix)
        @test state.work_dir == pwd()
        @test state.claude_args == String[]
        @test state.use_gemini == false
        @test state.use_opencode == false
        @test state.use_codex == false

        # Test state creation with gemini flag
        state_gemini = ClaudeBox.initialize_state(pwd(), String[], false, false, true, false, false)
        @test state_gemini.use_gemini == true
        @test state_gemini.use_opencode == false
        @test state_gemini.use_codex == false

        # Test state creation with opencode flag
        state_opencode = ClaudeBox.initialize_state(pwd(), String[], false, false, false, true, false)
        @test state_opencode.use_gemini == false
        @test state_opencode.use_opencode == true
        @test state_opencode.use_codex == false

        # Test state creation with codex flag
        state_codex = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, true)
        @test state_codex.use_gemini == false
        @test state_codex.use_opencode == false
        @test state_codex.use_codex == true

        # Test gemini_home_dir is created
        @test isdir(state.gemini_home_dir)
        @test state.gemini_home_dir == joinpath(state.claude_prefix, "gemini_home")

        # Test opencode_home_dir is created
        @test isdir(state.opencode_home_dir)
        @test state.opencode_home_dir == joinpath(state.claude_prefix, "opencode_home")
        # Test opencode bin directory is created (for native installation)
        @test isdir(joinpath(state.opencode_home_dir, "bin"))

        # Test codex_home_dir is created
        @test isdir(state.codex_home_dir)
        @test state.codex_home_dir == joinpath(state.claude_prefix, "codex_home")
    end

    # Skip tests requiring full environment setup in CI (requires JuliaHub authentication)
    if !IS_CI
    @testset "Git Config in Sandbox" begin
        # Create a test state and set up environment
        state = ClaudeBox.initialize_state(pwd())
        ClaudeBox.setup_environment!(state)

        # Create sandbox config
        config = ClaudeBox.create_sandbox_config(state)

        # Verify that gitconfig file is created
        gitconfig_path = joinpath(state.tools_prefix, "gitconfig")
        @test isfile(gitconfig_path)

        # Read and verify gitconfig contents
        gitconfig_content = read(gitconfig_path, String)

        # Verify expected sections and keys
        @test contains(gitconfig_content, "[http]")
        @test contains(gitconfig_content, "sslCAInfo = /opt/bb2-tools/etc/certs/ca-certificates.crt")

        @test contains(gitconfig_content, "[user]")
        @test contains(gitconfig_content, "name =")
        @test contains(gitconfig_content, "email =")

        @test contains(gitconfig_content, "[credential]")
        @test contains(gitconfig_content, "helper = /opt/build_tools/bin/git-credential-gh")

        @test contains(gitconfig_content, "[url \"https://github.com/\"]")
        @test contains(gitconfig_content, "insteadOf = git@github.com:")
        @test contains(gitconfig_content, "insteadOf = ssh://git@github.com/")

        # Verify credential helper script exists
        credential_helper_path = joinpath(state.build_tools_dir, "bin", "git-credential-gh")
        @test isfile(credential_helper_path)

        # Verify mount configuration includes gitconfig
        mounts = config.mounts
        @test haskey(mounts, "/root/.gitconfig")
        @test mounts["/root/.gitconfig"].host_path == gitconfig_path
    end

    @testset "Gemini Configuration Mounting" begin
        # Test with gemini mode enabled
        state_gemini = ClaudeBox.initialize_state(pwd(), String[], false, false, true, false, false)  # use_gemini = true
        ClaudeBox.setup_environment!(state_gemini)

        # Create sandbox config
        config_gemini = ClaudeBox.create_sandbox_config(state_gemini)

        # Verify that gemini_home_dir mount is included
        mounts_gemini = config_gemini.mounts
        @test haskey(mounts_gemini, "/root/.gemini")

        # Check if external .gemini directory exists
        external_gemini_dir = expanduser("~/.gemini")
        if isdir(external_gemini_dir)
            # The external directory should override the sandbox directory when using Gemini
            @test mounts_gemini["/root/.gemini"].host_path == external_gemini_dir
        else
            # Otherwise, should use the sandbox gemini_home_dir
            @test mounts_gemini["/root/.gemini"].host_path == state_gemini.gemini_home_dir
        end

        # Test with claude mode (gemini disabled)
        state_claude = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, false)  # use_gemini = false
        ClaudeBox.setup_environment!(state_claude)
        config_claude = ClaudeBox.create_sandbox_config(state_claude)
        mounts_claude = config_claude.mounts

        # When not using Gemini, external .gemini should NOT be mounted
        if isdir(external_gemini_dir)
            # The sandbox gemini_home_dir should still be mounted, but not the external one
            @test haskey(mounts_claude, "/root/.gemini")
            @test mounts_claude["/root/.gemini"].host_path == state_claude.gemini_home_dir
        else
            # If no external dir exists, should just have the sandbox dir
            @test haskey(mounts_claude, "/root/.gemini")
            @test mounts_claude["/root/.gemini"].host_path == state_claude.gemini_home_dir
        end

        # Verify environment variables for Gemini are included
        env = config_gemini.env
        @test haskey(env, "GOOGLE_API_KEY")
        @test haskey(env, "GEMINI_API_KEY")
    end

    @testset "OpenCode Configuration Mounting" begin
        # Test with opencode mode enabled
        state_opencode = ClaudeBox.initialize_state(pwd(), String[], false, false, false, true, false)  # use_opencode = true
        ClaudeBox.setup_environment!(state_opencode)

        # Create sandbox config
        config_opencode = ClaudeBox.create_sandbox_config(state_opencode)

        # Verify that opencode_home_dir mount is included
        mounts_opencode = config_opencode.mounts
        @test haskey(mounts_opencode, "/root/.opencode")

        # Check if external .opencode directory exists
        external_opencode_dir = expanduser("~/.opencode")
        if isdir(external_opencode_dir)
            # The external directory should override the sandbox directory when using OpenCode
            @test mounts_opencode["/root/.opencode"].host_path == external_opencode_dir
        else
            # Otherwise, should use the sandbox opencode_home_dir
            @test mounts_opencode["/root/.opencode"].host_path == state_opencode.opencode_home_dir
        end

        # Test with claude mode (opencode disabled)
        state_claude = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, false)  # use_opencode = false
        ClaudeBox.setup_environment!(state_claude)
        config_claude = ClaudeBox.create_sandbox_config(state_claude)
        mounts_claude = config_claude.mounts

        # When not using OpenCode, external .opencode should NOT be mounted
        if isdir(external_opencode_dir)
            # The sandbox opencode_home_dir should still be mounted, but not the external one
            @test haskey(mounts_claude, "/root/.opencode")
            @test mounts_claude["/root/.opencode"].host_path == state_claude.opencode_home_dir
        else
            # If no external dir exists, should just have the sandbox dir
            @test haskey(mounts_claude, "/root/.opencode")
            @test mounts_claude["/root/.opencode"].host_path == state_claude.opencode_home_dir
        end

        # Verify environment variables for OpenCode are included
        env = config_opencode.env
        @test haskey(env, "OPENAI_API_KEY")
        @test haskey(env, "GROQ_API_KEY")
        # OpenCode also uses these
        @test haskey(env, "ANTHROPIC_API_KEY")
        @test haskey(env, "GEMINI_API_KEY")
    end

    @testset "Codex Configuration Mounting" begin
        # Test with codex mode enabled
        state_codex = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, true)  # use_codex = true
        ClaudeBox.setup_environment!(state_codex)

        # Create sandbox config
        config_codex = ClaudeBox.create_sandbox_config(state_codex)

        # Verify that codex_home_dir mount is included
        mounts_codex = config_codex.mounts
        @test haskey(mounts_codex, "/root/.codex")

        # Check if external .codex directory exists
        external_codex_dir = expanduser("~/.codex")
        if isdir(external_codex_dir)
            # The external directory should override the sandbox directory when using Codex
            @test mounts_codex["/root/.codex"].host_path == external_codex_dir
        else
            # Otherwise, should use the sandbox codex_home_dir
            @test mounts_codex["/root/.codex"].host_path == state_codex.codex_home_dir
        end

        # Test with claude mode (codex disabled)
        state_claude = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, false)  # use_codex = false
        ClaudeBox.setup_environment!(state_claude)
        config_claude = ClaudeBox.create_sandbox_config(state_claude)
        mounts_claude = config_claude.mounts

        # When not using Codex, external .codex should NOT be mounted
        if isdir(external_codex_dir)
            # The sandbox codex_home_dir should still be mounted, but not the external one
            @test haskey(mounts_claude, "/root/.codex")
            @test mounts_claude["/root/.codex"].host_path == state_claude.codex_home_dir
        else
            # If no external dir exists, should just have the sandbox dir
            @test haskey(mounts_claude, "/root/.codex")
            @test mounts_claude["/root/.codex"].host_path == state_claude.codex_home_dir
        end

        # Verify environment variables for Codex are included (uses OPENAI_API_KEY)
        env = config_codex.env
        @test haskey(env, "OPENAI_API_KEY")
    end

    @testset "Build Tools Installation" begin
        # Create a test state and set up environment
        state = ClaudeBox.initialize_state(pwd())
        ClaudeBox.setup_environment!(state)

        # Verify tools installed in build_tools_dir (only the ones actually installed by BB2 setup)
        @test isfile(joinpath(state.build_tools_dir, "bin", "rg"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "python3"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "less"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "ps"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "curl"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "jq"))

        # Verify other tools
        @test isfile(joinpath(state.nodejs_dir, "bin", "node"))
        @test isfile(joinpath(state.gh_cli_dir, "bin", "gh"))

        # Verify BB2 toolchain directory exists and has content
        @test isdir(state.toolchain_dir)
        @test !isempty(readdir(state.toolchain_dir))

        # The toolchain provides Git, Make, GCC, Binutils, etc. through the BB2 toolchain
        # These are mounted at runtime in /opt/bb2-* directories in the sandbox
    end

    @testset "CLI Command Validation" begin
        # This test validates that the CLI commands work correctly in the sandbox
        # It tests running --help to ensure the commands are properly formed

        # First, ensure the CLIs are installed
        state = ClaudeBox.initialize_state(pwd())
        ClaudeBox.setup_environment!(state)

        # After setup, all CLIs should be installed
        @test state.claude_installed == true
        @test state.gemini_installed == true
        @test state.opencode_installed == true
        @test state.codex_installed == true

        # Test 1: Claude with --help (use_gemini = false, use_opencode = false, use_codex = false)
        state_claude = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, false)
        state_claude.claude_installed = true
        state_claude.gemini_installed = true
        state_claude.opencode_installed = true
        state_claude.codex_installed = true

        println("Testing claude command construction and execution...")
        claude_cmd = ClaudeBox.build_cli_command(state_claude, ["--help"]; use_full_path=true)
        println("  Command: $claude_cmd")

        # Capture output to verify the command works
        output = IOBuffer()
        config = ClaudeBox.create_sandbox_config(state_claude; stdout=output, stderr=output)

        claude_result = Sandbox.with_executor() do exe
            try
                run(exe, config, claude_cmd)

                # Check the output
                output_str = String(take!(output))
                @test !isempty(output_str)
                @test occursin("claude", lowercase(output_str)) || occursin("help", lowercase(output_str))

                println("✓ Claude command executed successfully")
                return true
            catch e
                println("✗ Claude command failed: $e")
                return false
            end
        end

        @test claude_result == true

        # Test 2: Gemini with --help (use_gemini = true)
        state_gemini = ClaudeBox.initialize_state(pwd(), String[], false, false, true, false, false)
        state_gemini.claude_installed = true
        state_gemini.gemini_installed = true
        state_gemini.opencode_installed = true
        state_gemini.codex_installed = true

        println("\nTesting gemini command construction and execution...")
        gemini_cmd = ClaudeBox.build_cli_command(state_gemini, ["--help"]; use_full_path=true)
        println("  Command: $gemini_cmd")

        # Capture output to verify the command works
        output = IOBuffer()
        config = ClaudeBox.create_sandbox_config(state_gemini; stdout=output, stderr=output)

        gemini_result = Sandbox.with_executor() do exe
            try
                run(exe, config, gemini_cmd)

                # Check the output
                output_str = String(take!(output))
                @test !isempty(output_str)
                @test occursin("gemini", lowercase(output_str)) || occursin("help", lowercase(output_str))

                println("✓ Gemini command executed successfully")
                return true
            catch e
                println("✗ Gemini command failed: $e")
                return false
            end
        end

        @test gemini_result == true

        # Test 3: OpenCode with --help (use_opencode = true)
        state_opencode = ClaudeBox.initialize_state(pwd(), String[], false, false, false, true, false)
        state_opencode.claude_installed = true
        state_opencode.gemini_installed = true
        state_opencode.opencode_installed = true
        state_opencode.codex_installed = true

        println("\nTesting opencode command construction and execution...")
        opencode_cmd = ClaudeBox.build_cli_command(state_opencode, ["--help"]; use_full_path=true)
        println("  Command: $opencode_cmd")

        # Capture output to verify the command works
        output = IOBuffer()
        config = ClaudeBox.create_sandbox_config(state_opencode; stdout=output, stderr=output)

        opencode_result = Sandbox.with_executor() do exe
            try
                run(exe, config, opencode_cmd)

                # Check the output
                output_str = String(take!(output))
                @test !isempty(output_str)
                @test occursin("opencode", lowercase(output_str)) || occursin("help", lowercase(output_str))

                println("✓ OpenCode command executed successfully")
                return true
            catch e
                println("✗ OpenCode command failed: $e")
                return false
            end
        end

        @test opencode_result == true

        # Test 4: Codex with --help (use_codex = true)
        state_codex = ClaudeBox.initialize_state(pwd(), String[], false, false, false, false, true)
        state_codex.claude_installed = true
        state_codex.gemini_installed = true
        state_codex.opencode_installed = true
        state_codex.codex_installed = true

        println("\nTesting codex command construction and execution...")
        codex_cmd = ClaudeBox.build_cli_command(state_codex, ["--help"]; use_full_path=true)
        println("  Command: $codex_cmd")

        # Capture output to verify the command works
        output = IOBuffer()
        config = ClaudeBox.create_sandbox_config(state_codex; stdout=output, stderr=output)

        codex_result = Sandbox.with_executor() do exe
            try
                run(exe, config, codex_cmd)

                # Check the output
                output_str = String(take!(output))
                @test !isempty(output_str)
                @test occursin("codex", lowercase(output_str)) || occursin("help", lowercase(output_str))

                println("✓ Codex command executed successfully")
                return true
            catch e
                println("✗ Codex command failed: $e")
                return false
            end
        end

        @test codex_result == true

        # Test 5: Test with arguments passed through claude_args
        state_with_args = ClaudeBox.initialize_state(pwd(), ["--version"], false, false, true, false, false)
        state_with_args.claude_installed = true
        state_with_args.gemini_installed = true
        state_with_args.opencode_installed = true
        state_with_args.codex_installed = true

        println("\nTesting command with arguments from state...")
        args_cmd = ClaudeBox.build_cli_command(state_with_args; use_full_path=true)
        println("  Command: $args_cmd")

        # Capture output to verify the command works
        output = IOBuffer()
        config = ClaudeBox.create_sandbox_config(state_with_args; stdout=output, stderr=output)

        args_result = Sandbox.with_executor() do exe
            try
                run(exe, config, args_cmd)

                # Check the output
                output_str = String(take!(output))
                @test !isempty(output_str)
                # Should show version info
                @test occursin("version", lowercase(output_str)) || occursin("gemini", lowercase(output_str)) || occursin(r"\d+\.\d+\.\d+", output_str)

                println("✓ Command with args executed successfully")
                return true
            catch e
                println("✗ Command with args failed: $e")
                return false
            end
        end

        @test args_result == true

        # Test 6: Test our command construction logic
        # Verify that each CLI gets the right flags
        println("\nTesting command construction logic...")

        # Build commands and verify they have the right structure
        claude_test_cmd = ClaudeBox.build_cli_command(state_claude; use_full_path=false)
        gemini_test_cmd = ClaudeBox.build_cli_command(state_gemini; use_full_path=false)
        opencode_test_cmd = ClaudeBox.build_cli_command(state_opencode; use_full_path=false)
        codex_test_cmd = ClaudeBox.build_cli_command(state_codex; use_full_path=false)

        # Convert to strings to check content
        claude_str = string(claude_test_cmd)
        gemini_str = string(gemini_test_cmd)
        opencode_str = string(opencode_test_cmd)
        codex_str = string(codex_test_cmd)

        # Claude should have the flag
        @test occursin("--dangerously-skip-permissions", claude_str)

        # Gemini should NOT have the flag, but should have --yolo
        @test !occursin("--dangerously-skip-permissions", gemini_str)
        @test occursin("--yolo", gemini_str)

        # OpenCode should NOT have any special flags
        @test !occursin("--dangerously-skip-permissions", opencode_str)
        @test !occursin("--yolo", opencode_str)
        @test !occursin("--full-auto", opencode_str)

        # Codex should have --dangerously-bypass-approvals-and-sandbox
        @test !occursin("--dangerously-skip-permissions", codex_str)
        @test !occursin("--yolo", codex_str)
        @test occursin("--dangerously-bypass-approvals-and-sandbox", codex_str)

        println("✓ Command construction logic is correct")
    end
    else
        @info "Skipping environment setup tests in CI (requires JuliaHub authentication)"
    end  # if !IS_CI
end

println("\nAll tests passed!")