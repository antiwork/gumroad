# frozen_string_literal: true

class PostToIndividualPingEndpointWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical

  ERROR_CODES_TO_RETRY = [499, 500, 502, 503, 504].freeze
  BACKOFF_STRATEGY = [60, 180, 600, 3600].freeze
  REQUEST_TIMEOUT_SECONDS = 5
  MAX_REDIRECTS = 3
  # Transient connect/read failures. Permanent URL verdicts (PrivateIP, InvalidUriScheme,
  # InvalidURIError) stay in the INTERNET_EXCEPTIONS drop path below.
  RETRYABLE_EXCEPTIONS = [
    SsrfFilter::UnresolvedHostname,
    Timeout::Error,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::ENETUNREACH,
    Errno::EHOSTUNREACH,
    Errno::EADDRNOTAVAIL,
    SocketError,
    EOFError,
    OpenSSL::SSL::SSLError,
    Faraday::ConnectionFailed,
    HTTP::ConnectionError,
    HTTP::TimeoutError
  ].freeze

  # `ping` says what the POST is about so the attempt can be recorded for the seller and for
  # support: { purchase_id:, subscription_id:, resource_name: }. Nil — no record — for jobs
  # enqueued before this argument existed.
  def perform(post_url, params, content_type = Mime[:url_encoded_form].to_s, user_id = nil, ping = nil)
    retry_count = params["retry_count"] || 0
    ping = ping.stringify_keys if ping.is_a?(Hash)

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
      record_delivery(post_url:, user_id:, ping:, retry_count:, response_code: response.code)
      return
    end

    Rails.logger.info("PostToIndividualPingEndpointWorker response=#{response.code} content_type=#{content_type} user_id=#{user_id}")
    record_delivery(post_url:, user_id:, ping:, retry_count:, response_code: response.code, succeeded: response.is_a?(Net::HTTPSuccess))

    unless response.is_a?(Net::HTTPSuccess)
      enqueue_retry(post_url, params, content_type, user_id, retry_count, ping) if ERROR_CODES_TO_RETRY.include?(response.code.to_i)
    end

  # Must precede the blanket INTERNET_EXCEPTIONS rescue: SsrfFilter::Error is in that
  # list, so UnresolvedHostname would otherwise drop, and PrivateIPAddress must keep
  # falling through to a plain drop.
  rescue *RETRYABLE_EXCEPTIONS => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error content_type=#{content_type} user_id=#{user_id} retry_count=#{retry_count}")
    record_delivery(post_url:, user_id:, ping:, retry_count:, error_class: e.class.name)
    enqueue_retry(post_url, params, content_type, user_id, retry_count, ping)
  # Permanent URL / connect verdicts (private IP, bad scheme, invalid URI).
  rescue *INTERNET_EXCEPTIONS => e
    Rails.logger.info("[#{e.class}] PostToIndividualPingEndpointWorker error content_type=#{content_type} user_id=#{user_id}")
    record_delivery(post_url:, user_id:, ping:, retry_count:, error_class: e.class.name)
  end

  private
    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end

    # Best-effort: the ping is the job's real work, so a failed write here is logged and dropped
    # rather than raised inside a :critical queue. A missing row leaves that ping unrecorded,
    # which is where every ping stood before this table existed.
    def record_delivery(post_url:, user_id:, ping:, retry_count:, response_code: nil, error_class: nil, succeeded: false)
      return if user_id.blank? || !ping.is_a?(Hash)

      PingDelivery.create!(
        user_id:,
        purchase_id: ping["purchase_id"],
        subscription_id: ping["subscription_id"],
        resource_name: ping["resource_name"].presence || ResourceSubscription::SALE_RESOURCE_NAME,
        post_url:,
        attempt: retry_count.to_i + 1,
        response_code:,
        error_class:,
        succeeded:
      )
    rescue => e
      Rails.logger.warn("PingDelivery record failed for user #{user_id}: #{e.class}: #{e.message}")
    end

    def enqueue_retry(post_url, params, content_type, user_id, retry_count, ping = nil)
      return unless retry_count < (BACKOFF_STRATEGY.length - 1)

      # Omits the ping context argument entirely when there is none, so a retry stays byte-identical
      # to the jobs this worker enqueued before the argument existed.
      args = [post_url, params.merge("retry_count" => retry_count + 1), content_type, user_id]
      args << ping if ping.present?

      PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, *args)
    end
end
