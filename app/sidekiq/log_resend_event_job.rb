# frozen_string_literal: true

class LogResendEventJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :mongo

  def perform(event_json)
    resend_event_info = ResendEventInfo.new(event_json)
    return if resend_event_info.invalid?
    return unless resend_event_info.type.in?([ResendEventInfo::EVENT_OPENED, ResendEventInfo::EVENT_CLICKED])

    case resend_event_info.type
    when ResendEventInfo::EVENT_OPENED
      EmailEvent.log_open_event(resend_event_info.email, resend_event_info.created_at)
    when ResendEventInfo::EVENT_CLICKED
      EmailEvent.log_click_event(resend_event_info.email, resend_event_info.created_at)
    end
  end
end
