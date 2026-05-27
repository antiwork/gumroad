# frozen_string_literal: true

require "spec_helper"

describe Page do
  let(:product) { create(:product) }

  it "normalizes blank custom_html to nil" do
    page = described_class.create!(pageable: product, custom_html: "")

    expect(page.reload.custom_html).to be_nil
  end

  it "normalizes custom_html to nil when sanitization removes all content" do
    page = described_class.create!(pageable: product, custom_html: %(<script src="https://evil.com/x.js"></script>))

    expect(page.reload.custom_html).to be_nil
  end
end
