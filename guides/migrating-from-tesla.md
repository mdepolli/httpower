# Migrating from Tesla to HTTPower

This guide shows you how to add HTTPower to your existing Tesla-based application without rewriting your code.

HTTPower provides circuit breaker, rate limiting, PCI-compliant logging, and smart retries on top of your Tesla setup. Your existing Tesla middleware continues to work - HTTPower wraps Tesla rather than replacing it.

## Prerequisites

- Existing Elixir application using Tesla
- Tesla `~> 1.11` or higher

## Step 1: Add HTTPower Dependency

Update your `mix.exs`:

```elixir
def deps do
  [
    {:tesla, "~> 1.11"},        # Your existing Tesla dependency
    {:httpower, "~> 0.5.0"}     # Add HTTPower
  ]
end
```

Run `mix deps.get`.

## Step 2: Keep Your Existing Tesla Client

**Don't change your Tesla code!** Your existing Tesla client works as-is:

```elixir
defmodule MyApp.ApiClient do
  use Tesla

  # All your existing Tesla middleware still works
  plug Tesla.Middleware.BaseURL, "https://api.example.com"
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Headers, [{"user-agent", "MyApp/1.0"}]
  plug Tesla.Middleware.Timeout, timeout: 30_000
  plug Tesla.Middleware.Compression, format: "gzip"

  # Add a function to expose the client
  def client do
    Tesla.client([])  # or Tesla.client(middleware()) if you build dynamically
  end

  # Your existing functions work unchanged
  def get_users do
    get("/users")
  end
end
```

The only addition is the `client/0` function to expose your Tesla client to HTTPower.

## Step 3: Wrap with HTTPower (Gradual Migration)

Now create HTTPower wrappers for the endpoints you want to protect. You can do this gradually - one endpoint at a time:

```elixir
defmodule MyApp.Users do
  @doc "Fetch users with HTTPower reliability patterns"
  def list_users do
    client = HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, MyApp.ApiClient.client()},
      circuit_breaker: [
        failure_threshold: 5,
        timeout: 60_000
      ],
      rate_limit: [
        requests: 100,
        per: :minute
      ]
    )

    HTTPower.get(client, "/users")
  end
end
```

Your Tesla middleware still runs - HTTPower calls Tesla, which executes all your plugs (BaseURL, JSON, Headers, etc.).

## Step 4: Configure Global Settings (Recommended)

Instead of passing options every time, configure globally in `config/config.exs`:

```elixir
# config/config.exs
config :httpower,
  # Circuit breaker configuration
  circuit_breaker: [
    enabled: true,
    failure_threshold: 5,
    window_size: 10,
    timeout: 60_000,
    half_open_requests: 1
  ],

  # Rate limiting configuration
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :minute,
    strategy: :wait,
    max_wait_time: 5000
  ],

  # Logging configuration
  logging: [
    enabled: true,
    level: :info,
    sanitize_headers: ["authorization", "api-key"],
    sanitize_body_fields: ["credit_card", "cvv", "password"]
  ]
```

Now your code becomes simpler:

```elixir
defmodule MyApp.Users do
  def list_users do
    client = HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, MyApp.ApiClient.client()}
    )

    HTTPower.get(client, "/users")
  end
end
```

## Step 5: Make Code Adapter-Agnostic (Recommended Final Step)

Encapsulate the adapter configuration so your application code is completely independent of Tesla. This allows you to swap adapters later without changing any code:

**Before (adapter visible):**
```elixir
defmodule MyApp.ApiClient do
  def list_users do
    client = HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, MyApp.TeslaClient.client()},  # Tesla-specific
      base_url: "https://api.example.com"
    )
    HTTPower.get(client, "/users")
  end
end
```

**After (adapter hidden):**
```elixir
defmodule MyApp.ApiClient do
  def list_users do
    HTTPower.get(client(), "/users")
  end

  def create_user(params) do
    body = Jason.encode!(params)
    HTTPower.post(client(), "/users",
      body: body,
      headers: %{"content-type" => "application/json"}
    )
  end

  defp client do
    HTTPower.new(
      base_url: "https://api.example.com",
      headers: %{"authorization" => "Bearer #{api_key()}"},
      timeout: 30
    )
    # No adapter specified - uses default configuration
    # Can be configured globally or per-environment
  end

  defp api_key, do: Application.fetch_env!(:myapp, :api_key)
end
```

**Option A: Configure adapter globally in config.exs:**
```elixir
# config/config.exs
config :httpower, adapter: {HTTPower.Adapter.Tesla, MyApp.TeslaClient.client()}

# Your client code - no adapter specified, uses global config
defp client do
  HTTPower.new(
    base_url: "https://api.example.com",
    headers: %{"authorization" => "Bearer #{api_key()}"},
    timeout: 30
  )
end
```

**Option B: Configure adapter per-client:**
```elixir
# No global config needed
defp client do
  HTTPower.new(
    adapter: {HTTPower.Adapter.Tesla, MyApp.TeslaClient.client()},
    base_url: "https://api.example.com",
    headers: %{"authorization" => "Bearer #{api_key()}"},
    timeout: 30
  )
end
```

With Option A, you can switch from Tesla to Req by changing one line in config - no code changes needed.

## Step 6: Update Tests to Use HTTPower.Test

Replace Tesla.Mock with HTTPower.Test for adapter-independent testing:

```elixir
# In test_helper.exs
Application.put_env(:httpower, :test_mode, true)

# In your tests
test "fetches users" do
  # Use HTTPower.Test, not Tesla.Mock
  HTTPower.Test.stub(fn conn ->
    Plug.Conn.resp(conn, 200, Jason.encode!(%{"users" => []}))
  end)

  assert {:ok, %{status: 200}} = MyApp.ApiClient.list_users()
end

test "creates user" do
  HTTPower.Test.stub(fn conn ->
    Plug.Conn.resp(conn, 201, Jason.encode!(%{"id" => 1}))
  end)

  assert {:ok, %{status: 201}} = MyApp.ApiClient.create_user(%{name: "John"})
end
```

HTTPower.Test works with any adapter, so your tests remain valid even if you switch from Tesla to Req.

## Step 7: Final Result

Your migration is complete! You now have:

```elixir
# Clean, adapter-agnostic API client
defmodule MyApp.ApiClient do
  def list_users do
    HTTPower.get(client(), "/users")
  end

  def create_user(params) do
    HTTPower.post(client(), "/users",
      body: Jason.encode!(params),
      headers: %{"content-type" => "application/json"}
    )
  end

  defp client do
    HTTPower.new(
      base_url: "https://api.example.com",
      headers: %{"authorization" => "Bearer #{api_key()}"}
      # Circuit breaker, rate limiting configured globally in config.exs
      # Adapter can be swapped without code changes
    )
  end

  defp api_key, do: Application.fetch_env!(:myapp, :api_key)
end
```

**Benefits of this final state:**
- No Tesla-specific code visible
- Can switch to Req adapter by changing config only
- Tests use HTTPower.Test (adapter-agnostic)
- Clean, maintainable API surface
- All Tesla middleware still works behind the scenes

## Migration Patterns

### Pattern 1: Wrapper Module (Recommended)

Keep Tesla client internal, expose HTTPower wrapper:

```elixir
defmodule MyApp.StripeClient do
  @tesla_client MyApp.TeslaClients.Stripe.client()

  defp httpower_client do
    HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, @tesla_client},
      circuit_breaker: [failure_threshold: 3],
      rate_limit: [requests: 100, per: :second]
    )
  end

  def create_charge(params) do
    HTTPower.post(httpower_client(), "/v1/charges", body: params)
  end

  def get_customer(id) do
    HTTPower.get(httpower_client(), "/v1/customers/#{id}")
  end
end
```

### Pattern 2: Drop-in Replacement

Replace Tesla calls directly:

```elixir
# Before:
defmodule MyApp.ApiClient do
  use Tesla
  plug Tesla.Middleware.BaseURL, "https://api.example.com"

  def fetch_data do
    get("/data")
  end
end

# After:
defmodule MyApp.ApiClient do
  use Tesla
  plug Tesla.Middleware.BaseURL, "https://api.example.com"

  def client, do: Tesla.client([])

  defp httpower, do: HTTPower.new(adapter: {HTTPower.Adapter.Tesla, client()})

  def fetch_data do
    # Changed from get("/data") to HTTPower.get
    HTTPower.get(httpower(), "/data")
  end
end
```

### Pattern 3: Gradual Migration

Migrate one critical endpoint at a time:

```elixir
defmodule MyApp.PaymentClient do
  use Tesla
  plug Tesla.Middleware.BaseURL, "https://api.stripe.com"

  def client, do: Tesla.client([])

  # Critical endpoint - migrated to HTTPower
  def create_charge(params) do
    client = HTTPower.new(adapter: {HTTPower.Adapter.Tesla, client()})
    HTTPower.post(client, "/v1/charges", body: params)
  end

  # Non-critical endpoint - still using plain Tesla
  def list_customers do
    get("/v1/customers")
  end
end
```

## Common Scenarios

### Scenario 1: Payment Processing (Stripe, PayPal, etc.)

```elixir
config :httpower,
  circuit_breaker: [
    enabled: true,
    failure_threshold: 3,      # Open circuit after 3 failures
    timeout: 30_000            # Try again after 30 seconds
  ],
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :second,
    strategy: :error           # Return error instead of waiting
  ],
  logging: [
    enabled: true,
    sanitize_body_fields: ["card_number", "cvv", "card_cvc"]
  ]
```

### Scenario 2: High-Volume API Integration

```elixir
config :httpower,
  circuit_breaker: [
    enabled: true,
    failure_threshold_percentage: 50,  # Open at 50% failure rate
    window_size: 100                    # Track last 100 requests
  ],
  rate_limit: [
    enabled: true,
    requests: 1000,
    per: :minute,
    strategy: :wait,
    max_wait_time: 10_000
  ]
```

### Scenario 3: Microservice Communication

```elixir
# Per-service configuration
defmodule MyApp.UserService do
  def client do
    HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, MyApp.Tesla.UserService.client()},
      circuit_breaker: [failure_threshold: 5, timeout: 60_000],
      circuit_breaker_key: "user_service"  # Isolate circuit per service
    )
  end
end

defmodule MyApp.OrderService do
  def client do
    HTTPower.new(
      adapter: {HTTPower.Adapter.Tesla, MyApp.Tesla.OrderService.client()},
      circuit_breaker: [failure_threshold: 3, timeout: 30_000],
      circuit_breaker_key: "order_service"
    )
  end
end
```

## FAQ

### Q: Do I need to rewrite my Tesla middleware?

No. Your Tesla middleware continues to work. HTTPower wraps Tesla, so all your plugs run normally.

### Q: Can I use Tesla's built-in retry?

Not recommended. Disable Tesla.Middleware.Retry to avoid double-retrying. HTTPower's retry logic includes exponential backoff and jitter.

### Q: What happens to Tesla.Middleware.Timeout?

Both work together. Tesla's timeout is the per-request timeout. HTTPower's `timeout` option does the same thing. If you set both, the lower value takes effect.

### Q: Can I gradually migrate?

Yes. Migrate critical endpoints first (payments, auth), then gradually add others.

### Q: Does this affect performance?

HTTPower adds ~1-5ms overhead for the reliability layer. The trade-off is worth it for production reliability (circuit breaker, rate limiting, retries).

### Q: Can I see the circuit breaker state?

Yes:

```elixir
HTTPower.Middleware.CircuitBreaker.get_state("my_api")
# Returns: :closed | :open | :half_open | nil
```

## Troubleshooting

### Issue: Circuit breaker not opening

**Symptom:** Service is failing but circuit stays closed.

**Solutions:**
1. Check if circuit breaker is enabled: `config :httpower, circuit_breaker: [enabled: true]`
2. Verify failure threshold is being reached
3. Check circuit key - different keys have different circuits
4. Add logging to see what's happening:
   ```elixir
   require Logger
   Logger.info("Circuit state: #{inspect(HTTPower.Middleware.CircuitBreaker.get_state("my_key"))}")
   ```

### Issue: Rate limiting too aggressive

**Symptom:** Getting `:too_many_requests` errors.

**Solutions:**
1. Increase rate limit: `rate_limit: [requests: 200, per: :minute]`
2. Use `:wait` strategy instead of `:error`
3. Use custom bucket keys to separate different endpoints
4. Check if multiple instances are sharing the rate limiter

### Issue: Tesla middleware not running

**Symptom:** Headers/transformations from Tesla plugs are missing.

**Solutions:**
1. Make sure you're passing the Tesla client: `adapter: {HTTPower.Adapter.Tesla, MyApp.Client.client()}`
2. Check that `client()` function builds Tesla client with middleware
3. Verify Tesla middleware order - some plugs must come first

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
