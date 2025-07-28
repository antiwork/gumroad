# frozen_string_literal: true

class PostToIndividualPingEndpointWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical

  ERROR_CODES_TO_RETRY = [499, 500, 502, 503, 504].freeze
  BACKOFF_STRATEGY = [60, 180, 600, 3600].freeze
  NOTIFICATION_THROTTLE_PERIOD = 1.week.freeze

  def perform(post_url, params, content_type = Mime[:url_encoded_form].to_s, user_id = nil)
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
        PostToIndividualPingEndpointWorker.perform_in(BACKOFF_STRATEGY[retry_count].seconds, post_url, params.merge("retry_count" => retry_count + 1), content_type, user_id)
      else
        send_ping_failure_notification(post_url, response.code, user_id)
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

    def send_ping_failure_notification(post_url, response_code, user_id = nil)
      return unless Feature.active?(:alert_on_ping_endpoint_failure)
      return unless user_id.present?

      seller = User.find_by(id: user_id)
      return unless seller

      # Only send notifications for seller.notification_endpoint failures, not resource subscriptions
      # TODO: We can configure notifications for resource subscription URLs too when we have a UI to edit/delete resource subscription URLs
      return unless post_url == seller.notification_endpoint

      if seller.last_ping_failure_notification_at.present?
        last_notification = Time.zone.parse(seller.last_ping_failure_notification_at)
        return if last_notification >= NOTIFICATION_THROTTLE_PERIOD.ago
      end

      ContactingCreatorMailer.ping_endpoint_failure(seller.id, post_url, response_code).deliver_later(queue: "critical")

      seller.last_ping_failure_notification_at = Time.current.to_s
      seller.save!
    end
end
