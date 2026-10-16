# frozen_string_literal: true

require "spec_helper"

describe "Product description image size", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  # [natural width, rendered width, figure width] for each description image, once all have loaded.
  def image_widths
    page.document.synchronize do
      widths = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll(".rich-text figure img")).map((img) =>
          img.complete && img.naturalWidth > 0
            ? [img.naturalWidth, img.getBoundingClientRect().width, img.closest("figure").getBoundingClientRect().width]
            : null
        )
      JS
      raise Capybara::ExpectationNotMet, "description images have not loaded" if widths.empty? || widths.include?(nil)
      widths
    end
  end

  it "shows an image narrower than the description at its own width" do
    product = create(:product, user: seller, description: '<figure><img src="/images/user-avatar.png"><p class="figcaption"></p></figure>')

    visit short_link_path(product)

    natural_width, rendered_width, figure_width = image_widths.sole
    expect(natural_width).to eq(184)
    expect(rendered_width).to eq(184)
    expect(figure_width).to be > 184
  end

  it "shrinks an image wider than the description to the description's width" do
    product = create(:product, user: seller, description: '<figure><img src="/images/opengraph_image.png"><p class="figcaption"></p></figure>')

    visit short_link_path(product)

    natural_width, rendered_width, figure_width = image_widths.sole
    expect(natural_width).to eq(1200)
    expect(rendered_width).to be_within(1).of(figure_width)
    expect(rendered_width).to be < 1200
  end
end
