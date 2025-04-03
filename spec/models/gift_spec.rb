# frozen_string_literal: true

require "spec_helper"

describe Gift do
  describe "saving" do
    it "removes leading/trailing spaces in emails" do
      gift = create(:gift, gifter_email: " abc@def.com ", giftee_email: " foo@bar.com ")
      expect(gift.gifter_email).to eq("abc@def.com")
      expect(gift.giftee_email).to eq("foo@bar.com")
    end

    it "errors if an email is invalid" do
      gift = build(:gift, gifter_email: "gifter@gumroad.com", giftee_email: "foo")
      expect(gift).not_to be_valid
      expect(gift.errors.full_messages).to include "Giftee email is invalid"

      gift = build(:gift, gifter_email: "foo", giftee_email: "giftee@gumroad.com")
      expect(gift).not_to be_valid
      expect(gift.errors.full_messages).to include "Gifter email is invalid"
    end
  end
end
