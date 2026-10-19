# frozen_string_literal: true

require "spec_helper"

describe StripePayoutRailSetups::Provision do
  include_context "with Stripe API stubs"

  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:bank_params) do
    ActionController::Parameters.new(
      bank_account: {
        type: AchAccount.name,
        account_number: "000123456789",
        account_number_confirmation: "000123456789",
        routing_number: "110000000",
        account_holder_full_name: "Synthetic Holder",
      }
    )
  end

  before do
    create(:user_compliance_info_business, user: seller, country: "French Polynesia")
    create(:tos_agreement, user: seller)
    Feature.activate_user(:merchant_migration, seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
  end

  def stage!
    result = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process
    expect(result.success).to be(true)
    result.setup
  end

  def expect_current_payout_method_untouched(payout_weekday:)
    seller.reload
    expect(seller.payment_address).to eq("seller-payouts@example.com")
    expect(seller.active_bank_account).to be_nil
    expect(seller.stripe_account).to be_nil
    expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to be_nil
    expect(seller.current_payout_processor).to eq(PayoutProcessorType::PAYPAL)
    expect(seller.payout_weekday).to eq(payout_weekday)
    expect(seller.has_stripe_account_connected?).to be(false)
    expect(seller.check_merchant_account_is_linked).to be(false)
    expect(seller.stripe_connect_account).to eq(connect_account)
    expect(StripePayoutProcessor.destination_merchant_account(seller, [])).to be_nil
    expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(true)
    expect(HandleNewBankAccountWorker.jobs.size).to eq(0)
  end

  it "prepares a managed account and links the candidate bank without making either live" do
    payout_weekday = seller.payout_weekday
    setup = stage!
    expect(setup).to be_pending
    expect(setup.bank_account).to be_deleted

    result = described_class.new(setup).process

    expect(result.success).to be(true)
    setup.reload
    expect(setup).to be_prepared
    expect(setup.prepared_at).to be_present
    expect(setup.attempt_started_at).to be_nil
    merchant_account = setup.merchant_account
    expect(merchant_account.user).to eq(seller)
    expect(merchant_account.is_a_stripe_connect_account?).to be(false)
    expect(merchant_account).to be_alive
    expect(merchant_account.charge_processor_alive?).to be(false)
    expect(merchant_account.charge_processor_merchant_id).to start_with("acct_mock_")
    expect(merchant_account.country).to eq("US")
    bank_account = setup.bank_account.reload
    expect(bank_account).to be_deleted
    expect(bank_account.stripe_connect_account_id).to eq(merchant_account.charge_processor_merchant_id)
    expect(bank_account.stripe_bank_account_id).to be_present
    expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller)).to be(true)
    expect_current_payout_method_untouched(payout_weekday:)
  end

  it "fails the setup on a known refusal and leaves the current payout method in place" do
    payout_weekday = seller.payout_weekday
    setup = stage!
    allow(Stripe::Account).to receive(:create).and_raise(
      Stripe::InvalidRequestError.new("Invalid account number", "external_account[account_number]", code: "account_number_invalid")
    )

    result = described_class.new(setup).process

    expect(result.success).to be(false)
    expect(result.exception).to be_a(Stripe::InvalidRequestError)
    setup.reload
    expect(setup.state).to eq(StripePayoutRailSetup::FAILED)
    expect(setup.failure_code).to eq("account_number_invalid")
    expect(setup.attempt_started_at).to be_nil
    expect(seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?)).to be_empty
    expect_current_payout_method_untouched(payout_weekday:)
  end

  it "keeps an uncertain outcome pending and replays the same account creation on retry" do
    payout_weekday = seller.payout_weekday
    setup = stage!
    idempotency_keys = []
    attempts = 0
    # Unit control: the first create loses its response; the replay with the same key returns the account.
    allow(Stripe::Account).to receive(:create) do |_params, opts = {}|
      idempotency_keys << opts[:idempotency_key]
      attempts += 1
      raise Stripe::APIConnectionError.new("Connection reset") if attempts == 1

      Stripe::Account.construct_from(
        id: "acct_mock_replayed",
        object: "account",
        country: "US",
        default_currency: "usd",
        charges_enabled: true,
        external_accounts: { object: "list", data: [{ id: "ba_mock_replayed", object: "bank_account", fingerprint: "fp_mock_replayed" }] },
        metadata: {}
      )
    end

    first = described_class.new(setup).process

    expect(first.success).to be(false)
    expect(first.exception).to be_a(Stripe::APIConnectionError)
    expect(setup.reload).to be_pending
    expect(setup.attempt_started_at).to be_nil
    expect_current_payout_method_untouched(payout_weekday:)

    second = described_class.new(setup).process

    expect(second.success).to be(true)
    expect(setup.reload).to be_prepared
    expect(idempotency_keys.size).to eq(2)
    expect(idempotency_keys.uniq.size).to eq(1)
    expect(seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?)).to eq([setup.merchant_account])
    expect_current_payout_method_untouched(payout_weekday:)
  end

  it "does not start a second attempt while one is in flight" do
    setup = stage!
    setup.update!(attempt_started_at: 1.minute.ago)
    expect(Stripe::Account).not_to receive(:create)

    result = described_class.new(setup).process

    expect(result.error).to eq(:rail_setup_not_pending)
    expect(setup.reload).to be_pending
    expect(setup.attempt_started_at).to be_within(1.second).of(1.minute.ago)
  end

  it "does not provision a setup that is already prepared" do
    setup = stage!
    described_class.new(setup).process
    expect(Stripe::Account).not_to receive(:create)

    expect(described_class.new(setup.reload).process.error).to eq(:rail_setup_not_pending)
  end

  it "keeps an in-flight attempt's recovery note when it refuses an ordinary account creation" do
    stage!
    note = seller.add_payout_note(
      content: "#{StripeMerchantAccountManager::NO_VERDICT_FAILURE_NOTE_PREFIX}: awaiting Stripe account creation",
      seller_visible: false,
      json_data: {
        "no_verdict" => true,
        "pending_create" => true,
        StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY => "synthetic-idempotency-key",
        StripeMerchantAccountManager::ACCOUNT_CREATION_ATTEMPTED_AT => Time.current.iso8601,
      }
    )

    expect do
      StripeMerchantAccountManager.create_account(seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
    end.to raise_error(MerchantRegistrationUserAlreadyHasAccountError)

    expect(note.reload).to be_alive
    expect(note.json_data[StripeMerchantAccountManager::ACCOUNT_CREATION_IDEMPOTENCY_KEY]).to eq("synthetic-idempotency-key")
  end

  it "stops the ordinary account creation from opening a live account beside an open setup" do
    stage!

    expect do
      StripeMerchantAccountManager.create_account(seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
    end.to raise_error(MerchantRegistrationUserAlreadyHasAccountError)
    expect do
      StripeMerchantAccountManager.create_account(seller, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"), from_admin: true)
    end.to raise_error(MerchantRegistrationUserAlreadyHasAccountError)
    expect(seller.reload.stripe_account).to be_nil
    expect(seller.merchant_accounts.stripe.reject(&:is_a_stripe_connect_account?)).to be_empty
  end

  describe "attempt fencing" do
    it "lets a worker whose lease was reclaimed neither release nor finish the newer attempt" do
      setup = stage!
      stale_token = StripePayoutRailSetup.claim_attempt!(setup.id, lease: described_class::ATTEMPT_LEASE)
      setup.update_columns(attempt_started_at: (described_class::ATTEMPT_LEASE + 1.minute).ago)
      current_token = StripePayoutRailSetup.claim_attempt!(setup.id, lease: described_class::ATTEMPT_LEASE)
      expect(current_token).to be_present.and(satisfy { |token| token != stale_token })

      expect(setup.finish_attempt!(stale_token)).to be(false)
      expect(setup.finish_attempt!(stale_token, state: StripePayoutRailSetup::FAILED, failure_code: "stale", failed_at: Time.current)).to be(false)
      expect(setup.finish_attempt!(stale_token, state: StripePayoutRailSetup::PREPARED, prepared_at: Time.current)).to be(false)
      setup.reload
      expect(setup).to be_pending
      expect(setup.attempt_token).to eq(current_token)
      expect(setup.attempt_started_at).to be_present
      expect(setup.attempt_count).to eq(2)

      expect(setup.finish_attempt!(current_token)).to be(true)
      expect(setup.reload.attempt_token).to be_nil
    end

    it "keeps the account a reclaimed attempt finished creating and lets the next attempt adopt it" do
      setup = stage!
      creates = 0
      overlapping = nil
      # Unit control: while the first create is outstanding its lease expires and a second worker runs.
      allow(Stripe::Account).to receive(:create) do |params, _opts = {}|
        creates += 1
        setup.update_columns(attempt_started_at: (described_class::ATTEMPT_LEASE + 1.minute).ago)
        overlapping = described_class.new(StripePayoutRailSetup.find(setup.id)).process
        Stripe::Account.construct_from(
          id: "acct_mock_first_attempt", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
          external_accounts: { object: "list", data: [{ id: "ba_mock_first_attempt", object: "bank_account", fingerprint: "fp_mock_first" }] },
          metadata: {}
        )
      end

      stale = described_class.new(setup).process

      expect(overlapping.success).to be(false)
      expect(overlapping.exception).to be_a(MerchantRegistrationUserAlreadyHasAccountError)
      expect(stale.error).to eq(:stale_attempt)
      setup.reload
      expect(setup).to be_pending
      expect(setup.attempt_token).to be_nil
      retained = seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?).sole
      expect(retained.charge_processor_merchant_id).to eq("acct_mock_first_attempt")
      expect(retained.charge_processor_alive?).to be(false)

      adopted = described_class.new(setup).process

      expect(adopted.success).to be(true)
      expect(creates).to eq(1)
      expect(setup.reload).to be_prepared
      expect(setup.merchant_account).to eq(retained)
      expect(seller.reload.stripe_account).to be_nil
    end

    it "does not adopt a newer not-live account another setup opened" do
      setup = stage!
      other_setup = create(:stripe_payout_rail_setup, user: seller, state: StripePayoutRailSetup::FAILED)
      foreign = create(:merchant_account, user: seller, country: "US", charge_processor_alive_at: nil, charge_processor_merchant_id: "acct_synthetic_other_setup",
                                          created_at: setup.created_at + 1.second)
      foreign.update!(rail_setup_id: other_setup.id.to_s)
      expect(foreign.created_at).to be >= setup.created_at
      expect(Stripe::Account).not_to receive(:create)

      result = described_class.new(setup).process

      expect(result.success).to be(false)
      expect(result.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
      expect(setup.reload).to be_pending
      expect(setup.merchant_account).to be_nil
      expect(foreign.reload).to be_alive
    end

    it "keeps the setup pending when the overlapped attempt's account already has its Stripe id" do
      setup = stage!
      overlapping = nil
      # SDK double: while the first worker is adding the representative, after it saved the Stripe id,
      # its lease expires and a second worker runs.
      allow(Stripe::Account).to receive(:create_person) do |_account_id, _params|
        if overlapping.nil?
          setup.update_columns(attempt_started_at: (described_class::ATTEMPT_LEASE + 1.minute).ago)
          overlapping = described_class.new(StripePayoutRailSetup.find(setup.id)).process
        end
        Stripe::StripeObject.construct_from(id: "person_mock_overlap", object: "person")
      end

      first = described_class.new(setup).process

      expect(overlapping.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
      expect(overlapping.error).to eq(:provider_error)
      expect(first.error).to eq(:stale_attempt)
      expect(setup.reload).to be_pending
      expect(setup.failure_code).to be_nil
      retained = seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?).sole
      expect(retained.charge_processor_merchant_id).to be_present

      expect(described_class.new(setup).process.success).to be(true)
      expect(setup.reload.merchant_account).to eq(retained)
    end

    it "does not adopt a linked account whose creation can still fail, so that failure deletes only the creator's own account" do
      setup = stage!
      overlapping = nil
      # The first worker's lease runs out after the bank was linked, while it clears old notes; a second
      # worker runs then, and the note cleanup fails.
      allow(StripeMerchantAccountManager).to receive(:clear_stale_no_verdict_failure_notes).and_wrap_original do |original, *args, **kwargs|
        if overlapping.nil?
          overlapping = travel(described_class::ATTEMPT_LEASE + 1.minute) { described_class.new(StripePayoutRailSetup.find(setup.id)).process }
          raise ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock")
        end
        original.call(*args, **kwargs)
      end

      expect { described_class.new(setup).process }.to raise_error(ActiveRecord::Deadlocked)

      expect(overlapping.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
      expect(setup.reload).to be_pending
      expect(setup.merchant_account).to be_nil
      deleted = seller.merchant_accounts.stripe.reject(&:is_a_stripe_connect_account?).sole
      expect(deleted).not_to be_alive
      expect(StripePayoutRailSetup.where(merchant_account_id: deleted.id)).to be_empty
    end

    it "keeps the in-flight attempt's idempotency key when an overlapping attempt is refused, so recovery replays it" do
      setup = stage!
      keys = []
      overlapping = nil
      # Unit control: the first worker's lease expires while its create is outstanding, a second worker
      # runs, then the first worker is killed before it learns the outcome.
      allow(Stripe::Account).to receive(:create) do |params, opts = {}|
        keys << opts[:idempotency_key]
        if keys.one?
          setup.update_columns(attempt_started_at: (described_class::ATTEMPT_LEASE + 1.minute).ago)
          overlapping = described_class.new(StripePayoutRailSetup.find(setup.id)).process
          raise Sidekiq::Shutdown
        end

        Stripe::Account.construct_from(
          id: "acct_mock_replayed_create", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
          external_accounts: { object: "list", data: [{ id: "ba_mock_replayed_create", object: "bank_account", fingerprint: "fp_mock_replayed" }] },
          metadata: {}
        )
      end

      expect { described_class.new(setup).process }.to raise_error(Sidekiq::Shutdown)
      expect(overlapping.exception).to be_a(MerchantRegistrationUserAlreadyHasAccountError)
      expect(setup.reload).to be_pending
      pending_note = seller.comments.alive.with_type_payout_note.find { _1.json_data["pending_create"] }
      expect(pending_note).to be_present

      travel(StripeMerchantAccountManager::STALE_HOLLOW_ACCOUNT_AGE + 1.minute) do
        expect(described_class.new(setup.reload).process.success).to be(true)
      end

      expect(keys.size).to eq(2)
      expect(keys.uniq.size).to eq(1)
      expect(setup.reload).to be_prepared
      expect(seller.merchant_accounts.alive.stripe.reject(&:is_a_stripe_connect_account?)).to eq([setup.merchant_account])
      expect(seller.reload.stripe_account).to be_nil
    end
  end

  describe "once the seller is no longer eligible" do
    {
      "the rollout gate is closed for the seller" => -> { Feature.deactivate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller) },
      "the flag store cannot be read" => lambda {
        allow(Feature).to receive(:active?).and_call_original
        allow(Feature).to receive(:active?).with(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, anything).and_raise(Redis::CannotConnectError.new("down"))
      },
      "Connect routes card sales" => -> { seller.update!(check_merchant_account_is_linked: true) },
      "the seller is suspended" => -> { seller.update!(user_risk_state: "suspended_for_tos_violation") },
      "the stored Connect row is gone" => -> { connect_account.delete_charge_processor_account! },
    }.each do |description, arrange|
      it "starts no provider work and leaves the pending setup as it was when #{description}" do
        setup = stage!
        instance_exec(&arrange)
        expect(Stripe::Account).not_to receive(:create)

        result = described_class.new(setup).process

        expect(result.success).to be(false)
        expect(result.error).to eq(:not_eligible)
        setup.reload
        expect(setup).to be_pending
        expect(setup.attempt_count).to eq(0)
        expect(setup.attempt_token).to be_nil
        expect(seller.reload.merchant_accounts.stripe.reject(&:is_a_stripe_connect_account?)).to be_empty
      end
    end
  end

  describe "a setup abandoned while Stripe is creating its account" do
    it "retires the account the fenced worker created, so an ordinary bank account can set up payouts" do
      setup = stage!
      # Unit control: Stripe answers only after the seller has disconnected the Connect link.
      allow(Stripe::Account).to receive(:create) do |params, _opts = {}|
        expect(StripeMerchantAccountManager.disconnect(user: seller)).to be_truthy
        Stripe::Account.construct_from(
          id: "acct_mock_abandoned_create", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
          external_accounts: { object: "list", data: [{ id: "ba_mock_abandoned_create", object: "bank_account", fingerprint: "fp_mock_abandoned" }] },
          metadata: {}
        )
      end

      result = described_class.new(setup).process

      expect(result.error).to eq(:stale_attempt)
      expect(setup.reload.state).to eq(StripePayoutRailSetup::FAILED)
      expect(setup.failure_code).to eq("connect_removed")
      created = seller.merchant_accounts.stripe.find_by(charge_processor_merchant_id: "acct_mock_abandoned_create")
      expect(created).not_to be_alive
      expect(created.charge_processor_alive?).to be(false)
      expect(seller.reload.stripe_connect_account).to be_nil
      expect(StripeMerchantAccountManager.blocks_new_managed_account?(seller)).to be(false)

      bank_account = create(:ach_account, user: seller)
      allow(Stripe::Account).to receive(:create) do |params, _opts = {}|
        Stripe::Account.construct_from(
          id: "acct_mock_ordinary_bank", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
          external_accounts: { object: "list", data: [{ id: "ba_mock_ordinary_bank", object: "bank_account", fingerprint: "fp_mock_ordinary" }] },
          metadata: {}
        )
      end
      StripeMerchantAccountManager.create_account(seller.reload, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))

      expect(seller.reload.stripe_account.charge_processor_merchant_id).to eq("acct_mock_ordinary_bank")
      expect(seller.active_bank_account).to eq(bank_account)
    end

    it "keeps the account for a setup that a newer attempt still owns" do
      setup = stage!
      allow(Stripe::Account).to receive(:create) do |params, _opts = {}|
        setup.update_columns(attempt_started_at: (described_class::ATTEMPT_LEASE + 1.minute).ago)
        StripePayoutRailSetup.claim_attempt!(setup.id, lease: described_class::ATTEMPT_LEASE)
        Stripe::Account.construct_from(
          id: "acct_mock_newer_owner", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
          external_accounts: { object: "list", data: [{ id: "ba_mock_newer_owner", object: "bank_account", fingerprint: "fp_mock_newer" }] },
          metadata: {}
        )
      end

      expect(described_class.new(setup).process.error).to eq(:stale_attempt)
      expect(setup.reload).to be_pending
      expect(seller.merchant_accounts.alive.stripe.find_by(charge_processor_merchant_id: "acct_mock_newer_owner")).to be_present
    end
  end

  describe "a debit card candidate" do
    let(:card_params) { ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" }) }
    let(:credit_card) { create(:us_debit_stripe_credit_card) }

    before do
      chargeable = double("chargeable")
      allow(ChargeProcessor).to receive(:get_chargeable_for_params).and_return(chargeable)
      allow(CreditCard).to receive(:create).with(chargeable).and_return(credit_card)
    end

    def stage_card!
      StripePayoutRailSetups::Stage.new(seller:, params: card_params).process.setup
    end

    # Unit control for the provider's charges readiness on the prepared account.
    def stub_charges_enabled(enabled)
      allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
        Stripe::Account.construct_from(
          id: account_id, object: "account", country: "US", default_currency: "usd", charges_enabled: enabled.call,
          external_accounts: { object: "list", data: [{ id: "card_mock_linked", object: "card", fingerprint: "fp_card_mock", currency: "usd", country: "US", available_payout_methods: %w[standard instant] }] },
          metadata: {}
        )
      end
    end

    it "waits for Stripe to enable charges, then links the card to the prepared account without making either live" do
      payout_weekday = seller.payout_weekday
      charges_enabled = false
      stub_charges_enabled(-> { charges_enabled })
      setup = stage_card!

      expect(described_class.new(setup).process.success).to be(true)
      setup.reload
      expect(setup).to be_awaiting_card_link
      expect(setup.bank_account.stripe_connect_account_id).to be_nil
      expect(Stripe::Token).not_to have_received(:create)
      expect_current_payout_method_untouched(payout_weekday:)

      charges_enabled = true
      StripeMerchantAccountManager.handle_stripe_event_account_updated(
        "id" => "evt_synthetic", "type" => "account.updated",
        "data" => { "object" => { "object" => "account", "id" => setup.merchant_account.charge_processor_merchant_id, "charges_enabled" => true, "type" => "custom" } }
      )
      expect(LinkStagedRailCardJob.jobs.size).to eq(1)
      LinkStagedRailCardJob.drain

      setup.reload
      expect(setup).to be_prepared
      card = setup.bank_account.reload
      expect(card).to be_deleted
      expect(card.stripe_connect_account_id).to eq(setup.merchant_account.charge_processor_merchant_id)
      expect(card.stripe_bank_account_id).to eq("card_mock_linked")
      expect(Stripe::Token).to have_received(:create).with({ customer: credit_card.stripe_customer_id }, { stripe_account: setup.merchant_account.charge_processor_merchant_id, idempotency_key: "rail-setup-#{setup.id}-card-#{card.id}-token" })
      expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
      expect_current_payout_method_untouched(payout_weekday:)
    end

    it "fails the card setup when Stripe refuses the card, and retries later when there is no verdict" do
      stub_charges_enabled(-> { true })
      setup = stage_card!
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("Connection reset"))

      described_class.new(setup).process
      expect(setup.reload).to be_awaiting_card_link
      expect(setup.attempt_token).to be_nil

      allow(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("This card doesn't appear to be a debit card.", "external_account", code: "invalid_card_type"))
      expect(StripePayoutRailSetups::LinkStagedCard.new(setup).process).to eq(:failed)
      setup.reload
      expect(setup.state).to eq(StripePayoutRailSetup::FAILED)
      expect(setup.failure_code).to eq("invalid_card_type")
      expect(seller.reload.active_bank_account).to be_nil
    end

    it "hands a link with no verdict to a retried job, which links the card once Stripe answers" do
      stub_charges_enabled(-> { true })
      setup = stage_card!
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::APIConnectionError.new("Connection reset"))

      described_class.new(setup).process

      expect(setup.reload).to be_awaiting_card_link
      expect(LinkStagedRailCardJob.jobs.map { _1["args"] }).to eq([[setup.id]])
      expect { LinkStagedRailCardJob.new.perform(setup.id) }.to raise_error(LinkStagedRailCardJob::RetryLater)
      expect(setup.reload).to be_awaiting_card_link

      allow(Stripe::Account).to receive(:update) { |account_id, *_args| Stripe::Account.retrieve(account_id) }
      LinkStagedRailCardJob.new.perform(setup.id)

      expect(setup.reload).to be_prepared
      expect(setup.bank_account.reload.stripe_bank_account_id).to eq("card_mock_linked")
      expect(setup.bank_account).to be_deleted
      expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
      expect(seller.reload.stripe_account).to be_nil
    end

    it "retries the ready webhook's job when it overlaps the inline link that read charges as disabled" do
      charges_enabled = false
      webhook_job_error = nil
      reads = 0
      setup = stage_card!
      # Unit control: Stripe enables charges while the inline link is reading the account, and the
      # account.updated job runs during that read.
      allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
        reads += 1
        if reads == 1
          charges_enabled = true
          StripeMerchantAccountManager.handle_stripe_event_account_updated(
            "id" => "evt_synthetic_ready", "type" => "account.updated",
            "data" => { "object" => { "object" => "account", "id" => account_id, "charges_enabled" => true, "type" => "custom" } }
          )
          begin
            LinkStagedRailCardJob.drain
          rescue LinkStagedRailCardJob::RetryLater => e
            webhook_job_error = e
          end
          enabled = false
        else
          enabled = charges_enabled
        end
        Stripe::Account.construct_from(
          id: account_id, object: "account", country: "US", default_currency: "usd", charges_enabled: enabled,
          external_accounts: { object: "list", data: [{ id: "card_mock_linked", object: "card", fingerprint: "fp_card_mock", currency: "usd", country: "US", available_payout_methods: %w[standard] }] },
          metadata: {}
        )
      end

      described_class.new(setup).process

      expect(webhook_job_error).to be_a(LinkStagedRailCardJob::RetryLater)
      expect(setup.reload).to be_awaiting_card_link
      expect(setup.attempt_token).to be_nil

      LinkStagedRailCardJob.new.perform(setup.id)

      expect(setup.reload).to be_prepared
      expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
    end

    it "retires the prepared account when Stripe refuses the card, so a different card can be set up next" do
      payout_weekday = seller.payout_weekday
      stub_charges_enabled(-> { true })
      setup = stage_card!
      allow(Stripe::Account).to receive(:update).and_raise(Stripe::InvalidRequestError.new("This card doesn't appear to be a debit card.", "external_account", code: "invalid_card_type"))

      described_class.new(setup).process

      setup.reload
      expect(setup.state).to eq(StripePayoutRailSetup::FAILED)
      refused_account = setup.merchant_account.reload
      expect(refused_account).not_to be_alive
      expect(refused_account.charge_processor_merchant_id).to be_present
      expect_current_payout_method_untouched(payout_weekday:)

      allow(Stripe::Account).to receive(:update) { |account_id, *_args| Stripe::Account.retrieve(account_id) }
      allow(CreditCard).to receive(:create).and_return(create(:us_debit_stripe_credit_card))
      next_setup = stage_card!
      expect(next_setup).not_to eq(setup)

      expect(described_class.new(next_setup).process.success).to be(true)

      next_setup.reload
      expect(next_setup).to be_prepared
      expect(next_setup.merchant_account).not_to eq(refused_account)
      expect(next_setup.merchant_account.charge_processor_alive?).to be(false)
      expect_current_payout_method_untouched(payout_weekday:)
    end

    describe "after the link job's retries are gone" do
      def strand_awaiting_card
        charges_enabled = false
        stub_charges_enabled(-> { charges_enabled })
        setup = stage_card!
        described_class.new(setup).process
        expect(setup.reload).to be_awaiting_card_link
        # The job that would have linked it ran out of retries, or was never enqueued.
        LinkStagedRailCardJob.jobs.clear
        stub_charges_enabled(-> { true })
        setup
      end

      it "is picked up by the weekly payout-setup sweep and linked without going live" do
        payout_weekday = seller.payout_weekday
        setup = strand_awaiting_card

        travel(described_class::ATTEMPT_LEASE + 1.minute) { RetryStripeRejectedPayoutSetupsJob.new.perform }

        expect(LinkStagedRailCardJob.jobs.map { _1["args"] }).to eq([[setup.id]])
        LinkStagedRailCardJob.drain
        setup.reload
        expect(setup).to be_prepared
        expect(setup.bank_account.reload.stripe_bank_account_id).to eq("card_mock_linked")
        expect(setup.bank_account).to be_deleted
        expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
        expect_current_payout_method_untouched(payout_weekday:)
      end

      {
        "the rollout gate is closed" => -> { Feature.deactivate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller) },
        "the seller is suspended" => -> { seller.update!(user_risk_state: "suspended_for_tos_violation") },
        "Connect routes card sales" => -> { seller.update!(check_merchant_account_is_linked: true) },
      }.each do |description, arrange|
        it "does not link the card when #{description}" do
          setup = strand_awaiting_card
          instance_exec(&arrange)

          travel(described_class::ATTEMPT_LEASE + 1.minute) { RetryStripeRejectedPayoutSetupsJob.new.perform }
          expect { LinkStagedRailCardJob.drain }.not_to raise_error

          expect(setup.reload).to be_awaiting_card_link
          expect(Stripe::Token).not_to have_received(:create)
          expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
        end
      end
    end

    it "records what Stripe still needs before it enables charges, once per change" do
      stub_charges_enabled(-> { false })
      setup = stage_card!
      described_class.new(setup).process
      event = {
        "id" => "evt_synthetic_requirements", "type" => "account.updated",
        "data" => { "object" => { "object" => "account", "id" => setup.merchant_account.charge_processor_merchant_id, "charges_enabled" => false,
                                  "type" => "custom", "requirements" => { "currently_due" => ["individual.verification.document"], "past_due" => [], "disabled_reason" => "requirements.past_due" } } }
      }

      2.times { StripeMerchantAccountManager.handle_stripe_event_account_updated(event) }

      notes = seller.comments.alive.with_type_payout_note.select { _1.content.include?("Payout rail setup ##{setup.id}") }
      expect(notes.map(&:content)).to eq(["Payout rail setup ##{setup.id}: Stripe still needs individual.verification.document (requirements.past_due)."])
      expect(notes.sole.json_data[PayoutNoteVisibility::SELLER_VISIBLE_FLAG]).to be(false)
      expect(setup.reload).to be_awaiting_card_link
    end

    it "does not adopt a newer not-live account another setup opened, since a card has no bank link to check" do
      stub_charges_enabled(-> { false })
      setup = stage_card!
      other_setup = create(:stripe_payout_rail_setup, user: seller, state: StripePayoutRailSetup::FAILED)
      foreign = create(:merchant_account, user: seller, country: "US", charge_processor_alive_at: nil, charge_processor_merchant_id: "acct_synthetic_other_card_setup",
                                          created_at: setup.created_at + 1.second)
      foreign.update!(rail_setup_id: other_setup.id.to_s)
      expect(Stripe::Account).not_to receive(:create)

      expect(described_class.new(setup).process.success).to be(false)

      expect(setup.reload).to be_pending
      expect(setup.merchant_account).to be_nil
      expect(foreign.reload).to be_alive
    end

    describe "while an earlier attempt is still creating the account" do
      let(:team_member) { create(:user, is_team_member: true) }

      # SDK double: the first worker's lease runs out while it adds the representative, after the Stripe
      # id was saved; a second worker runs then, and the first worker meets `then_first` when it resumes.
      def overlap_first_person_call(setup, then_first:)
        overlapping = nil
        allow(Stripe::Account).to receive(:create_person) do |_account_id, _params|
          if overlapping.nil?
            overlapping = travel(described_class::ATTEMPT_LEASE + 1.minute) { described_class.new(StripePayoutRailSetup.find(setup.id)).process }
            then_first.call
          end
          Stripe::StripeObject.construct_from(id: "person_mock_card", object: "person")
        end
        -> { overlapping }
      end

      def half_created_account
        seller.merchant_accounts.stripe.reject(&:is_a_stripe_connect_account?).sole
      end

      it "does not adopt it, so a refusal the first worker meets next deletes only its own unrecorded account" do
        payout_weekday = seller.payout_weekday
        stub_charges_enabled(-> { false })
        setup = stage_card!
        overlapping = overlap_first_person_call(setup, then_first: -> { raise Stripe::InvalidRequestError.new("Invalid date of birth", "dob", code: "invalid_dob") })

        first = described_class.new(setup).process

        expect(overlapping.call.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
        expect(first.exception).to be_a(Stripe::InvalidRequestError)
        setup.reload
        expect(setup).to be_pending
        expect(setup.merchant_account).to be_nil
        deleted = half_created_account
        expect(deleted).not_to be_alive
        expect(Stripe::Account).to have_received(:delete).with(deleted.charge_processor_merchant_id).once
        expect(StripePayoutRailSetup.where(merchant_account_id: deleted.id)).to be_empty
        expect(LinkStagedRailCardJob.jobs).to be_empty
        expect(Stripe::Token).not_to have_received(:create)
        expect_current_payout_method_untouched(payout_weekday:)
      end

      it "does not adopt an account left half-created by a worker shut down mid-creation, which staff Cancel then retires" do
        payout_weekday = seller.payout_weekday
        stub_charges_enabled(-> { false })
        setup = stage_card!
        overlapping = overlap_first_person_call(setup, then_first: -> { raise Sidekiq::Shutdown })

        expect { described_class.new(setup).process }.to raise_error(Sidekiq::Shutdown)

        expect(overlapping.call.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
        stranded = half_created_account
        expect(stranded).to be_alive
        expect(stranded.rail_setup_completed_id).to be_nil
        expect(setup.reload).to be_pending
        expect(setup.merchant_account).to be_nil

        expect(described_class.new(setup).process.exception).to be_an_instance_of(MerchantRegistrationUserAlreadyHasAccountError)
        expect(setup.reload).to be_pending
        expect(Stripe::Account).to have_received(:create).once

        expect(StripePayoutRailSetups::Cancel.new(setup:, cancelled_by: team_member, reason_reference: "support-thread-synthetic-8").process.success).to be(true)
        expect(stranded.reload).not_to be_alive
        expect(stranded.charge_processor_merchant_id).to be_present
        expect(Stripe::Account).not_to have_received(:delete)
        expect_current_payout_method_untouched(payout_weekday:)
      end

      it "adopts the account once an earlier attempt finished creating it but never recorded it, then links and activates the card" do
        charges_enabled = false
        stub_charges_enabled(-> { charges_enabled })
        setup = stage_card!
        finishes = 0
        allow_any_instance_of(StripePayoutRailSetup).to receive(:finish_attempt!).and_wrap_original do |original, *args, **kwargs|
          finishes += 1
          raise ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock") if finishes == 1

          original.call(*args, **kwargs)
        end
        expect { described_class.new(setup).process }.to raise_error(ActiveRecord::Deadlocked)
        finished = half_created_account
        expect(setup.reload.merchant_account).to be_nil
        expect(finished.rail_setup_completed_id).to eq(setup.id.to_s)

        expect(described_class.new(setup).process.success).to be(true)

        expect(Stripe::Account).to have_received(:create).once
        expect(setup.reload).to be_awaiting_card_link
        expect(setup.merchant_account).to eq(finished)
        charges_enabled = true
        StripeMerchantAccountManager.handle_stripe_event_account_updated(
          "id" => "evt_synthetic_adopted", "type" => "account.updated",
          "data" => { "object" => { "object" => "account", "id" => finished.charge_processor_merchant_id, "charges_enabled" => true, "type" => "custom" } }
        )
        LinkStagedRailCardJob.drain
        expect(setup.reload).to be_prepared

        # SDK double for the provider readiness read at activation.
        allow(Stripe::Account).to receive(:retrieve).with(finished.charge_processor_merchant_id) do
          Stripe::Account.construct_from(
            id: finished.charge_processor_merchant_id, country: "US", payouts_enabled: true, charges_enabled: true, metadata: { user_compliance_info_id: seller.alive_user_compliance_info.external_id },
            requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
            external_accounts: { object: "list", data: [{ id: "card_mock_linked", object: "card", currency: "usd", country: "US", available_payout_methods: %w[standard instant] }] }
          )
        end
        expect(StripePayoutRailSetups::Activate.new(setup:, activated_by: team_member, consent_reference: "support-thread-synthetic-8").process.success).to be(true)
        expect(seller.reload.stripe_account).to eq(finished)
        expect(seller.active_bank_account).to eq(setup.bank_account)
      end
    end

    it "lets a job for a setup that stopped waiting finish without retrying" do
      stub_charges_enabled(-> { false })
      setup = stage_card!
      described_class.new(setup).process
      setup.reload.abandon!(:connect_removed)

      expect { LinkStagedRailCardJob.new.perform(setup.id) }.not_to raise_error
      expect(Stripe::Token).not_to have_received(:create)
    end

    it "does not link a card for a setup that is no longer waiting for one" do
      stub_charges_enabled(-> { false })
      setup = stage_card!
      described_class.new(setup).process
      setup.reload.abandon!(:connect_removed)

      expect(StripePayoutRailSetups::LinkStagedCard.new(setup).process).to eq(:not_awaiting)
      expect(Stripe::Token).not_to have_received(:create)
    end
  end

  it "resumes an uncertain attempt through Stage with the original candidate and idempotency key" do
    keys = []
    attempts = 0
    # Unit control: the first create loses its response; the replay with the same key returns the account.
    allow(Stripe::Account).to receive(:create) do |params, opts = {}|
      keys << opts[:idempotency_key]
      attempts += 1
      raise Stripe::APIConnectionError.new("Connection reset") if attempts == 1

      Stripe::Account.construct_from(
        id: "acct_mock_resumed", object: "account", country: params[:country], default_currency: "usd", charges_enabled: true,
        external_accounts: { object: "list", data: [{ id: "ba_mock_resumed", object: "bank_account", fingerprint: "fp_mock_resumed" }] },
        metadata: {}
      )
    end
    first_setup = stage!
    described_class.new(first_setup).process
    expect(first_setup.reload).to be_pending

    resumed = StripePayoutRailSetups::Stage.new(seller:, params: bank_params).process
    expect(resumed.setup).to eq(first_setup)
    described_class.new(resumed.setup).process

    expect(first_setup.reload).to be_prepared
    expect(keys.size).to eq(2)
    expect(keys.uniq.size).to eq(1)
    expect(seller.bank_accounts.count).to eq(1)
  end
end
