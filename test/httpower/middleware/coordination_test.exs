defmodule HTTPower.Middleware.CoordinationTest do
  use ExUnit.Case, async: true

  alias HTTPower.Middleware.CircuitBreaker

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()
  end

  describe "configuration profiles" do
    test "payment_processing profile sets correct options" do
      client =
        HTTPower.new(
          base_url: "https://payment-gateway.com",
          profile: :payment_processing
        )

      assert client.base_url == "https://payment-gateway.com"

      # Check rate limit settings
      rate_limit = Keyword.get(client.options, :rate_limit)
      assert rate_limit[:enabled] == true
      assert rate_limit[:requests] == 100
      assert rate_limit[:per] == :minute
      assert rate_limit[:adaptive] == true

      # Check circuit breaker settings
      circuit_breaker = Keyword.get(client.options, :circuit_breaker)
      assert circuit_breaker[:enabled] == true
      assert circuit_breaker[:failure_threshold_percentage] == 30.0
      assert circuit_breaker[:timeout] == 30_000

      # Check deduplication settings
      deduplicate = Keyword.get(client.options, :deduplicate)
      assert deduplicate[:enabled] == true
      assert deduplicate[:ttl] == 5_000

      # Check retry settings
      assert client.options[:max_retries] == 3
      assert client.options[:base_delay] == 2_000
    end

    test "high_volume_api profile sets correct options" do
      client = HTTPower.new(profile: :high_volume_api)

      rate_limit = Keyword.get(client.options, :rate_limit)
      assert rate_limit[:requests] == 1000
      assert rate_limit[:per] == :minute

      circuit_breaker = Keyword.get(client.options, :circuit_breaker)
      assert circuit_breaker[:failure_threshold_percentage] == 50.0
      assert circuit_breaker[:timeout] == 5_000

      deduplicate = Keyword.get(client.options, :deduplicate)
      assert deduplicate[:ttl] == 1_000
    end

    test "microservices_mesh profile sets correct options" do
      client = HTTPower.new(profile: :microservices_mesh)

      rate_limit = Keyword.get(client.options, :rate_limit)
      assert rate_limit[:requests] == 500
      assert rate_limit[:adaptive] == true

      circuit_breaker = Keyword.get(client.options, :circuit_breaker)
      assert circuit_breaker[:failure_threshold_percentage] == 40.0
      assert circuit_breaker[:timeout] == 10_000

      deduplicate = Keyword.get(client.options, :deduplicate)
      assert deduplicate[:ttl] == 2_000
    end

    test "explicit options override profile settings" do
      client =
        HTTPower.new(
          profile: :high_volume_api,
          rate_limit: [requests: 2000],
          max_retries: 5
        )

      # Profile default should be overridden
      rate_limit = Keyword.get(client.options, :rate_limit)
      assert rate_limit[:requests] == 2000

      # Other profile settings should still be present
      assert rate_limit[:per] == :minute
      assert rate_limit[:adaptive] == true

      # Explicit retry override
      assert client.options[:max_retries] == 5

      # Profile defaults that weren't overridden
      circuit_breaker = Keyword.get(client.options, :circuit_breaker)
      assert circuit_breaker[:enabled] == true
    end

    test "raises error for unknown profile" do
      assert_raise ArgumentError, ~r/Unknown profile: :invalid_profile/, fn ->
        HTTPower.new(profile: :invalid_profile)
      end
    end

    test "HTTPower.Profiles.list/0 returns all profiles" do
      profiles = HTTPower.Profiles.list()
      assert :payment_processing in profiles
      assert :high_volume_api in profiles
      assert :microservices_mesh in profiles
      assert length(profiles) == 3
    end

    test "HTTPower.Profiles.get/1 returns profile config" do
      {:ok, config} = HTTPower.Profiles.get(:payment_processing)
      assert is_list(config)
      assert Keyword.has_key?(config, :rate_limit)
      assert Keyword.has_key?(config, :circuit_breaker)
      assert Keyword.has_key?(config, :deduplicate)

      assert HTTPower.Profiles.get(:invalid) == {:error, :unknown_profile}
    end
  end

  describe "circuit breaker records 5xx as failure" do
    test "5xx responses after retry exhaustion trip the circuit breaker" do
      circuit_key = "5xx_circuit_test_#{System.unique_integer()}"

      CircuitBreaker.reset_circuit(circuit_key)

      # Stub always returns 500
      HTTPower.Test.stub(fn conn ->
        Plug.Conn.send_resp(conn, 500, Jason.encode!(%{error: "internal server error"}))
      end)

      # Make requests that will exhaust retries and return {:ok, %{status: 500}}
      # With failure_threshold: 3, three 500 responses should open the circuit
      for _ <- 1..3 do
        HTTPower.get("https://api.example.com/test",
          circuit_breaker: [
            enabled: true,
            failure_threshold: 3,
            window_size: 10,
            circuit_breaker_key: circuit_key
          ],
          max_retries: 0,
          base_delay: 1,
          max_delay: 1
        )
      end

      # Flush the async failure-recording casts before reading state
      flush_circuit_breaker()

      # Circuit should be open because 5xx responses are server failures
      assert CircuitBreaker.get_state(circuit_key) == :open
    end

    test "429 responses trip the circuit breaker" do
      circuit_key = "429_circuit_test_#{System.unique_integer()}"

      CircuitBreaker.reset_circuit(circuit_key)

      HTTPower.Test.stub(fn conn ->
        Plug.Conn.send_resp(conn, 429, Jason.encode!(%{error: "too many requests"}))
      end)

      for _ <- 1..3 do
        HTTPower.get("https://api.example.com/test",
          circuit_breaker: [
            enabled: true,
            failure_threshold: 3,
            window_size: 10,
            circuit_breaker_key: circuit_key
          ],
          max_retries: 0,
          base_delay: 1,
          max_delay: 1
        )
      end

      flush_circuit_breaker()

      assert CircuitBreaker.get_state(circuit_key) == :open
    end

    test "4xx responses do NOT trip the circuit breaker" do
      circuit_key = "4xx_circuit_test_#{System.unique_integer()}"

      CircuitBreaker.reset_circuit(circuit_key)

      HTTPower.Test.stub(fn conn ->
        Plug.Conn.send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
      end)

      for _ <- 1..5 do
        HTTPower.get("https://api.example.com/test",
          circuit_breaker: [
            enabled: true,
            failure_threshold: 3,
            window_size: 10,
            circuit_breaker_key: circuit_key
          ],
          max_retries: 0
        )
      end

      flush_circuit_breaker()

      # 4xx are client errors - circuit should stay closed
      state = CircuitBreaker.get_state(circuit_key)
      assert state in [:closed, nil]
    end

    test "2xx responses keep circuit breaker closed" do
      circuit_key = "2xx_circuit_test_#{System.unique_integer()}"

      CircuitBreaker.reset_circuit(circuit_key)

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      for _ <- 1..5 do
        HTTPower.get("https://api.example.com/test",
          circuit_breaker: [
            enabled: true,
            failure_threshold: 3,
            window_size: 10,
            circuit_breaker_key: circuit_key
          ]
        )
      end

      flush_circuit_breaker()

      state = CircuitBreaker.get_state(circuit_key)
      assert state in [:closed, nil]
    end
  end

  # CircuitBreaker records results via async GenServer.cast and get_state/1 reads
  # ETS directly, so a synchronous call flushes the mailbox: when it returns, all
  # previously-enqueued casts (and test send/3 messages) have been processed and
  # their ETS writes are visible. Deterministic replacement for a fixed sleep.
  defp flush_circuit_breaker, do: :sys.get_state(CircuitBreaker)
end
