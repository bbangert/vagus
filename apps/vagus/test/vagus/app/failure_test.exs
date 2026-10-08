defmodule Vagus.App.FailureTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Failure
  alias Vagus.Resource.Stamp
  alias Vagus.Runtime.Docker
  alias Vagus.Test.AppManifests

  # The engine's own words. Those marked "recorded" are what moby answered
  # in `Vagus.Runtime.EngineLiveTest`; the rest are its messages as its
  # source and its users' reports have them.
  @in_use "failed to set up container networking: driver failed programming external " <>
            "connectivity on endpoint app_x (4f0c): failed to bind host port for " <>
            "0.0.0.0:8080:172.30.33.5:80/tcp: address already in use"
  @in_use_proxy "driver failed programming external connectivity on endpoint app_x (4f0c): " <>
                  "Error starting userland proxy: listen tcp4 0.0.0.0:1883: bind: address " <>
                  "already in use"
  @allocated "driver failed programming external connectivity on endpoint app_x (4f0c): " <>
               "Bind for 0.0.0.0:8123 failed: port is already allocated"
  @allocated_v6 "Bind for [::]:5353 failed: port is already allocated"

  defp row(action, reason) do
    %{class: class, cause: cause} = Failure.classify(action, reason)
    {class, cause}
  end

  describe "a port that is taken" do
    test "is permanent and a port conflict, in both of the engine's texts" do
      # "address already in use" is recorded: a start with a host listener on the port.
      for message <- [@in_use, @in_use_proxy, @allocated, @allocated_v6],
          action <- [:start, :create] do
        assert row(action, {:status, 500, message}) == {:permanent, :port_conflict}, message
      end
    end

    test "names the host port the engine named" do
      ports =
        for message <- [@in_use, @in_use_proxy, @allocated, @allocated_v6] do
          Failure.classify(:start, {:status, 500, message}).detail.port
        end

      assert ports == [8080, 1883, 8123, 5353]

      assert Failure.classify(:start, {:status, 500, "bind: address already in use"}).detail ==
               %{port: nil}
    end

    test "names it however the engine writes the address" do
      rows = [
        {"Bind for 0.0.0.0:8080 failed: port is already allocated", 8080},
        {"Bind for :::8080 failed: port is already allocated", 8080},
        {"Bind for [::]:8080 failed: port is already allocated", 8080},
        {"Bind for [::1]:443 failed: port is already allocated", 443},
        {"listen tcp :8080: bind: address already in use", 8080},
        {"listen tcp4 0.0.0.0:53: bind: address already in use", 53},
        {"listen udp6 [::]:5353: bind: address already in use", 5353},
        {"failed to bind host port for 0.0.0.0:65535:172.30.33.5:80/tcp: address already in use",
         65_535},
        # No port is above this: whatever those digits are, they are not one.
        {"Bind for 0.0.0.0:65536 failed: port is already allocated", nil},
        {"Bind for 0.0.0.0:99999 failed: port is already allocated", nil},
        {"Bind for 0.0.0.0:0 failed: port is already allocated", nil},
        {"Bind for 0.0.0.0:123456 failed: port is already allocated", nil},
        {"port is already allocated", nil}
      ]

      for {message, port} <- rows do
        assert Failure.classify(:start, {:status, 500, message}) ==
                 %{class: :permanent, cause: :port_conflict, detail: %{port: port}},
               message
      end
    end

    test "is one in any case of the text, and under any 5xx" do
      assert row(:start, {:status, 500, "Bind for 0.0.0.0:80 failed: Port Is Already Allocated"}) ==
               {:permanent, :port_conflict}

      assert row(:start, {:status, 500, "ADDRESS ALREADY IN USE"}) == {:permanent, :port_conflict}

      for status <- [500, 502, 503, 599] do
        assert row(:start, {:status, status, @allocated}) == {:permanent, :port_conflict}
        assert row(:pull, {:status, status, @in_use}) == {:permanent, :port_conflict}
      end
    end

    test "is not one under a 4xx, whose status says what it is" do
      assert row(:create, {:status, 400, @allocated}) == {:permanent, :invalid_config}
      assert row(:start, {:status, 404, @in_use}) == {:transient, :not_found}
      assert row(:pull, {:status, 404, @in_use}) == {:permanent, :image_not_found}
      assert row(:start, {:status, 409, @in_use}) == {:transient, :engine_refused}
    end

    test "is what the client's own error becomes" do
      reason = {:http, 500, @allocated}
      assert row(:start, Docker.failure(reason)) == {:permanent, :port_conflict}
    end
  end

  describe "an image that does not exist" do
    test "is permanent for a pull the engine refused with a 404" do
      # The first is recorded: a tag that does not exist.
      for message <- [
            "manifest for busybox:vagus-no-such-tag not found: manifest unknown: manifest unknown",
            "Manifest Unknown",
            "no such image",
            nil
          ] do
        assert row(:pull, {:status, 404, message}) == {:permanent, :image_not_found}
      end
    end

    test "is permanent for a pull that failed in its stream with one of the texts" do
      for message <- [
            "manifest unknown",
            "manifest for ghcr.io/a/b:1 not found: manifest unknown: manifest unknown",
            "MANIFEST UNKNOWN",
            "ghcr.io/a/b:1: Not Found"
          ] do
        assert row(:pull, {:stream, message}) == {:permanent, :image_not_found}, message

        assert row(:pull, Docker.failure({:pull_failed, message})) ==
                 {:permanent, :image_not_found}
      end
    end

    test "is not what a 404 means to any other action" do
      # Recorded: a create whose image is not there, a start of no container.
      assert row(:create, {:status, 404, "No such image: repo/none:1"}) ==
               {:transient, :not_found}

      assert row(:start, {:status, 404, "No such container: app_x"}) == {:transient, :not_found}
      assert row(:remove, {:status, 404, nil}) == {:transient, :not_found}
    end
  end

  describe "a pull the registry refuses" do
    # Recorded: a repository that does not exist, which a registry does not
    # tell from one that is private.
    @no_repository "pull access denied for vagus-does-not-exist, repository does not exist or " <>
                     "may require 'docker login': denied: requested access to the resource is denied"

    test "is permanent and its own cause, by each of the texts, in any case" do
      texts = [
        @no_repository,
        "unauthorized: authentication required",
        "Head \"https://ghcr.io/v2/a/b/manifests/1\": unauthorized",
        "denied: requested access to the resource is denied",
        "requested access to the resource is denied",
        "repository does not exist or may require 'docker login'",
        "UNAUTHORIZED",
        "Denied",
        "Repository Does Not Exist"
      ]

      for message <- texts do
        assert row(:pull, {:stream, message}) == {:permanent, :pull_denied}, message

        for status <- [401, 403, 404, 500] do
          assert row(:pull, {:status, status, message}) == {:permanent, :pull_denied}, message
        end
      end

      assert row(:pull, Docker.failure({:pull_failed, {404, %{"message" => @no_repository}}})) ==
               {:permanent, :pull_denied}
    end

    test "is that only for a pull" do
      assert row(:start, {:status, 403, "permission denied"}) == {:transient, :engine_refused}
      assert row(:create, {:status, 500, "access denied"}) == {:transient, :engine_error}
    end
  end

  describe "a config the engine will not take" do
    test "is permanent" do
      assert row(:create, {:status, 400, "invalid mount config for type \"bind\""}) ==
               {:permanent, :invalid_config}

      assert row(:pull, {:status, 400, nil}) == {:permanent, :invalid_config}
      assert row(:pull, {:invalid, {:invalid_ref, "a b"}}) == {:permanent, :invalid_config}
      assert row(:create, Docker.failure({:invalid_ref, "a b"})) == {:permanent, :invalid_config}
    end
  end

  describe "what another attempt may get past" do
    test "an engine that is away, slow, or broke the connection" do
      for action <- [:pull, :create, :start, :remove, :remove_image] do
        assert row(action, {:unreachable, :enoent}) == {:transient, :engine_unreachable}
        assert row(action, {:unreachable, :econnrefused}) == {:transient, :engine_unreachable}
        assert row(action, {:timeout, :recv}) == {:transient, :engine_timeout}
        assert row(action, {:timeout, :idle}) == {:transient, :engine_timeout}
        assert row(action, {:timeout, :total}) == {:transient, :engine_timeout}
        assert row(action, {:transport, :closed}) == {:transient, :engine_transport}
      end

      assert row(:start, Docker.failure({:connect, :enoent})) == {:transient, :engine_unreachable}

      assert row(:start, Docker.failure(%Mint.TransportError{reason: :timeout})) ==
               {:transient, :engine_timeout}

      assert row(:start, Docker.failure(%Mint.TransportError{reason: :closed})) ==
               {:transient, :engine_transport}
    end

    test "a 5xx that is no port conflict, with or without a message" do
      assert row(:start, {:status, 500, "OCI runtime create failed: unable to start"}) ==
               {:transient, :engine_error}

      assert row(:start, {:status, 500, nil}) == {:transient, :engine_error}
      assert row(:pull, {:status, 503, "service unavailable"}) == {:transient, :engine_error}
    end

    test "a refusal that is neither a 400 nor a 404" do
      # Recorded: the last reference to an image a container uses.
      assert row(:remove_image, {:status, 409, "conflict: unable to remove repository reference"}) ==
               {:transient, :engine_refused}
    end

    test "a pull that failed in its stream for another reason, or died" do
      assert row(:pull, {:stream, "unexpected EOF"}) == {:transient, :pull_failed}
      assert row(:pull, {:stream, "toomanyrequests: rate limit"}) == {:transient, :pull_failed}
      assert row(:pull, {:crashed, :killed}) == {:transient, :pull_crashed}
      assert row(:pull, {:crashed, {%RuntimeError{}, []}}) == {:transient, :pull_crashed}
    end

    test "a status that is no refusal and no failure of the engine's" do
      for status <- [100, 101, 204, 301, 304, 399, 401, 409, 418, 499] do
        assert row(:start, {:status, status, "whatever"}) == {:transient, :engine_refused}
        assert row(:start, {:status, status, nil}) == {:transient, :engine_refused}
      end
    end

    test "a name in use, by a container or by a process" do
      assert row(:create, :already_exists) == {:transient, :already_exists}
      # Whatever the action: only a create answers so, and nothing depends on it.
      assert row(:start, :already_exists) == {:transient, :already_exists}
      assert row(:pull, :already_exists) == {:transient, :already_exists}

      assert row(:start, {:other, {:name_taken, Vagus.Mqtt.Broker.Addon_core_mqtt}}) ==
               {:transient, :name_taken}
    end
  end

  describe "a stop that timed out" do
    test "is still stopping, and no failure" do
      for which <- [:recv, :idle, :total] do
        assert row(:stop, {:timeout, which}) == {:pending, :still_stopping}
      end
    end

    test "is only that for a stop, and a stop that failed otherwise has failed" do
      assert row(:remove, {:timeout, :recv}) == {:transient, :engine_timeout}
      assert row(:stop, {:unreachable, :enoent}) == {:transient, :engine_unreachable}
      assert row(:stop, {:status, 500, "cannot stop container"}) == {:transient, :engine_error}
    end
  end

  describe "a pull's state" do
    test "is classified when it is a failure, and is none otherwise" do
      stamp = %Stamp{incarnation: 1, at: 5}

      assert %{class: :permanent, cause: :image_not_found, detail: {:stream, "manifest unknown"}} =
               Failure.of_pull({:failed, {:stream, "manifest unknown"}, stamp})

      assert %{class: :transient, cause: :pull_crashed} =
               Failure.of_pull({:failed, {:crashed, :killed}, stamp})

      assert %{class: :transient, cause: :engine_unreachable} =
               Failure.of_pull({:failed, {:unreachable, :enoent}, stamp})

      assert Failure.of_pull(:idle) == nil
      assert Failure.of_pull({:pulling, nil}) == nil
    end
  end

  describe "anything else" do
    test "what only a pull reports is unknown from any other action" do
      for action <- [:create, :start, :stop, :remove, :remove_image] do
        assert row(action, {:crashed, :killed}) == {:permanent, :crashed}
        assert row(action, {:stream, "manifest unknown"}) == {:transient, :unknown}
        assert row(action, {:stream, "unauthorized"}) == {:transient, :unknown}
      end
    end

    test "is transient and unknown, and keeps what it was" do
      for reason <- [{:other, :weird}, :nope, nil, {:status, "500", "x"}, {:stream, "x"}, %{}] do
        assert Failure.classify(:start, reason) ==
                 %{class: :transient, cause: :unknown, detail: reason}
      end
    end

    test "never raises, whatever the action and whatever failed" do
      generator = fn -> {AppManifests.garbage(1), AppManifests.garbage()} end

      AppManifests.each(2_000, generator, fn {action, reason} ->
        assert %{class: class, cause: cause} = Failure.classify(action, reason)
        assert class in [:permanent, :transient, :pending]
        assert is_atom(cause)
      end)

      shaped = fn ->
        AppManifests.pick([
          {:status, AppManifests.garbage(0), AppManifests.garbage(0)},
          {:status, 500, AppManifests.garbage(0)},
          {:stream, AppManifests.garbage(0)},
          {:timeout, AppManifests.garbage(0)},
          {:other, AppManifests.garbage(1)}
        ])
      end

      AppManifests.each(2_000, shaped, fn reason ->
        for action <- [:pull, :stop, :start] do
          assert %{class: _, cause: _} = Failure.classify(action, reason)
        end
      end)
    end
  end
end
