# frozen_string_literal: true

require "spec_helper"

describe Radar::SellerFraudSignalScanService do
  def seller_with_sales(count)
    seller = create(:user)
    product = create(:product, user: seller)
    purchases = Array.new(count) { create(:purchase, link: product) }
    [seller, purchases]
  end

  def dispute(purchase, seller, reason: Dispute::REASON_FRAUDULENT, state: :formalized)
    create(:dispute, purchase:, seller:, reason:, state:, event_created_at: Time.current)
  end

  def efw(purchase)
    create(:early_fraud_warning, purchase:, processor_id: "issfr_#{SecureRandom.hex(8)}")
  end

  def scanned_sellers
    described_class.call[:sellers]
  end

  it "reports a seller whose recent sales are disputed or warned far above the threshold" do
    seller, purchases = seller_with_sales(30)
    purchases.first(4).each { |purchase| dispute(purchase, seller) }
    purchases.last(4).each { |purchase| efw(purchase) }

    expect(scanned_sellers.size).to eq(1)

    scanned = scanned_sellers.first
    expect(scanned[:seller_id]).to eq(seller.id)
    expect(scanned[:email]).to eq(seller.email)
    expect(scanned[:successful_sales]).to eq(30)
    expect(scanned[:disputes]).to eq(4)
    expect(scanned[:efws]).to eq(4)
    expect(scanned[:signals]).to eq(8)
    expect(scanned[:share]).to eq(0.2667)
  end

  it "ignores a seller below the minimum sales floor" do
    seller, purchases = seller_with_sales(20)
    purchases.first(10).each { |purchase| dispute(purchase, seller) }

    expect(scanned_sellers).to be_empty
  end

  it "ignores a seller whose signals stay under the share threshold" do
    seller, purchases = seller_with_sales(30)
    purchases.first(3).each { |purchase| dispute(purchase, seller) }

    expect(scanned_sellers).to be_empty
  end

  it "does not count a dispute that was won" do
    seller, purchases = seller_with_sales(30)
    purchases.first(8).each { |purchase| dispute(purchase, seller, state: :won) }

    expect(scanned_sellers).to be_empty
  end

  it "does not count PayPal-processor disputes, warnings or sales" do
    seller, purchases = seller_with_sales(30)
    paypal_purchases = Array.new(8) do
      purchase = create(:purchase, link: purchases.first.link)
      purchase.update_column(:charge_processor_id, PaypalChargeProcessor.charge_processor_id)
      purchase
    end
    paypal_purchases.each { |purchase| dispute(purchase, seller) }

    expect(scanned_sellers).to be_empty
  end

  it "counts an early fraud warning that hangs off a charge rather than a purchase" do
    seller, purchases = seller_with_sales(30)
    purchases.first(8).each { |purchase| dispute(purchase, seller) }
    create(:early_fraud_warning, purchase: nil, charge: create(:charge, seller:),
                                 processor_id: "issfr_#{SecureRandom.hex(8)}")

    expect(scanned_sellers.first[:efws]).to eq(1)
  end

  it "reports how many of the disputes are marked fraudulent" do
    seller, purchases = seller_with_sales(30)
    dispute(purchases[0], seller, reason: Dispute::REASON_FRAUDULENT)
    dispute(purchases[1], seller, reason: Dispute::REASON_UNRECOGNIZED)
    dispute(purchases[2], seller, reason: Dispute::REASON_PRODUCT_NOT_RECEIVED)
    purchases.last(5).each { |purchase| efw(purchase) }

    scanned = scanned_sellers.first
    expect(scanned[:disputes]).to eq(3)
    expect(scanned[:fraudulent_disputes]).to eq(2)
  end

  it "ranks the highest share first" do
    worse, worse_purchases = seller_with_sales(30)
    worse_purchases.first(12).each { |purchase| dispute(purchase, worse) }
    better, better_purchases = seller_with_sales(30)
    better_purchases.first(8).each { |purchase| dispute(purchase, better) }

    expect(scanned_sellers.map { |seller| seller[:seller_id] }).to eq([worse.id, better.id])
  end

  it "changes nothing about the sellers it reports" do
    seller, purchases = seller_with_sales(30)
    purchases.first(8).each { |purchase| dispute(purchase, seller) }
    risk_state = seller.user_risk_state

    scanned_sellers

    expect(seller.reload.user_risk_state).to eq(risk_state)
    expect(seller.suspended?).to be(false)
  end
end
