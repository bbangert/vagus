defmodule Vagus.Resource.Collector do
  @moduledoc """
  What a resource owes to the existence of others, and what to do once they
  are gone. No process: the runtime of the kind concerned asks, at the start
  of each pass over a resource, and commits the answer.

  Three rules:

    * a resource whose owners (`owner_refs`) are all gone is deleted;
    * a spec path written by a resource (`Vagus.Resource.writer/1`) that is
      gone is released;
    * of a kind with `retention/0`, the finished resources beyond the newest
      `keep`, and those finished longer ago than `ttl_ms`, are deleted.

  Ownership is what the resource declares, and it is by uid: a new resource
  under an old name owns nothing its predecessor did. Every collection is an
  ordinary delete, so finalizers run.

  The check is made from the resource that depends, not from the one that
  went, so it needs no notice of the removal to have arrived: a resync finds
  whatever a missed notice left behind.
  """

  alias Vagus.Resource
  alias Vagus.Resource.{Stamp, Store}

  @doc "The resources whose removal `resource` must hear of."
  @spec dependencies(Resource.t()) :: [Resource.key()]
  def dependencies(%Resource{} = resource) do
    owners = for ref <- resource.owner_refs, do: {ref.kind, ref.name}
    Enum.uniq(owners ++ for({kind, name, _uid} <- writers(resource), do: {kind, name}))
  end

  @doc "The op that collects `resource`, or else those that release what dead writers held on it."
  @spec ops(Resource.t(), keyword()) :: [Store.op()]
  def ops(%Resource{kind: kind, name: name} = resource, opts \\ []) do
    orphan? =
      resource.owner_refs != [] and not resource.deleting? and
        Enum.all?(resource.owner_refs, &gone?({&1.kind, &1.name, &1.uid}, opts))

    # Only the delete for an orphan. A release beside it would have to be
    # admitted for the delete to happen, and a spec that is not valid without
    # the released entry would keep the orphan for ever.
    if orphan? do
      [{:delete, kind, name}]
    else
      for writer <- writers(resource), gone?(writer, opts) do
        {:release_writer, kind, name, writer}
      end
    end
  end

  @doc """
  The finished resources of `kind` that `retention` no longer keeps, each
  by uid: by the time one is deleted, its name may be another resource's.

  Newest is highest uid. A finished stamp is status, so after a reboot it is
  taken again and tells nothing of the order things finished in; the uid
  does, and needs no clock.
  """
  @spec expired(
          Resource.kind(),
          %{keep: non_neg_integer(), ttl_ms: non_neg_integer() | :infinity},
          Stamp.t(),
          keyword()
        ) :: [Resource.ref()]
  def expired(kind, %{keep: keep, ttl_ms: ttl}, %Stamp{} = now, opts \\ []) do
    finished =
      for %Resource{deleting?: false, status: %{finished: %Stamp{}}} = resource <-
            Store.list(kind, opts),
          do: resource

    {kept, beyond} = finished |> Enum.sort_by(& &1.uid, :desc) |> Enum.split(keep)
    old = Enum.filter(kept, &(ttl != :infinity and Stamp.age(&1.status.finished, now) > ttl))

    Enum.map(beyond ++ old, &Resource.ref/1)
  end

  defp writers(resource) do
    resource.managed_fields
    |> Map.values()
    |> Enum.uniq()
    |> Enum.filter(
      &match?({kind, name, uid} when is_atom(kind) and is_binary(name) and is_integer(uid), &1)
    )
  end

  defp gone?({kind, name, uid}, opts),
    do: not match?(%Resource{uid: ^uid}, Store.get(kind, name, opts))
end
