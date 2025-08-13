defmodule Supavisor.TIHandler do
  @moduledoc false
  use ThousandIsland.Handler

  require Logger
  alias Supavisor.ClientHandler
  alias Supavisor.TISock

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    peer_ip =
      case TISock.peername(socket) do
        {:ok, {ip, _}} -> List.to_string(:inet.ntoa(ip))
        _ -> "undefined"
      end

    Logger.metadata(peer_ip: peer_ip, local: state[:local] || false, state: :init)

    # Start the existing state machine using a minimal shim of the socket
    pid = :proc_lib.spawn_link(ClientHandler, :start_ti, [socket, state])

    {:continue, %{pid: pid, socket: socket}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{pid: pid} = s) do
    send(pid, {:tcp, socket, data})
    {:continue, s}
  end

  @impl ThousandIsland.Handler
  def handle_close(socket, %{pid: pid}) do
    send(pid, {:tcp_closed, socket})
    :ok
  end
end
