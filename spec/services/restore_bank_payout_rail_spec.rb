# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe RestoreBankPayoutRail do
  let(:user) { create(:named_user) }
  let!(:compliance_info) { create(:user_compliance_info, user:, country: "India") }
  let!(:merchant_account) { create(:merchant_account, user:, country: "IN") }
  let!(:bank_account) { create(:indian_bank_account, user:, stripe_connect_account_id: merchant_account.charge_processor_merchant_id) }

  def switch_to_paypal!
    params = ActionController::Parameters.new(payment_address: "paypal@example.com", confirm_bank_rail_loss: "true")
    expect(UpdatePayoutMethod.new(user_params: params, seller: user).process).to eq(success: true)
    user.reload
  end

  def stub_stripe_account(**attrs)
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id)
      .and_return(Stripe::Account.construct_from({ id: merchant_account.charge_processor_merchant_id, country: "IN", payouts_enabled: true }.merge(attrs)))
  end

  before { stub_stripe_account }

  it "revives the bank account and merchant account a PayPal switch removed, and clears the PayPal address" do
    switch_to_paypal!
    expect(user.active_bank_account).to be_nil
    expect(user.stripe_account).to be_nil

    result = described_class.new(user:).process

    expect(result.success).to be(true)
    user.reload
    expect(user.active_bank_account).to eq(bank_account)
    expect(user.stripe_account).to eq(merchant_account)
    expect(merchant_account.reload).to have_attributes(deleted_at: nil, charge_processor_deleted_at: nil)
    expect(merchant_account.charge_processor_alive_at).to be_present
    expect(user.payment_address).to be_blank
    expect(user.can_setup_bank_payouts?).to be(true)
  end

  it "refuses a US rail removed by a completed country change to India" do
    compliance_info.mark_deleted!
    create(:user_compliance_info, user:, country: "United States")
    merchant_account.update!(country: "US")
    bank_account.destroy!
    us_bank_account = create(:ach_account, user:, stripe_connect_account_id: merchant_account.charge_processor_merchant_id)
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    UpdateUserCountry.new(new_country_code: "IN", user: user.reload).process
    stub_stripe_account(country: "US")

    result = described_class.new(user: user.reload).process

    expect(result.success).to be(false)
    expect(result.error).to eq(:incompatible_bank_rail)
    expect(us_bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "refuses an Indian rail removed by a country change even after returning to India" do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    UpdateUserCountry.new(new_country_code: "US", user:).process
    UpdateUserCountry.new(new_country_code: "IN", user: user.reload).process
    user.update!(payment_address: "paypal@example.com")

    result = described_class.new(user: user.reload).process

    expect(result.success).to be(false)
    expect(result.error).to eq(:not_removed_by_paypal_switch)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
    expect(user.reload.payment_address).to eq("paypal@example.com")
  end

  it "refuses a deleted bank account from a different country" do
    bank_account.destroy!
    us_bank_account = create(:ach_account, user:, stripe_connect_account_id: merchant_account.charge_processor_merchant_id)
    switch_to_paypal!

    result = described_class.new(user:).process

    expect(result.error).to eq(:incompatible_bank_rail)
    expect(us_bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "refuses a deleted merchant account from a different country" do
    switch_to_paypal!
    merchant_account.update!(country: "US")

    result = described_class.new(user:).process

    expect(result.error).to eq(:incompatible_bank_rail)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "refuses a payable Stripe account from a different country" do
    switch_to_paypal!
    stub_stripe_account(country: "US")

    result = described_class.new(user:).process

    expect(result.error).to eq(:incompatible_bank_rail)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "refuses a Stripe account whose country cannot be verified" do
    switch_to_paypal!
    stub_stripe_account(country: nil)

    result = described_class.new(user:).process

    expect(result.error).to eq(:incompatible_bank_rail)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "restores a historical Indian PayPal rail after a same-country compliance revision" do
    merchant_account.update!(created_at: 2.years.ago)
    bank_account.update_columns(created_at: 2.years.ago)
    travel_to 1.year.ago do
      switch_to_paypal!
    end
    compliance_info.mark_deleted!
    create(:user_compliance_info, user:, country: "India")

    result = described_class.new(user: user.reload).process

    expect(result.success).to be(true)
    expect(user.reload.active_bank_account).to eq(bank_account)
    expect(user.stripe_account).to eq(merchant_account)
  end

  it "refuses where the seller can re-create the rail themselves" do
    compliance_info.mark_deleted!
    create(:user_compliance_info, user:, country: "Egypt")
    switch_to_paypal!

    result = described_class.new(user:).process

    expect(result.error).to eq(:rail_recreatable)
    expect(user.reload.payment_address).to eq("paypal@example.com")
  end

  it "refuses when a bank account is already active" do
    result = described_class.new(user:).process

    expect(result.success).to be(false)
    expect(result.error).to eq(:bank_account_already_active)
  end

  it "refuses when there is nothing to restore" do
    bank_account.destroy!

    result = described_class.new(user:).process

    expect(result.error).to eq(:no_deleted_bank_account)
  end

  # Other flows soft-delete bank rows on their own (country change, payout recovery); only the
  # pair a PayPal switch removed in one go comes back.
  it "refuses a bank account that was not removed together with its merchant account" do
    switch_to_paypal!
    merchant_account.update_columns(charge_processor_deleted_at: 3.days.ago)

    result = described_class.new(user:).process

    expect(result.error).to eq(:not_removed_by_paypal_switch)
    expect(user.reload.active_bank_account).to be_nil
  end

  it "refuses when Stripe no longer has the account, leaving everything deleted" do
    switch_to_paypal!
    stub_stripe_account(deleted: true)

    result = described_class.new(user:).process

    expect(result.error).to eq(:stripe_account_unavailable)
    expect(user.reload.active_bank_account).to be_nil
    expect(user.payment_address).to eq("paypal@example.com")
  end

  it "refuses when Stripe still has the account but has disabled payouts on it" do
    switch_to_paypal!
    stub_stripe_account(payouts_enabled: false, requirements: { disabled_reason: "rejected.fraud" })

    result = described_class.new(user:).process

    expect(result.error).to eq(:stripe_account_unavailable)
    expect(user.reload.active_bank_account).to be_nil
  end

  it "does not revive on top of a bank account saved while it waited for the lock" do
    switch_to_paypal!
    service = described_class.new(user:)
    allow(user).to receive(:with_lock).and_wrap_original do |original, &block|
      create(:indian_bank_account, user:, account_number: "000987654321", account_number_last_four: "4321")
      original.call(&block)
    end

    result = service.process

    expect(result.error).to eq(:bank_account_already_active)
    expect(user.bank_accounts.alive.count).to eq(1)
    expect(merchant_account.reload.deleted_at).to be_present
  end

  it "refuses if the country changes while Stripe is being checked" do
    switch_to_paypal!
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    allow(Stripe::Account).to receive(:retrieve).and_wrap_original do |_original, *_args|
      UpdateUserCountry.new(new_country_code: "EG", user: User.find(user.id)).process
      Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, country: "IN", payouts_enabled: true)
    end

    result = described_class.new(user:).process

    expect(result.error).to eq(:rail_recreatable)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
  end

  it "refuses if compliance changes while Stripe is being checked" do
    switch_to_paypal!
    allow(Stripe::Account).to receive(:retrieve).and_wrap_original do |_original, *_args|
      result = UpdateUserComplianceInfo.new(
        compliance_params: ActionController::Parameters.new(is_business: true, business_country: "EG"),
        user: User.find(user.id)
      ).process
      expect(result[:success]).to be(true)
      Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, country: "IN", payouts_enabled: true)
    end

    result = described_class.new(user:).process

    expect(result.error).to eq(:rail_recreatable)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
    expect(user.reload.payment_address).to eq("paypal@example.com")
  end

  it "refuses a different provider account than the one checked" do
    switch_to_paypal!
    allow(Stripe::Account).to receive(:retrieve).and_wrap_original do |_original, *_args|
      merchant_account.update!(charge_processor_merchant_id: "acct_replaced")
      Stripe::Account.construct_from(id: "acct_original", country: "IN", payouts_enabled: true)
    end

    result = described_class.new(user:).process

    expect(result.error).to eq(:payout_rail_changed)
    expect(bank_account.reload).to be_deleted
    expect(merchant_account.reload).to be_deleted
    expect(user.reload.payment_address).to eq("paypal@example.com")
  end

  it "does not revive when the seller becomes able to re-create the rail while it waited for the lock" do
    switch_to_paypal!
    service = described_class.new(user:)
    allow(user).to receive(:with_lock).and_wrap_original do |original, &block|
      compliance_info.mark_deleted!
      create(:user_compliance_info, user:, country: "Egypt")
      original.call(&block)
    end

    result = service.process

    expect(result.error).to eq(:rail_recreatable)
    expect(user.reload.active_bank_account).to be_nil
    expect(merchant_account.reload.deleted_at).to be_present
  end
end


describe RestoreBankPayoutRail, "concurrent compliance writers" do
  self.use_transactional_tests = false

  before do
    @user = create(:named_user, payment_address: "")
    @compliance_info = create(:user_compliance_info, user: @user, country: "India")
    stub_const("GUMROAD_ADMIN_ID", @user.id)
  end

  after do
    @user.comments.destroy_all
    @user.user_compliance_infos.destroy_all
    @user.destroy!
  end

  %i[country compliance].each do |writer|
    it "keeps #{writer} changes out of a restore's locked section" do
      if writer == :country
        @compliance_info.mark_deleted!
        @compliance_info = create(:user_compliance_info, user: @user, country: "Cuba")
      end
      @user.with_lock do
        thread = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection.execute("SET SESSION innodb_lock_wait_timeout = 1")
            other_user = User.find(@user.id)
            if writer == :country
              UpdateUserCountry.new(new_country_code: "IR", user: other_user).process
            else
              UpdateUserComplianceInfo.new(
                compliance_params: ActionController::Parameters.new(is_business: true, business_country: "EG"),
                user: other_user
              ).process
            end
            :changed
          rescue ActiveRecord::LockWaitTimeout
            :blocked
          ensure
            connection.execute("SET SESSION innodb_lock_wait_timeout = DEFAULT")
          end
        end
        expect(Timeout.timeout(10) { thread.value }).to eq(:blocked)
        expect(@compliance_info.reload).not_to be_deleted
      ensure
        thread&.join(10)
      end
    end
  end
end
