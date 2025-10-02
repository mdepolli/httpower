# Migrating from Req to HTTPower

This guide shows you how to add HTTPower's production reliability features to your Req-based application.

Since HTTPower uses Req as its default adapter, migration is straightforward. HTTPower adds circuit breaker, rate limiting, PCI-compliant logging, and enhanced retry logic on top of Req's foundation.

## Prerequisites

- Existing Elixir application using Req
- Req `~> 0.4.0` or higher

## Step 1: Add HTTPower Dependency

Update your `mix.exs`:

```elixir
def deps do
  [
    {:req, "~> 0.4.0"},         # Your existing Req dependency
    {:httpower, "~> 0.5.0"}     # Add HTTPower
  ]
end
```

Run `mix deps.get`.

## Step 2: Simple Migration - Direct Replacement

The simplest migration is to replace `Req` calls with `HTTPower`:

**Before (Req):**
```elixir
defmodule MyApp.ApiClient do
  def fetch_users do
    Req.get!("https://api.example.com/users")
  end

  def create_user(params) do
    Req.post!("https://api.example.com/users", json: params)
  end
end
```

**After (HTTPower):**
```elixir
defmodule MyApp.ApiClient do
  def fetch_users do
    case HTTPower.get("https://api.example.com/users") do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, error}
    end
  end

  def create_user(params) do
    HTTPower.post("https://api.example.com/users",
      body: Jason.encode!(params),
      headers: %{"content-type" => "application/json"}
    )
  end
end
```

**Note:** HTTPower returns `{:ok, response}` or `{:error, error}` tuples instead of raising. This gives you explicit error handling.

## Step 3: Using Req.new() Configurations

If you're using `Req.new()` with options, wrap it with HTTPower:

**Before (Req with options):**
```elixir
defmodule MyApp.GithubClient do
  def client do
    Req.new(
      base_url: "https://api.github.com",
      headers: [{"user-agent", "MyApp/1.0"}],
      retry: :transient
    )
  end

  def get_repo(owner, repo) do
    Req.get!(client(), url: "/repos/#{owner}/#{repo}")
  end
end
```

**After (HTTPower with Req options):**
```elixir
defmodule MyApp.GithubClient do
  def client do
    HTTPower.new(
      base_url: "https://api.github.com",
      headers: %{"user-agent" => "MyApp/1.0"},
      # HTTPower handles retries - disable Req's
      retry: false
    )
  end

  def get_repo(owner, repo) do
    HTTPower.get(client(), "/repos/#{owner}/#{repo}")
  end
end
```

## Step 4: Add HTTPower Features

Now add HTTPower's production reliability features:

```elixir
defmodule MyApp.GithubClient do
  def client do
    HTTPower.new(
      base_url: "https://api.github.com",
      headers: %{"user-agent" => "MyApp/1.0"},

      # HTTPower's retry with exponential backoff
      max_retries: 3,
      base_delay: 1000,

      # Circuit breaker
      circuit_breaker: [
        failure_threshold: 5,
        timeout: 60_000
      ],

      # Rate limiting
      rate_limit: [
        requests: 60,
        per: :minute
      ]
    )
  end
end
```

## Step 5: Global Configuration (Recommended)

Configure reliability patterns globally in `config/config.exs`:

```elixir
# config/config.exs
config :httpower,
  # Retry configuration
  max_retries: 3,
  base_delay: 1000,
  max_delay: 30000,
  retry_safe: false,

  # Circuit breaker
  circuit_breaker: [
    enabled: true,
    failure_threshold: 5,
    window_size: 10,
    timeout: 60_000
  ],

  # Rate limiting
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :minute,
    strategy: :wait
  ],

  # Logging
  logging: [
    enabled: true,
    level: :info
  ]
```

Then simplify your client code:

```elixir
defmodule MyApp.GithubClient do
  def client do
    HTTPower.new(
      base_url: "https://api.github.com",
      headers: %{"user-agent" => "MyApp/1.0"}
    )
  end
end
```

## Testing Strategy

HTTPower maintains compatibility with Req.Test:

**Before (Req.Test):**
```elixir
test "fetches users" do
  Req.Test.stub(MyApp, fn conn ->
    Req.Test.json(conn, %{"users" => []})
  end)

  client = Req.new(plug: {Req.Test, MyApp})
  assert %Req.Response{status: 200} = Req.get!(client, url: "/users")
end
```

**After (HTTPower with Req.Test):**
```elixir
# In test_helper.exs
Application.put_env(:httpower, :test_mode, true)

# In your tests
test "fetches users" do
  Req.Test.stub(HTTPower, fn conn ->
    Req.Test.json(conn, %{"users" => []})
  end)

  assert {:ok, %{status: 200}} = HTTPower.get("/users",
    plug: {Req.Test, HTTPower}
  )
end
```

## Migration Patterns

### Pattern 1: Gradual Module-by-Module

Migrate one module at a time while keeping others on Req:

```elixir
# Still using Req
defmodule MyApp.InternalClient do
  def fetch_config do
    Req.get!("http://internal-config/settings")
  end
end

# Migrated to HTTPower
defmodule MyApp.ExternalApiClient do
  def fetch_data do
    HTTPower.get("https://external-api.com/data")
  end
end
```

### Pattern 2: Wrapper Pattern

Keep Req calls, wrap critical paths with HTTPower:

```elixir
defmodule MyApp.PaymentClient do
  # Critical payment calls use HTTPower
  def charge_customer(amount) do
    client = HTTPower.new(
      base_url: "https://api.stripe.com",
      circuit_breaker: [failure_threshold: 3]
    )

    HTTPower.post(client, "/v1/charges", body: encode_params(amount))
  end

  # Non-critical calls still use Req
  def list_products do
    Req.get!("https://api.stripe.com/v1/products")
  end
end
```

### Pattern 3: Feature Flags

Use feature flags for gradual rollout:

```elixir
defmodule MyApp.ApiClient do
  def fetch_users do
    if use_httpower?() do
      HTTPower.get("https://api.example.com/users")
    else
      {:ok, Req.get!("https://api.example.com/users")}
    end
  end

  defp use_httpower? do
    Application.get_env(:myapp, :use_httpower, false)
  end
end
```

## Key Differences

### Error Handling

**Req:**
```elixir
# Raises on error
response = Req.get!("https://api.example.com")

# Returns result tuple
{:ok, response} = Req.get("https://api.example.com")
```

**HTTPower:**
```elixir
# Always returns result tuple (never raises)
{:ok, response} = HTTPower.get("https://api.example.com")
{:error, error} = HTTPower.get("https://unreachable.com")
```

### Retry Behavior

**Req:**
- Built-in retry with `:transient`, `:safe_transient`, or custom function
- Retries 3 times by default with exponential backoff

**HTTPower:**
- Configurable retry with exponential backoff and jitter
- Retryable status codes: 408, 429, 500-504
- Retryable errors: timeout, closed, econnrefused (if `retry_safe: true`)
- Disable Req's retry to avoid double-retrying: `retry: false`

### Req Options Pass-Through

HTTPower passes most Req options through:

```elixir
HTTPower.get("https://api.example.com",
  # HTTPower options
  max_retries: 3,
  circuit_breaker: [...],

  # Req options (passed through)
  connect_timeout: 15_000,
  receive_timeout: 30_000,
  decode_body: false
)
```

## Common Scenarios

### Scenario 1: API Client with Retries

```elixir
defmodule MyApp.ApiClient do
  def client do
    HTTPower.new(
      base_url: "https://api.example.com",
      headers: %{"authorization" => "Bearer #{token()}"},
      max_retries: 5,
      timeout: 30
    )
  end

  def fetch_data do
    HTTPower.get(client(), "/data")
  end
end
```

### Scenario 2: High-Volume API with Rate Limiting

```elixir
config :httpower,
  rate_limit: [
    enabled: true,
    requests: 1000,
    per: :minute,
    strategy: :wait,
    max_wait_time: 5000
  ]

defmodule MyApp.HighVolumeClient do
  def process_batch(items) do
    Enum.map(items, fn item ->
      HTTPower.post("https://api.example.com/process", body: item)
    end)
  end
end
```

### Scenario 3: Payment Processing with Circuit Breaker

```elixir
config :httpower,
  circuit_breaker: [
    enabled: true,
    failure_threshold: 3,
    timeout: 30_000
  ],
  logging: [
    enabled: true,
    sanitize_body_fields: ["card_number", "cvv"]
  ]

defmodule MyApp.PaymentClient do
  def charge(amount) do
    case HTTPower.post("https://api.stripe.com/v1/charges", body: amount) do
      {:ok, response} -> {:ok, response}
      {:error, %{reason: :service_unavailable}} -> {:error, :service_unavailable}
      {:error, error} -> {:error, error}
    end
  end
end
```

## FAQ

### Q: Do I need to change all my Req calls at once?

No. You can migrate gradually. HTTPower and Req can coexist in the same application.

### Q: Can I use Req-specific features?

Most Req features work through pass-through options. Some Req-specific features (like plugins) may not be directly supported. Check the documentation or file an issue.

### Q: Should I disable Req's retry?

Yes. Set `retry: false` when creating HTTPower clients to avoid double-retrying. HTTPower's retry logic is more configurable.

### Q: What about Req.Request structs?

HTTPower doesn't use `Req.Request` structs directly. Use HTTPower's client pattern with `HTTPower.new()` instead.

### Q: Can I still use Req.new() options?

Yes. Most `Req.new()` options work with `HTTPower.new()`. HTTPower internally uses Req, so options are passed through.

## Troubleshooting

### Issue: Double retrying

**Symptom:** Requests are being retried too many times.

**Solution:** Disable Req's built-in retry:
```elixir
HTTPower.new(
  base_url: "https://api.example.com",
  retry: false  # Disable Req's retry
)
```

### Issue: Test mode not blocking requests

**Symptom:** Real HTTP requests happening in tests.

**Solution:** Enable test mode in test_helper.exs:
```elixir
Application.put_env(:httpower, :test_mode, true)
```

### Issue: JSON encoding/decoding

**Symptom:** JSON not automatically handled like in Req.

**Solution:** HTTPower doesn't automatically encode/decode JSON. Use Jason explicitly:
```elixir
# Encode body
HTTPower.post(url,
  body: Jason.encode!(params),
  headers: %{"content-type" => "application/json"}
)

# Decode response
{:ok, response} = HTTPower.get(url)
Jason.decode!(response.body)
```

## Next Steps

- Read [Configuration Reference](configuration-reference.md) for all available options
- Read [Production Deployment Guide](production-deployment.md) for production setup
- Review runnable examples in `guides/examples/`

## Getting Help

If you encounter issues:
1. Check this migration guide
2. Review the configuration reference and production deployment guide
3. Review examples in `guides/examples/`
4. Open an issue: https://github.com/mdepolli/httpower/issues
