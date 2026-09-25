defmodule BmsclPhoenixFixture.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BmsclPhoenixFixtureWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BmsclPhoenixFixture.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    BmsclPhoenixFixtureWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
