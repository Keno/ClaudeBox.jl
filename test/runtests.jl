using Test
using ClaudeSandboxApp

@testset "ClaudeSandboxApp Tests" begin
    @testset "Argument Parsing" begin
        # Test help parsing
        options = ClaudeSandboxApp.parse_args(String["--help"])
        @test options["help"] == true
        
        # Test version parsing
        options = ClaudeSandboxApp.parse_args(String["--version"])
        @test options["version"] == true
        
        # Test reset parsing
        options = ClaudeSandboxApp.parse_args(String["--reset"])
        @test options["reset"] == true
        
        # Test work directory parsing
        options = ClaudeSandboxApp.parse_args(String["-w", "/tmp"])
        @test options["work_dir"] == "/tmp"
        
        # Test default work directory
        options = ClaudeSandboxApp.parse_args(String[])
        @test options["work_dir"] == pwd()
    end
    
    @testset "State Initialization" begin
        # Test state creation
        state = ClaudeSandboxApp.initialize_state(pwd())
        @test state isa ClaudeSandboxApp.AppState
        @test isdir(state.prefix_dir)
        @test state.work_dir == pwd()
    end
end

println("\nAll tests passed!")