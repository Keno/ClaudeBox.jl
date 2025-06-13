module GitHubAuth

using HTTP
using JSON
using GitHub

const CLIENT_ID = "Iv23liWHeR3R9yYlUhqm"
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
end

function request_device_code()
    response = HTTP.post(
        DEVICE_CODE_URL,
        ["Accept" => "application/json"],
        "client_id=$(CLIENT_ID)&scope=repo"
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

function poll_for_token(device_code::String, interval::Int)
    while true
        response = HTTP.post(
            ACCESS_TOKEN_URL,
            ["Accept" => "application/json"],
            "client_id=$(CLIENT_ID)&device_code=$(device_code)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        )
        
        data = JSON.parse(String(response.body))
        
        if haskey(data, "access_token")
            return AccessTokenResponse(
                data["access_token"],
                data["token_type"],
                data["scope"]
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

function authenticate()
    println("\n🔐 GitHub Authorization Request")
    println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    println("This will securely authorize access to your GitHub repositories")
    println("without requiring a full personal access token. The app will only")
    println("have access to repositories you explicitly grant permission to.")
    println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    println("\nRequesting device code...")
    device_response = request_device_code()
    
    println("\nPlease visit: $(device_response.verification_uri)")
    println("And enter code: $(device_response.user_code)")
    println("\nWaiting for authorization...")
    
    token_response = poll_for_token(device_response.device_code, device_response.interval)
    
    println("\nAuthentication successful!")
    return token_response.access_token
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

end # module