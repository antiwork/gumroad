# frozen_string_literal: true

require "test_helper"

class BlackRecurringServiceTest < ActiveSupport::TestCase
  self.described_class = BlackRecurringService



  context_ BlackRecurringService do
  context_ "state transitions" do
      before do
        @black_recurring_service = create(:black_recurring_service, state: "inactive")

        @mail_double = double
        allow(@mail_double).to receive(:deliver_later)
      end

  test "transitions to active" do
        @black_recurring_service.mark_active!
        expect(@black_recurring_service.reload.state).to eq("active")
      end
    end
  end
end
