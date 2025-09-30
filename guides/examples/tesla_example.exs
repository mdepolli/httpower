# HTTPower with Tesla Adapter Example
#
# This example shows how to use HTTPower with the Tesla adapter.
# Perfect for existing apps that already use Tesla - keep your Tesla
# configuration and add HTTPower's production features on top.
#
# Run this example:
#   mix run examples/tesla_example.exs

Mix.install([
  {:httpower, path: Path.expand("..", __DIR__)},
  {:tesla, "~> 1.11"}
])

IO.puts("\n🚀 HTTPower with Tesla Adapter Examples\n")

# ============================================================================
# Example 1: Simple Tesla client with HTTPower
# ============================================================================
IO.puts("📡 Example 1: Basic Tesla adapter")

# Create a Tesla client
tesla_client = Tesla.client([Tesla.Middleware.JSON])

case HTTPower.get("https://api.github.com/repos/elixir-lang/elixir",
       adapter: {HTTPower.Adapter.Tesla, tesla_client}
     ) do
  {:ok, response} ->
    IO.puts("✓ Success! Status: #{response.status}")
    IO.puts("  Repository: #{response.body["full_name"]}")
    IO.puts("  Stars: #{response.body["stargazers_count"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 2: Tesla client with middleware
# ============================================================================
IO.puts("\n📡 Example 2: Tesla with middleware")

tesla_client =
  Tesla.client([
    {Tesla.Middleware.BaseURL, "https://api.github.com"},
    Tesla.Middleware.JSON,
    {Tesla.Middleware.Headers, [{"user-agent", "HTTPower-Tesla-Example/1.0"}]}
  ])

case HTTPower.get("/users/josevalim",
       adapter: {HTTPower.Adapter.Tesla, tesla_client}
     ) do
  {:ok, response} ->
    IO.puts("✓ User: #{response.body["login"]}")
    IO.puts("  Name: #{response.body["name"]}")
    IO.puts("  Bio: #{response.body["bio"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 3: HTTPower configured client with Tesla
# ============================================================================
IO.puts("\n📡 Example 3: HTTPower client with Tesla adapter")

tesla_client =
  Tesla.client([
    {Tesla.Middleware.BaseURL, "https://api.github.com"},
    Tesla.Middleware.JSON
  ])

httpower_client =
  HTTPower.new(
    adapter: {HTTPower.Adapter.Tesla, tesla_client},
    max_retries: 3,
    timeout: 30
  )

case HTTPower.get(httpower_client, "/users/chrismccord") do
  {:ok, response} ->
    IO.puts("✓ User: #{response.body["login"]}")
    IO.puts("  Company: #{response.body["company"]}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 4: POST request with Tesla adapter
# ============================================================================
IO.puts("\n📡 Example 4: POST with Tesla")

tesla_client = Tesla.client([Tesla.Middleware.JSON])

body = Jason.encode!(%{title: "HTTPower + Tesla", description: "Working together!"})

case HTTPower.post("https://httpbin.org/post",
       body: body,
       headers: %{"Content-Type" => "application/json"},
       adapter: {HTTPower.Adapter.Tesla, tesla_client}
     ) do
  {:ok, response} ->
    IO.puts("✓ POST successful: #{response.status}")
    IO.puts("  Echo: #{inspect(response.body["json"])}")

  {:error, error} ->
    IO.puts("✗ Error: #{error.message}")
end

# ============================================================================
# Example 5: HTTPower retry with Tesla
# ============================================================================
IO.puts("\n📡 Example 5: Retry logic (works the same with Tesla!)")

tesla_client = Tesla.client([])

case HTTPower.get("https://httpbin.org/status/503",
       adapter: {HTTPower.Adapter.Tesla, tesla_client},
       max_retries: 2,
       # Fast retry for demo
       base_delay: 100
     ) do
  {:ok, response} ->
    IO.puts("✓ Got response (after retries): #{response.status}")

  {:error, error} ->
    IO.puts("✗ Failed after retries: #{error.message}")
end

IO.puts("\n✨ All examples completed!")
IO.puts(
  "🎯 HTTPower's retry, circuit breaker, and rate limiting work the same with Tesla!\n"
)