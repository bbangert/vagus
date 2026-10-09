defmodule Vagus.App.PolicyTest do
  use ExUnit.Case, async: true

  alias Vagus.App.Policy

  @mqtt %{uuid: "u1", addon: "mosq", service: "mqtt", config: %{"host" => "a"}}

  describe "discover/5" do
    test "an unseen app and service is new, under the fresh uuid" do
      assert {:new, %{uuid: "u2", addon: "mosq", service: "other", config: %{}}} =
               Policy.discover([@mqtt], "mosq", "other", %{}, "u2")

      assert {:new, %{uuid: "u2", addon: "zigbee"}} =
               Policy.discover([@mqtt], "zigbee", "mqtt", %{"host" => "a"}, "u2")
    end

    test "the same app, service and config is the existing message, untouched" do
      assert {:existing, @mqtt} ==
               Policy.discover([@mqtt], "mosq", "mqtt", %{"host" => "a"}, "u2")
    end

    test "a changed config keeps the uuid" do
      assert {:updated, %{@mqtt | config: %{"host" => "b"}}} ==
               Policy.discover([@mqtt], "mosq", "mqtt", %{"host" => "b"}, "u2")
    end
  end

  describe "service roles" do
    @roles %{"mqtt" => "provide", "zigbee" => "want", "db" => "need"}

    test "only the provide role may provide" do
      caller = {:addon, %{slug: "a", services_role: @roles}}

      assert Policy.may_provide?(caller, "mqtt")
      refute Policy.may_provide?(caller, "zigbee")
      refute Policy.may_provide?(caller, "unknown")
      refute Policy.may_provide?(:supervisor, "mqtt")
      refute Policy.may_provide?(nil, "mqtt")
    end

    test "Core always reads; an app with any role for the service reads it" do
      caller = {:addon, %{slug: "a", services_role: @roles}}

      assert Policy.may_read_service?(:supervisor, "anything")

      for service <- ["mqtt", "zigbee", "db"],
          do: assert(Policy.may_read_service?(caller, service))

      refute Policy.may_read_service?(caller, "unknown")
      refute Policy.may_read_service?(nil, "mqtt")
    end
  end

  describe "services_view/1" do
    test "lists every known service, provided or not" do
      assert [%{slug: "mqtt", available: false, providers: []}] = Policy.services_view([])

      assert [%{slug: "mqtt", available: true, providers: ["mosq"]}] =
               Policy.services_view([{"mqtt", "mosq"}, {"unknown", "x"}])
    end
  end
end
