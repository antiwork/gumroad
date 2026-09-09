# frozen_string_literal: true

describe Order::PreparePaymentIntentService do
  let(:seller) { build_stubbed(:user) }
  let(:purchase) { double(seller:, link: double(unique_permalink: "product")) }
  let(:order) { double(id: 123) }
  let(:params) { {} }
  let(:service) { described_class.new(order:, params:, confirmation_token: "unused") }
  let(:reported) do
    { "permalink" => "product", "price_cents" => 1200, "tip_cents" => 100,
      "shipping_cents" => 0, "tax_cents" => 50, "total_cents" => 1350 }
  end
  let(:actual) do
    double(purchase:, presentment_price_cents: 1200, presentment_tip_cents: 100,
           presentment_shipping_cents: 0, presentment_total_cents: 1350)
  end

  before do
    allow(service).to receive(:purchases_to_charge).and_return([purchase])
    allow(service).to receive(:gumroad_amount_cents).and_return(100)
    allow(Rails.logger).to receive(:info)
  end

  def sign(allocations: [reported], sellers: [seller], currency: Currency::CAD)
    Checkout::DirectListedAmountToken.issue(allocations:, sellers:, currency:)
  end

  def reject_with(reason, allocations: [actual])
    listed = double(allocations:)
    allow(Charge::DirectListedPresentment).to receive(:new).and_return(listed)
    expect(listed).not_to receive(:perform)
    decision = double(currency: Currency::CAD)

    expect(service.send(:direct_listed_presentment_for, double, decision)).to be_nil
    expect(service.instance_variable_get(:@direct_listed_amount_mismatch)).to eq(true)
    expect(Rails.logger).to have_received(:info).with(
      "Direct-listed client-confirm amount changed before prepare for order 123; refusing the stale Payment Element amount; reason=#{reason}"
    )
  end

  it "logs an invalid signature without logging the supplied token" do
    params[:direct_listed_amount_token] = "sensitive-invalid-token"
    reject_with(:invalid_or_expired_token)
  end

  it "logs an expired token as unverifiable without attempting to decode it again" do
    params[:direct_listed_amount_token] = sign
    travel(Checkout::DirectListedAmountToken::TTL + 1.second) { reject_with(:invalid_or_expired_token) }
  end

  it "logs the seller mismatch before a simultaneous currency mismatch" do
    params[:direct_listed_amount_token] = sign(sellers: [build_stubbed(:user)], currency: Currency::EUR)
    reject_with(:seller_mismatch)
  end

  it "logs a currency mismatch" do
    params[:direct_listed_amount_token] = sign(currency: Currency::EUR)
    reject_with(:currency_mismatch)
  end

  it "logs malformed signed allocations" do
    params[:direct_listed_amount_token] = Rails.application.message_verifier(Checkout::DirectListedAmountToken::PURPOSE).generate(
      { "sellers" => [seller.id], "currency" => Currency::CAD, "allocations" => [] },
      purpose: Checkout::DirectListedAmountToken::PURPOSE
    )
    reject_with(:invalid_allocations)
  end

  it "logs a different allocation count" do
    params[:direct_listed_amount_token] = sign(allocations: [reported, reported])
    reject_with(:allocation_count_mismatch)
  end

  %w[permalink price_cents tip_cents shipping_cents].each do |field|
    it "logs a #{field} component mismatch before comparing totals" do
      changed = reported.merge(field => (field == "permalink" ? "other-product" : 99), "total_cents" => 1)
      params[:direct_listed_amount_token] = sign(allocations: [changed])
      reject_with(:component_mismatch)
    end
  end

  it "logs an above-reviewed total after matching components" do
    params[:direct_listed_amount_token] = sign(allocations: [reported.merge("total_cents" => 1349)])
    reject_with(:above_reviewed_total)
  end

  it "includes the reason at the method-forced rejection log site" do
    params[:direct_listed_amount_token] = sign(currency: Currency::EUR)
    service.instance_variable_set(:@previewed_payment_method_type, "ideal")
    allow(service).to receive(:intent_forced_currency).and_return(Currency::CAD)
    allow(service).to receive(:free_and_test_lines_share_currency?).and_return(true)
    allow(service).to receive(:client_confirm_buyer_currency_decision).and_return(double(eligible?: false))
    allow(purchase.link).to receive(:price_currency_type).and_return(Currency::CAD)
    allow(Charge::DirectListedPresentment).to receive(:new).and_return(double(allocations: [actual]))

    expect(service.send(:client_confirm_presentment_for, double)).to be_nil
    expect(Rails.logger).to have_received(:info).with(
      "Direct-listed client-confirm amount changed before prepare for order 123; refusing the stale Payment Element amount; reason=currency_mismatch"
    )
  end

  [nil, 1350, 1400].each do |total|
    it "accepts #{total || 'absent'} reviewed total without a rejection reason" do
      params[:direct_listed_amount_token] = sign(allocations: [reported.merge("total_cents" => total)]) if total
      expect(service.send(:direct_listed_allocations_match?, [actual], Currency::CAD)).to eq(true)
      expect(service.instance_variable_get(:@direct_listed_amount_rejection_reason)).to be_nil
    end
  end
end
