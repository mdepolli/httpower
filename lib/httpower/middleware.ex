defmodule HTTPower.Middleware do
  @moduledoc """
  Behaviour for HTTPower pipeline middleware.

  Middleware are composable, reusable components that process HTTP requests
  in a pipeline. Each middleware can inspect, modify, short-circuit, or fail
  a request as it flows through the pipeline.

  ## Implementing Middleware

  To implement middleware, create a module that implements this behaviour:

      defmodule MyApp.CustomAuth do
        @behaviour HTTPower.Middleware

        @impl true
        def handle_request(request, config) do
          token = get_token_from_somewhere()
          headers = Map.put(request.headers, "authorization", "Bearer \#{token}")
          {:ok, %{request | headers: headers}}
        end
      end

  ## Return Values

  Middleware callbacks must return one of:

  - `:ok` - Continue to next middleware with request unchanged
  - `{:ok, modified_request}` - Continue with modified request
  - `{:halt, response}` - Short-circuit pipeline and return response immediately
  - `{:error, reason}` - Fail the request with error

  ## Examples

      # Continue unchanged
      def handle_request(request, _config) do
        :ok
      end

      # Modify request headers
      def handle_request(request, _config) do
        headers = Map.put(request.headers, "x-custom", "value")
        {:ok, %{request | headers: headers}}
      end

      # Short-circuit on cache hit
      def handle_request(request, config) do
        case check_cache(request) do
          {:ok, cached_response} -> {:halt, cached_response}
          :miss -> :ok
        end
      end

      # Fail request
      def handle_request(request, config) do
        if rate_limit_exceeded?(request) do
          {:error, %HTTPower.Error{reason: :too_many_requests}}
        else
          :ok
        end
      end

  ## Middleware Communication

  Middleware can communicate with each other through the `request.private` map:

      # Store data for later middleware or post-request processing
      def handle_request(request, config) do
        private = Map.put(request.private, :my_middleware_data, %{...})
        {:ok, %{request | private: private}}
      end

      # Read data stored by previous middleware
      def handle_request(request, config) do
        case Map.get(request.private, :my_middleware_data) do
          nil -> :ok
          data -> process_data(data)
        end
      end

  ## Configuration

  Middleware are configured at compile-time in `config.exs`:

      config :httpower,
        my_middleware: [
          enabled: true,  # Middleware only runs if enabled
          option1: "value",
          option2: 123
        ]

  The configuration is passed to `handle_request/2` as the second argument.

  ## Performance

  Middleware are only called if they are enabled in configuration. Disabled
  middleware have zero runtime overhead - they are not included in the compiled
  pipeline at all.

  ## Built-in Middleware

  HTTPower includes these built-in middleware:

  - `HTTPower.Middleware.RateLimiter` - Token bucket rate limiting
  - `HTTPower.Middleware.CircuitBreaker` - Circuit breaker pattern
  - `HTTPower.Middleware.Dedup` - Request deduplication

  See individual module documentation for details.
  """

  alias HTTPower.{Error, Request, Response}

  @doc """
  Handles a request in the pipeline.

  Receives the request and middleware configuration, returns whether to
  continue, modify, halt, or error.

  ## Parameters

  - `request` - The request struct (see `HTTPower.Request`)
  - `config` - Middleware configuration from `config.exs`

  ## Return Values

  - `:ok` - Continue unchanged
  - `{:ok, modified_request}` - Continue with modifications
  - `{:halt, response}` - Short-circuit with response
  - `{:error, reason}` - Fail the request
  """
  @callback handle_request(request :: Request.t(), config :: keyword()) ::
              :ok
              | {:ok, Request.t()}
              | {:halt, Response.t()}
              | {:error, Error.t() | atom()}
end
