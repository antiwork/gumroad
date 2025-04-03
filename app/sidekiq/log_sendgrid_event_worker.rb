# frozen_string_literal: true

class LogSendgridEventWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  def perform(params)
    events = params["_json"]
    # Handling potential SendGrid weirdness where sometimes it might not give us an array.
    events = [events] unless events.is_a?(Array)

    events.each do |event|
      event_type = event["event"]
      next unless %w[open click].include?(event_type)

      timestamp = Time.zone.at(event["timestamp"])

      case event_type
      when "open"
        EmailEvent.log_open_event(event["email"], timestamp)
      when "click"
        EmailEvent.log_click_event(event["email"], timestamp)
      end
    end
  end
end
