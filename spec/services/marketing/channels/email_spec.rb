# frozen_string_literal: true

require "spec_helper"

describe Marketing::Channels::Email do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:utm_link) { create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id) }
  let(:action) { create(:marketing_action, user: seller, link: product, channel: "email", utm_link:) }

  before do
    create(:payment_completed, user: seller)
    allow(seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
  end

  it "returns the draft's edit path and posts nothing" do
    result = described_class.new(action).call

    draft = seller.installments.alive.find_by(installment_type: Installment::AUDIENCE_TYPE)
    expect(result.action).to eq(action)
    expect(result.edit_url).to eq(Rails.application.routes.url_helpers.edit_email_path(draft.external_id))
    expect(result.intent_url).to be_nil
    expect(result.connect_path).to be_nil
  end

  it "returns no edit path for a seller who cannot email yet" do
    allow(seller).to receive(:sales_cents_total).and_return(0)

    expect(described_class.new(action).call.edit_url).to be_nil
  end
end
