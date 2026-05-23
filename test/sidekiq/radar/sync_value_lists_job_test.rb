# frozen_string_literal: true

require "test_helper"

class RadarSyncValueListsJobTest < ActiveSupport::TestCase
  self.described_class = Radar::SyncValueListsJob



  context_ Radar::SyncValueListsJob do
  test "is enqueued in the low queue" do
      expect(described_class.sidekiq_options["queue"]).to eq("low")
    end

  context_ "#perform" do
  test "calls sync_blocked_emails and sync_blocked_cards on the service" do
        service = instance_double(Radar::ValueListSyncService)
        allow(Radar::ValueListSyncService).to receive(:new).and_return(service)

        expect(service).to receive(:sync_blocked_emails)
        expect(service).to receive(:sync_blocked_cards)

        described_class.new.perform
      end
    end
  end
end
