defmodule BeamVoice.Media.SessionTest do
  use ExUnit.Case, async: false
  alias BeamVoice.Media.Session
  alias ExWebRTC.{PeerConnection, MediaStreamTrack, SessionDescription, ICECandidate}

  test "real ICE/DTLS-SRTP Opus forwarding is gated and stops with its owner" do
    {:ok, room} = :beamvoice_room_registry.get_or_create("media-integration")
    :ok = :beamvoice_room.join(room, "a", self())
    :ok = :beamvoice_room.join(room, "b", self())
    {:ok, a} = Session.start(self(), room, "a")
    {:ok, b} = Session.start(self(), room, "b")
    {:ok, publisher} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
    {:ok, subscriber} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
    on_exit(fn ->
      for pid <- [a, b, publisher, subscriber] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)
    track = MediaStreamTrack.new(:audio)
    {:ok, _} = PeerConnection.add_transceiver(publisher, track, direction: :sendonly)
    {:ok, _} = PeerConnection.add_transceiver(subscriber, :audio, direction: :recvonly)
    peers = %{publisher => {a, "up"}, subscriber => {b, "down"}}
    for {pc, {session, id}} <- peers do
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)
      assert :ok = Session.offer(session, id, "a", SessionDescription.to_json(offer))
    end
    connect(peers, MapSet.new(), System.monotonic_time(:millisecond) + 15000)
    assert PeerConnection.get_dtls_transport_state(publisher) == :connected
    assert PeerConnection.get_dtls_transport_state(subscriber) == :connected
    packet = ExRTP.Packet.new(<<0xF8, 0xFF, 0xFE>>, sequence_number: 1, timestamp: 960)
    :ok = PeerConnection.send_rtp(publisher, track.id, packet)
    refute_receive {:ex_webrtc, ^subscriber, {:rtp, _, _, _}}, 200
    assert Session.stats(b).forwarded == 0
    assert :ok = Session.set_forwarding(b, "a", true)
    # Subscription crosses processes; confirm it before injecting the deterministic sample.
    :sys.get_state(a)
    :ok = PeerConnection.send_rtp(publisher, track.id, %{packet | sequence_number: 2, timestamp: 1920})
    assert_receive {:ex_webrtc, ^subscriber, {:rtp, _, nil, received}}, 3000
    assert received.payload == packet.payload
    assert received.timestamp == 1920
    assert Session.stats(b).forwarded == 1
    assert :ok = Session.set_forwarding(b, "a", false)
    :sys.get_state(a)
    :ok = PeerConnection.send_rtp(publisher, track.id, %{packet | sequence_number: 3, timestamp: 2880})
    refute_receive {:ex_webrtc, ^subscriber, {:rtp, _, _, _}}, 200
  end

  test "foreign owner and room are rejected before allocating transports" do
    {:ok, room} = :beamvoice_room_registry.get_or_create("media-authorization")
    :ok = :beamvoice_room.join(room, "a", self())
    {:ok, session} = Session.start(self(), room, "a")
    assert {:error, :unauthorized} = Session.start(self(), room, "stranger")
    result = Task.async(fn -> Session.offer(session, "x", "a", %{"type" => "offer", "sdp" => "bad"}) end)
    assert {:error, :unauthorized} = Task.await(result)
    assert {:error, :unauthorized} = Session.offer(session, "x", "stranger", %{"type" => "offer", "sdp" => "bad"})
    assert {:error, :invalid_sdp} = Session.offer(session, "x", "a", %{"type" => "offer", "sdp" => "bad"})
    malformed = "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=fingerprint:sha-256 broken\n"
    assert {:error, :invalid_sdp} = Session.offer(session, "x", "a", %{"type" => "offer", "sdp" => malformed})
    assert Process.alive?(session)
    assert {:error, :invalid_candidate} = Session.candidate(session, "missing", %{"candidate" => "bad"})
    Session.close(session)
  end

  defp connect(peers, connected, deadline) do
    if MapSet.size(connected) < map_size(peers) do
      remaining = max(0, deadline - System.monotonic_time(:millisecond))
      receive do
        {:media_signal, %{"type" => "media_answer", "transport" => id, "sdp" => answer}} ->
          {pc, _} = Enum.find(peers, fn {_, {_, transport}} -> transport == id end)
          :ok = PeerConnection.set_remote_description(pc, SessionDescription.from_json(answer))
          connect(peers, connected, deadline)
        {:media_signal, %{"type" => "media_candidate", "transport" => id, "candidate" => candidate}} ->
          {pc, _} = Enum.find(peers, fn {_, {_, transport}} -> transport == id end)
          :ok = PeerConnection.add_ice_candidate(pc, ICECandidate.from_json(candidate))
          connect(peers, connected, deadline)
        {:ex_webrtc, pc, {:ice_candidate, candidate}} ->
          {session, id} = Map.fetch!(peers, pc)
          :ok = Session.candidate(session, id, ICECandidate.to_json(candidate))
          connect(peers, connected, deadline)
        {:ex_webrtc, pc, {:connection_state_change, :connected}} ->
          connect(peers, MapSet.put(connected, pc), deadline)
        _ -> connect(peers, connected, deadline)
      after
        remaining -> flunk("real WebRTC negotiation timed out")
      end
    end
  end
end
