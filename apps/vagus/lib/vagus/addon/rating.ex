defmodule Vagus.Addon.Rating do
  @moduledoc """
  The 1–8 security rating `GET /addons/{slug}/info` reports, ported from
  upstream's `rating_security/1` (`supervisor/apps/utils.py`).

  The ladder is reproduced term for term rather than reinterpreted — this
  number drives the frontend's add-on security panel, so a Vagus-invented
  scale would be a silent divergence in a field users read as a warning.

  Three upstream terms are unreachable here and are **not** approximated:

    * `apparmor: "profile"` (+1) — Vagus models `apparmor` as a boolean, so
      only disable (−1) and default (0) exist.
    * `signed` (+1) — `Vagus.Addon.Info` reports `signed: false` always;
      Vagus has no image-signature verification.
    * `kernel_modules` (−1) — not a `Vagus.Addon.Config` field yet.

  Each would only ever move the score, never change which config is worse than
  which, so the ordering upstream intends is preserved.

  Note what is **absent**: `devices:` does not lower the rating upstream, even
  though it can grant raw disk access. That is upstream's judgement and is kept
  for parity — the honest reporting of *which* devices an add-on asks for lives
  in `Info`'s `devices` field, not here.
  """

  alias Vagus.Addon.Config

  # Upstream's `Capabilities` tuple in the privileged check — capabilities that
  # meaningfully weaken container isolation. Not every capability counts.
  @dangerous_caps ~w(BPF CHECKPOINT_RESTORE DAC_READ_SEARCH NET_ADMIN NET_RAW
                     PERFMON SYS_ADMIN SYS_MODULE SYS_PTRACE SYS_RAWIO)

  @doc """
  Scores `config` on upstream's ladder: start at 5, adjust, clamp to 1..8.

  `docker_api` or `full_access` **sets** the score to 1 rather than
  subtracting — upstream treats either as "not secure, full stop", so a
  well-behaved add-on cannot earn its way back up.
  """
  @spec score(Config.t()) :: 1..8
  def score(%Config{} = config) do
    5
    |> apparmor(config)
    |> ingress_or_auth(config)
    |> privileged(config)
    |> role(config)
    |> namespaces(config)
    |> unsecure_override(config)
    |> clamp()
  end

  defp apparmor(rating, %Config{apparmor: false}), do: rating - 1
  defp apparmor(rating, _config), do: rating

  # Ingress outranks auth_api rather than stacking with it: an ingress add-on
  # is reached through Core's authenticated proxy, which subsumes the weaker
  # "can call the auth API" signal.
  defp ingress_or_auth(rating, %Config{ingress: true}), do: rating + 2
  defp ingress_or_auth(rating, %Config{auth_api: true}), do: rating + 1
  defp ingress_or_auth(rating, _config), do: rating

  defp privileged(rating, %Config{privileged: caps}) do
    if Enum.any?(caps, &(&1 in @dangerous_caps)), do: rating - 1, else: rating
  end

  defp role(rating, %Config{hassio_role: "manager"}), do: rating - 1
  defp role(rating, %Config{hassio_role: "admin"}), do: rating - 2
  defp role(rating, _config), do: rating

  defp namespaces(rating, %Config{} = config) do
    rating
    |> then(&if config.host_network, do: &1 - 1, else: &1)
    |> then(&if config.host_pid, do: &1 - 2, else: &1)
    # host_uts alone cannot set the hostname — it only matters paired with the
    # capability that makes it usable, which is why upstream gates the term.
    |> then(&if config.host_uts and "SYS_ADMIN" in config.privileged, do: &1 - 1, else: &1)
  end

  defp unsecure_override(_rating, %Config{docker_api: true}), do: 1
  defp unsecure_override(_rating, %Config{full_access: true}), do: 1
  defp unsecure_override(rating, _config), do: rating

  defp clamp(rating), do: rating |> min(8) |> max(1)
end
