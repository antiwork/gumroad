# frozen_string_literal: true
class Ai::ProductAdvisorService
  class MaxRetriesExceededError < StandardError; end
  PRODUCT_ADVISOR_TIMEOUT_IN_SECONDS = 30

  def initialize(product:)
    @product = product
  end

  def analyze
    result, duration = with_retries(operation: "Analyze product", context: product.name) do
      response = openai_client.chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: product_data_json }
          ],
          response_format: { type: "json_object" },
          temperature: 0.5
        }
      )
      content = response.dig("choices", 0, "message", "content")
      raise "No content returned from product advisor" if content.blank?
      JSON.parse(content, symbolize_names: true)
    end
    result[:duration_in_seconds] = duration
    result
  end

  private
    attr_reader :product

    def openai_client
      OpenAI::Client.new(request_timeout: PRODUCT_ADVISOR_TIMEOUT_IN_SECONDS)
    end

    def product_data_json
      {
        name: product.name,
        description: product.description,
        price_cents: product.default_price_cents,
        customizable_price: product.customizable_price?,
        cover_image_url: product.thumbnail_or_cover_url,
        custom_fields: product.custom_fields.map { |f| { name: f.name, type: f.type } },
        permalink: product.unique_permalink
      }.to_json
    end

    def system_prompt
      <<~PROMPT
        You are a Gumroad product advisor. Analyze the product and score it 0-10 on each dimension.
        Dimensions: description_quality, cover_image, pricing_strategy, discoverability, social_proof.
        Return JSON only: { "overall_score": 0-100, "dimensions": [{ "name": "...", "score": 0-10, "suggestion": "..." }], "top_3_improvements": ["..."] }
        Suggestions must be specific, actionable, and reference actual product data. Order dimensions by score ascending.
      PROMPT
    end

    def with_retries(operation:, context: nil, max_tries: 2, delay: 1)
      tries = 0
      start_time = Time.now
      begin
        tries += 1
        result = yield
        duration = Time.now - start_time
        Rails.logger.info("Successfully completed '#{operation}' in #{duration.round(2)}s")
        [result, duration]
      rescue => e
        duration = Time.now - start_time
        if tries < max_tries
          Rails.logger.info("Failed to perform '#{operation}', attempt #{tries}/#{max_tries}: #{context}: #{e.message}")
          sleep(delay)
          retry
        else
          Rails.logger.error("Failed to perform '#{operation}' after #{max_tries} attempts in #{duration.round(2)}s: #{context}: #{e.message}")
          raise MaxRetriesExceededError, "Failed to perform '#{operation}' after #{max_tries} attempts: #{e.message}"
        end
      end
    end
end
