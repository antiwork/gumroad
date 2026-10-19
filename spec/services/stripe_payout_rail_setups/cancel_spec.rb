# frozen_string_literal: true

require "spec_helper"

describe StripePayoutRailSetups::Cancel do
  include_context "with Stripe API stubs"

  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }
  let(:reason_reference) { "support-thread-synthetic-2" }

  before do
    create(:user_compliance_info_business, user: seller, country: "French Polynesia")
    create(:tos_agreement, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
  end

  def bank_params(account_number = "000123456789")
    ActionController::Parameters.new(
      bank_account: {
        type: AchAccount.name,
        account_number:,
        account_number_confirmation: account_number,
        routing_number: "110000000",
        account_holder_full_name: "Synthetic Holder",
      }
    )
  end

  def prepare_bank(account_number = "000123456789")
    setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params(account_number)).process.setup
    expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)
    setup.reload
  end

  def cancel(setup, cancelled_by: team_member, reference: reason_reference)
    described_class.new(setup:, cancelled_by:, reason_reference: reference).process
  end

  def expect_current_payout_method_kept(payout_weekday:)
    seller.reload
    expect(seller.payment_address).to eq("seller-payouts@example.com")
    expect(seller.active_bank_account).to be_nil
    expect(seller.stripe_account).to be_nil
    expect(seller.current_payout_processor).to eq(PayoutProcessorType::PAYPAL)
    expect(seller.payout_weekday).to eq(payout_weekday)
    expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(true)
  end

  it "ends a prepared setup that compliance edits made unactivatable, and the next bank account prepares against current details" do
    payout_weekday = seller.payout_weekday
    setup = prepare_bank
    prepared_account = setup.merchant_account
    seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed After Preparation, LLC" }
    current_revision = seller.reload.alive_user_compliance_info.external_id
    expect(Stripe::Account.retrieve(prepared_account.charge_processor_merchant_id)["metadata"]["user_compliance_info_id"]).not_to eq(current_revision)
    expect(StripePayoutRailSetups::Stage.new(seller:, params: bank_params("000111222333")).process.error).to eq(:rail_setup_in_progress)

    result = cancel(setup)

    expect(result.success).to be(true)
    setup.reload
    expect(setup.state).to eq(StripePayoutRailSetup::FAILED)
    expect(setup.failure_code).to eq("cancelled_by_staff")
    expect(prepared_account.reload).not_to be_alive
    expect(prepared_account.charge_processor_merchant_id).to be_present
    expect(seller.comments.with_type_payout_note.last.content).to include(team_member.email, reason_reference, "##{setup.id}")
    expect_current_payout_method_kept(payout_weekday:)

    next_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params("000111222333")).process.setup
    expect(StripePayoutRailSetups::Provision.new(next_setup).process.success).to be(true)

    next_setup.reload
    expect(next_setup).to be_prepared
    expect(next_setup.merchant_account).not_to eq(prepared_account)
    expect(next_setup.merchant_account.charge_processor_alive?).to be(false)
    expect(Stripe::Account.retrieve(next_setup.merchant_account.charge_processor_merchant_id)["metadata"]["user_compliance_info_id"]).to eq(current_revision)
    expect_current_payout_method_kept(payout_weekday:)
  end

  it "ends a card setup still waiting for Stripe to enable charges" do
    payout_weekday = seller.payout_weekday
    chargeable = double("chargeable")
    allow(ChargeProcessor).to receive(:get_chargeable_for_params).and_return(chargeable)
    allow(CreditCard).to receive(:create).with(chargeable).and_return(create(:us_debit_stripe_credit_card))
    allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
      Stripe::Account.construct_from(id: account_id, object: "account", country: "US", charges_enabled: false,
                                     requirements: { currently_due: ["individual.verification.document"] }, metadata: {})
    end
    setup = StripePayoutRailSetups::Stage.new(seller:, params: ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" })).process.setup
    StripePayoutRailSetups::Provision.new(setup).process
    expect(setup.reload).to be_awaiting_card_link

    expect(cancel(setup).success).to be(true)

    expect(setup.reload.state).to eq(StripePayoutRailSetup::FAILED)
    expect(setup.merchant_account.reload).not_to be_alive
    expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller.reload)).to be(false)
    expect_current_payout_method_kept(payout_weekday:)
  end

  it "keeps an uncertain attempt's recovery note when it ends a pending setup" do
    allow(Stripe::Account).to receive(:create).and_raise(Stripe::APIConnectionError.new("Connection reset"))
    setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup
    StripePayoutRailSetups::Provision.new(setup).process
    recovery_note = seller.comments.alive.with_type_payout_note.find { _1.content.start_with?(StripeMerchantAccountManager::NO_VERDICT_FAILURE_NOTE_PREFIX) }
    expect(recovery_note.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY]).to be_present

    expect(cancel(setup).success).to be(true)

    expect(setup.reload.state).to eq(StripePayoutRailSetup::FAILED)
    expect(recovery_note.reload).to be_alive
    expect(recovery_note.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY]).to be_present
    expect(recovery_note.json_data["abandoned_reason"]).to eq("rail_setup_ended")
  end

  describe "after an attempt stopped between Stripe creating the account and the setup recording it" do
    def stub_ready_account(setup)
      account_id = setup.merchant_account.charge_processor_merchant_id
      compliance_revision = seller.alive_user_compliance_info.external_id
      # SDK double for the provider readiness read at activation.
      allow(Stripe::Account).to receive(:retrieve).with(account_id) do
        Stripe::Account.construct_from(
          id: account_id, country: "US", payouts_enabled: true, charges_enabled: true, metadata: { user_compliance_info_id: compliance_revision },
          requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
          external_accounts: { object: "list", data: [{ id: setup.bank_account.stripe_bank_account_id, object: "bank_account", status: "new", currency: "usd", country: "US" }] }
        )
      end
    end

    def expect_next_bank_prepares_and_activates(stranded, payout_weekday:)
      seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed After Cancel, LLC" }
      next_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params("000111222333")).process.setup
      expect(StripePayoutRailSetups::Provision.new(next_setup).process.success).to be(true)
      next_setup.reload
      expect(next_setup).to be_prepared
      expect(next_setup.merchant_account).not_to eq(stranded)
      expect_current_payout_method_kept(payout_weekday:)

      stub_ready_account(next_setup)
      expect(StripePayoutRailSetups::Activate.new(setup: next_setup, activated_by: team_member, consent_reference: "support-thread-synthetic-7").process.success).to be(true)
      expect(seller.reload.stripe_account).to eq(next_setup.merchant_account)
    end

    it "retires the account a worker shut down mid-attempt had opened, and the next bank account prepares and activates" do
      payout_weekday = seller.payout_weekday
      person_calls = 0
      # SDK double: Sidekiq shuts the worker down while it adds the representative, after the Stripe id was saved.
      allow(Stripe::Account).to receive(:create_person) do |_account_id, _params|
        person_calls += 1
        raise Sidekiq::Shutdown if person_calls == 1

        Stripe::StripeObject.construct_from(id: "person_mock_#{person_calls}", object: "person")
      end
      setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup

      expect { StripePayoutRailSetups::Provision.new(setup).process }.to raise_error(Sidekiq::Shutdown)

      expect(setup.reload).to be_pending
      expect(setup.merchant_account).to be_nil
      stranded = seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?).sole
      provider_id = stranded.charge_processor_merchant_id
      expect(provider_id).to be_present

      expect(cancel(setup).success).to be(true)

      expect(stranded.reload).not_to be_alive
      expect(stranded.charge_processor_merchant_id).to eq(provider_id)
      expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller.reload)).to be(false)
      expect_next_bank_prepares_and_activates(stranded, payout_weekday:)
    end

    it "retires the account when recording the attempt failed after Stripe created it" do
      payout_weekday = seller.payout_weekday
      finishes = 0
      allow_any_instance_of(StripePayoutRailSetup).to receive(:finish_attempt!).and_wrap_original do |original, *args, **kwargs|
        finishes += 1
        raise ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock") if finishes == 1

        original.call(*args, **kwargs)
      end
      setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup

      expect { StripePayoutRailSetups::Provision.new(setup).process }.to raise_error(ActiveRecord::Deadlocked)

      expect(setup.reload).to be_pending
      expect(setup.merchant_account).to be_nil
      stranded = seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?).sole

      expect(cancel(setup).success).to be(true)

      expect(stranded.reload).not_to be_alive
      expect_next_bank_prepares_and_activates(stranded, payout_weekday:)
    end
  end

  describe "after cancelling a setup whose account creation got no verdict" do
    # Replays of the first key whose responses are also lost before one comes back.
    let(:lost_replays) { 1 }
    let(:stripe_double) { { created: {}, keys: [], lost_replays: } }

    # SDK double for Stripe's idempotent Account.create and account listing: the first create opens an
    # account but its response is lost, a key replayed with other parameters is refused, and a new key
    # opens a new account.
    before do
      allow(Stripe::Account).to receive(:create) do |params, opts = {}|
        stripe_double.delete(:during_create)&.call
        refusal = stripe_double.delete(:refuse_next_create)
        raise refusal if refusal

        key = opts[:idempotency_key]
        stripe_double[:keys] << key
        if (existing = stripe_double[:created][key])
          raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters.") if existing[:params] != params
          raise Stripe::APIConnectionError.new("Connection reset") if (stripe_double[:lost_replays] -= 1) >= 0

          next existing[:account]
        end

        account_id = "acct_mock_#{stripe_double[:created].size + 1}"
        account = Stripe::Account.construct_from(
          id: account_id, object: "account", type: "custom", country: params[:country], created: Time.current.to_i, charges_enabled: true,
          payouts_enabled: true, metadata: params[:metadata], requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
          external_accounts: { object: "list", data: [{ id: "ba_#{account_id}", object: "bank_account", fingerprint: "fp_#{account_id}", status: "new", currency: "usd", country: "US" }] }
        )
        lose_response = stripe_double[:created].empty? || stripe_double.delete(:lose_next_create)
        stripe_double[:created][key] = { params:, account: }
        raise Stripe::APIConnectionError.new("Connection reset") if lose_response

        account
      end
      allow(Stripe::Account).to receive(:list) do
        Stripe::ListObject.construct_from(object: "list", has_more: false, data: stripe_double[:created].values.map { _1[:account] })
      end
      allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
        stripe_double[:created].values.map { _1[:account] }.find { _1.id == account_id } || raise(Stripe::InvalidRequestError.new("No such account", "id"))
      end
      allow_any_instance_of(Stripe::Account).to receive(:refresh) { |account| account }
    end

    def keys
      stripe_double[:keys]
    end

    def account_for(key)
      stripe_double[:created].fetch(key)[:account]
    end

    it "prepares the next setup on a fresh account from current details, keeps the old receipt, and activates once" do
      payout_weekday = seller.payout_weekday
      cancelled_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup
      StripePayoutRailSetups::Provision.new(cancelled_setup).process
      StripePayoutRailSetups::Provision.new(cancelled_setup.reload).process
      expect(cancelled_setup.reload).to be_pending
      expect(keys.size).to eq(2)
      expect(keys.uniq.size).to eq(1)
      old_key = keys.first
      receipt = seller.comments.with_type_payout_note.find { _1.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY] == old_key }

      expect(cancel(cancelled_setup).success).to be(true)
      RetryStripeRejectedPayoutSetupForSellerJob.drain
      seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed After Cancel, LLC" }
      current_revision = seller.reload.alive_user_compliance_info.external_id

      next_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params("000111222333")).process.setup
      expect(StripePayoutRailSetups::Provision.new(next_setup).process.success).to be(true)

      next_setup.reload
      expect(next_setup).to be_prepared
      expect(keys.last).not_to eq(old_key)
      expect(next_setup.merchant_account.charge_processor_merchant_id).to eq(account_for(keys.last).id)
      expect(next_setup.merchant_account.charge_processor_merchant_id).not_to eq(account_for(old_key).id)
      sent_metadata = stripe_double[:created].fetch(keys.last)[:params][:metadata]
      expect(sent_metadata[:user_compliance_info_id]).to eq(current_revision)
      expect(sent_metadata[:bank_account_id]).to eq(next_setup.bank_account.external_id)
      expect(receipt.reload).to be_alive
      expect(receipt.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY]).to eq(old_key)
      expect(MerchantAccount.where(charge_processor_merchant_id: account_for(old_key).id)).to be_empty
      expect_current_payout_method_kept(payout_weekday:)

      result = StripePayoutRailSetups::Activate.new(setup: next_setup, activated_by: team_member, consent_reference: "support-thread-synthetic-6").process
      expect(result.success).to be(true)
      expect(seller.reload.stripe_account).to eq(next_setup.merchant_account)
    end

    it "recovers the setup's own account when its retry is sent with changed details, never the cancelled setup's" do
      cancelled_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup
      StripePayoutRailSetups::Provision.new(cancelled_setup).process
      expect(cancel(cancelled_setup).success).to be(true)
      cancelled_account_id = account_for(keys.first).id
      stripe_double[:lose_next_create] = true

      setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params("000111222333")).process.setup
      StripePayoutRailSetups::Provision.new(setup).process
      expect(setup.reload).to be_pending
      own_key = keys.last
      seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed Between Retries, LLC" }

      expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)

      expect(keys.last).to eq(own_key)
      expect(setup.reload).to be_prepared
      expect(setup.merchant_account.charge_processor_merchant_id).to eq(account_for(own_key).id)
      expect(setup.merchant_account.charge_processor_merchant_id).not_to eq(cancelled_account_id)
    end

    context "when the replay of the setup's own uncertain attempt is answered" do
      let(:lost_replays) { 0 }

      it "adopts the account that attempt opened, under the same key" do
        setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup
        StripePayoutRailSetups::Provision.new(setup).process
        StripePayoutRailSetups::Provision.new(setup.reload).process

        expect(setup.reload).to be_prepared
        expect(keys.size).to eq(2)
        expect(keys.uniq.size).to eq(1)
        expect(setup.merchant_account.charge_processor_merchant_id).to eq(account_for(keys.first).id)
      end
    end

    context "when the seller's retry job runs for a newer setup beside another context's note" do
      let(:lost_replays) { 0 }
      let(:key_field) { StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY }
      let(:setup_field) { StripeMerchantAccountManager::RAIL_SETUP_ID_NOTE_KEY }

      # Stages a bank and runs its first preparation, whose Stripe response is lost.
      def pending_setup_with_lost_create(account_number)
        stripe_double[:lose_next_create] = true
        setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params(account_number)).process.setup
        StripePayoutRailSetups::Provision.new(setup).process
        expect(setup.reload).to be_pending
        setup
      end

      def own_outstanding_notes(setup)
        seller.comments.alive.with_type_payout_note.select { _1.json_data[setup_field] == setup.id.to_s && _1.json_data["abandoned_at"].blank? }
      end

      def expect_kept_receipt(note, key)
        note.reload
        expect(note).to be_alive
        expect(note.json_data[key_field]).to eq(key)
        expect(note.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_ATTEMPTED_AT]).to be_present
        expect(note.json_data["abandoned_reason"]).to eq(RetryStripeRejectedPayoutSetupForSellerJob::ABANDONED_REASON_SWITCHED_OFF_STRIPE)
      end

      def expect_prepared_on_own_account(setup, own_key)
        expect(setup.reload).to be_prepared
        expect(setup.merchant_account.charge_processor_merchant_id).to eq(account_for(own_key).id)
        expect(own_outstanding_notes(setup)).to be_empty
      end

      it "prepares only the new setup and keeps the receipt a cancelled setup's late answer opened" do
        payout_weekday = seller.payout_weekday
        cancelled_setup = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process.setup
        # Staff cancel the setup while its worker waits on Stripe, whose answer is then lost.
        stripe_double[:during_create] = -> { expect(cancel(StripePayoutRailSetup.find(cancelled_setup.id)).success).to be(true) }
        StripePayoutRailSetups::Provision.new(cancelled_setup).process
        expect(cancelled_setup.reload.state).to eq(StripePayoutRailSetup::FAILED)
        cancelled_key = keys.first
        late_note = seller.comments.alive.with_type_payout_note.select { _1.json_data[setup_field] == cancelled_setup.id.to_s && _1.json_data["abandoned_at"].blank? }.sole
        expect(late_note.json_data[key_field]).to eq(cancelled_key)

        setup = pending_setup_with_lost_create("000111222333")
        own_key = keys.last
        RetryStripeRejectedPayoutSetupForSellerJob.drain

        expect_prepared_on_own_account(setup, own_key)
        expect(keys.count(cancelled_key)).to eq(1)
        expect(MerchantAccount.where(charge_processor_merchant_id: account_for(cancelled_key).id)).to be_empty
        expect_kept_receipt(late_note, cancelled_key)
        expect_current_payout_method_kept(payout_weekday:)
      end

      it "prepares the new setup ahead of an older ordinary uncertain create, whose receipt is kept" do
        payout_weekday = seller.payout_weekday
        expect do
          StripeMerchantAccountManager.create_account(seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        end.to raise_error(Stripe::APIConnectionError)
        ordinary_key = keys.first
        ordinary_note = seller.comments.alive.with_type_payout_note.select { _1.json_data[key_field] == ordinary_key }.sole
        expect(ordinary_note.json_data[setup_field]).to be_nil

        setup = pending_setup_with_lost_create("000111222333")
        own_key = keys.last
        RetryStripeRejectedPayoutSetupForSellerJob.drain

        expect_prepared_on_own_account(setup, own_key)
        expect(keys.count(ordinary_key)).to eq(1)
        expect(MerchantAccount.where(charge_processor_merchant_id: account_for(ordinary_key).id)).to be_empty
        expect_kept_receipt(ordinary_note, ordinary_key)
        expect_current_payout_method_kept(payout_weekday:)
      end

      it "keeps retrying the new setup when an older note is an ordinary postal-code refusal" do
        payout_weekday = seller.payout_weekday
        stripe_double[:refuse_next_create] = Stripe::InvalidRequestError.new("Invalid postal code", "individual[address][postal_code]", code: "postal_code_invalid")
        expect do
          StripeMerchantAccountManager.create_account(seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
        end.to raise_error(Stripe::InvalidRequestError)
        postal_note = seller.comments.alive.with_type_payout_note.select { _1.content.start_with?(StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX) }.sole

        setup = pending_setup_with_lost_create("000111222333")
        own_key = keys.last
        RetryStripeRejectedPayoutSetupForSellerJob.drain

        expect_prepared_on_own_account(setup, own_key)
        postal_note.reload
        expect(postal_note).to be_alive
        expect(postal_note.json_data["abandoned_reason"]).to eq(RetryStripeRejectedPayoutSetupForSellerJob::ABANDONED_REASON_SWITCHED_OFF_STRIPE)
        expect_current_payout_method_kept(payout_weekday:)
      end

      it "starts no provider work and keeps the setup's own note once the seller leaves the rollout" do
        setup = pending_setup_with_lost_create("000111222333")
        own_note = own_outstanding_notes(setup).sole
        own_key = own_note.json_data[key_field]
        Feature.deactivate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
        creates = keys.size

        RetryStripeRejectedPayoutSetupForSellerJob.drain

        expect(keys.size).to eq(creates)
        expect(setup.reload).to be_pending
        own_note.reload
        expect(own_note).to be_alive
        expect(own_note.json_data["abandoned_at"]).to be_blank
        expect(own_note.json_data[key_field]).to eq(own_key)
      end
    end
  end

  it "refuses an actor who is not a team member and a missing reference" do
    setup = prepare_bank

    expect(cancel(setup, cancelled_by: seller).error).to eq(:not_authorized)
    expect(cancel(setup, cancelled_by: nil).error).to eq(:not_authorized)
    expect(cancel(setup, reference: " ").error).to eq(:reference_missing)
    expect(setup.reload).to be_prepared
    expect(setup.merchant_account.reload).to be_alive
  end

  it "leaves an activated rail and its live account alone" do
    setup = prepare_bank
    setup.merchant_account.update!(charge_processor_alive_at: Time.current)
    setup.update!(state: StripePayoutRailSetup::ACTIVATED)

    expect(cancel(setup).error).to eq(:rail_setup_not_open)

    expect(setup.reload.state).to eq(StripePayoutRailSetup::ACTIVATED)
    expect(setup.merchant_account.reload).to be_alive
    expect(setup.merchant_account.charge_processor_alive?).to be(true)
  end
end
