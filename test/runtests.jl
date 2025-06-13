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
end

println("\nAll tests passed!")