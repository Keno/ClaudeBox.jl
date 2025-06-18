#!/usr/bin/env julia

using ClaudeBox

# Test if make is available in the sandbox
println("Testing GNUMake_jll integration in ClaudeBox...")

# Create a simple Makefile for testing
makefile_content = """
.PHONY: test
test:
\t@echo "Hello from GNU Make!"
\t@echo "Make version:"
\t@make --version | head -n1
"""

# Write the Makefile
write("Makefile", makefile_content)

println("\nCreated test Makefile")
println("Run 'claudebox' and then 'make test' to verify GNU Make is working")