-module(beamvoice_media_adapter).
-callback start_transport(map()) -> {ok, term()} | {error, term()}.
-callback stop_transport(term()) -> ok | {error, term()}.
-callback forward_packet(term(), binary()) -> ok | {error, term()}.
%% Contract only: ex_webrtc implementation is intentionally NOT bundled in this MVP.
