# frozen_string_literal: true

# Post-walk product synthesis: takes the captured Q&A transcript from a
# completed walk and asks Claude to draft a Gumroad product (title,
# description, chapters, price, bullets). The iOS app calls this once
# per walk; the Anthropic key stays server-side.
class Api::V2::Walks::SynthesisController < Api::V2::BaseController
  before_action :doorkeeper_authorize!
  before_action :require_walks_subscription

  MIN_EXCHANGES = 5
  MAX_EXCHANGES = 100
  ANTHROPIC_MODEL = "claude-opus-4-7"
  MAX_TOKENS = 4096

  def create
    topic = params[:topic].to_s
    exchanges = Array(params[:exchanges])

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

    transcript = format_transcript(exchanges)
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
      if draft.nil?
        render json: { error: "Could not parse synthesis result." }, status: :bad_gateway
      else
        render json: draft.merge(model: ANTHROPIC_MODEL)
      end
    else
      Rails.logger.warn("Anthropic synthesis failed: #{upstream.status} #{upstream.body}")
      render json: { error: "Could not synthesize product draft." }, status: :bad_gateway
    end
  end

  private
    def format_transcript(exchanges)
      exchanges.each_with_index.map do |ex, i|
        question = ex[:question].to_s.presence || ex["question"].to_s
        answer = ex[:answer].to_s.presence || ex["answer"].to_s
        "Q#{i + 1}: #{question}\nA#{i + 1}: #{answer}"
      end.join("\n\n")
    end

    # Claude returns content as an array of typed blocks; we asked for plain
    # text + no code fences but strip them defensively in case the model
    # decided to be helpful.
    def extract_json_from_anthropic_response(body)
      blocks = body.dig("content") || []
      text = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"].to_s }.join
      cleaned = text.strip.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.warn("Anthropic synthesis returned non-JSON: #{e.message} — raw: #{cleaned.truncate(500)}")
      nil
    end

    def require_walks_subscription
      jws = request.headers["X-Apple-Transaction-JWS"].to_s
      return if current_resource_owner&.gumroad_walks_subscribed?(transaction_jws: jws)
      render json: { error: "Active Gumroad Walks subscription required." }, status: :payment_required
    end
end
