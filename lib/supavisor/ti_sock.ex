defmodule Supavisor.TISock do
  @moduledoc false

  alias ThousandIsland.Socket, as: TISocket

  @spec send(TISocket.t(), iodata()) :: :ok | {:error, term()}
  def send(socket, data), do: TISocket.send(socket, data)

  @spec close(TISocket.t()) :: :ok
  def close(socket), do: TISocket.close(socket)

  @spec setopts(TISocket.t(), keyword()) :: :ok
  def setopts(_socket, _opts), do: :ok

  @spec controlling_process(TISocket.t(), pid) :: :ok
  def controlling_process(_socket, _pid), do: :ok

  @spec peername(TISocket.t()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def peername(socket), do: TISocket.peername(socket)

  @spec send_timeout(TISocket.t(), non_neg_integer()) :: :ok
  def send_timeout(_socket, _timeout), do: :ok
end
