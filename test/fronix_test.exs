defmodule FronixTest do
  use ExUnit.Case
  doctest Fronix

  test "greets the world" do
    assert Fronix.hello() == :world
  end
end
