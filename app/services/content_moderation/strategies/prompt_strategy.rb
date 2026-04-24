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
    You are a content moderator. Evaluate the following content for spam policy violations.

    Policy:
    - ALLOW normal product descriptions, marketing copy, solicitations, and promotional content
    - ALLOW repetitive formatting that serves a purpose (e.g., product variants)
    - FLAG massive unsolicited bulk messaging or copy-paste content
    - FLAG extremely repetitive content with no substantive variation
    - FLAG obvious artificial engagement manipulation (fake reviews, bot-generated content)
    - FLAG content that is clearly auto-generated nonsense or keyword stuffing

    Be permissive for borderline cases. Only flag content that is clearly spam.
  RULES

  MODEL = "gpt-4o-mini"
  JUDGE_MODEL = "gpt-4o-mini"

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

    def build_messages(rules, skip_images: false)
      user_content = []
      user_content << { type: "text", text: "Content to evaluate:\n\n#{@text.presence || '[no text provided]'}" }

      if !skip_images && @image_urls.present?
        @image_urls.sample(3).each do |url|
          user_content << { type: "image_url", image_url: { url: url } }
        end
      end

      [
        { role: "system", content: "#{rules}\n\nRespond with JSON: {\"flagged\": true/false, \"reasoning\": \"explanation\"}" },
        { role: "user", content: user_content },
      ]
    end
end
