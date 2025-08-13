defmodule Supavisor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias Supavisor.Monitoring.PromEx

  @metrics_disabled Application.compile_env(:supavisor, :metrics_disabled, false)

  @impl true
  def start(_type, _args) do
    primary_config = :logger.get_primary_config()

    host =
      case node() |> Atom.to_string() |> String.split("@") do
        [_, host] -> host
        _ -> nil
      end

    region = Application.get_env(:supavisor, :region)

    global_metadata =
      %{
        nodehost: host,
        az: Application.get_env(:supavisor, :availability_zone),
        region: region,
        location: System.get_env("LOCATION_KEY") || region,
        instance_id: System.get_env("INSTANCE_ID"),
        short_node_id: short_node_id()
      }

    :ok =
      :logger.set_primary_config(
        :metadata,
        Map.merge(primary_config.metadata, global_metadata)
      )

    :ok = Logger.add_handlers(:supavisor)

    :ok =
      :gen_event.swap_sup_handler(
        :erl_signal_server,
        {:erl_signal_handler, []},
        {Supavisor.SignalHandler, []}
      )

    local_proxy_shards_count = Application.fetch_env!(:supavisor, :local_proxy_shards)

    local_proxy_shards =
      for shard <- 0..(local_proxy_shards_count - 1), mode <- [:session, :transaction] do
        name = String.to_atom("pg_proxy_internal_#{mode}_#{shard}")
        {ThousandIsland,
         port: 0,
         handler_module: Supavisor.TIHandler,
         num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
         num_connections: 100_000,
         handler_options: %{mode: mode, local: true, shard: shard},
         transport_options: [nodelay: true, keepalive: true],
         supervisor_options: [name: name]}
      end

    proxy_ports =
      [
        {ThousandIsland,
         port: Application.get_env(:supavisor, :proxy_port_transaction),
         handler_module: Supavisor.TIHandler,
         num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
         num_connections: 100_000,
         handler_options: %{mode: :transaction, local: false},
         transport_options: [nodelay: true, keepalive: true],
         supervisor_options: [name: :pg_proxy_transaction]},
        {ThousandIsland,
         port: 4545,
         handler_module: Supavisor.TIHandler,
         num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
         num_connections: 100_000,
         handler_options: %{mode: :session, local: false},
         transport_options: [nodelay: true, keepalive: true],
         supervisor_options: [name: :pg_proxy_session]},
        {ThousandIsland,
         port: Application.get_env(:supavisor, :proxy_port),
         handler_module: Supavisor.TIHandler,
         num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
         num_connections: 100_000,
         handler_options: %{mode: :proxy, local: false},
         transport_options: [nodelay: true, keepalive: true],
         supervisor_options: [name: :pg_proxy]}
      ] ++ local_proxy_shards

    :syn.set_event_handler(Supavisor.SynHandler)
    :syn.add_node_to_scopes([:tenants, :availability_zone])

    :syn.join(:availability_zone, Application.get_env(:supavisor, :availability_zone), self(),
      node: node()
    )

    topologies = Application.get_env(:libcluster, :topologies) || []

    children = [
      Supavisor.ErlSysMon,
      Supavisor.Health,
      {Registry, keys: :unique, name: Supavisor.Registry.Tenants},
      {Registry, keys: :unique, name: Supavisor.Registry.ManagerTables},
      {Registry, keys: :unique, name: Supavisor.Registry.PoolPids},
      {Registry, keys: :duplicate, name: Supavisor.Registry.TenantSups},
      {Registry,
       keys: :duplicate,
       name: Supavisor.Registry.TenantClients,
       partitions: System.schedulers_online()},
      {Registry,
       keys: :duplicate,
       name: Supavisor.Registry.TenantProxyClients,
       partitions: System.schedulers_online()},
      {Cluster.Supervisor, [topologies, [name: Supavisor.ClusterSupervisor]]},
      Supavisor.Repo,
      # Start the Telemetry supervisor
      SupavisorWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Supavisor.PubSub},
      {
        PartitionSupervisor,
        child_spec: DynamicSupervisor, strategy: :one_for_one, name: Supavisor.DynamicSupervisor
      },
      Supavisor.Vault
      # Thousand Island listeners will be appended below
    ]

    Logger.warning("metrics_disabled is #{inspect(@metrics_disabled)}")

    children =
      if @metrics_disabled do
        children
      else
        children ++ [PromEx, Supavisor.TenantsMetrics, Supavisor.MetricsCleaner]
      end

    children = children ++ proxy_ports ++ [SupavisorWeb.Endpoint]

    # start Cachex only if the node uses names, this is necessary for test setup
    children =
      if node() != :nonode@nohost do
        [{Cachex, name: Supavisor.Cache} | children]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Supavisor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SupavisorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @spec short_node_id() :: String.t() | nil
  defp short_node_id do
    with {:ok, fly_alloc_id} when is_binary(fly_alloc_id) <-
           Application.fetch_env(:supavisor, :fly_alloc_id),
         [short_alloc_id, _] <- String.split(fly_alloc_id, "-", parts: 2) do
      short_alloc_id
    else
      _ -> nil
    end
  end
end
