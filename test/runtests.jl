using Test
using ClaudeBox

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
    end
    
    @testset "State Initialization" begin
        # Test state creation
        state = ClaudeBox.initialize_state(pwd())
        @test state isa ClaudeBox.AppState
        @test isdir(state.tools_prefix)
        @test isdir(state.claude_prefix)
        @test state.work_dir == pwd()
        @test state.claude_args == String[]
    end
    
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
        @test contains(gitconfig_content, "sslCAInfo = /etc/ssl/certs/ca-certificates.crt")
        
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
    
    @testset "Build Tools Installation" begin
        # Create a test state and set up environment
        state = ClaudeBox.initialize_state(pwd())
        ClaudeBox.setup_environment!(state)
        
        # Verify all build tools are installed using the same function as the main code
        @test ClaudeBox.are_all_build_tools_installed(state) == true
        
        # Also verify individual tools to ensure the function is checking correctly
        @test isfile(joinpath(state.build_tools_dir, "bin", "git"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "make"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "rg"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "python3"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "less"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "ps"))
        @test isfile(joinpath(state.build_tools_dir, "tools", "clang"))
        
        # Verify binutils tools
        @test isfile(joinpath(state.build_tools_dir, "bin", "ld"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "as"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "objdump"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "ar"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "nm"))
        @test isfile(joinpath(state.build_tools_dir, "bin", "strip"))
        
        # Verify other tools
        @test isfile(joinpath(state.nodejs_dir, "bin", "node"))
        @test isfile(joinpath(state.gh_cli_dir, "bin", "gh"))
    end
end

println("\nAll tests passed!")