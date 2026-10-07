defmodule Vagus.Resource.Persistence do
  @moduledoc """
  The resource file: one human-readable JSON document holding every
  resource's durable fields, and never `status`.

  `spec` and `progress` go through the kind's hooks. The generic fields are
  round-tripped here exactly, which JSON alone cannot do: an atom is written
  as `":name"`, a tuple as `{"tuple": [...]}`, and a string that would read
  back as an atom as `{"string": ":..."}`. A map whose only key is `"$stamp"`
  is a `Vagus.Resource.Stamp`; a spec or progress may not use that shape for
  anything else.

  Nothing is written that would not load: `encode/2` decodes its own output
  and refuses contents that come back different.

  A file naming a kind or an atom this build does not know fails the load on
  purpose, since nothing here could act on it and dropping it would read as
  "never installed". The consequence: a file written by a newer build that
  introduced a kind, a finalizer or a writer name does not load on an older
  build.
  """

  alias Vagus.Resource
  alias Vagus.Resource.{Kind, Stamp}

  @version 1

  @type kinds :: %{Resource.kind() => Kind.t()}
  @type contents :: %{resources: [Resource.t()], next_uid: pos_integer()}

  @doc """
  `status` is dropped. `{:error, {:not_round_trippable, key | reason}}` when
  reading the result back would not give the same resources: a kind whose
  hooks do not invert each other, or a value JSON changes.
  """
  @spec encode(contents(), kinds()) :: {:ok, binary()} | {:error, term()}
  def encode(%{resources: resources, next_uid: next_uid}, kinds) do
    resources = Enum.map(resources, &%{&1 | status: %{}})

    document = %{
      "version" => @version,
      "next_uid" => next_uid,
      "resources" => Enum.map(resources, &encode_resource(&1, Map.fetch!(kinds, &1.kind)))
    }

    case Jason.encode(document, pretty: true) do
      {:ok, binary} -> verified(binary, %{resources: resources, next_uid: next_uid}, kinds)
      {:error, error} -> {:error, {:not_persistable, Exception.message(error)}}
    end
  catch
    reason -> {:error, reason}
  end

  defp verified(binary, contents, kinds) do
    case decode(binary, kinds) do
      {:ok, ^contents} ->
        {:ok, binary}

      {:ok, %{resources: read_back}} ->
        differing =
          for {written, read} <- Enum.zip(contents.resources, read_back),
              written != read,
              do: {written.kind, written.name}

        {:error, {:not_round_trippable, List.first(differing)}}

      {:error, reason} ->
        {:error, {:not_round_trippable, reason}}
    end
  end

  @doc "A missing file is an empty store; any other failure is an error."
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(Path.t(), kinds()) :: {:ok, contents()} | {:error, term()}
  def read(path, kinds) do
    case File.read(path) do
      {:ok, binary} -> decode(binary, kinds)
      {:error, :enoent} -> {:ok, %{resources: [], next_uid: 1}}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  @spec decode(binary(), kinds()) :: {:ok, contents()} | {:error, term()}
  def decode(binary, kinds) do
    by_name = Map.new(kinds, fn {kind, codec} -> {Atom.to_string(kind), {kind, codec}} end)

    case Jason.decode(binary) do
      {:ok, %{"version" => @version, "next_uid" => next_uid, "resources" => entries}}
      when is_integer(next_uid) and is_list(entries) ->
        with {:ok, resources} <- decode_resources(entries, by_name) do
          {:ok, %{resources: resources, next_uid: next_uid}}
        end

      {:ok, %{"version" => version}} when version != @version ->
        {:error, {:unsupported_version, version}}

      {:ok, _other} ->
        {:error, :malformed}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:unparseable, Exception.message(error)}}
    end
  catch
    reason -> {:error, reason}
  end

  @doc """
  Replaces the file so that after a power cut it holds either the old
  content or the new, never a mixture or an empty file: the data is on flash
  before the rename, and the rename is on flash before this returns `:ok`.

  `{:error, reason}` is a failure before the rename: the file is as it was.
  `{:unknown, reason}` is a failure after it: the file has the new content,
  but whether that survives a power cut is not known.
  """
  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  @spec write(Path.t(), iodata()) :: :ok | {:error, term()} | {:unknown, term()}
  def write(path, data) do
    dir = Path.dirname(path)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- synced(tmp, [:write], &:file.write(&1, data)),
         :ok <- File.rename(tmp, path) do
      with {:error, reason} <- synced(dir, [:read, :directory], fn _fd -> :ok end),
           do: {:unknown, reason}
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp synced(path, modes, fun) do
    opened =
      File.open(path, [:raw, :binary | modes], fn fd ->
        with :ok <- fun.(fd), do: :file.sync(fd)
      end)

    with {:ok, result} <- opened, do: result
  end

  defp encode_resource(%Resource{} = resource, %Kind{} = codec) do
    %{
      "kind" => Atom.to_string(resource.kind),
      "name" => resource.name,
      "uid" => resource.uid,
      "generation" => resource.generation,
      "deleting" => resource.deleting?,
      "finalizers" => Enum.map(resource.finalizers, &encode_term/1),
      "owner_refs" =>
        for ref <- resource.owner_refs do
          %{"kind" => Atom.to_string(ref.kind), "name" => ref.name, "uid" => ref.uid}
        end,
      "managed_fields" =>
        for {path, writer} <- Enum.sort(resource.managed_fields) do
          %{"path" => Enum.map(path, &encode_term/1), "writer" => encode_term(writer)}
        end,
      "spec" => hook(codec, :encode_spec, resource.spec, resource),
      "progress" => hook(codec, :encode_progress, resource.progress, resource)
    }
  end

  # A kind's hook is the one piece of this that is not ours. Whatever it
  # raises has to come back as a reason: the caller is the store deciding a
  # commit or its own start, and neither may die of it.
  defp hook(codec, name, value, %{kind: kind, name: resource}) do
    Map.fetch!(codec, name).(value)
  rescue
    exception -> throw({:hook_failed, name, {kind, resource}, Exception.message(exception)})
  end

  defp decode_resources(entries, by_name) do
    entries
    |> Enum.reduce_while([], fn entry, acc ->
      case decode_resource(entry, by_name) do
        {:ok, resource} -> {:cont, [resource | acc]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      resources -> {:ok, Enum.reverse(resources)}
    end
  end

  defp decode_resource(
         %{
           "kind" => kind,
           "name" => name,
           "uid" => uid,
           "generation" => generation,
           "deleting" => deleting?,
           "finalizers" => finalizers,
           "owner_refs" => owner_refs,
           "managed_fields" => managed_fields,
           "spec" => spec,
           "progress" => progress
         },
         by_name
       )
       when is_binary(name) and is_integer(uid) and is_integer(generation) and
              is_boolean(deleting?) and is_list(finalizers) and is_list(owner_refs) and
              is_list(managed_fields) do
    with {:ok, {kind, codec}} <- known_kind(by_name, kind),
         {:ok, owner_refs} <- decode_refs(owner_refs, by_name) do
      {:ok,
       %Resource{
         kind: kind,
         name: name,
         uid: uid,
         generation: generation,
         deleting?: deleting?,
         finalizers: Enum.map(finalizers, &decode_term/1),
         owner_refs: owner_refs,
         managed_fields:
           Map.new(managed_fields, fn
             %{"path" => path, "writer" => writer} when is_list(path) ->
               {Enum.map(path, &decode_term/1), decode_term(writer)}

             _other ->
               throw(:malformed)
           end),
         spec: hook(codec, :decode_spec, Stamp.revive(spec), %{kind: kind, name: name}),
         progress:
           hook(codec, :decode_progress, Stamp.revive(progress), %{kind: kind, name: name})
       }}
    end
  end

  defp decode_resource(_entry, _by_name), do: {:error, :malformed}

  defp decode_refs(refs, by_name) do
    Enum.reduce_while(refs, {:ok, []}, fn
      %{"kind" => kind, "name" => name, "uid" => uid} = ref, {:ok, acc}
      when map_size(ref) == 3 and is_binary(name) and is_integer(uid) ->
        case known_kind(by_name, kind) do
          {:ok, {kind, _codec}} -> {:cont, {:ok, acc ++ [%{kind: kind, name: name, uid: uid}]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, :malformed}}
    end)
  end

  defp known_kind(by_name, kind) do
    case by_name do
      %{^kind => known} -> {:ok, known}
      _unknown -> {:error, {:unknown_kind, kind}}
    end
  end

  defp encode_term(atom) when is_atom(atom), do: ":" <> Atom.to_string(atom)
  defp encode_term(":" <> _rest = string), do: %{"string" => string}
  defp encode_term(string) when is_binary(string), do: string
  defp encode_term(integer) when is_integer(integer), do: integer
  defp encode_term(list) when is_list(list), do: Enum.map(list, &encode_term/1)

  defp encode_term(tuple) when is_tuple(tuple),
    do: %{"tuple" => tuple |> Tuple.to_list() |> Enum.map(&encode_term/1)}

  defp encode_term(other), do: throw({:not_persistable, other})

  # Minting atoms from a file is unbounded; see the moduledoc for what
  # refusing an unknown one costs.
  defp decode_term(":" <> name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> throw({:unknown_atom, name})
  end

  defp decode_term(string) when is_binary(string), do: string
  defp decode_term(integer) when is_integer(integer), do: integer
  defp decode_term(list) when is_list(list), do: Enum.map(list, &decode_term/1)
  defp decode_term(%{"string" => string}) when is_binary(string), do: string

  defp decode_term(%{"tuple" => elements}) when is_list(elements),
    do: elements |> Enum.map(&decode_term/1) |> List.to_tuple()

  defp decode_term(_other), do: throw(:malformed)
end
