# frozen_string_literal: true

require "test_helper"

class PurchaseMarkSuccessfulServiceTest < ActiveSupport::TestCase
  self.described_class = Purchase::MarkSuccessfulService

  # frozen_string_literal: false

  context_ Purchase::MarkSuccessfulService do
  context_ "#handle_purchase_success" do
  test "calls save_gumroad_day_timezone on seller if purchase is neither free nor a test purchase" do
        expect_any_instance_of(User).to receive(:save_gumroad_day_timezone).and_call_original

        Purchase::MarkSuccessfulService.new(create(:purchase, purchase_state: "in_progress")).perform
      end
    end
  end
end
