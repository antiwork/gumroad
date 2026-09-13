# frozen_string_literal: true

require "spec_helper"

# THROWAWAY capture for PR 7607 evidence — delete after use, never commit.
RSpec.describe "pr7607 refund-email capture" do
  it "renders the KRW partial-refund email to disk" do
    seller = create(:user, name: "Ellis Kim")
    product = create(:product, user: seller, name: "Korea Field Guide", price_cents: 999)
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
    purchase = create(:purchase, link: product, seller:)
    create(:purchase_presentment, purchase:, presentment_currency: Currency::KRW,
                                  presentment_price_cents: 13_889, presentment_gumroad_tax_cents: 0,
                                  presentment_total_cents: 13_889, presentment_gumroad_amount_cents: 1_389)
    purchase.reload

    mail = CustomerMailer.partial_refund("buyer@example.com", product.id, purchase.id, 500, "partially", 6_945, Currency::KRW)
    html = mail.body.encoded
    html = html.gsub(/=\r?\n/, "").gsub("=3D", "=").gsub("=E2=80=99", "'").gsub("=E2=82=", "€")

    label = ENV.fetch("GR_LABEL")
    File.write("/tmp/media/pr7607-refund-krw-#{label}.html", html)
    puts "CAPTURE #{label}: shows_6945=#{html.include?('6,945') || html.include?('6945')}"
    puts "CAPTURE #{label}: shows_69_45=#{html.include?('69.45')}"
    puts "CAPTURE #{label}: subject=#{mail.subject.inspect}"
  end
end