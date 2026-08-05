defmodule Vagus.Addon.Store.RepositorySpecTest do
  @moduledoc "Repository-string parsing + upstream slug derivation."
  use ExUnit.Case, async: true

  alias Vagus.Addon.Store.RepositorySpec

  describe "slug/1 — upstream vectors" do
    test "matches upstream's get_hash_from_repository for four known repositories" do
      assert RepositorySpec.slug("https://github.com/awesome-developer/awesome-repo") ==
               "a474bbd1"

      assert RepositorySpec.slug("https://github.com/hassio-addons/repository") == "a0d7b954"

      assert RepositorySpec.slug("https://github.com/esphome/home-assistant-addon") ==
               "5c53de3b"

      assert RepositorySpec.slug("https://github.com/music-assistant/home-assistant-addon") ==
               "d5369777"
    end

    test "input is lowercased before hashing" do
      mixed = "https://GitHub.com/Awesome-Developer/Awesome-Repo"
      lower = "https://github.com/awesome-developer/awesome-repo"

      assert RepositorySpec.slug(mixed) == RepositorySpec.slug(lower)
    end

    test "a #branch suffix changes the hash" do
      url = "https://github.com/foo/bar"

      refute RepositorySpec.slug(url) == RepositorySpec.slug(url <> "#mybranch")
    end
  end

  describe "parse/1 — accepted formats" do
    test "url#branch splits into url and ref, source keeps the full string" do
      full = "https://github.com/foo/bar#mybranch"

      assert {:ok, %{source: ^full, url: "https://github.com/foo/bar", ref: "mybranch"}} =
               RepositorySpec.parse(full)
    end

    test "a plain url (no branch suffix) gets ref \"HEAD\"" do
      full = "https://github.com/foo/bar"

      assert {:ok, %{source: ^full, url: ^full, ref: "HEAD"}} = RepositorySpec.parse(full)
    end
  end

  describe "parse/1 — rejected formats" do
    test "empty string" do
      assert {:error, :invalid_format} = RepositorySpec.parse("")
    end

    test "a bare #branch with no url at all" do
      assert {:error, :invalid_format} = RepositorySpec.parse("#only-branch")
    end

    test "no scheme" do
      assert {:error, :invalid_format} = RepositorySpec.parse("github.com/foo/bar")
    end

    test "no host" do
      assert {:error, :invalid_format} = RepositorySpec.parse("https://")
    end

    test "garbage" do
      assert {:error, :invalid_format} = RepositorySpec.parse("not a url")
    end

    test "non-binary input" do
      assert {:error, :invalid_format} = RepositorySpec.parse(nil)
      assert {:error, :invalid_format} = RepositorySpec.parse(123)
    end
  end

  # Parse then run the stricter runtime gate, the way `Vagus.Addon.Store`'s
  # add flow does.
  defp safe(full) do
    {:ok, spec} = RepositorySpec.parse(full)
    RepositorySpec.ensure_safe(spec)
  end

  describe "ensure_safe/1 — runtime fetchability/integrity gate" do
    test "a plain github.com url is accepted" do
      assert :ok = safe("https://github.com/o/r")
    end

    test "github.com host is matched case-insensitively" do
      assert :ok = safe("https://GitHub.COM/o/r")
    end

    test "legitimate refs (single dotted segment, path-style) pass" do
      assert :ok = safe("https://github.com/o/r#feature/x")
      assert :ok = safe("https://github.com/o/r#release/1.2")
      assert :ok = safe("https://github.com/o/r#v1.2.3")
      assert :ok = safe("https://github.com/o/r#HEAD")
    end

    test "a non-github host is rejected" do
      assert {:error, :invalid_format} = safe("https://notgithub.com/a/b")
      assert {:error, :invalid_format} = safe("https://example.test/a/b")
    end

    test "a github.com subdomain is rejected" do
      assert {:error, :invalid_format} = safe("https://raw.githubusercontent.com/o/r")
      assert {:error, :invalid_format} = safe("https://api.github.com/o/r")
    end

    test "a userinfo trick (github.com@evil.com) is rejected on the real host" do
      # URI parses this to host: "evil.com", userinfo: "github.com".
      assert {:error, :invalid_format} = safe("https://github.com@evil.com/o/r")
    end

    test "a non-empty userinfo is rejected even when the host is github.com" do
      assert {:error, :invalid_format} = safe("https://user@github.com/o/r")
    end

    test "a ref with a path-traversal segment is rejected" do
      assert {:error, :invalid_format} =
               safe(
                 "https://github.com/home-assistant/addons/#../../../attacker/evil/tar.gz/main"
               )

      assert {:error, :invalid_format} = safe("https://github.com/o/r#..")
      assert {:error, :invalid_format} = safe("https://github.com/o/r#.")
      assert {:error, :invalid_format} = safe("https://github.com/o/r#a/../b")
      assert {:error, :invalid_format} = safe("https://github.com/o/r#a//b")
    end

    test "an over-length repository string is rejected" do
      long = "https://github.com/o/" <> String.duplicate("r", 2048)
      {:ok, spec} = RepositorySpec.parse(long)
      assert {:error, :invalid_format} = RepositorySpec.ensure_safe(spec)
    end
  end
end
