using ClaudeBox

# Initialize state
state = ClaudeBox.initialize_state(pwd())

# Test toolchain setup
println("Testing toolchain setup...")
ClaudeBox.setup_environment!(state)

# Check if toolchain binaries exist
toolchain_dir = state.toolchain_dir
println("\nChecking toolchain binaries in: $toolchain_dir")

binaries = ["gcc", "g++", "ar", "ld", "nm", "objdump", "strip", "ranlib"]
for binary in binaries
    # Look for x86_64-linux-gnu-<binary>
    binary_path = joinpath(toolchain_dir, "bin", "x86_64-linux-gnu-$binary")
    if isfile(binary_path)
        println("✓ Found: $binary_path")
    else
        println("✗ Missing: $binary_path")
        # Check if it exists without prefix
        alt_path = joinpath(toolchain_dir, "bin", binary)
        if isfile(alt_path)
            println("  → Found alternative: $alt_path")
        end
    end
end

# List what's actually in the bin directory
println("\nContents of $(joinpath(toolchain_dir, "bin")):")
if isdir(joinpath(toolchain_dir, "bin"))
    for file in readdir(joinpath(toolchain_dir, "bin"))
        println("  - $file")
    end
else
    println("  Directory does not exist!")
end