defmodule HTTPowerTest do
  use ExUnit.Case
  doctest HTTPower

  test "greets the world" do
    assert HTTPower.hello() == :world
  end
end
