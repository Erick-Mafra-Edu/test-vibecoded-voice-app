defmodule BeamVoice.Media.MixProject do
  use Mix.Project

  def project do
    [app: :beamvoice_media, version: "0.2.0", elixir: "~> 1.18",
     start_permanent: Mix.env() == :prod,
     deps: [{:ex_webrtc, "0.17.0"}, {:beamvoice, path: "..", manager: :rebar3}],
     releases: [beamvoice: [applications: [beamvoice_media: :permanent]]]]
  end

  def application do
    [extra_applications: [:logger, :beamvoice], mod: {BeamVoice.Media.Application, []}]
  end
end
