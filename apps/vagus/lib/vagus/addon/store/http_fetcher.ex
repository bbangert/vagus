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
  """

  @finch Vagus.Core.Finch
  @max_archive 33_554_432
  # Hard cap on the DECOMPRESSED archive so a gzip bomb can't OOM the device.
  @max_uncompressed 268_435_456

  @doc "Fetches + extracts `repository`'s archive. See the moduledoc."
  @spec fetch(map()) :: {:ok, [{String.t(), binary()}]} | {:error, term()}
  def fetch(%{url: url} = repo) do
    ref = Map.get(repo, :ref, "master")

    with {:ok, codeload} <- codeload_url(url, ref),
         {:ok, archive} <- download(codeload),
         {:ok, files} <- extract(archive) do
      {:ok, files}
    end
  end

  def fetch(_repo), do: {:error, :invalid_repository}

  ## Internals

  defp codeload_url(url, ref) do
    case Regex.run(~r{github\.com[/:]([^/]+)/([^/.]+)}, url) do
      [_, owner, repo] -> {:ok, "https://codeload.github.com/#{owner}/#{repo}/tar.gz/#{ref}"}
      _ -> {:error, {:unsupported_repo_url, url}}
    end
  end

  defp download(url) do
    case Finch.request(Finch.build(:get, url), @finch, receive_timeout: 60_000) do
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
