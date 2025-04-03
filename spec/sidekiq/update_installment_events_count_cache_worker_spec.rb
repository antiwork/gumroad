# frozen_string_literal: true

require "spec_helper"

describe UpdateInstallmentEventsCountCacheWorker do
  describe "#perform" do
    it "calculates and caches the correct installment_events count" do
      installment = create(:installment)
      create_list(:installment_event, 2, installment:)
      UpdateInstallmentEventsCountCacheWorker.new.perform(installment.id)
      installment.reload
      expect(installment.installment_events_count).to eq(2)
    end
  end
end
