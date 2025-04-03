# frozen_string_literal: true

require "spec_helper"

describe DeleteOldUnusedEventsWorker do
  describe "#perform" do
    it "deletes targeted rows" do
      stub_const("#{described_class}::DELETION_BATCH_SIZE", 1)

      create(:event, event_name: "i_want_this", created_at: 2.months.ago - 1.day)
      permitted = create(:purchase_event, created_at: 2.months.ago - 1.day)
      kept_because_recent = create(:event, event_name: "i_want_this", created_at: 1.month.ago)

      described_class.new.perform
      expect(Event.all).to match_array([permitted, kept_because_recent])

      described_class.new.perform(from: 1.year.ago, to: Time.current)
      expect(Event.all).to match_array([permitted])
    end
  end
end
