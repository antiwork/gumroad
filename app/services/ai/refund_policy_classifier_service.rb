# frozen_string_literal: true

class Ai::RefundPolicyClassifierService
  class MaxRetriesExceededError < StandardError; end

  REFUND_POLICY_CLASSIFICATION_TIMEOUT_IN_SECONDS = 30

  def classify(prompt:)
    result, _duration = with_retries(operation: "Classify refund policy", context: prompt.truncate(50)) do
      openai_client.chat(
        parameters: {
          messages: [{ role: "user", content: prompt }],
          model: "gpt-4o-mini",
          temperature: 0.0,
          max_tokens: 10
        }
      )
    end
    result
  end

  private
    def openai_client
      OpenAI::Client.new(request_timeout: REFUND_POLICY_CLASSIFICATION_TIMEOUT_IN_SECONDS)
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
