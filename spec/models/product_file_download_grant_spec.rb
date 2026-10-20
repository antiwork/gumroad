# frozen_string_literal: true

require "spec_helper"

describe ProductFileDownloadGrant do
  let(:product) { create(:product) }
  let(:product_file) { create(:streamable_video, link: product, stream_only: true) }
  let(:url_redirect) { create(:url_redirect, purchase: create(:purchase, link: product)) }

  it "allows only one grant per buyer and file" do
    described_class.create!(url_redirect:, product_file:)
    duplicate = described_class.new(url_redirect:, product_file:)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:product_file_id]).to be_present
  end

  it "rejects a duplicate even when validations are skipped" do
    described_class.create!(url_redirect:, product_file:)

    expect do
      described_class.new(url_redirect:, product_file:).save!(validate: false)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows the same file to be granted to another buyer" do
    other_redirect = create(:url_redirect, purchase: create(:purchase, link: product))
    described_class.create!(url_redirect:, product_file:)

    expect { described_class.create!(url_redirect: other_redirect, product_file:) }.not_to raise_error
  end
end
