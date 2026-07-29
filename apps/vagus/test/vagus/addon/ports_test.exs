defmodule Vagus.Addon.PortsTest do
  @moduledoc """
  The config-declares-the-set / user-sets-the-values split behind the
  frontend's Network card (`Vagus.Addon.Ports`, mirroring upstream's
  `App.ports` property and setter).
  """
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, Ports}

  defp config(ports) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "1",
        "slug" => "test",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "ports" => ports
      })

    config
  end

  describe "effective/2" do
    test "an override replaces the config default for that port only" do
      c = config(%{"22/tcp" => nil, "80/tcp" => 8080})

      assert Ports.effective(c, %{"22/tcp" => 2222}) == %{"22/tcp" => 2222, "80/tcp" => 8080}
    end

    test "a port the user never touched keeps its default, including an unpublished null" do
      # The whole reason the config's keys drive the shape: an optional port
      # left unpublished has to stay visible in the card, or the user can
      # never publish it.
      c = config(%{"22/tcp" => nil, "80/tcp" => 8080})

      assert Ports.effective(c, %{}) == %{"22/tcp" => nil, "80/tcp" => 8080}
    end

    test "an override for a port the config no longer declares is not published" do
      # An add-on update dropped the port; a stale override must not resurrect
      # it in the container spec.
      c = config(%{"22/tcp" => nil})

      assert Ports.effective(c, %{"22/tcp" => 2222, "9999/tcp" => 9999}) == %{"22/tcp" => 2222}
    end

    test "a port added by an add-on update appears with its new default" do
      c = config(%{"22/tcp" => 22, "443/tcp" => 4443})

      assert Ports.effective(c, %{"22/tcp" => 2222}) == %{"22/tcp" => 2222, "443/tcp" => 4443}
    end

    test "an add-on declaring no ports passes its overrides through untouched" do
      assert Ports.effective(config(%{}), %{"22/tcp" => 2222}) == %{"22/tcp" => 2222}
      assert Ports.effective(config(%{}), %{}) == %{}
    end
  end

  describe "sanitize/2" do
    test "keeps declared ports, silently forgets undeclared ones" do
      c = config(%{"22/tcp" => nil})

      assert {:ok, %{"22/tcp" => 2222}} =
               Ports.sanitize(c, %{"22/tcp" => 2222, "9999/tcp" => 1})
    end

    test "null is a valid host port — it means 'declared but not published'" do
      assert {:ok, %{"22/tcp" => nil}} =
               Ports.sanitize(config(%{"22/tcp" => 22}), %{"22/tcp" => nil})
    end

    test "0 and 65535 are in range; anything outside it is refused" do
      c = config(%{"22/tcp" => nil})

      assert {:ok, %{"22/tcp" => 0}} = Ports.sanitize(c, %{"22/tcp" => 0})
      assert {:ok, %{"22/tcp" => 65_535}} = Ports.sanitize(c, %{"22/tcp" => 65_535})
      assert {:error, message} = Ports.sanitize(c, %{"22/tcp" => 65_536})
      assert message =~ "22/tcp"
      assert {:error, _} = Ports.sanitize(c, %{"22/tcp" => -1})
    end

    test "a non-integer value is refused rather than persisted" do
      # Persisting "eighty" would defer the failure to container start, long
      # after the user has been told the save succeeded.
      assert {:error, _} = Ports.sanitize(config(%{"22/tcp" => nil}), %{"22/tcp" => "2222"})
    end

    test "an undeclared port with a bad value is dropped before it can be rejected" do
      # Order matters: the frontend only posts keys it was given, so an
      # unknown key is a stale tab, not a user error to 400 over.
      assert {:ok, %{}} = Ports.sanitize(config(%{"22/tcp" => nil}), %{"9999/tcp" => "nope"})
    end
  end
end
