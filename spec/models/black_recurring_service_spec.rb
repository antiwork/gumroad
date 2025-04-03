# frozen_string_literal: true

require "spec_helper"

describe BlackRecurringService do
  describe "state transitions" do
    before do
      @black_recurring_service = create(:black_recurring_service, state: "inactive")
      allow_any_instance_of(User).to receive(:tier_pricing_enabled?).and_return(false)

      @mail_double = double
      allow(@mail_double).to receive(:deliver_later)
    end

    it "transitions to active" do
      @black_recurring_service.mark_active!
      expect(@black_recurring_service.reload.state).to eq("active")
    end
  end
end
