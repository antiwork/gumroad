# frozen_string_literal: true

# Issues short-lived ephemeral tokens (`ek_...`) for the Gumroad Walks iOS app
# to connect directly to OpenAI's Realtime WebSocket. The long-lived OpenAI
# key never leaves this server — the client only ever holds a token scoped
# to a single voice-interview session and bounded to a 2-hour TTL.
#
# Why this exists at all:
#  - Apple's 3.1.1 review process and OpenAI's ToS both reject distributing
#    a Bearer key in a client binary (the gumroad-walks iOS app's previous
#    submission was rejected for exactly this).
#  - Proxying the WS audio frames through Rails would put 2-4 hours of mic
#    audio per walk through our infrastructure — wasteful and slow.
#  - OpenAI's `/v1/realtime/client_secrets` endpoint solves both: server
#    holds the master key, client gets a per-session token, audio flows
#    direct client <-> OpenAI.
class Api::V2::Walks::RealtimeTokensController < Api::V2::BaseController
  # No Doorkeeper. Gumroad OAuth is only required to *publish* the post-walk
  # draft (see GumroadAuth#publishProduct in the iOS app); starting a walk
  # itself only needs the StoreKit subscription, and the first walk is free.
  # require_walks_entitlement does the JWS-or-anonymous gating below.
  skip_before_action :verify_authenticity_token, only: [:create]
  before_action :require_walks_entitlement

  REALTIME_MODEL = "gpt-realtime-2"
  TRANSCRIPTION_MODEL = "gpt-realtime-whisper"
  VOICE = "marin"

  def create
    topic = params[:topic].to_s

    upstream = HTTP.timeout(30)
      .auth("Bearer #{GlobalConfig.get('OPENAI_API_KEY')}")
      .post(
        "https://api.openai.com/v1/realtime/client_secrets",
        json: { session: session_config(topic) }
      )

    if upstream.status.success?
      render json: upstream.parse
    else
      Rails.logger.warn("OpenAI client_secrets failed: #{upstream.status} #{upstream.body}")
      render json: { error: "Could not create realtime session." }, status: :bad_gateway
    end
  rescue HTTP::Error => e
    Rails.logger.warn("OpenAI realtime token network error: #{e.class} #{e.message}")
    render json: { error: "Could not reach realtime service." }, status: :bad_gateway
  end

  private
    # The full session shape — mirrors what the iOS Interviewer used to send
    # via session.update, but pinned server-side so the client can't widen
    # the model's capabilities (no tools, no extra modalities, locked voice).
    def session_config(topic)
      {
        type: "realtime",
        model: REALTIME_MODEL,
        instructions: GumroadWalksPrompts.interviewer(topic:),
        output_modalities: ["audio"],
        audio: {
          input: {
            transcription: { model: TRANSCRIPTION_MODEL, language: "en" },
            turn_detection: {
              type: "semantic_vad",
              eagerness: "low",
              create_response: true,
              interrupt_response: true,
            },
          },
          output: { voice: VOICE },
        },
      }
    end

    # Two entitlement paths:
    #   - Subscriber: X-Apple-Transaction-JWS header verifies via Apple's
    #     chain -> active ProSub -> allow.
    #   - Anonymous (no JWS): treated as free-trial. Rack::Attack throttles
    #     by IP keep abuse bounded (see config/initializers/rack_attack.rb).
    #     The iOS client only sends an anonymous request for the user's first
    #     walk; subsequent walks either attach the JWS or surface the paywall.
    # If a JWS IS present but invalid/expired, reject with 402 — we know the
    # user is supposed to be subscribed and the proof failed.
    def require_walks_entitlement
      jws = request.headers["X-Apple-Transaction-JWS"].to_s.presence
      return if jws.nil?
      return if AppStoreWalksJwsVerifier.verify(jws).valid?
      render json: { error: "Active Gumroad Walks subscription required." }, status: :payment_required
    end
end
