# frozen_string_literal: true

require "test_helper"

class UpdateInstallmentEventsCountCacheWorkerTest < ActiveSupport::TestCase
  self.described_class = UpdateInstallmentEventsCountCacheWorker



  context_ UpdateInstallmentEventsCountCacheWorker do
  context_ "#perform" do
  test "calculates and caches the correct installment_events count" do
        installment = create(:installment)
        create_list(:installment_event, 2, installment:)
        UpdateInstallmentEventsCountCacheWorker.new.perform(installment.id)
        installment.reload
        expect(installment.installment_events_count).to eq(2)
      end
    end
  end
end
