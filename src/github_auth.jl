module GitHubAuth

using HTTP
using JSON
using GitHub

const DEFAULT_CLIENT_ID = "Iv23liWHeR3R9yYlUhqm"
const DANGEROUS_CLIENT_ID = "Iv23lixNKn0ZUEkVwNzp"
const DEVICE_CODE_URL = "https://github.com/login/device/code"
const ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"

struct DeviceCodeResponse
    device_code::String
    user_code::String
    verification_uri::String
    expires_in::Int
    interval::Int
end

struct AccessTokenResponse
    access_token::String
    token_type::String
    scope::String
    refresh_token::Union{String, Nothing}
    expires_in::Union{Int, Nothing}
    refresh_token_expires_in::Union{Int, Nothing}
end

function request_device_code(client_id::String=DEFAULT_CLIENT_ID)
    response = HTTP.post(
        DEVICE_CODE_URL,
        ["Accept" => "application/json"],
        "client_id=$(client_id)&scope=repo"
    )
    
    if response.status != 200
        error("Failed to request device code: $(response.status)")
    end
    
    data = JSON.parse(String(response.body))
    return DeviceCodeResponse(
        data["device_code"],
        data["user_code"],
        data["verification_uri"],
        data["expires_in"],
        data["interval"]
    )
end

function poll_for_token(device_code::String, interval::Int, client_id::String=DEFAULT_CLIENT_ID)
    while true
        response = HTTP.post(
            ACCESS_TOKEN_URL,
            ["Accept" => "application/json"],
            "client_id=$(client_id)&device_code=$(device_code)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        )
        
        data = JSON.parse(String(response.body))
        
        if haskey(data, "access_token")
            return AccessTokenResponse(
                data["access_token"],
                data["token_type"],
                data["scope"],
                get(data, "refresh_token", nothing),
                get(data, "expires_in", nothing),
                get(data, "refresh_token_expires_in", nothing)
            )
        elseif haskey(data, "error")
            if data["error"] == "authorization_pending"
                sleep(interval)
                continue
            elseif data["error"] == "slow_down"
                sleep(interval + 5)
                continue
            else
                error("Authentication failed: $(data["error"])")
            end
        end
    end
end

function authenticate(; dangerous_mode::Bool=false)
    client_id = dangerous_mode ? DANGEROUS_CLIENT_ID : DEFAULT_CLIENT_ID
    device_response = request_device_code(client_id)
    
    println("\nPlease visit: $(device_response.verification_uri)")
    println("And enter code: $(device_response.user_code)")
    if dangerous_mode
        println("\n⚠️  Using DANGEROUS mode with broader permissions!")
    end
    println("\nWaiting for authorization (press Ctrl+C to skip)...")
    
    token_response = poll_for_token(device_response.device_code, device_response.interval, client_id)
    
    println("\nAuthentication successful!")
    return token_response
end

function validate_token(token::String; silent::Bool=false)
    try
        # Make a simple API call to validate the token
        response = HTTP.get(
            "https://api.github.com/user",
            ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github.v3+json"]
        )
        
        if response.status == 200
            user_data = JSON.parse(String(response.body))
            if !silent
                println("Authenticated as: $(user_data["login"])")
            end
            return true
        else
            return false
        end
    catch e
        if !silent
            println("Token validation failed: $e")
        end
        return false
    end
end

function get_user_info(token::String)
    try
        response = HTTP.get(
            "https://api.github.com/user",
            ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github.v3+json"]
        )
        
        if response.status == 200
            user_data = JSON.parse(String(response.body))
            return (
                login = something(get(user_data, "login", nothing), ""),
                name = something(get(user_data, "name", nothing), ""),
                email = something(get(user_data, "email", nothing), "")
            )
        end
    catch e
        # Return empty values on error
    end
    return (login = "", name = "", email = "")
end

function refresh_access_token(refresh_token::String; dangerous_mode::Bool=false)
    client_id = dangerous_mode ? DANGEROUS_CLIENT_ID : DEFAULT_CLIENT_ID
    try
        response = HTTP.post(
            ACCESS_TOKEN_URL,
            ["Accept" => "application/json"],
            "client_id=$(client_id)&refresh_token=$(refresh_token)&grant_type=refresh_token"
        )
        
        if response.status == 200
            data = JSON.parse(String(response.body))
            if haskey(data, "access_token")
                return AccessTokenResponse(
                    data["access_token"],
                    data["token_type"],
                    data["scope"],
                    get(data, "refresh_token", refresh_token),  # May return same or new refresh token
                    get(data, "expires_in", nothing),
                    get(data, "refresh_token_expires_in", nothing)
                )
            end
        end
    catch e
        # Refresh failed, return nothing
    end
    return nothing
end

function check_claude_sandbox_repo(token::String)
    try
        # Get authenticated user info
        user_response = HTTP.get(
            "https://api.github.com/user",
            ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github.v3+json"]
        )
        
        if user_response.status != 200
            return nothing
        end
        
        user_data = JSON.parse(String(user_response.body))
        username = user_data["login"]
        
        # Check if .claude_sandbox repo exists
        repo_response = HTTP.get(
            "https://api.github.com/repos/$username/.claude_sandbox",
            ["Authorization" => "Bearer $token", "Accept" => "application/vnd.github.v3+json"]
        )
        
        if repo_response.status == 200
            repo_data = JSON.parse(String(repo_response.body))
            return (
                clone_url = repo_data["clone_url"],
                ssh_url = repo_data["ssh_url"],
                username = username
            )
        end
    catch e
        # Repository doesn't exist or other error
    end
    return nothing
end

end # module