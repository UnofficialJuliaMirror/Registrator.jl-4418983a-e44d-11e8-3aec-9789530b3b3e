using Registrator: Registrator
using Registrator.WebUI: @gf
using GitForge: GitForge, get_user
using GitForge.GitHub: GitHub, GitHubAPI, NoToken, Token
using HTTP: HTTP
using Sockets: Sockets
using Distributed
using JSON, JWTs

const UI = Registrator.WebUI

empty!(UI.CONFIG)
merge!(UI.CONFIG, Dict(
    "ip" => "localhost",
    "port" => 4000,
    "registry_url" => "https://github.com/JuliaRegistries/General",
    "server_url" => "http://localhost:4000",
    "github" => Dict{String, Any}(
        # We need a token to avoid rate limits on Travis.
        "token" => get(ENV, "GITHUB_API_TOKEN", ""),
        "client_id" => "",
        "client_secret" => "",
    ),
    "gitlab" => Dict{String, Any}(
        "token" => "",
        "client_id" => "",
        "client_secret" => "",
    ),
))

const backup = deepcopy(UI.CONFIG)

function restoreconfig!()
    empty!(UI.CONFIG)
    merge!(UI.CONFIG, deepcopy(backup))
end

@testset "Web UI" begin
    @testset "Provider initialization" begin
        UI.init_providers()
        @test length(UI.PROVIDERS) == 2
        @test Set(collect(keys(UI.PROVIDERS))) == Set(["github", "gitlab"])
        empty!(UI.PROVIDERS)

        delete!(UI.CONFIG, "github")
        UI.CONFIG["gitlab"]["disable_rate_limits"] = true
        UI.init_providers()
        @test collect(keys(UI.PROVIDERS)) == ["gitlab"]
        @test !GitForge.has_rate_limits(UI.PROVIDERS["gitlab"].client, identity)
        empty!(UI.PROVIDERS)
        restoreconfig!()

        mktemp() do path, io
            extra_provider = """
                PROVIDERS["myprovider"] = Provider(;
                    name="MyProvider",
                    client=GitHubAPI(),
                    client_id="abc",
                    client_secret="abc",
                    auth_url="abc",
                    token_url="abc",
                    scope="public_repo",
                )
                """
            print(io, extra_provider)
            close(io)

            UI.CONFIG["extra_providers"] = path
            UI.init_providers()
            @test haskey(UI.PROVIDERS, "myprovider")
            empty!(UI.PROVIDERS)
            restoreconfig!()
        end
    end

    # Patch the GitHub API client to avoid needing a real API key.
    t = isempty(UI.CONFIG["github"]["token"]) ? NoToken() : Token(UI.CONFIG["github"]["token"])
    UI.init_providers()
    UI.PROVIDERS["github"] = UI.Provider(;
        name="GitHub",
        client=GitHubAPI(; token=t),
        client_id=UI.CONFIG["github"]["client_id"],
        client_secret=UI.CONFIG["github"]["client_secret"],
        auth_url="https://github.com/login/oauth/authorize",
        token_url="https://github.com/login/oauth/access_token",
        scope="public_repo",
    )

    @testset "Registry initialization" begin
        UI.init_registry()
        reg = UI.REGISTRY[]
        @test reg.url == reg.clone == UI.CONFIG["registry_url"]
        @test reg.repo isa GitHub.Repo

        UI.CONFIG["registry_clone_url"] = "git@github.com:JuliaRegistries/General.git"
        UI.init_registry()
        reg = UI.REGISTRY[]
        @test reg.url == UI.CONFIG["registry_url"]
        @test reg.clone == UI.CONFIG["registry_clone_url"]
        restoreconfig!()
    end

    # Start the server.
    # TODO: Stop it when this test set is done.
    task = @async UI.start_server(Sockets.localhost, 4000)
    @info "Waiting for server to start..."
    sleep(10)    # Wait for server to be up

    @testset "404s" begin
        for r in values(UI.ROUTES)
            resp = HTTP.get(UI.CONFIG["server_url"] * r * "/foo"; status_exception=false)
            @test resp.status == 404
            @test occursin("Page not found", String(resp.body))
        end
    end

    @testset "Route: /" begin
        # The response should contain the registry URL and authentication links.
        resp = HTTP.get(UI.CONFIG["server_url"]; status_exception=false)
        @test resp.status == 200
        s = String(resp.body)
        @test occursin(UI.CONFIG["registry_url"], s)
        @test occursin("GitHub", s)
        @test occursin("GitLab", s)

        # When a provider is disabled, its authentication link should not appear.
        delete!(UI.PROVIDERS, "gitlab")
        resp = HTTP.get(UI.CONFIG["server_url"]; status_exception=false)
        @test resp.status == 200
        s = String(resp.body)
        @test occursin("GitHub", s)
        @test !occursin("GitLab", s)
    end

    @testset "Route: /select" begin
        resp = HTTP.get(UI.CONFIG["server_url"] * UI.ROUTES[:SELECT]; status_exception=false)
        @test resp.status == 200
        @test occursin("package to register", String(resp.body))
    end

    @testset "Route: /register (validation)" begin
        resp = HTTP.get(UI.CONFIG["server_url"] * UI.ROUTES[:REGISTER]; status_exception=false)
        @test resp.status == 405
        @test occursin("Method not allowed", String(resp.body))

        resp = HTTP.post(UI.CONFIG["server_url"] * UI.ROUTES[:REGISTER]; status_exception=false)
        @test resp.status == 400
        @test occursin("Missing or invalid state cookie", String(resp.body))

        # Pretend we've gone through authentication.
        state = "foo"
        client = UI.PROVIDERS["github"].client
        user = @gf get_user(client, "christopher-dG")
        UI.USERS[state] = UI.User(user, client)

        url = UI.CONFIG["server_url"] * UI.ROUTES[:REGISTER]
        cookies = Dict("state" => state)

        body = "package=&ref=master"
        resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
        @test resp.status == 400
        @test occursin("Package URL was not provided", String(resp.body))

        body = "package=foo&ref=master"
        resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
        @test resp.status == 400
        @test occursin("Package URL is invalid", String(resp.body))

        body = "package=https://github.com/foo/bar&ref="
        resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
        @test resp.status == 400
        @test occursin("Branch was not provided", String(resp.body))

        body = "package=https://github.com/JuliaLang/NotARealRepo&ref=master"
        resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
        @test resp.status == 400
        @test occursin("Repository was not found", String(resp.body))

        body = "package=http://github.com/JuliaLang/julia&ref=master"
        resp = HTTP.post(url; body=body, cookies=cookies, status_exception=false)
        @test resp.status == 400
        @test occursin("Unauthorized to release this package", String(resp.body))
    end

    @testset "Route: /register_jwt (validation)" begin
        url = UI.CONFIG["server_url"] * UI.ROUTES[:REGISTER_JWT]
        resp = HTTP.get(url; status_exception=false)
        @test resp.status == 405
        @test occursin("Method not allowed", String(resp.body))

        resp = HTTP.post(url; status_exception=false)
        @test resp.status == 400
        @test occursin("`jwt` not found in headers", String(resp.body))

        # Pretend we've gone through authentication.
        payload = JSON.parse("""{
           "iss": "https://auth.example.com",
           "sub": "ChUxjfgsajfurjsjdut0483672kdhgstgy283jssZQ",
           "aud": "example-audience",
           "exp": 1536080651,
           "iat": 1535994251,
           "nonce": "1777777777777aaaaaaaaabbbbbbbbbb",
           "at_hash": "222222-G-JJJJJJJJJJJJJ",
           "name": "Example User"
        }""");
        jwt = JWTs.JWT(; payload=payload)
        UI.setkeys("https://raw.githubusercontent.com/tanmaykm/JWTs.jl/master/test/jwkkey.json")

	headers = HTTP.Headers(["jwt" => string(jwt)])
        body = "package=&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
        @test occursin("Invalid JWT", String(resp.body))

        sign!(jwt, UI.KEYSET, UI.KEYID)

	headers = HTTP.Headers(["jwt" => string(jwt)])
        body = "package=&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
        @test occursin("`email` not found", String(resp.body))

        payload = JSON.parse("""{
           "iss": "https://auth.example.com",
           "sub": "ChUxjfgsajfurjsjdut0483672kdhgstgy283jssZQ",
           "aud": "example-audience",
           "exp": 1536080651,
           "iat": 1535994251,
           "nonce": "1777777777777aaaaaaaaabbbbbbbbbb",
           "at_hash": "222222-G-JJJJJJJJJJJJJ",
           "email": "user@example.com",
           "email_verified": true,
           "name": "Example User"
        }""");
        jwt = JWT(; payload=payload)
        sign!(jwt, UI.KEYSET, UI.KEYID)

	headers = HTTP.Headers(["jwt" => string(jwt)])
        body = "package=&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
        @test occursin("Unsupported git service", String(resp.body))

        body = "package=foo&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
        @test occursin("Unsupported git service", String(resp.body))

	body = "package=$(HTTP.escape("https://github.com/foo/bar"))&ref="
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
	@show String(copy(resp.body))
        @test occursin("Branch was not provided", String(resp.body))

	body = "package=$(HTTP.escape("https://github.com/JuliaLang/NotARealRepo"))&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
	@show String(copy(resp.body))
        @test occursin("Repository was not found", String(resp.body))

	body = "package=$(HTTP.escape("https://github.com/JuliaLang/julia"))&ref=master"
        resp = HTTP.post(url; body=body, headers=headers, status_exception=false)
        @test resp.status == 400
	@show String(copy(resp.body))
        @test occursin("Unauthorized to release this package", String(resp.body))
    end

end
