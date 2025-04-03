# frozen_string_literal: true

class HandleSendgridEventJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(params)
    events = params["_json"]
    events = [events] unless events.is_a?(Array) # Handling potential SendGrid weirdness where sometimes it might not give us an array.

    events.each do |event|
      sendgrid_event_info = SendgridEventInfo.new(event)
      next if sendgrid_event_info.invalid?

      HandleEmailEventInfo.perform(sendgrid_event_info)
    end
  end
end
