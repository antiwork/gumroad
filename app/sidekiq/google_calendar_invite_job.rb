# frozen_string_literal: true

class GoogleCalendarInviteJob
  include Sidekiq::Job

  def perform(call_id)
    call = Call.find(call_id)
    return if call.google_calendar_event_id.present?

    link = call.link
    buyer = call.purchase.purchaser&.email || call.purchase.email

    google_calendar_integration = link.get_integration(Integration.type_for(Integration::GOOGLE_CALENDAR))
    return unless google_calendar_integration

    gcal_api = GoogleCalendarApi.new

    event = {
      summary: "Call with #{buyer}",
      description: "Scheduled call for #{link.name}",
      start: {
        dateTime: call.start_time.iso8601,
      },
      end: {
        dateTime: call.end_time.iso8601,
      },
      attendees: [
        { email: buyer }
      ],
      reminders: {
        useDefault: true
      }
    }

    response = insert_or_refresh_and_insert_event(gcal_api, google_calendar_integration, event)

    if response.success?
      call.update(google_calendar_event_id: response.parsed_response["id"])
    else
      Rails.logger.error "Failed to insert Google Calendar event: #{response.parsed_response}"
    end
  end

  private
    def insert_or_refresh_and_insert_event(gcal_api, integration, event)
      response = insert_event(gcal_api, integration, event)
      return response if response.success?

      if response.code == 401
        new_access_token = refresh_token(gcal_api, integration)
        return insert_event(gcal_api, integration, event, new_access_token) if new_access_token
      end

      response
    end

    def insert_event(gcal_api, integration, event, access_token = nil)
      access_token ||= integration.access_token
      response = gcal_api.insert_event(integration.calendar_id, event, access_token:)
      response
    end

    def refresh_token(gcal_api, integration)
      refresh_response = gcal_api.refresh_token(integration.refresh_token)
      if refresh_response.success?
        new_access_token = refresh_response.parsed_response["access_token"]
        integration.update(access_token: new_access_token)
        new_access_token
      else
        Rails.logger.error "Failed to refresh Google Calendar token: #{refresh_response.parsed_response}"
        nil
      end
    end
end
