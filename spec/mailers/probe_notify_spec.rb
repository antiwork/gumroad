# frozen_string_literal: true

require "spec_helper"

describe "probe notifications through the mailer" do
  let(:seller) { create(:named_user) }
  let(:product) { create(:product, user: seller, name: "Affiliated Product", price_cents: 20_00) }
  let(:collaborator) { create(:collaborator, seller:, affiliate_basis_points: 40_00, products: [product]) }
  let(:purchase) { create(:purchase_in_progress, affiliate: collaborator, link: product, seller:) }

  before do
    purchase.process!
    purchase.update_balance_and_mark_successful!
  end

  it "no stub: do notifications fire" do
    names = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| names << [payload[:name], payload[:cached]] }
    mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
    _ = mail.body.encoded
    ActiveSupport::Notifications.unsubscribe(sub)
    puts "NOSTUB #{names.inspect}"
    expect(names).to be_an(Array)
  end

  it "with stub: do notifications fire" do
    names = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| names << [payload[:name], payload[:cached]] }
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).and_call_original
    mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
    _ = mail.body.encoded
    ActiveSupport::Notifications.unsubscribe(sub)
    puts "STUB #{names.inspect}"
    expect(names).to be_an(Array)
  end
end
