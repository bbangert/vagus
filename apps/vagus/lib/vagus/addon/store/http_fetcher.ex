defmodule Vagus.Addon.Store.HTTPFetcher do
  @moduledoc """
  Default `Vagus.Addon.Store` fetcher: downloads a repository's source archive
  over HTTP and extracts it in memory, returning `{:ok, [{path, content}]}`.

  Uses GitHub's `codeload` endpoint (`https://codeload.github.com/<owner>/<repo>/tar.gz/<ref>`)
  so there's no redirect to follow, streams into `:erl_tar` with `[:memory,
  :compressed]`, and strips the archive's single top-level wrapper directory so
  paths are repo-relative (`mosquitto/config.yaml`, not `addons-master/…`).

  A repo map is `%{slug, url, ref}` (`ref` defaults to `"master"`). Never
  raises; any failure is an `{:error, reason}`.

  One fetch is bounded: Finch's pool and connect timeouts, then
  `@request_timeout` for the whole response. Finch checks that limit as each
  chunk arrives, so the response can overrun it by one `@receive_timeout`.
  """

  @finch Vagus.Core.Finch
  @receive_timeout 60_000
  # The largest archive accepted, at about 1 Mbit/s.
  @request_timeout 300_000
  @codeload "https://codeload.github.com"
  @max_archive 33_554_432
  # Hard cap on the DECOMPRESSED archive so a gzip bomb can't OOM the device.
  @max_uncompressed 268_435_456

  @doc """
  Fetches + extracts `repository`'s archive. See the moduledoc.

  `opts` is for tests: `:base` replaces the codeload origin and
  `:request_timeout` the limit on the whole response.
  """
  @spec fetch(map(), keyword()) :: {:ok, [{String.t(), binary()}]} | {:error, term()}
  def fetch(repo, opts \\ [])

  def fetch(%{url: url} = repo, opts) do
    ref = Map.get(repo, :ref, "master")

    with {:ok, codeload} <- codeload_url(url, ref, Keyword.get(opts, :base, @codeload)),
         {:ok, archive} <-
           download(codeload, Keyword.get(opts, :request_timeout, @request_timeout)) do
      extract(archive)
    end
  end

  def fetch(_repo, _opts), do: {:error, :invalid_repository}

  ## Internals

  defp codeload_url(url, ref, base) do
    case Regex.run(~r{github\.com[/:]([^/]+)/([^/.]+)}, url) do
      [_, owner, repo] ->
        # Encode the ref — a branch/tag can contain `/` or other path-unsafe
        # characters that would otherwise reshape the URL.
        {:ok, "#{base}/#{owner}/#{repo}/tar.gz/#{URI.encode(ref)}"}

      _ ->
        {:error, {:unsupported_repo_url, url}}
    end
  end

  defp download(url, request_timeout) do
    timeouts = [receive_timeout: @receive_timeout, request_timeout: request_timeout]

    case Finch.request(Finch.build(:get, url), @finch, timeouts) do
      {:ok, %Finch.Response{status: 200, body: body}} when byte_size(body) <= @max_archive ->
        {:ok, body}

      {:ok, %Finch.Response{status: 200}} ->
        {:error, :archive_too_large}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Bounded gunzip + in-memory tar extract (caps the decompressed size so a
  # gzip bomb can't OOM), then normalize paths to strings and drop the leading
  # wrapper dir GitHub adds (`<repo>-<ref>/`).
  defp extract(archive) do
    case Vagus.Targz.extract_capped(archive, @max_uncompressed) do
      {:ok, entries} ->
        {:ok, Enum.map(entries, fn {path, content} -> {strip_wrapper(path), content} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strip_wrapper(path) do
    case String.split(path, "/", parts: 2) do
      [_wrapper, rest] -> rest
      [only] -> only
    end
  end
end
