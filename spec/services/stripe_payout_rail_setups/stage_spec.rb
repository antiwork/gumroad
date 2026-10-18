# frozen_string_literal: true

require "spec_helper"

describe StripePayoutRailSetups::Stage do
  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:bank_account_params) do
    {
      type: AchAccount.name,
      account_number: "000123456789",
      account_number_confirmation: "000123456789",
      routing_number: "110000000",
      account_holder_full_name: "Synthetic Holder",
    }
  end
  let(:params) { ActionController::Parameters.new(bank_account: bank_account_params) }
  let(:card_params) { ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" }) }

  before do
    create(:user_compliance_info_business, user: seller, country: "French Polynesia")
    Feature.activate_user(:merchant_migration, seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
  end

  # Unit control at the card tokenization boundary: the submitted token resolves to this synthetic
  # US debit card instead of a Stripe customer being created.
  def stub_card_tokenization(credit_card)
    chargeable = double("chargeable")
    allow(ChargeProcessor).to receive(:get_chargeable_for_params).and_return(chargeable)
    allow(CreditCard).to receive(:create).with(chargeable).and_return(credit_card)
  end

  # Unit control: Stripe never answers this account creation, so the setup stays pending with a real
  # recorded provider attempt bound to its candidate.
  def attempt_without_verdict!(setup)
    create(:tos_agreement, user: seller)
    allow(Stripe::Account).to receive(:create).and_raise(Stripe::APIConnectionError.new("Connection reset"))
    StripePayoutRailSetups::Provision.new(setup).process
    expect(setup.reload).to be_pending
    expect(setup.attempt_count).to eq(1)
  end

  describe ".applies_to?" do
    it "accepts a new bank account or a new debit card beside a Connect row that is not routing card sales" do
      expect(described_class.applies_to?(seller, params)).to be(true)
      expect(described_class.applies_to?(seller, card_params)).to be(true)
    end

    it "refuses while the rollout gate is closed for the seller" do
      Feature.deactivate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)

      expect(described_class.applies_to?(seller, params)).to be(false)
      expect(described_class.applies_to?(seller, card_params)).to be(false)
    end

    it "refuses a card and a bank account in the same request" do
      expect(described_class.applies_to?(seller, ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" }, bank_account: bank_account_params))).to be(false)
    end

    it "refuses an instrument sent along with a PayPal address" do
      expect(described_class.applies_to?(seller, ActionController::Parameters.new(bank_account: bank_account_params, payment_address: "new-paypal@example.com"))).to be(false)
      expect(described_class.applies_to?(seller, ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" }, payment_address: "new-paypal@example.com"))).to be(false)
    end

    it "refuses a holder-name-only edit" do
      expect(described_class.applies_to?(seller, ActionController::Parameters.new(bank_account: { type: AchAccount.name, account_holder_full_name: "Synthetic Holder" }))).to be(false)
    end

    it "refuses when Connect is routing card sales" do
      seller.update!(check_merchant_account_is_linked: true)

      expect(described_class.applies_to?(seller, params)).to be(false)
    end

    it "refuses when there is no Connect row or a managed account already exists" do
      expect(described_class.applies_to?(create(:user), params)).to be(false)

      create(:merchant_account, user: seller, country: "US")
      expect(described_class.applies_to?(seller.reload, params)).to be(false)
    end
  end

  describe ".conflicting_change" do
    def conflict(extra)
      described_class.conflicting_change(seller.reload, ActionController::Parameters.new({ bank_account: bank_account_params }.merge(extra)))
    end

    it "allows the settings form's unchanged echo of compliance details and payout preferences" do
      expect(conflict(user: { is_business: "on", country: "PF", business_country: "US", first_name: "Changed" },
                      payout_threshold_cents: seller.payout_threshold_cents.to_s, payout_frequency: seller.payout_frequency,
                      payouts_paused_by_user: "false")).to be_nil
    end

    it "refuses a change of the representative's country, the business country or the account type" do
      expect(conflict(user: { is_business: "on", country: "FR" })).to eq(:routing_details_changed)
      expect(conflict(user: { is_business: "on", business_country: "FR" })).to eq(:routing_details_changed)
      expect(conflict(user: { is_business: "off" })).to eq(:routing_details_changed)
    end

    context "for an individual" do
      before do
        seller.alive_user_compliance_info.dup_and_save! do |info|
          info.is_business = false
          info.country = "French Polynesia"
        end
      end

      it "predicts the country the compliance save writes for a truthy raw is_business, including a cleared one" do
        expect(conflict(user: { is_business: "off", country: "FR" })).to eq(:routing_details_changed)
        expect(conflict(user: { is_business: "false", country: "FR" })).to eq(:routing_details_changed)
        expect(conflict(user: { is_business: "", country: "FR" })).to eq(:routing_details_changed)
        expect(conflict(user: { is_business: "off", country: "ZZ" })).to eq(:routing_details_changed)
      end

      it "allows the form's echo and a country the save ignores" do
        expect(conflict(user: { is_business: "off", country: "PF" })).to be_nil
        expect(conflict(user: { is_business: false, country: "FR" })).to be_nil
        expect(conflict(user: { country: "FR" })).to be_nil
        expect(conflict(user: { is_business: "off" })).to be_nil
      end

      it "refuses a switch to business" do
        expect(conflict(user: { is_business: "on" })).to eq(:routing_details_changed)
        expect(conflict(user: { is_business: true })).to eq(:routing_details_changed)
      end
    end

    it "refuses a change of the payout threshold, frequency or pause" do
      expect(conflict(payout_threshold_cents: (seller.payout_threshold_cents + 100).to_s)).to eq(:payout_preferences_changed)
      expect(conflict(payout_frequency: User::PayoutSchedule::MONTHLY)).to eq(:payout_preferences_changed)
      expect(conflict(payouts_paused_by_user: "true")).to eq(:payout_preferences_changed)
    end
  end

  describe "#process" do
    it "saves the candidate as an inactive bank account and opens a pending setup" do
      old_bank_account = create(:ach_account, user: seller)
      HandleNewBankAccountWorker.jobs.clear
      bank_request = create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::BANK_ACCOUNT)

      result = described_class.new(seller:, params:).process

      expect(result.success).to be(true)
      setup = result.setup
      expect(setup).to be_pending
      expect(setup.user).to eq(seller)
      candidate = setup.bank_account
      expect(candidate).to be_an_instance_of(AchAccount)
      expect(candidate).to be_deleted
      expect(candidate.account_number_last_four).to eq("6789")
      expect(candidate.account_number.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))).to eq("000123456789")
      seller.reload
      expect(seller.active_bank_account).to eq(old_bank_account)
      expect(seller.bank_accounts.alive).to eq([old_bank_account])
      expect(seller.payment_address).to eq("seller-payouts@example.com")
      expect(HandleNewBankAccountWorker.jobs.size).to eq(0)
      expect(bank_request.reload.state).to eq("requested")
    end

    it "saves a debit card candidate the same way" do
      stub_card_tokenization(create(:us_debit_stripe_credit_card))

      result = described_class.new(seller:, params: card_params).process

      expect(result.success).to be(true)
      candidate = result.setup.bank_account
      expect(candidate).to be_an_instance_of(CardBankAccount)
      expect(candidate).to be_deleted
      expect(result.setup).to be_card
      expect(seller.reload.active_bank_account).to be_nil
      expect(HandleNewBankAccountWorker.jobs.size).to eq(0)
    end

    it "returns the card error, saves nothing and discards the card when it is not a US debit card" do
      credit_card = create(:us_debit_stripe_credit_card, funding_type: ChargeableFundingType::CREDIT)
      stub_card_tokenization(credit_card)

      expect do
        result = described_class.new(seller:, params: card_params).process
        expect(result.error).to eq(:bank_account_error)
      end.to not_change { BankAccount.count }.and not_change { StripePayoutRailSetup.count }
      expect(CreditCard.exists?(credit_card.id)).to be(false)
    end

    it "returns the form error and saves nothing when the account numbers do not match" do
      bad_params = ActionController::Parameters.new(bank_account: bank_account_params.merge(account_number_confirmation: "000123456780"))

      expect do
        result = described_class.new(seller:, params: bad_params).process
        expect(result.error).to eq(:account_number_does_not_match)
      end.to not_change { BankAccount.count }.and not_change { StripePayoutRailSetup.count }
    end

    it "resumes a pending setup with its original candidate when the same bank account is submitted again" do
      first = described_class.new(seller:, params:).process.setup

      expect do
        second = described_class.new(seller:, params:).process
        expect(second.setup).to eq(first)
        expect(second.setup.bank_account).to eq(first.bank_account)
      end.to not_change { BankAccount.count }.and not_change { StripePayoutRailSetup.count }
    end

    it "replaces the candidate of a pending setup that never reached Stripe" do
      first = described_class.new(seller:, params:).process.setup
      original_candidate = first.bank_account
      other = ActionController::Parameters.new(bank_account: bank_account_params.merge(account_number: "000111222333", account_number_confirmation: "000111222333"))

      result = described_class.new(seller:, params: other).process

      expect(result.setup).to eq(first)
      expect(first.reload.bank_account).not_to eq(original_candidate)
      expect(first.bank_account).to be_deleted
      expect(first.bank_account.account_number.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))).to eq("000111222333")
      expect(StripePayoutRailSetup.count).to eq(1)
      expect(seller.reload.bank_accounts.alive).to be_empty
    end

    it "refuses a different bank account once a provider attempt for the earlier one is unresolved" do
      first = described_class.new(seller:, params:).process.setup
      attempt_without_verdict!(first)
      other = ActionController::Parameters.new(bank_account: bank_account_params.merge(account_number: "000111222333", account_number_confirmation: "000111222333"))
      renamed = ActionController::Parameters.new(bank_account: bank_account_params.merge(account_holder_full_name: "Another Holder"))

      expect do
        expect(described_class.new(seller:, params: other).process.error).to eq(:rail_setup_other_instrument)
        expect(described_class.new(seller:, params: renamed).process.error).to eq(:rail_setup_other_instrument)
      end.to not_change { BankAccount.count }

      expect(first.reload.bank_account.account_number.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))).to eq("000123456789")
    end

    it "refuses a debit card while a bank account attempt is unresolved, and discards the new card" do
      attempt_without_verdict!(described_class.new(seller:, params:).process.setup)
      credit_card = create(:us_debit_stripe_credit_card)
      stub_card_tokenization(credit_card)

      expect(described_class.new(seller:, params: card_params).process.error).to eq(:rail_setup_other_instrument)
      expect(CreditCard.exists?(credit_card.id)).to be(false)
    end

    it "resumes a pending card setup only for the same card" do
      card = create(:us_debit_stripe_credit_card)
      stub_card_tokenization(card)
      first = described_class.new(seller:, params: card_params).process.setup
      attempt_without_verdict!(first)

      same_card_again = create(:us_debit_stripe_credit_card, stripe_fingerprint: card.stripe_fingerprint)
      stub_card_tokenization(same_card_again)
      expect(described_class.new(seller:, params: card_params).process.setup).to eq(first)
      expect(CreditCard.exists?(same_card_again.id)).to be(false)

      stub_card_tokenization(create(:us_debit_stripe_credit_card))
      expect(described_class.new(seller:, params: card_params).process.error).to eq(:rail_setup_other_instrument)
    end

    it "refuses a new candidate while the setup is being provisioned or is prepared" do
      setup = described_class.new(seller:, params:).process.setup
      setup.update!(attempt_started_at: 1.minute.ago, attempt_token: "synthetic-attempt")

      expect do
        expect(described_class.new(seller:, params:).process.error).to eq(:rail_setup_in_progress)
      end.not_to change { BankAccount.count }

      setup.update!(attempt_started_at: nil, attempt_token: nil, state: StripePayoutRailSetup::PREPARED)
      expect(described_class.new(seller:, params:).process.error).to eq(:rail_setup_in_progress)
      expect(setup.reload.bank_account).to eq(setup.bank_account)
    end
  end
end
