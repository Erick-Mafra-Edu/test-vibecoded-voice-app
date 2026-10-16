defmodule BeamVoice.Media.Session do
  @moduledoc "One authenticated participant's bounded WebRTC transports; media never crosses rooms."
  use GenServer, restart: :temporary
  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate, MediaStreamTrack}

  def start_link(owner, room, user), do: GenServer.start_link(__MODULE__, {owner, room, user})
  def start(owner, room, user) do
    DynamicSupervisor.start_child(BeamVoice.Media.Supervisor,
      %{id: __MODULE__, start: {__MODULE__, :start_link, [owner, room, user]}, restart: :temporary})
  end
  def offer(pid, transport, publisher, sdp), do: GenServer.call(pid, {:offer, transport, publisher, sdp}, 5000)
  def candidate(pid, transport, candidate), do: GenServer.call(pid, {:candidate, transport, candidate}, 2000)
  def set_forwarding(pid, publisher, enabled) when is_boolean(enabled),
    do: GenServer.call(pid, {:forwarding, publisher, enabled}, 2000)
  def close(pid), do: GenServer.stop(pid, :normal)
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init({owner, room, user}) do
    Process.flag(:trap_exit, true)
    with {:ok, ^owner} <- :beamvoice_room.session(room, user),
         {:ok, _} <- Registry.register(BeamVoice.Media.Registry, {room, user}, nil) do
      Process.monitor(owner)
      Process.monitor(room)
      {:ok, %{owner: owner, room: room, user: user, transports: %{}, subscribers: %{},
        received: 0, forwarded: 0, dropped: 0, bytes: 0, packets: 0,
        window: System.monotonic_time(:millisecond)}}
    else
      _ -> {:stop, :unauthorized}
    end
  end

  @impl true
  def handle_call({:offer, id, publisher, %{"type" => "offer", "sdp" => sdp}}, {caller, _}, state)
      when is_binary(id) and byte_size(id) in 1..64 and is_binary(sdp) and byte_size(sdp) <= 32768 do
    cond do
      caller != state.owner -> {:reply, {:error, :unauthorized}, state}
      Map.has_key?(state.transports, id) -> {:reply, {:error, :transport_exists}, state}
      Enum.any?(state.transports, fn {_, t} -> t.publisher == publisher end) ->
        {:reply, {:error, :publisher_transport_exists}, state}
      map_size(state.transports) >= 24 -> {:reply, {:error, :transport_limit}, state}
      not member?(state.room, publisher) -> {:reply, {:error, :unauthorized}, state}
      not audio_offer?(sdp) -> {:reply, {:error, :invalid_sdp}, state}
      true -> negotiate(id, publisher, sdp, state)
    end
  end
  def handle_call({:candidate, id, json}, {caller, _}, state) do
    case {caller == state.owner, Map.get(state.transports, id), valid_candidate?(json)} do
      {true, %{candidates: n} = t, true} when n < 64 ->
        try do
          result = PeerConnection.add_ice_candidate(t.pc, ICECandidate.from_json(json))
          {:reply, result, put_in(state.transports[id].candidates, n + 1)}
        rescue
          _ -> {:reply, {:error, :invalid_candidate}, state}
        catch
          :exit, _ -> {:reply, {:error, :transport_unavailable}, state}
        end
      _ -> {:reply, {:error, :invalid_candidate}, state}
    end
  end
  def handle_call({:forwarding, publisher, enabled}, {caller, _}, state) when caller == state.owner do
    case Enum.find(state.transports, fn {_, t} -> t.publisher == publisher and t.track != nil end) do
      {id, t} ->
        case Registry.lookup(BeamVoice.Media.Registry, {state.room, publisher}) do
          [{source, _}] ->
            GenServer.cast(source, {:subscribe, self(), state.user, enabled})
            {:reply, :ok, put_in(state.transports[id], %{t | enabled: enabled, source: source})}
          [] -> {:reply, {:error, :publisher_unavailable}, state}
        end
      nil -> {:reply, {:error, :transport_missing}, state}
    end
  end
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:received, :forwarded, :dropped]), state}
  end
  def handle_call(_, _, state), do: {:reply, {:error, :bad_request}, state}

  @impl true
  def handle_cast({:subscribe, pid, user, enabled}, state) do
    authorized = Registry.lookup(BeamVoice.Media.Registry, {state.room, user}) == [{pid, nil}] and
      member?(state.room, user)
    subscribers = cond do
      not authorized -> state.subscribers
      enabled and not Map.has_key?(state.subscribers, pid) ->
        Map.put(state.subscribers, pid, Process.monitor(pid))
      not enabled ->
        if ref = state.subscribers[pid], do: Process.demonitor(ref, [:flush])
        Map.delete(state.subscribers, pid)
      true -> state.subscribers
    end
    {:noreply, %{state | subscribers: subscribers}}
  end
  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, state) do
    with {id, t} <- transport(state, pc) do
      signal(state, %{"type" => "media_candidate", "transport" => id,
        "publisher" => t.publisher, "candidate" => ICECandidate.to_json(candidate)})
    end
    {:noreply, state}
  end
  def handle_info({:ex_webrtc, pc, {:track, %{kind: :audio, id: track}}}, state) do
    case transport(state, pc) do
      {id, %{publisher: user}} when user == state.user ->
        {:noreply, put_in(state.transports[id].input_track, track)}
      _ -> {:noreply, state}
    end
  end
  def handle_info({:ex_webrtc, pc, {:connection_state_change, status}}, state) do
    case transport(state, pc) do
      {id, t} ->
        signal(state, %{"type" => "media_state", "transport" => id,
          "publisher" => t.publisher, "state" => Atom.to_string(status)})
        {:noreply, put_in(state.transports[id].connected, status == :connected)}
      _ -> {:noreply, state}
    end
  end
  def handle_info({:ex_webrtc, pc, {:rtp, track, nil, packet}}, state) do
    now = System.monotonic_time(:millisecond)
    state = if now - state.window >= 1000,
      do: %{state | window: now, bytes: 0, packets: 0}, else: state
    state = %{state | packets: state.packets + 1, bytes: state.bytes + byte_size(packet.payload)}
    case transport(state, pc) do
      {_, %{publisher: user}} when user == state.user and
          (state.packets > 120 or state.bytes > 64000) ->
        :beamvoice_metrics.inc(:rtp_packets_dropped_total)
        {:stop, :media_rate_limit, %{state | dropped: state.dropped + 1}}
      {_, %{publisher: user, input_track: ^track}} when user == state.user and
          state.packets <= 120 and state.bytes <= 64000 and byte_size(packet.payload) <= 1500 ->
        Enum.each(state.subscribers, fn {pid, _} ->
          if below_queue_limit?(pid), do: send(pid, {:forward_rtp, self(), user, packet})
        end)
        :beamvoice_metrics.inc(:rtp_packets_received_total)
        {:noreply, %{state | received: state.received + 1}}
      _ ->
        :beamvoice_metrics.inc(:rtp_packets_dropped_total)
        {:noreply, %{state | dropped: state.dropped + 1}}
    end
  end
  def handle_info({:forward_rtp, source, publisher, packet}, state) do
    case Enum.find(state.transports, fn {_, t} ->
      t.publisher == publisher and t.source == source and t.enabled and t.connected
    end) do
      {_, t} ->
        if below_queue_limit?(t.pc) do
          # ExWebRTC rewrites SSRC/PT/extensions and encrypts with this recipient's SRTP context.
          :ok = PeerConnection.send_rtp(t.pc, t.track, packet)
          :beamvoice_metrics.inc(:rtp_packets_forwarded_total)
          {:noreply, %{state | forwarded: state.forwarded + 1}}
        else
          :beamvoice_metrics.inc(:rtp_packets_dropped_total)
          {:noreply, %{state | dropped: state.dropped + 1}}
        end
      nil ->
        :beamvoice_metrics.inc(:rtp_packets_dropped_total)
        {:noreply, %{state | dropped: state.dropped + 1}}
    end
  end
  def handle_info({:DOWN, _ref, :process, pid, _}, state) when pid == state.owner or pid == state.room,
    do: {:stop, :normal, state}
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  def handle_info({:EXIT, pc, _reason}, state) do
    case transport(state, pc) do
      nil -> {:noreply, state}
      _ -> {:stop, :transport_failed, state}
    end
  end
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.transports, fn {_, t} ->
      try do
        if Process.alive?(t.pc), do: PeerConnection.stop(t.pc)
      catch
        :exit, _ -> :ok
      end
    end)
    :ok
  end

  defp negotiate(id, publisher, sdp, state) do
    options = Application.get_env(:beamvoice_media, :peer_options, []) ++
      [audio_codecs: [:opus], video_codecs: [], features: [:rtcp_reports], ice_servers: []]
    with {:ok, pc} <- PeerConnection.start_link(options) do
      track = if publisher != state.user, do: MediaStreamTrack.new(:audio), else: nil
      result = try do
        if track, do: PeerConnection.add_track(pc, track)
        with :ok <- PeerConnection.set_remote_description(pc, %SessionDescription{type: :offer, sdp: sdp}),
             {:ok, answer} <- PeerConnection.create_answer(pc),
             :ok <- PeerConnection.set_local_description(pc, answer), do: {:ok, answer}
      rescue
        _ -> {:error, :invalid_sdp}
      catch
        :exit, _ -> {:error, :transport_unavailable}
      end
      case result do
        {:ok, answer} ->
          t = %{pc: pc, publisher: publisher, track: track && track.id, input_track: nil,
            candidates: 0, connected: false, enabled: false, source: nil}
          signal(state, %{"type" => "media_answer", "transport" => id,
            "publisher" => publisher, "sdp" => SessionDescription.to_json(answer)})
          {:reply, :ok, put_in(state.transports[id], t)}
        _ ->
          try do
            PeerConnection.stop(pc)
          catch
            :exit, _ -> :ok
          end
          {:reply, {:error, :invalid_sdp}, state}
      end
    else
      _ -> {:reply, {:error, :transport_unavailable}, state}
    end
  end

  defp signal(state, message), do: send(state.owner, {:media_signal, message})
  defp transport(state, pc), do: Enum.find(state.transports, fn {_, t} -> t.pc == pc end)
  defp member?(room, user), do: match?({:ok, _}, :beamvoice_room.session(room, user))
  defp below_queue_limit?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n < 128
      _ -> false
    end
  end
  defp audio_offer?(sdp) do
    lines = String.split(sdp, "\n")
    Enum.count(lines, &String.starts_with?(&1, "m=")) == 1 and
      Enum.any?(lines, &String.starts_with?(&1, "m=audio ")) and
      String.contains?(sdp, "UDP/TLS/RTP/SAVPF") and String.contains?(sdp, "a=fingerprint:sha-256 ")
  end
  defp valid_candidate?(%{"candidate" => value} = json) when is_binary(value) and byte_size(value) <= 2048 do
    map_size(json) <= 4 and Map.has_key?(json, "sdpMid") and
      Map.has_key?(json, "sdpMLineIndex") and
      (is_nil(json["sdpMid"]) or (is_binary(json["sdpMid"]) and byte_size(json["sdpMid"]) <= 32)) and
      (is_nil(json["sdpMLineIndex"]) or json["sdpMLineIndex"] == 0) and
      (is_nil(json["usernameFragment"]) or (is_binary(json["usernameFragment"]) and byte_size(json["usernameFragment"]) <= 256))
  end
  defp valid_candidate?(_), do: false
end
