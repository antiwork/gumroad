# frozen_string_literal: true

class ContentModeration::Strategies::PromptStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10

  ADULT_CONTENT_RULES = <<~RULES
    You are a content moderator. Evaluate the following content for adult/sexual content policy violations.

    Policy:
    - ALLOW artistic nudity, educational anatomy, breastfeeding, and non-sexual body imagery
    - FLAG sexual or fetish-driven nude images, overtly sexual images with exaggerated body parts
    - FLAG content that is primarily pornographic in nature
    - FLAG content depicting or promoting sexual exploitation

    Be permissive for borderline cases. Only flag content that clearly violates the policy.
  RULES

  SPAM_RULES = <<~RULES
    You are a content moderator for Gumroad, a marketplace where creators sell digital
    products, courses, bundles, licenses, AND ongoing email subscriptions, newsletters,
    serialized fiction, comics, podcasts, and other recurring content. Evaluate the
    following content for spam policy violations.

    Default: do not flag. Only flag content that is unmistakably spam. When in doubt,
    treat the content as compliant.

    The content you receive comes from one of three surfaces:
    1. A product listing — description, marketing copy, feature lists, license terms.
    2. A post or email sent to existing subscribers — newsletters, serial fiction,
       daily comics, dialogue-driven storylines, journal entries, or any installment
       of an ongoing subscription where the post itself IS the product the
       subscriber paid for. These posts often contain no marketing copy and no
       reference to a product, because they ARE the product.
    3. An affiliate recruitment email — the creator is inviting their audience to
       join the product's affiliate program. These emails will explicitly mention
       commission rates, earnings, payouts, referral links, and the creator's
       affiliate program. This is a legitimate, expected use of Gumroad's
       affiliate feature, not MLM spam.

    ALLOW (these are normal Gumroad content, never flag them):
    - Product descriptions, marketing copy, and promotional language
    - Bundles that repeat the base product name across items
    - Multi-tier products that reuse feature descriptions across tiers
      (e.g., Basic / Pro / Enterprise plans with overlapping feature lists)
    - Technical, educational, or domain-specific content that repeats
      terminology by necessity
    - License terms, pricing tables, and feature comparisons that share structure
    - Repeated product, brand, or feature names across sections of one listing
    - Identical sentences appearing several times in succession — these are almost
      always image alt-text or captions extracted from a product image gallery
      where each image carries the same caption, and they describe the product
      itself. Treat as compliant even when the image context isn't visible.
    - Serialized creative content: comic-strip dialogue, fiction installments,
      poetry, song lyrics, character interactions, scene narration, recurring
      story beats. A single installment from a long-running series will often
      look out-of-context, surreal, or "nonsensical" on its own — that is
      normal for serial fiction and comics, not spam.
    - Conversational dialogue between named or fictional characters, even when
      short, absurd, humorous, or non-sequitur. If a human could plausibly have
      written it as part of a story, comic, or newsletter, treat as compliant.
    - Newsletter, journal, or daily-update content with no product description
      and no marketing copy.
    - Affiliate recruitment emails: phrases like "earn a commission", "earn extra
      income", "10% commission", "join my affiliate program", "share my product
      and get paid", "your affiliate link", "monthly payouts", and similar
      commission/earnings language are normal recruitment copy. Treat as
      compliant unless paired with classic MLM red flags (multi-level downline
      structures, guaranteed returns, "no selling required", recruitment over
      product sales).

    Important: this content is extracted from HTML and stripped of structure. You
    will not see images, headings, or layout. For posts/emails the visual content
    (cartoon panels, screenshots, illustrations) is often the primary payload and
    the text alone is dialogue or captions. Repetition that looks suspicious in
    plain text is often legitimate in the rendered page (alt text on a gallery,
    table cells, list items). Do not flag based on plain-text repetition alone.

    Repetition alone is NOT spam. Lack of a product description is NOT spam.
    Coherent prose that doesn't mention a product is NOT spam.

    Flag only when:
    - Content is clearly machine-generated nonsense or word salad — random tokens,
      gibberish character sequences, not coherent prose or dialogue
    - Repeated phrases are unrelated to a product AND are obviously promotional
      (slogans for unrelated brands, off-topic SEO keywords, link farms)
    - Obvious keyword stuffing of unrelated terms
    - Fake reviews, artificial engagement, or bot-generated text
    - Aggressive call-to-action spam ("BUY NOW BUY NOW BUY NOW", "click here click
      here click here") with no other information

    If the content describes a real product, OR reads as a coherent installment of
    creative or editorial work — even one that is repetitive, surreal, or makes no
    reference to a product — it is not spam.
  RULES

  MODEL = "gpt-4o-mini"
  JUDGE_MODEL = "gpt-4o-mini"
  SUPPORTED_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze

  def initialize(text:, image_urls: [])
    @text = text
    @image_urls = image_urls
  end

  def perform
    return Result.new(status: "compliant", reasoning: []) if @text.blank? && @image_urls.empty?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    return Result.new(status: "compliant", reasoning: []) if api_key.blank?

    @client = OpenAI::Client.new(access_token: api_key, request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)

    all_reasoning = []

    [
      { name: "adult_content", rules: ADULT_CONTENT_RULES, skip_images: false },
      { name: "spam", rules: SPAM_RULES, skip_images: true },
    ].each do |preset|
      result = evaluate_preset(preset)
      next if result[:status] == "compliant"

      if passes_uncertainty_check?(result[:reasoning])
        all_reasoning << "#{preset[:name]}: #{result[:reasoning]}"
      end
    end

    if all_reasoning.any?
      Result.new(status: "flagged", reasoning: all_reasoning)
    else
      Result.new(status: "compliant", reasoning: [])
    end
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError, Faraday::ParsingError, Net::ReadTimeout => e
    Rails.logger.warn("ContentModeration::PromptStrategy timeout: #{e.class} - #{e.message}")
    Result.new(status: "compliant", reasoning: [])
  rescue StandardError => e
    Rails.logger.error("ContentModeration::PromptStrategy error: #{e.message}")
    raise
  end

  private
    def evaluate_preset(preset)
      messages = build_messages(preset[:rules], skip_images: preset[:skip_images])

      response = @client.chat(
        parameters: {
          model: MODEL,
          messages: messages,
          response_format: { type: "json_object" },
          temperature: 0.1,
        }
      )

      content = response.dig("choices", 0, "message", "content")
      parsed = JSON.parse(content)

      {
        status: parsed["flagged"] ? "flagged" : "compliant",
        reasoning: parsed["reasoning"].to_s,
      }
    rescue Faraday::BadRequestError => e
      notify_openai_rejection(e, stage: "preset:#{preset[:name]}", images_sent: !preset[:skip_images])
      { status: "compliant", reasoning: "" }
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError, Faraday::ParsingError, Net::ReadTimeout => e
      Rails.logger.warn("ContentModeration::PromptStrategy preset timeout on #{preset[:name]}: #{e.class} - #{e.message}")
      { status: "compliant", reasoning: "" }
    rescue StandardError => e
      Rails.logger.error("ContentModeration::PromptStrategy preset evaluation error: #{e.message}")
      raise
    end

    def passes_uncertainty_check?(reasoning)
      response = @client.chat(
        parameters: {
          model: JUDGE_MODEL,
          messages: [
            {
              role: "system",
              content: "You are a meta-evaluator. Given a content moderation reasoning, determine if the moderator expressed uncertainty or hedging. Respond with JSON: {\"uncertain\": true/false}",
            },
            {
              role: "user",
              content: "Moderation reasoning: #{reasoning}",
            },
          ],
          response_format: { type: "json_object" },
          temperature: 0.0,
        }
      )

      content = response.dig("choices", 0, "message", "content")
      parsed = JSON.parse(content)

      !parsed["uncertain"]
    rescue Faraday::BadRequestError => e
      notify_openai_rejection(e, stage: "uncertainty_check", images_sent: false)
      false
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError, Faraday::ParsingError, Net::ReadTimeout => e
      Rails.logger.warn("ContentModeration::PromptStrategy uncertainty check timeout: #{e.class} - #{e.message}")
      false
    rescue StandardError => e
      Rails.logger.error("ContentModeration::PromptStrategy uncertainty check error: #{e.message}")
      raise
    end

    def notify_openai_rejection(error, stage:, images_sent:)
      body = error.response&.dig(:body)
      error_payload = body.is_a?(Hash) ? body["error"] : nil
      error_message = error_payload.is_a?(Hash) ? error_payload["message"].to_s : body.to_s
      error_code    = error_payload.is_a?(Hash) ? error_payload["code"] : nil
      error_param   = error_payload.is_a?(Hash) ? error_payload["param"] : nil

      Rails.logger.warn(
        "ContentModeration::PromptStrategy OpenAI 400 on #{stage} (code=#{error_code}): #{error_message[0, 500]}"
      )

      ErrorNotifier.notify(
        "ContentModeration::PromptStrategy OpenAI rejected input",
        stage: stage,
        model: MODEL,
        openai_error_code: error_code,
        openai_error_param: error_param,
        openai_error_message: error_message[0, 1000],
        text_length: @text.to_s.length,
        image_url_count: @image_urls.size,
        image_urls_sent: images_sent ? @image_urls.first(20) : [],
      )
    end

    def supported_image_url?(url)
      path = URI.parse(url).path.to_s
      ext = File.extname(path).downcase
      SUPPORTED_IMAGE_EXTENSIONS.include?(ext)
    rescue URI::InvalidURIError
      false
    end

    def build_messages(rules, skip_images: false)
      user_content = []
      user_content << { type: "text", text: "Content to evaluate:\n\n#{@text.presence || '[no text provided]'}" }

      if !skip_images && @image_urls.present?
        supported_urls = @image_urls.select { |url| supported_image_url?(url) }
        if supported_urls.empty? && @image_urls.any?
          Rails.logger.warn(
            "ContentModeration::PromptStrategy filtered out all #{@image_urls.size} image URLs (unsupported formats)"
          )
        end
        supported_urls.sample(3).each do |url|
          user_content << { type: "image_url", image_url: { url: url } }
        end
      end

      [
        { role: "system", content: "#{rules}\n\nRespond with JSON: {\"flagged\": true/false, \"reasoning\": \"explanation\"}" },
        { role: "user", content: user_content },
      ]
    end
end
