defmodule Vagus.Version do
  @moduledoc """
  The one place that decides whether an installed version is out of date.

  Extracted from `Vagus.Core.Versions` so add-ons and HA Core answer
  `update_available` the same way. Writing a second comparison for add-ons
  is how the two drift.

  ## It is a string inequality, not a semantic comparison

  Deliberately, and matching the real Supervisor: an add-on's `version` is an
  opaque tag chosen by whoever publishes the repository. It is frequently
  semver (`7.1.0`), but it is also routinely a date (`2025.1.0`), a bare
  integer, or a build tag. Ordering those is not something a comparator can do
  correctly without knowing the publisher's scheme, so "differs from what the
  store advertises" is the only honest question to ask.

  The practical consequence is that a *downgrade* in the store — a repository
  yanking a bad release and re-advertising the previous tag — reads as an
  available update. That is upstream's behaviour too, and it is the desirable
  one: the store's current version is what the user should end up running.
  """

  @doc """
  `true` when both versions are known and they differ.

  A `nil`/unknown value on either side is `false` rather than `true`: an
  add-on whose store entry has gone missing (detached) or whose latest
  version could not be fetched must not sprout an update button that cannot
  work.
  """
  @spec update_available?(term(), term()) :: boolean()
  def update_available?(installed, latest) do
    is_binary(installed) and is_binary(latest) and installed != latest
  end
end
