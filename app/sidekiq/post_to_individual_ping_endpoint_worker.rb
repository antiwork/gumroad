# frozen_string_literal: true

class PostToIndividualPingEndpointWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical

  ERROR_CODES_TO_RETRY = [499, 500, 502, 503, 504].freeze
  BACKOFF_STRATEGY = [60, 180, 600, 3600].freeze

  def perform(post_url, params, content_type = Mime[:url_encoded_form].to_s)
    retry_count = params["retry_count"] || 0

    body = if content_type == Mime[:json]
      params.to_json
    elsif content_type == Mime[:url_encoded_form]
      params.deep_transform_keys { encode_brackets(_1) }
    else
      params
    end

    response = HTTParty.post(post_url, body:, timeout: 5, headers: { "Content-Type" => content_type })

    Rails.logger.info("PostToIndividualPingEndpointWorker response=#{response.code} url=#{post_url} content_type=#{content_type} params=#{params.inspect}")

    unless response.success?
      if ERROR_CODES_TO_RETRY.include?(response.code) && retry_count < (BACKOFF_STRATEGY.length - 1)
        PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, post_url, params.merge("retry_count" => retry_count + 1), content_type)
      end
    end

  # rescue clause to handle connection errors. Without this, the job
  # would fail if the user inputted post_url is invalid.
  rescue *INTERNET_EXCEPTIONS => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error=\"#{e.message}\" url=#{post_url} content_type=#{content_type} params=#{params.inspect}")
  end

  private
    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
