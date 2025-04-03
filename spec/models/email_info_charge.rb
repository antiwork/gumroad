# frozen_string_literal: true

require "spec_helper"

describe EmailInfoCharge do
  describe "validations" do
    it "requires charge_id and email_info_id" do
      email_info_charge = EmailInfoCharge.new
      expect(email_info_charge).to_not be_valid
      expect(email_info_charge.errors.full_messages).to include("Charge must exist")
      expect(email_info_charge.errors.full_messages).to include("Email info must exist")
    end
  end
end
