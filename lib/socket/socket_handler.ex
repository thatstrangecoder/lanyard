defmodule Lanyard.SocketHandler do
  require Logger

  alias Lanyard.Presence

  @type t :: %{
          awaiting_init: boolean,
          encoding: String.t(),
          compression: String.t()
        }

  defstruct awaiting_init: true,
            encoding: nil,
            compression: nil

  @behaviour :cowboy_websocket

  def init(request, _state) do
    compression =
      request
      |> :cowboy_req.parse_qs()
      |> Enum.find(fn {name, _value} -> name == "compression" end)
      |> case do
        {_name, "zlib_json"} -> :zlib
        _ -> :json
      end

    state = %__MODULE__{awaiting_init: true, encoding: "json", compression: compression}

    {:cowboy_websocket, request, state}
  end

  def websocket_init(state) do
    {:reply,
     construct_socket_msg(state.compression, %{op: 1, d: %{"heartbeat_interval" => 30000}}),
     state}
  end

  def websocket_handle({:ping, _binary}, state) do
    {:ok, state}
  end

  def websocket_handle({_type, json}, state) do
    with {:ok, json} <- Poison.decode(json) do
      case json["op"] do
        2 ->
          init_state =
            case json["d"] do
              %{"subscribe_to_ids" => ids} ->
                Logger.debug(
                  "Sockets | Socket initialized and subscribed to list: #{inspect(ids)}"
                )

                ids
                |> Enum.reduce(%{}, fn id, acc ->
                  case GenRegistry.lookup(Lanyard.Presence, id) do
                    {:ok, pid} ->
                      {:ok, raw_data} = Presence.get_presence(id)
                      {_, presence} = Presence.build_pretty_presence(raw_data)
                      GenServer.cast(pid, {:add_subscriber, self()})
                      %{"#{id}": presence} |> Map.merge(acc)

                    _ ->
                      acc
                  end
                end)

              %{"subscribe_to_id" => id} ->
                {:ok, pid} = GenRegistry.lookup(Lanyard.Presence, id)

                {:ok, raw_data} = Presence.get_presence(id)
                {_, presence} = Presence.build_pretty_presence(raw_data)

                GenServer.cast(pid, {:add_subscriber, self()})

                Logger.debug("Sockets | Socket initialized and subscribed to singleton: #{id}")
                presence
            end

          {:reply,
           construct_socket_msg(state.compression, %{op: 0, t: "INIT_STATE", d: init_state}),
           state}

        # Used for heartbeating
        3 ->
          {:ok, state}

        _ ->
          {:reply, {:close, 4004, "unknown_opcode"}, state}
      end
    end
  end

  @spec websocket_info({:remote_send, any}, atom | %{:compression => any, optional(any) => any}) ::
          {:reply,
           {:binary,
            maybe_improper_list(
              binary | maybe_improper_list(any, binary | []) | byte,
              binary | []
            )}
           | {:text,
              binary
              | maybe_improper_list(
                  binary | maybe_improper_list(any, binary | []) | byte,
                  binary | []
                )}, atom | %{:compression => any, optional(any) => any}}
  def websocket_info({:remote_send, message}, state) do
    {:reply, construct_socket_msg(state.compression, message), state}
  end

  defp construct_socket_msg(compression, data) do
    case compression do
      :zlib ->
        data = data |> Poison.encode!()

        z = :zlib.open()
        :zlib.deflateInit(z)

        data = :zlib.deflate(z, data, :finish)

        :zlib.deflateEnd(z)

        {:binary, data}

      _ ->
        data =
          data
          |> Poison.encode!()

        {:text, data}
    end
  end
end
