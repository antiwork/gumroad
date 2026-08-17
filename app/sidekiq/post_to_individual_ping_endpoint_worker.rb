# frozen_string_literal: true

class PostToIndividualPingEndpointWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical

  ERROR_CODES_TO_RETRY = [499, 500, 502, 503, 504].freeze
  BACKOFF_STRATEGY = [60, 180, 600, 3600].freeze
  REQUEST_TIMEOUT_SECONDS = 5
  MAX_REDIRECTS = 3

  def perform(post_url, params, content_type = Mime[:url_encoded_form].to_s, user_id = nil)
    retry_count = params["retry_count"] || 0

    body = if content_type == Mime[:json]
      params.to_json
    elsif content_type == Mime[:url_encoded_form]
      params.deep_transform_keys { encode_brackets(_1) }
    else
      params
    end
    # HTTParty's serializer keeps the form-encoded wire format identical to what it used to send.
    body = HTTParty::HashConversions.to_params(body) if body.is_a?(Hash)

    options = {
      body:,
      headers: { "Content-Type" => content_type },
      # Endpoints commonly answer with trailing-slash/https normalization redirects (gp#2058:
      # refusing them silently dropped sale pings), so follow a few — SsrfFilter re-validates
      # every hop's resolved IPs, and the same POST body is re-sent on each hop. Past the limit
      # we want the 3xx back (instead of a raise) so it can be logged.
      max_redirects: MAX_REDIRECTS,
      allow_unfollowed_redirects: true,
      http_options: { open_timeout: REQUEST_TIMEOUT_SECONDS, read_timeout: REQUEST_TIMEOUT_SECONDS }
    }
    uri = URI.parse(post_url)
    if uri.userinfo.present?
      # Net::HTTP doesn't send URL userinfo as basic auth on its own; HTTParty did.
      user, pass = uri.userinfo.split(":", 2)
      options[:request_proc] = ->(request) { request.basic_auth(user, pass) }
    end

    # SsrfFilter validates the resolved IPs and connects to the exact IP it validated,
    # closing the DNS-rebinding TOCTOU a separate validate-then-connect leaves open.
    response = SsrfFilter.post(post_url, options)

    if response.is_a?(Net::HTTPRedirection)
      Rails.logger.info("PostToIndividualPingEndpointWorker exhausted redirect limit response=#{response.code} content_type=#{content_type} user_id=#{user_id}")
      return
    end

    Rails.logger.info("PostToIndividualPingEndpointWorker response=#{response.code} content_type=#{content_type} user_id=#{user_id}")

    unless response.is_a?(Net::HTTPSuccess)
      if ERROR_CODES_TO_RETRY.include?(response.code.to_i) && retry_count < (BACKOFF_STRATEGY.length - 1)
        PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, post_url, params.merge("retry_count" => retry_count + 1), content_type, user_id)
      end
    end

  # An empty lookup is usually a DNS blip, not a verdict on the URL (gp#2155), so retry it on the
  # same backoff as a 5xx. Must precede the blanket rescue: SsrfFilter::Error is in
  # INTERNET_EXCEPTIONS, which is also why PrivateIPAddress still falls through to a plain drop.
  rescue SsrfFilter::UnresolvedHostname => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error content_type=#{content_type} user_id=#{user_id} retry_count=#{retry_count}")
    if retry_count < (BACKOFF_STRATEGY.length - 1)
      PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, post_url, params.merge("retry_count" => retry_count + 1), content_type, user_id)
    end
  # rescue clause to handle connection errors. Without this, the job
  # would fail if the user inputted post_url is invalid.
  rescue *INTERNET_EXCEPTIONS => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error content_type=#{content_type} user_id=#{user_id}")
  end

  private
    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
