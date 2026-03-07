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
end
