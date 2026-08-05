defmodule Vagus.Addon.Store.RepositorySpec do
  @moduledoc """
  Parses a Home Assistant "repository string" (what a user types into the
  Repositories dialog, e.g. `https://github.com/hassio-addons/repository` or
  `https://github.com/foo/bar#some-branch`) and derives the slug the store
  keys it by — the same two operations upstream's
  `supervisor/store/validate.py` (`RE_REPOSITORY`) and
  `supervisor/store/utils.py` (`get_hash_from_repository`) perform.

  `parse/1` is the format gate: only a well-formed URL (scheme + host) with
  an optional `#branch` suffix is accepted, matching upstream's regex plus
  its `AwesomeVersion`-adjacent URL sanity check. `slug/1` is a pure hash —
  it does not call `parse/1` and does not validate anything — because
  upstream hashes the *full* string (branch suffix included) while `parse/1`
  needs the branch split out, and the two callers (persistence, which stores
  the full string; duplicate-detection, which stores the parsed url) want
  different inputs at different times.
  """

  # `[^#]+` for the URL half mirrors upstream's `RE_REPOSITORY`: `#` is the
  # one character that can never appear in a git remote URL, so it safely
  # marks the start of an optional branch ref. `[\w\-./]+` is upstream's own
  # branch charset — permissive enough for `feature/x` or `v1.2.3` refs.
  @format ~r{^(?<url>[^#]+)(?:#(?<branch>[\w\-./]+))?$}

  @typedoc "A parsed repository string, ready to persist or add."
  @type t :: %{source: String.t(), url: String.t(), ref: String.t()}

  @doc """
  Parses a repository string into its URL and ref.

  `ref` is the `#branch` suffix verbatim, or `"HEAD"` when the string carries
  none — codeload.github.com serves `tar.gz/HEAD` as an alias for the
  repository's default branch, so `"HEAD"` is a real, fetchable ref rather
  than a placeholder needing a main/master fallback.

  Rejects anything that isn't a well-formed absolute URL (a scheme and a
  non-empty host both present) before the `#`, including the empty string,
  a bare `#branch` (no URL at all), and non-binary input.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(full) when is_binary(full) do
    with %{"url" => url, "branch" => branch} <- Regex.named_captures(@format, full),
         {:ok, uri} <- URI.new(url),
         true <- absolute_url?(uri) do
      {:ok, %{source: full, url: url, ref: ref(branch)}}
    else
      _no_match_or_bad_url -> {:error, :invalid_format}
    end
  end

  def parse(_not_a_string), do: {:error, :invalid_format}

  defp absolute_url?(%URI{scheme: scheme, host: host}) do
    is_binary(scheme) and scheme != "" and is_binary(host) and host != ""
  end

  defp ref(""), do: "HEAD"
  defp ref(branch), do: branch

  # The only host `Vagus.Addon.Store.HTTPFetcher` can actually fetch from: its
  # codeload URL is built from a `github.com`-only regex. Pin the parsed host
  # to it here so a runtime-added repository's *displayed* url can never name a
  # host the fetcher won't honour.
  @fetchable_host "github.com"

  # A hard ceiling on the whole posted string. Anything near this is already
  # pathological — the point is only to keep an adversarial caller from
  # persisting an unbounded blob into `store_repositories.json`.
  @max_source_bytes 2048

  @doc """
  A stricter, fetchability + integrity gate for a *runtime-added* repository,
  run by the add flow **after** `parse/1` has already accepted the format.

  Separate from `parse/1` on purpose: `parse/1` stays the pure, upstream-parity
  format gate (`RE_REPOSITORY` plus a URL sanity check), while this closes the
  gap between the url a repository is *displayed and deduplicated* under and the
  repo `Vagus.Addon.Store.HTTPFetcher` would actually pull. Config-declared
  repositories are trusted and never pass through here.

  Rejects (all as `{:error, :invalid_format}`, so the router keeps mapping it to
  the one 400 "No valid repository format!"):

    * a url whose real `%URI{}.host` is not exactly `#{@fetchable_host}`
      (case-insensitive) — subdomains like `raw.githubusercontent.com` and
      userinfo tricks like `https://github.com@evil.com/...` (which URI parses
      to `host: "evil.com"`) are rejected, as is any non-empty userinfo.
    * a ref carrying a path-traversal segment — the codeload URL interpolates
      the ref into a path, and `URI.encode/1` leaves `/` and `.` intact, so a
      ref like `../../../attacker/evil/tar.gz/main` would resolve to a *different
      repository* than the displayed url. Whole `""`/`"."`/`".."` segments are
      rejected; a segment that merely contains dots (`v1.2.3`, `release/1.2`,
      `feature/x`) is fine.
    * a repository string longer than #{@max_source_bytes} bytes.
  """
  @spec ensure_safe(t()) :: :ok | {:error, :invalid_format}
  def ensure_safe(%{source: source, url: url, ref: ref}) do
    with :ok <- ensure_length(source),
         :ok <- ensure_fetchable_host(url) do
      ensure_safe_ref(ref)
    end
  end

  defp ensure_length(source) when byte_size(source) <= @max_source_bytes, do: :ok
  defp ensure_length(_source), do: {:error, :invalid_format}

  defp ensure_fetchable_host(url) do
    with {:ok, %URI{host: host, userinfo: userinfo}} <- URI.new(url),
         true <- is_binary(host) and String.downcase(host) == @fetchable_host,
         true <- is_nil(userinfo) do
      :ok
    else
      _not_github -> {:error, :invalid_format}
    end
  end

  defp ensure_safe_ref(ref) do
    if ref |> String.split("/") |> Enum.any?(&(&1 in ["", ".", ".."])) do
      {:error, :invalid_format}
    else
      :ok
    end
  end

  @doc """
  Derives the upstream store slug for a repository string.

  Upstream's `get_hash_from_repository`: first 8 hex characters of
  `sha1(lowercase(full_repository_string))`. `full_repository_string` is the
  *whole* input, `#branch` suffix included — two branches of the same URL
  are different repositories to the store and must land on different slugs.
  """
  @spec slug(String.t()) :: String.t()
  def slug(full_repository_string) do
    full_repository_string
    |> String.downcase()
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end
end
