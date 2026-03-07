defmodule HTTPower.TestTest do
  use ExUnit.Case, async: true

  describe "cross-process mock resolution" do
    test "Task.async can see parent's mock via $callers" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{from: "parent_mock"})
      end)

      task =
        Task.async(fn ->
          HTTPower.get("https://api.example.com/test")
        end)

      assert {:ok, %{status: 200, body: %{"from" => "parent_mock"}}} = Task.await(task)
    end

    test "Task.async_stream can see parent's mock via $callers" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      results =
        1..3
        |> Task.async_stream(fn _ ->
          HTTPower.get("https://api.example.com/test")
        end)
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, %{status: 200}}} -> true
               _ -> false
             end)
    end

    test "nested Task.async sees grandparent's mock" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{nested: true})
      end)

      task =
        Task.async(fn ->
          inner_task =
            Task.async(fn ->
              HTTPower.get("https://api.example.com/test")
            end)

          Task.await(inner_task)
        end)

      assert {:ok, %{status: 200, body: %{"nested" => true}}} = Task.await(task)
    end

    test "concurrent async tests are isolated" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{test_id: "isolation_test"})
      end)

      task =
        Task.async(fn ->
          HTTPower.get("https://api.example.com/test")
        end)

      assert {:ok, %{body: %{"test_id" => "isolation_test"}}} = Task.await(task)
    end
  end

  describe "allow/2" do
    test "allows a specific PID to use the test's mock" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{allowed: true})
      end)

      {:ok, pid} = Agent.start_link(fn -> nil end)
      HTTPower.Test.allow(pid)

      result =
        Agent.get(pid, fn _ ->
          HTTPower.get("https://api.example.com/test")
        end)

      assert {:ok, %{status: 200, body: %{"allowed" => true}}} = result

      Agent.stop(pid)
    end

    test "transitive: allowed process spawns task, task sees mock" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{transitive: true})
      end)

      {:ok, pid} = Agent.start_link(fn -> nil end)
      HTTPower.Test.allow(pid)

      result =
        Agent.get(pid, fn _ ->
          task =
            Task.async(fn ->
              HTTPower.get("https://api.example.com/test")
            end)

          Task.await(task)
        end)

      assert {:ok, %{status: 200, body: %{"transitive" => true}}} = result

      Agent.stop(pid)
    end

    test "allow/2 with explicit owner" do
      HTTPower.Test.setup()

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{explicit: true})
      end)

      {:ok, pid} = Agent.start_link(fn -> nil end)
      HTTPower.Test.allow(pid, self())

      result =
        Agent.get(pid, fn _ ->
          HTTPower.get("https://api.example.com/test")
        end)

      assert {:ok, %{status: 200, body: %{"explicit" => true}}} = result

      Agent.stop(pid)
    end

    test "cleanup removes allowances on test exit" do
      owner = self()
      {:ok, pid} = Agent.start_link(fn -> nil end)

      :ets.insert(:httpower_test_stubs, {owner, fn _ -> nil end})
      :ets.insert(:httpower_test_stubs, {{:allow, pid}, owner})

      assert :ets.lookup(:httpower_test_stubs, {:allow, pid}) != []

      :ets.delete(:httpower_test_stubs, owner)
      :ets.match_delete(:httpower_test_stubs, {{:allow, :_}, owner})

      assert :ets.lookup(:httpower_test_stubs, {:allow, pid}) == []

      Agent.stop(pid)
    end
  end
end
