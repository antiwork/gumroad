# frozen_string_literal: true

require "test_helper"

class InstallmentEventTest < ActiveSupport::TestCase
  self.described_class = InstallmentEvent



  context_ InstallmentEvent do
  context_ "Creation" do
  test "queues update of Installment's installment_events_count" do
        installment_event = create(:installment_event)
        expect(UpdateInstallmentEventsCountCacheWorker).to have_enqueued_sidekiq_job(installment_event.installment_id)
      end
    end
  end
end
