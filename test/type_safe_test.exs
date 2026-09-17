defmodule TypeSafeTest do
  use ExUnit.Case, async: true

  doctest TypeSafe

  test "version/0 returns the mix project version string" do
    assert TypeSafe.version() == "0.1.0"
  end
end
