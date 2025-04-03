# frozen_string_literal: true

require "spec_helper"

describe GoogleCalendarInviteJob do
  describe "#perform" do
    let(:call) { create(:call) }
    let(:link) { call.link }
    let(:buyer_email) { "buyer@example.com" }
    let(:google_calendar_integration) { create(:google_calendar_integration) }
    let(:gcal_api) { instance_double(GoogleCalendarApi) }

    before do
      allow(Call).to receive(:find).with(call.id).and_return(call)
      allow(call).to receive(:link).and_return(link)
      allow(call.purchase).to receive(:purchaser).and_return(double(email: buyer_email))
      allow(link).to receive(:get_integration).and_return(google_calendar_integration)
      allow(GoogleCalendarApi).to receive(:new).and_return(gcal_api)
    end

    context "when the call already has a Google Calendar event ID" do
      before do
        allow(call).to receive(:google_calendar_event_id).and_return("existing_event_id")
      end

      it "does nothing" do
        expect(gcal_api).not_to receive(:insert_event)
        described_class.new.perform(call.id)
      end
    end

    context "when the call does not have a Google Calendar event ID" do
      before do
        allow(call).to receive(:google_calendar_event_id).and_return(nil)
      end

      context "when the Google Calendar integration is not present" do
        before do
          allow(link).to receive(:get_integration).and_return(nil)
        end

        it "does nothing" do
          expect(gcal_api).not_to receive(:insert_event)
          described_class.new.perform(call.id)
        end
      end

      context "when the Google Calendar integration is present" do
        let(:event) do
          {
            summary: "Call with #{buyer_email}",
            description: "Scheduled call for #{link.name}",
            start: { dateTime: call.start_time.iso8601 },
            end: { dateTime: call.end_time.iso8601 },
            attendees: [{ email: buyer_email }],
            reminders: { useDefault: true }
          }
        end

        context "when the API call is successful" do
          let(:api_response) { double(success?: true, parsed_response: { "id" => "new_event_id" }) }

          before do
            allow(gcal_api).to receive(:insert_event).and_return(api_response)
          end

          it "creates a Google Calendar event and updates the call" do
            expect(gcal_api).to receive(:insert_event).with(google_calendar_integration.calendar_id, event, access_token: google_calendar_integration.access_token)
            expect(call).to receive(:update).with(google_calendar_event_id: "new_event_id")
            described_class.new.perform(call.id)
          end
        end

        context "when the API call fails with a 401 error" do
          let(:failed_response) { double(success?: false, code: 401) }
          let(:refresh_response) { double(success?: true, parsed_response: { "access_token" => "new_access_token" }) }
          let(:success_response) { double(success?: true, parsed_response: { "id" => "new_event_id" }) }

          before do
            allow(gcal_api).to receive(:insert_event).and_return(failed_response, success_response)
            allow(gcal_api).to receive(:refresh_token).and_return(refresh_response)
          end

          it "refreshes the token and retries inserting the event" do
            expect(gcal_api).to receive(:refresh_token).with(google_calendar_integration.refresh_token)
            expect(google_calendar_integration).to receive(:update).with(access_token: "new_access_token")
            expect(gcal_api).to receive(:insert_event).with(google_calendar_integration.calendar_id, event, access_token: "new_access_token")
            expect(call).to receive(:update).with(google_calendar_event_id: "new_event_id")
            described_class.new.perform(call.id)
          end
        end

        context "when the API call fails with a non-401 error" do
          let(:failed_response) { double(success?: false, code: 500, parsed_response: "Internal Server Error") }

          before do
            allow(gcal_api).to receive(:insert_event).and_return(failed_response)
          end

          it "logs the error" do
            expect(Rails.logger).to receive(:error).with("Failed to insert Google Calendar event: Internal Server Error")
            described_class.new.perform(call.id)
          end
        end
      end
    end
  end
end
