defmodule BeamVoice.Media.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link([
      {Registry, keys: :unique, name: BeamVoice.Media.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: BeamVoice.Media.Supervisor}
    ], strategy: :one_for_all, name: __MODULE__)
  end
end
