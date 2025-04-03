# frozen_string_literal: true

class HandleResendEventJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(event_json)
    resend_event_info = ResendEventInfo.new(event_json)
    return if resend_event_info.invalid?

    HandleEmailEventInfo.perform(resend_event_info)
  end
end
