# frozen_string_literal: true

require "spec_helper"

describe Link, "first published date" do
  let(:product) { create(:product, draft: true, purchase_disabled_at: Time.current) }

  it "records the moment a draft first goes live" do
    expect do
      product.publish!
    end.to change { product.reload.first_published_at }.from(nil)
  end

  it "keeps the original date when an unpublished listing goes live again" do
    product.publish!
    first_published_at = product.reload.first_published_at

    travel_to 3.days.from_now do
      product.unpublish!
      product.publish!
    end

    expect(product.reload.first_published_at).to eq(first_published_at)
  end
end
