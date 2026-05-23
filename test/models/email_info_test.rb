# frozen_string_literal: true

require "test_helper"

class EmailInfoTest < ActiveSupport::TestCase
  self.described_class = EmailInfo



  context_ EmailInfo do
  context_ "#unsubscribe_buyer" do
      let(:purchase) { create(:purchase) }

  context_ "for a Purchase" do
        let(:email_info) { create(:customer_email_info, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD, purchase: purchase) }

  test "calls unsubscribe_buyer on purchase" do
          allow_any_instance_of(Purchase).to receive(:unsubscribe_buyer).and_return("unsubscribed!")
          expect(email_info.unsubscribe_buyer).to eq("unsubscribed!")
        end
      end

  context_ "for a Charge" do
        let(:charge) { create(:charge, purchases: [purchase]) }
        let(:email_info) do
          create(
            :customer_email_info,
            purchase_id: nil,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
            email_info_charge_attributes: { charge_id: charge.id }
          )
        end

        before do
          charge.order.purchases << purchase
        end

  test "calls unsubscribe_buyer on order" do
          allow_any_instance_of(Order).to receive(:unsubscribe_buyer).and_return("unsubscribed!")
          expect(email_info.unsubscribe_buyer).to eq("unsubscribed!")
        end
      end
    end
  end
end
