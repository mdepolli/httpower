# HTTPower with Req Adapter Example
#
# This example shows how to use HTTPower with the default Req adapter.
# Req is a "batteries-included" HTTP client that's perfect for new projects.
#
# Run this example:
#   mix run examples/req_example.exs

Mix.install([{:httpower, path: Path.expand("..", __DIR__)}])

IO.puts("\n🚀 HTTPower with Req Adapter Examples\n")

# ============================================================================
# Example 1: Simple GET request (uses Req adapter by default)
# ============================================================================
IO.puts("📡 Example 1: Simple GET request")

case HTTPower.get("https://api.github.com/repos/elixir-lang/elixir") do
  {:ok, response} ->
    IO.puts("✓ Success! Status: #{response.status}")
    IO.puts("  Repository: #{response.body["full_name"]}")
    IO.puts("  Stars: #{response.body["stargazers_count"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 2: Explicit Req adapter (same as default)
# ============================================================================
IO.puts("\n📡 Example 2: Explicit Req adapter")

case HTTPower.get("https://api.github.com/users/octocat",
       adapter: HTTPower.Adapter.Req
     ) do
  {:ok, response} ->
    IO.puts("✓ User: #{response.body["login"]}")
    IO.puts("  Name: #{response.body["name"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 3: Configured client with Req (default adapter)
# ============================================================================
IO.puts("\n📡 Example 3: Configured HTTPower client")

client =
  HTTPower.new(
    base_url: "https://api.github.com",
    headers: %{"User-Agent" => "HTTPower-Example/1.0"},
    timeout: 30
  )

case HTTPower.get(client, "/users/josevalim") do
  {:ok, response} ->
    IO.puts("✓ User: #{response.body["login"]}")
    IO.puts("  Bio: #{response.body["bio"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 4: Retry logic with exponential backoff
# ============================================================================
IO.puts("\n📡 Example 4: Retry configuration")

case HTTPower.get("https://httpbin.org/status/503",
       max_retries: 2,
       base_delay: 100,
       # Fast retry for demo
       retry_safe: true
     ) do
  {:ok, response} ->
    IO.puts("✓ Got response (after retries): #{response.status}")

  {:error, error} ->
    IO.puts("✗ Failed after retries: #{error.message}")
end

# ============================================================================
# Example 5: POST request with JSON
# ============================================================================
IO.puts("\n📡 Example 5: POST with JSON")

body = Jason.encode!(%{title: "Test Issue", body: "Created by HTTPower"})

case HTTPower.post("https://httpbin.org/post",
       body: body,
       headers: %{"Content-Type" => "application/json"}
     ) do
  {:ok, response} ->
    IO.puts("✓ POST successful: #{response.status}")
    IO.puts("  Echo: #{inspect(response.body["json"])}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

IO.puts("\n✨ All examples completed!\n")