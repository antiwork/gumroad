# frozen_string_literal: true

require "spec_helper"

describe BankCodeDirectoryCheck do
  let(:user) { create(:named_user) }
  let(:bank_account) { build(:egypt_bank_account, user:, bank_code: "QNBAEGCX027") }

  def stripe_rejection(code: nil, param: nil, message: "We couldn't find the bank for that BIC")
    Stripe::InvalidRequestError.new(message, param, code:)
  end

  # Stripe's EG directory answers for the routing number's own entry, and for the branch segment
  # inside the account number, under the same code on a different param.
  def unresolvable_routing_number
    stripe_rejection(code: "routing_number_invalid", param: "bank_account[routing_number]")
  end

  def unresolvable_branch
    stripe_rejection(
      code: "bank_account_unusable",
      param: "bank_account[account_number]",
      message: "We couldn't find the bank for this account number"
    )
  end

  describe ".rejection_for" do
    it "tokenises the new details without creating anything and passes resolvable details" do
      expect(Stripe::Token).to receive(:create).with(
        {
          bank_account: {
            country: "EG",
            currency: "egp",
            routing_number: "QNBAEGCX027",
            account_number: "EG800002000156789012345180002",
          },
        },
        hash_including(:client)
      ).and_return(double(bank_account: double(bank_name: "QATAR NATIONAL BANK S.A.E")))

      expect(described_class.rejection_for(bank_account)).to be_nil
    end

    it "names the 8-character code when Stripe cannot find the bank for a branch-suffixed BIC" do
      allow(Stripe::Token).to receive(:create).and_raise(unresolvable_routing_number)

      rejection = described_class.rejection_for(bank_account)

      expect(rejection.message).to eq(
        "Our payment partner couldn't find a bank for the bank code QNBAEGCX027. " \
        "Use the 8-character SWIFT/BIC code instead: QNBAEGCX rather than QNBAEGCX027."
      )
      expect(rejection.field).to eq(:bank_code)
    end

    it "treats a rejection on the routing_number param as a directory miss even without a code" do
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(param: "bank_account[routing_number]"))

      expect(described_class.rejection_for(bank_account).message).to include("QNBAEGCX rather than QNBAEGCX027")
    end

    it "asks the seller to check an 8-character code Stripe cannot resolve" do
      bank_account.bank_code = "ZZZZEGCX"
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "routing_number_invalid"))

      expect(described_class.rejection_for(bank_account).message).to eq(
        "Our payment partner couldn't find a bank for the bank code ZZZZEGCX. " \
        "Please check it against the SWIFT/BIC code your bank publishes."
      )
    end

    it "names the branch and flags the account number when Stripe cannot find the bank for it" do
      allow(Stripe::Token).to receive(:create).and_raise(unresolvable_branch)

      rejection = described_class.rejection_for(bank_account)

      expect(rejection.message).to eq(
        "Our payment partner couldn't find the branch this account number belongs to. " \
        "Check the account number against your bank's records, or use an account at another branch."
      )
      expect(rejection.field).to eq(:account_number)
    end

    it "fails open when Stripe rejects the account number's format rather than its branch" do
      allow(Stripe::Token).to receive(:create).and_raise(stripe_rejection(code: "account_number_invalid", param: "bank_account[account_number]", message: "Invalid account number"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.rejection_for(bank_account)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/failed open.*Invalid account number/)
    end

    it "fails open on a connection error" do
      allow(Stripe::Token).to receive(:create).and_raise(Stripe::APIConnectionError.new("timed out"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.rejection_for(bank_account)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/failed open.*timed out/)
    end

    it "fails open on a rate limit" do
      allow(Stripe::Token).to receive(:create).and_raise(Stripe::RateLimitError.new("slow down"))

      expect(described_class.rejection_for(bank_account)).to be_nil
    end

    it "does not call Stripe for a country that is not opted in" do
      expect(Stripe::Token).not_to receive(:create)

      expect(described_class.rejection_for(build(:bahrain_bank_account, user:))).to be_nil
    end

    context "with an account whose payout shape carries no routing number" do
      # A Swedish account holding a GB IBAN: IbanBankAccount#cross_border_sepa_payout? sends it with
      # no routing number.
      let(:bank_account) { build(:sweden_bank_account, user:, account_number: "GB79TRWI60846411112222") }

      it "probes the account number alone, with no routing number on the payload" do
        expect(Stripe::Token).to receive(:create).with(
          { bank_account: { country: "GB", currency: "eur", account_number: "GB79TRWI60846411112222" } },
          hash_including(:client)
        ).and_return(double)

        expect(described_class.rejection_for(bank_account)).to be_nil
      end

      it "names the bank rather than the account number when the account number was the only detail sent" do
        allow(Stripe::Token).to receive(:create).and_raise(unresolvable_branch)

        rejection = described_class.rejection_for(bank_account)

        expect(rejection.message).to eq(
          "This IBAN can't receive payouts because our payment partner couldn't find its bank. " \
          "Please enter an IBAN from a different bank."
        )
        expect(rejection.field).to eq(:account_number)
      end

      it "fails open on the account number's format, which is not a directory answer" do
        expect(Stripe::Token).to receive(:create).and_raise(
          stripe_rejection(code: "account_number_invalid", param: "bank_account[account_number]",
                           message: "Invalid account number")
        )
        allow(Rails.logger).to receive(:warn)

        expect(described_class.rejection_for(bank_account)).to be_nil
        expect(Rails.logger).to have_received(:warn).with(/failed open/)
      end

      it "fails open on a routing number error, since no routing number was sent" do
        expect(Stripe::Token).to receive(:create).and_raise(unresolvable_routing_number)
        allow(Rails.logger).to receive(:warn)

        expect(described_class.rejection_for(bank_account)).to be_nil
      end

      it "skips the probe when the same details are already attached at Stripe" do
        previous = create(:sweden_bank_account, user:, account_number: "GB79TRWI60846411112222",
                                                stripe_bank_account_id: "ba_123")
        expect(Stripe::Token).not_to receive(:create)

        expect(described_class.rejection_for(bank_account, previous_bank_account: previous)).to be_nil
      end

      it "probes the same IBAN when the previous row never attached" do
        previous = create(:sweden_bank_account, user:, account_number: "GB79TRWI60846411112222",
                                                stripe_bank_account_id: nil)
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_for(bank_account, previous_bank_account: previous)
      end

      it "does not probe a domestic IBAN row that sends a routing number, while that country is not opted in" do
        expect(Stripe::Token).not_to receive(:create)

        expect(described_class.rejection_for(build(:san_marino_bank_account, user:))).to be_nil
      end
    end

    context "with a UK sort code" do
      let(:bank_account) { build(:uk_bank_account, user:, sort_code: "60-84-64") }

      it "probes the sort code and passes one Stripe resolves" do
        expect(Stripe::Token).to receive(:create).with(
          { bank_account: { country: "GB", currency: "gbp", routing_number: "60-84-64", account_number: "1234567" } },
          hash_including(:client)
        ).and_return(double)

        expect(described_class.rejection_for(bank_account)).to be_nil
      end

      it "names the sort code and asks for a different bank when Stripe cannot find it" do
        allow(Stripe::Token).to receive(:create).and_raise(unresolvable_routing_number)

        rejection = described_class.rejection_for(bank_account)

        expect(rejection.message).to eq(
          "Our payment partner couldn't find a bank for the sort code 60-84-64, so it can't be used " \
          "for payouts. Please enter an account at a different bank."
        )
        expect(rejection.field).to eq(:sort_code)
      end

      it "probes, then fails open on an account number format rejection" do
        expect(Stripe::Token).to receive(:create).and_raise(
          stripe_rejection(code: "account_number_invalid", param: "bank_account[account_number]", message: "Invalid")
        )
        allow(Rails.logger).to receive(:warn)

        expect(described_class.rejection_for(bank_account)).to be_nil
      end

      it "fails open when Stripe cannot place the account number, because only the sort code is opted in" do
        expect(Stripe::Token).to receive(:create).and_raise(unresolvable_branch)
        allow(Rails.logger).to receive(:warn)

        expect(described_class.rejection_for(bank_account)).to be_nil
      end
    end

    context "with the previous alive bank account" do
      it "skips the probe when the details are unchanged and already attached at Stripe" do
        previous = create(:egypt_bank_account, user:, bank_code: "QNBAEGCX027", stripe_bank_account_id: "ba_123")
        expect(Stripe::Token).not_to receive(:create)

        expect(described_class.rejection_for(bank_account, previous_bank_account: previous)).to be_nil
      end

      it "probes an unchanged code whose previous row never attached" do
        previous = create(:egypt_bank_account, user:, bank_code: "QNBAEGCX027", stripe_bank_account_id: nil)
        allow(Stripe::Token).to receive(:create).and_raise(unresolvable_routing_number)

        expect(described_class.rejection_for(bank_account, previous_bank_account: previous).message).to include("QNBAEGCX rather than")
      end

      it "probes when only the account number changed under a code that is already attached" do
        previous = create(:egypt_bank_account, user:, bank_code: "QNBAEGCX027", stripe_bank_account_id: "ba_123")
        bank_account.account_number = "EG380019000500000000263180002"
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_for(bank_account, previous_bank_account: previous)
      end

      it "probes when the code changed" do
        previous = create(:egypt_bank_account, user:, bank_code: "NBEGEGCX331", stripe_bank_account_id: "ba_123")
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_for(bank_account, previous_bank_account: previous)
      end

      it "probes when the previous row is for another country" do
        previous = create(:bahrain_bank_account, user:, stripe_bank_account_id: "ba_123")
        allow(previous).to receive(:stripe_external_account_routing_number).and_return("QNBAEGCX027")
        expect(Stripe::Token).to receive(:create).and_return(double)

        described_class.rejection_for(bank_account, previous_bank_account: previous)
      end
    end
  end
end
