# frozen_string_literal: true

module PreviewBoxHelpers
  # The preview sidebar no longer renders a visible "Preview" heading (the browser-style
  # PreviewChrome bar identifies it instead), so locate the region by its aria-label.
  def in_preview(&block)
    preview = find("aside[aria-label='Preview']")
    scroll_to preview
    within preview do
      block.call
    end
  end

  def expect_current_step(step)
    if step === :product_preview
      expect(page).to have_selector(".product-main")
    elsif step === :purchase_form
      expect(page).to have_section("Checkout")
    elsif step === :receipt
      expect(page).to have_section("Your purchase was successful!")
    elsif step === :content
      expect(page).to have_selector("[role=tree][aria-label=Files]")
    elsif step === :rich_content
      expect(page).to have_selector("[aria-label='Product content']")
    else
      expect(false).to be true
    end
  end
end
