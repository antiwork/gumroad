# frozen_string_literal: true

require "spec_helper"

describe ServiceMailer do
  before do
    @user = create(:user)
    @black_recurring_service = create(:black_recurring_service, user: @user)
  end

  describe "service_charge_receipt" do
    it "renders properly" do
      service_charge = create(:service_charge, user: @user, recurring_service: @black_recurring_service)
      mail = ServiceMailer.service_charge_receipt(service_charge.id)
      expect(mail.subject).to eq "Gumroad — Receipt"
      expect(mail.to).to eq [@user.email]
      expect(mail.body).to include "Thanks for continuing to support Gumroad!"
      expect(mail.body).to include "you'll be charged at the same rate."
    end

    it "renders properly with discount code" do
      service_charge = create(:service_charge, discount_code: DiscountCode::INVITE_CREDIT_DISCOUNT_CODE, user: @user, recurring_service: @black_recurring_service)
      mail = ServiceMailer.service_charge_receipt(service_charge.id)
      expect(mail.subject).to eq "Gumroad — Receipt"
      expect(mail.to).to eq [@user.email]
      expect(mail.body).to include "Thanks for continuing to support Gumroad!"
      expect(mail.body).to include "you'll be charged at the same rate."
      expect(mail.body).to include "Credit applied:"
    end
  end
end
