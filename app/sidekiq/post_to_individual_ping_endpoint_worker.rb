# frozen_string_literal: true

class PostToIndividualPingEndpointWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical

  ERROR_CODES_TO_RETRY = [499, 500, 502, 503, 504].freeze
  BACKOFF_STRATEGY = [60, 180, 600, 3600].freeze

  def perform(post_url, params, content_type = Mime[:url_encoded_form].to_s, user_id = nil)
    return unless ResourceSubscription.valid_post_url?(post_url, require_resolvable: true)

    retry_count = params["retry_count"] || 0

    body = if content_type == Mime[:json]
      params.to_json
    elsif content_type == Mime[:url_encoded_form]
      params.deep_transform_keys { encode_brackets(_1) }
    else
      params
    end

    # valid_post_url? above only proves the hostname resolved to a public address at the time it
    # was checked; a DNS-rebinding host can return a different (private) address by the time we
    # connect. SsrfFilter re-resolves right before opening the socket and pins Net::HTTP to that
    # exact validated address, closing the gap between the check and the connection.
    response = SsrfFilter.post(
      post_url,
      body: body.is_a?(String) ? body : HTTParty::HashConversions.to_params(body),
      headers: { "Content-Type" => content_type },
      max_redirects: 0,
      allow_unfollowed_redirects: true,
      http_options: { open_timeout: 5, read_timeout: 5 }
    )
    response_code = response.code.to_i

    Rails.logger.info("PostToIndividualPingEndpointWorker response=#{response_code} content_type=#{content_type} user_id=#{user_id}")

    unless response.is_a?(Net::HTTPSuccess)
      if ERROR_CODES_TO_RETRY.include?(response_code) && retry_count < (BACKOFF_STRATEGY.length - 1)
        PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, post_url, params.merge("retry_count" => retry_count + 1), content_type, user_id)
      end
    end

  # rescue clause to handle connection errors. Without this, the job would fail if the user
  # inputted post_url is invalid. SsrfFilter::Error covers delivery-time rejections (e.g. every
  # resolved address turning out to be private).
  rescue *INTERNET_EXCEPTIONS, SsrfFilter::Error => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error content_type=#{content_type} user_id=#{user_id}")
  end

  private
    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
