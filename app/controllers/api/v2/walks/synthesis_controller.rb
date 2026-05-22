# frozen_string_literal: true

# Post-walk product synthesis: takes the captured Q&A transcript from a
# completed walk and asks Claude to draft a Gumroad product (title,
# description, chapters, price, bullets). The iOS app calls this once
# per walk; the Anthropic key stays server-side.
class Api::V2::Walks::SynthesisController < Api::V2::BaseController
  # See RealtimeTokensController for the entitlement rationale.
  skip_before_action :verify_authenticity_token, only: [:create]
  before_action :require_walks_entitlement

  MIN_EXCHANGES = 5
  MAX_EXCHANGES = 100
  MAX_TOPIC_LENGTH = 500
  MAX_EXCHANGE_CONTENT_LENGTH = 2000
  ANTHROPIC_MODEL = "claude-opus-4-7"
  MAX_TOKENS = 4096

  def create
    topic = params[:topic].to_s
    exchanges = Array(params[:exchanges])

    if topic.length > MAX_TOPIC_LENGTH
      return render json: {
        error: "Topic too long — please keep it under #{MAX_TOPIC_LENGTH} characters.",
      }, status: :unprocessable_entity
    end

    if exchanges.length < MIN_EXCHANGES
      return render json: {
        error: "Walks under #{MIN_EXCHANGES} exchanges don't have enough to draft a product yet. Keep talking — 10-15 minutes of back-and-forth gives the synthesizer enough to work with.",
      }, status: :unprocessable_entity
    end

    if exchanges.length > MAX_EXCHANGES
      return render json: {
        error: "Transcript too long — please keep walks under #{MAX_EXCHANGES} exchanges.",
      }, status: :unprocessable_entity
    end

    normalized_exchanges = normalize_exchanges(exchanges)
    if normalized_exchanges.nil?
      return render json: {
        error: "Each exchange must be an object with question and answer fields no longer than #{MAX_EXCHANGE_CONTENT_LENGTH} characters.",
      }, status: :unprocessable_entity
    end

    transcript = format_transcript(normalized_exchanges)
    user_prompt = GumroadWalksPrompts.synthesizer_user(topic:, transcript:)

    upstream = HTTP.timeout(120)
      .headers(
        "x-api-key" => GlobalConfig.get("ANTHROPIC_API_KEY"),
        "anthropic-version" => "2023-06-01",
      )
      .post(
        "https://api.anthropic.com/v1/messages",
        json: {
          model: ANTHROPIC_MODEL,
          max_tokens: MAX_TOKENS,
          system: GumroadWalksPrompts::SYNTHESIZER_SYSTEM,
          messages: [{ role: "user", content: user_prompt }],
        }
      )

    if upstream.status.success?
      draft = extract_json_from_anthropic_response(upstream.parse)
      if draft.is_a?(Hash)
        render json: draft.merge(model: ANTHROPIC_MODEL)
      else
        Rails.logger.warn("Anthropic synthesis returned unexpected structure: #{draft.class}")
        render json: { error: "Could not parse synthesis result." }, status: :bad_gateway
      end
    else
      Rails.logger.warn("Anthropic synthesis failed: #{upstream.status} #{upstream.body}")
      render json: { error: "Could not synthesize product draft." }, status: :bad_gateway
    end
  rescue HTTP::Error => e
    Rails.logger.warn("Anthropic synthesis network error: #{e.class} #{e.message}")
    render json: { error: "Could not reach synthesis service." }, status: :bad_gateway
  end

  private
    # Returns an array of `{ question:, answer: }` hashes, or nil if any
    # element isn't a hash-like or has fields over MAX_EXCHANGE_CONTENT_LENGTH.
    # Hostile clients can send arrays of bare strings — without this guard the
    # `ex[:question]` reads in format_transcript raise TypeError.
    def normalize_exchanges(exchanges)
      exchanges.map do |ex|
        return nil unless ex.is_a?(Hash) || ex.is_a?(ActionController::Parameters)
        question = (ex[:question].presence || ex["question"]).to_s
        answer = (ex[:answer].presence || ex["answer"]).to_s
        return nil if question.length > MAX_EXCHANGE_CONTENT_LENGTH
        return nil if answer.length > MAX_EXCHANGE_CONTENT_LENGTH
        { question:, answer: }
      end
    end

    def format_transcript(exchanges)
      exchanges.each_with_index.map do |ex, i|
        "Q#{i + 1}: #{ex[:question]}\nA#{i + 1}: #{ex[:answer]}"
      end.join("\n\n")
    end

    # Claude returns content as an array of typed blocks; we asked for plain
    # text + no code fences but strip them defensively in case the model
    # decided to be helpful.
    def extract_json_from_anthropic_response(body)
      blocks = body.dig("content") || []
      text = blocks.filter_map { |b| b["text"].to_s if b["type"] == "text" }.join
      cleaned = text.strip.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.warn("Anthropic synthesis returned non-JSON: #{e.message} — raw: #{cleaned.truncate(500)}")
      nil
    end

    def require_walks_entitlement
      jws = request.headers["X-Apple-Transaction-JWS"].to_s.presence
      return if jws && AppStoreWalksJwsVerifier.verify(jws).valid?
      render json: { error: "Active Gumroad Walks subscription required." }, status: :payment_required
    end
end
