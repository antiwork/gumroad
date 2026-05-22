# frozen_string_literal: true

class Ai::PageGeneratorService
  TIMEOUT_IN_SECONDS = 90
  MAX_TOKENS = 8000

  # Generation runs through the Vercel AI Gateway (OpenAI-compatible API),
  # which lets us swap models with a one-line change to MODEL — the Ruby
  # OpenAI client interface is preserved end-to-end. Set AI_GATEWAY_URL to
  # an empty string (or override to direct OpenAI) in dev/test if needed.
  DEFAULT_GATEWAY_URL = "https://ai-gateway.vercel.sh/v1"
  GATEWAY_URL = ENV["AI_GATEWAY_URL"].presence || DEFAULT_GATEWAY_URL
  ACCESS_TOKEN = ENV["AI_GATEWAY_API_KEY"].presence || ENV["OPENAI_API_KEY"]
  MODEL = "anthropic/claude-opus-4-7"

  # Transient errors are re-raised so Sidekiq retries the job. Permanent
  # errors (bad responses, malformed JSON, our own bugs) return a failure
  # Result so the job exits cleanly with `generation_error` set.
  TRANSIENT_ERRORS = [
    Faraday::TimeoutError,
    Faraday::ConnectionFailed,
    Faraday::ServerError, # HTTP 5xx
    Net::OpenTimeout,
    Net::ReadTimeout,
  ].freeze

  Result = Struct.new(:html, :version, :error, keyword_init: true) do
    def success? = error.nil?
  end

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are an expert web developer specializing in Tailwind CSS.

    OUTPUT FORMAT (CRITICAL):
    Your response MUST be raw HTML code only. Start immediately with the opening HTML tag (e.g., <div). Do NOT include:
    - Markdown code fences (```html or ```)
    - Explanations or commentary
    - Anything other than pure HTML

    Your HTML response should:
    - Use only Tailwind CSS classes for styling (no custom CSS style attributes)
    - Always use sections to divide the page into logical sections
    - Add significant padding and margin to sections (e.g. <section class="py-12">) and other elements
    - Include responsive design classes for mobile, tablet, and desktop
    - Follow the 3-3-3 Rule: maximum 3 font sizes, 3 font weights, and 3 colors
    - Be self-contained (no doctype, html, head, or body tags — just the inner content)

    For buy buttons, use this format:
    <a href="PRODUCT_SHORT_URL?wanted=true" class="...">Buy Now</a>

    For product data that should stay live, use data attributes:
    <span data-gumroad-ref="product:PERMALINK" data-gumroad-field="price">$XX</span>
    <span data-gumroad-ref="product:PERMALINK" data-gumroad-field="name">Product Name</span>

    The current year is #{Time.current.year}.

    Remember: Output raw HTML only. No markdown, no code blocks, no explanations.
  PROMPT

  def initialize(page:, seller:, prompt:, parent_version: nil)
    @page = page
    @seller = seller
    @prompt = prompt
    @parent_version = parent_version
  end

  def call
    messages = build_messages
    response = openai_client.chat(
      parameters: {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        temperature: 0.7,
        messages: messages,
      },
    )

    raw_html = response.dig("choices", 0, "message", "content").to_s.strip
    # Strip markdown code fences if the model includes them anyway
    raw_html = raw_html.sub(/\A```html\s*/i, "").sub(/\s*```\z/, "")

    sanitized = Ai::PageSanitizer.sanitize(raw_html)

    version = @page.page_versions.create!(
      html: sanitized,
      prompt: @prompt,
      parent: @parent_version,
    )

    Result.new(html: sanitized, version: version)
  rescue *TRANSIENT_ERRORS => e
    # Re-raise so Sidekiq retries the job — these are network/timeout/5xx
    # blips that usually resolve on retry.
    Rails.logger.warn("Ai::PageGeneratorService transient error: #{e.class}: #{e.message}")
    raise
  rescue Faraday::ClientError => e
    # 429 (rate limit) is transient; other 4xx are permanent (bad request,
    # auth, etc.) and should not retry.
    status = e.response&.dig(:status)
    if status == 429
      Rails.logger.warn("Ai::PageGeneratorService rate-limited (429): #{e.message}")
      raise
    end
    Rails.logger.error("Ai::PageGeneratorService client error #{status}: #{e.message}")
    Result.new(error: "Failed to generate page. Please try again.")
  rescue => e
    Rails.logger.error("Ai::PageGeneratorService error: #{e.class}: #{e.message}")
    Result.new(error: "Failed to generate page. Please try again.")
  end

  private

  def build_messages
    products_context = @seller.products.alive.limit(50).map do |p|
      "- #{p.name} (#{p.display_price}) [permalink: #{p.unique_permalink}, url: #{p.long_url}]"
    end.join("\n")

    user_message = <<~MSG
      Creator: #{@seller.display_name}

      Available products:
      #{products_context}

      #{existing_html_context}

      User request: #{@prompt}
    MSG

    [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: user_message },
    ]
  end

  def existing_html_context
    if @parent_version
      <<~CTX
        Current page HTML (modify this based on the user's request):
        #{@parent_version.html.truncate(20_000)}
      CTX
    else
      ""
    end
  end

  def openai_client
    @openai_client ||= OpenAI::Client.new(
      access_token: ACCESS_TOKEN,
      uri_base: GATEWAY_URL,
      request_timeout: TIMEOUT_IN_SECONDS,
    )
  end
end
