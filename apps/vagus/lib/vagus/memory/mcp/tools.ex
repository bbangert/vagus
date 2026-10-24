defmodule Vagus.Memory.MCP.Tools do
  @moduledoc """
  The six MCP tools and their argument mapping onto `Vagus.Memory`. A
  wrong-typed or missing argument is a tool error the model can read and
  correct, not a protocol error.
  """

  alias Vagus.Memory.Store

  @string %{type: "string"}

  @tools [
    %{
      name: "remember",
      description:
        "Store a memory for later recall: a fact, decision, lesson or observation. " <>
          "Use a short kind (e.g. fact, decision, lesson) and a scope to group it " <>
          "(a project, device or topic).",
      inputSchema: %{
        type: "object",
        properties: %{
          kind: @string,
          scope: @string,
          text: @string,
          refs: %{type: "array", maxItems: 64, description: "Related ids, paths or URLs."}
        },
        required: ["kind", "text"]
      }
    },
    %{
      name: "recall",
      description:
        "Search stored memories by meaning and keywords; returns the best matches, " <>
          "newest first among equals.",
      inputSchema: %{
        type: "object",
        properties: %{
          query: @string,
          scope: @string,
          k: %{type: "integer", minimum: 1, maximum: 100, default: 8}
        },
        required: ["query"]
      }
    },
    %{
      name: "journal",
      description: "Append an entry to a task's journal; a summary also marks the task finished.",
      inputSchema: %{
        type: "object",
        properties: %{task: @string, entry: @string, summary: @string},
        required: ["task", "entry"]
      }
    },
    %{
      name: "device_note",
      description: "Append a note to what is known about a device (by its id).",
      inputSchema: %{
        type: "object",
        properties: %{device_id: @string, text: @string},
        required: ["device_id", "text"]
      }
    },
    %{
      name: "capture_register",
      description: "Record a captured file (a log, trace or image) by its path, with metadata.",
      inputSchema: %{
        type: "object",
        properties: %{path: @string, meta: %{type: "object"}},
        required: ["path"]
      }
    },
    %{
      name: "forget",
      description:
        "Hide a memory from recall, with the reason; optionally name the memory that " <>
          "replaces it. Nothing is deleted.",
      inputSchema: %{
        type: "object",
        properties: %{id: %{type: "integer"}, reason: @string, replaced_by: %{type: "integer"}},
        required: ["id", "reason"]
      }
    }
  ]

  @names for tool <- @tools, do: tool.name

  @spec list() :: [map()]
  def list, do: @tools

  @spec known?(String.t()) :: boolean()
  def known?(name), do: name in @names

  @spec call(String.t(), term(), map()) :: {:ok, term()} | {:error, term()}
  def call(_name, arguments, _context) when not is_map(arguments),
    do: {:error, {:invalid_argument, "arguments"}}

  def call("remember", args, context) do
    with {:ok, kind} <- required(args, "kind"),
         {:ok, text} <- required(args, "text"),
         {:ok, scope} <- optional(args, "scope", &is_binary/1),
         {:ok, refs} <- optional(args, "refs", &is_list/1) do
      Store.remember(kind, scope, text,
        refs: refs || [],
        source_task: context.source_task,
        store: context.store
      )
    end
  end

  def call("recall", args, context) do
    with {:ok, query} <- required(args, "query"),
         {:ok, scope} <- optional(args, "scope", &is_binary/1),
         {:ok, k} <- optional(args, "k", &is_integer/1) do
      Store.recall(query, scope: scope, k: k || 8, store: context.store)
    end
  end

  def call("journal", args, context) do
    with {:ok, task} <- required(args, "task"),
         {:ok, entry} <- required(args, "entry"),
         {:ok, summary} <- optional(args, "summary", &is_binary/1) do
      Store.journal(task, entry, summary: summary, store: context.store)
    end
  end

  def call("device_note", args, context) do
    with {:ok, device_id} <- required(args, "device_id"),
         {:ok, text} <- required(args, "text") do
      Store.device_note(device_id, text, store: context.store)
    end
  end

  def call("capture_register", args, context) do
    with {:ok, path} <- required(args, "path"),
         {:ok, meta} <- optional(args, "meta", &is_map/1) do
      Store.capture_register(path, meta || %{}, task: context.task, store: context.store)
    end
  end

  def call("forget", args, context) do
    with {:ok, id} <- required(args, "id", &is_integer/1),
         {:ok, reason} <- required(args, "reason"),
         {:ok, replaced_by} <- optional(args, "replaced_by", &is_integer/1) do
      Store.forget(id, reason,
        replaced_by: replaced_by,
        source_task: context.source_task,
        store: context.store
      )
    end
  end

  defp required(args, key, valid? \\ &is_binary/1) do
    case Map.fetch(args, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid(key)
      :error -> invalid(key)
    end
  end

  defp optional(args, key, valid?) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value -> if valid?.(value), do: {:ok, value}, else: invalid(key)
    end
  end

  defp invalid(key), do: {:error, {:invalid_argument, key}}
end
