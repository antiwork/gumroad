# frozen_string_literal: true

require "spec_helper"

# A chargeable is anything that can be used to charge a credit card for a purchase, subscription, etc. It should be
# immutable except when the prepare function is called. This protocol is designed to be backed by any other object or
# remote system (i.e. a charge processor) which is why all data is exposed through functions.

shared_examples_for "a chargeable" do
  # charge_processor_id: A string indicating the charge processor
  describe "#charge_processor_id" do
    it "is set" do
      expect(chargeable.charge_processor_id).to be_kind_of(String)
      expect(chargeable.charge_processor_id).to_not be_empty
    end
  end

  # prepare: prepares the chargeable for charging. Other functions may not provide data until prepare is called.
  describe "#prepare" do
    it "returns true" do
      expect(chargeable.prepare!).to be(true)
    end
    it "is callable multiple times" do
      10.times { chargeable.prepare! }
    end
  end

  # fingerprint: A unique fingerprint for the credit card this chargeable will charge.
  describe "#fingerprint" do
    describe "before prepare" do
      it "is safe to call" do
        chargeable.fingerprint
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is set" do
        expect(chargeable.fingerprint).to_not be(nil)
      end
    end
  end

  # last4: The last 4 digits of the credit card the chargeable will charge.
  describe "#last4" do
    describe "before prepare" do
      it "is 4 digits or nil" do
        expect(chargeable.last4).to match(/^[0-9]{4}$/) if chargeable.last4.present?
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }
      it "is 4 digits" do
        expect(chargeable.last4).to match(/^[0-9]{4}$/)
      end
    end
  end

  # number_length: The length of the card number of the credit card the chargeable will charge.
  describe "#number_length" do
    describe "before prepare" do
      it "is numeric length between 13 and 19 or nil" do
        expect(chargeable.number_length).to be_between(13, 19) if chargeable.number_length.present?
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is numeric length between 13 and 19" do
        expect(chargeable.number_length).to be_between(13, 19)
      end
    end
  end

  # expiry_month: The month portion of the expiry date of the credit card the chargeable will charge.
  describe "#expiry_month" do
    describe "before prepare" do
      it "is a valid month as a 1 or 2 digit integer or nil" do
        expect(chargeable.expiry_month).to be_between(1, 12) if chargeable.expiry_month.present?
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is a valid month as a 1 or 2 digit integer" do
        expect(chargeable.expiry_month).to be_between(1, 12)
      end
    end
  end

  # expiry_year: The month portion of the expiry date of the credit card the chargeable will charge.
  describe "#expiry_year" do
    describe "before prepare" do
      it "is a 2 or 4 digit integer" do
        if chargeable.expiry_year.present?
          expect(chargeable.expiry_year).to be_between(10, 9999)
          expect(chargeable.expiry_year).to_not be_between(100, 999)
        end
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is a 2 or 4 digit integer" do
        expect(chargeable.expiry_year).to be_between(10, 9999)
        expect(chargeable.expiry_year).to_not be_between(100, 999)
      end
    end
  end

  # zip_code: The zip code that will be verified against the credit card the chargeable will charge.
  describe "#zip_code" do
    describe "before prepare" do
      it "is safe to call" do
        chargeable.zip_code
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is safe to call" do
        chargeable.zip_code
      end
    end
  end

  # card_type: The card type of the credit card the chargeable will charge.
  describe "#card_type" do
    describe "before prepare" do
      it "is safe to call" do
        chargeable.card_type
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is set" do
        expect(chargeable.card_type).to_not be(nil)
      end
    end
  end

  # country: The issuing country of the credit card the chargeable will charge.
  describe "#country" do
    describe "before prepare" do
      it "is safe to call" do
        chargeable.country
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is set" do
        expect(chargeable.country).to_not be(nil)
      end
    end
  end

  # reusable_token!: Creates a token (which is returned) which can be used repeatedly to reference the chargeable
  # to charge, auth, etc. May optionally take a user id which may be stored at the processor if the processor
  # supports it and only if the chargeable is not already persisted.
  describe "#reusable_token!" do
    describe "before prepare" do
      it "is set" do
        expect(chargeable.reusable_token!(nil)).to_not be(nil)
      end
    end

    describe "after prepare" do
      before { chargeable.prepare! }

      it "is set" do
        expect(chargeable.reusable_token!(nil)).to_not be(nil)
      end
    end
  end
end
