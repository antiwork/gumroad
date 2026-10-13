# frozen_string_literal: true

require "spec_helper"

describe Onetime::RelabelAffiliateGumroadHeldBalances do
  let(:seller) { create(:user) }
  let(:affiliate_user) { create(:affiliate_user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:gumroad_account) do
    create(:merchant_account, user: nil, currency: Currency::USD,
                              charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
  end
  let(:booked_at) { Time.utc(2026, 9, 25, 9, 0) }
  let(:fix_deployed_at) { Time.utc(2026, 9, 29, 4, 53) }

  def service(balance_ids:, dry_run: true)
    described_class.new(balance_ids:, fix_deployed_at:, dry_run:)
  end

  def create_mislabelled_affiliate_balance(cents: 62, currency: Currency::EUR, credit_cents: cents, user: affiliate_user)
    purchase = create(:purchase, seller:, link: product, created_at: booked_at, succeeded_at: booked_at)
    direct_affiliate = create(:direct_affiliate, affiliate_user: user, seller:)

    bt = travel_to(booked_at) do
      BalanceTransaction.create!(
        user:,
        merchant_account: gumroad_account,
        purchase:,
        issued_amount: BalanceTransaction::Amount.new(currency:, gross_cents: cents, net_cents: cents),
        holding_amount: BalanceTransaction::Amount.new(currency:, gross_cents: cents, net_cents: cents),
        update_user_balance: true,
      )
    end
    AffiliateCredit.create!(purchase:, affiliate: direct_affiliate, affiliate_amount_cents: credit_cents,
                            affiliate_fee_cents: 0, affiliate_balance: bt.balance)

    [Balance.find(bt.balance_id), bt]
  end

  it "reports without changing anything on a dry run" do
    balance, bt = create_mislabelled_affiliate_balance

    result = service(balance_ids: [balance.id]).process

    expect(result[:stats][:corrected]).to eq(1)
    expect(balance.reload.holding_currency).to eq(Currency::EUR)
    expect(bt.reload.holding_amount_currency).to eq(Currency::EUR)
  end

  it "relabels balance and balance transactions to USD without changing any cents" do
    balance, bt = create_mislabelled_affiliate_balance(cents: 62)

    result = service(balance_ids: [balance.id], dry_run: false).process

    expect(result[:stats][:corrected]).to eq(1)
    balance.reload
    expect([balance.currency, balance.holding_currency]).to eq([Currency::USD, Currency::USD])
    expect([balance.amount_cents, balance.holding_amount_cents]).to eq([62, 62])
    bt.reload
    expect([bt.issued_amount_currency, bt.holding_amount_currency]).to eq([Currency::USD, Currency::USD])
    expect([bt.issued_amount_net_cents, bt.holding_amount_net_cents]).to eq([62, 62])
  end

  it "refuses a row whose cents differ from the affiliate credit" do
    balance, = create_mislabelled_affiliate_balance(cents: 62, credit_cents: 70)

    result = service(balance_ids: [balance.id], dry_run: false).process

    expect(result[:stats][:bt_credit_cents_mismatch]).to eq(1)
    expect(balance.reload.holding_currency).to eq(Currency::EUR)
  end

  it "refuses a seller-leg row (balance user is the purchase seller)" do
    balance, = create_mislabelled_affiliate_balance(user: seller)

    result = service(balance_ids: [balance.id], dry_run: false).process

    expect(result[:stats][:bt_not_affiliate_leg]).to eq(1)
    expect(balance.reload.holding_currency).to eq(Currency::EUR)
  end

  it "refuses a balance that is no longer unpaid" do
    balance, = create_mislabelled_affiliate_balance
    balance.update_columns(state: "processing")

    result = service(balance_ids: [balance.id], dry_run: false).process

    expect(result[:stats][:not_unpaid]).to eq(1)
    expect(balance.reload.holding_currency).to eq(Currency::EUR)
  end

  it "skips balances that are already USD" do
    balance, = create_mislabelled_affiliate_balance(currency: Currency::USD)

    result = service(balance_ids: [balance.id], dry_run: false).process

    expect(result[:stats][:already_usd]).to eq(1)
  end

  it "refuses balance transactions created after the USD booking deployed" do
    balance, = create_mislabelled_affiliate_balance
    late = described_class.new(balance_ids: [balance.id], fix_deployed_at: booked_at - 1.day, dry_run: false).process

    expect(late[:stats][:bt_created_after_fix]).to eq(1)
  end
end
