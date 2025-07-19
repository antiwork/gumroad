require 'rails_helper'

RSpec.feature "Checkout with discount and upsell", type: :feature, js: true do
  let(:seller) { create(:user) }
  let(:buyer_email) { "buyer@example.com" }
  
  let(:product) do
    create(:product, 
      user: seller,
      name: "Basic Plan",
      price: 50_00,
      enable_variants: true
    )
  end
  
  let(:basic_variant) do
    create(:variant,
      product: product,
      name: "Basic",
      price_diff: 0
    )
  end
  
  let(:premium_variant) do
    create(:variant,
      product: product,
      name: "Premium",
      price_diff: 50_00
    )
  end
  
  let(:discount_code) do
    create(:offer_code,
      user: seller,
      code: "SAVE20",
      amount_off: 20,
      offer_type: "percentage",
      universal: true
    )
  end
  
  let!(:upsell) do
    create(:upsell,
      product: product,
      offered_variant: premium_variant,
      original_variant: basic_variant,
      text: "Upgrade to Premium!",
      description: "Get more features with Premium"
    )
  end

  scenario "discount code is preserved when accepting an upsell offer" do
    # Visit product page with discount code
    visit product_path(product, offer_code: discount_code.code)
    
    # Select basic variant
    find("label", text: "Basic").click
    
    # Add to cart
    click_button "Add to cart"
    
    # Verify discount is applied to basic variant (40.00 instead of 50.00)
    within(".cart-summary") do
      expect(page).to have_content("$40.00")
      expect(page).to have_content("SAVE20")
    end
    
    # Fill in checkout form
    fill_in "Email", with: buyer_email
    fill_in "Card number", with: "4242424242424242"
    fill_in "Expiry", with: "12/30"
    fill_in "CVC", with: "123"
    
    # Click pay - this should trigger the upsell modal
    click_button "Pay"
    
    # Upsell modal should appear
    within(".modal") do
      expect(page).to have_content("Upgrade to Premium!")
      
      # Accept the upsell
      click_button "Upgrade"
    end
    
    # Verify the discount is now applied to the premium variant
    # Premium is $100, with 20% off = $80
    within(".cart-summary") do
      expect(page).to have_content("$80.00")
      expect(page).to have_content("SAVE20")
      expect(page).to have_content("Premium")
    end
    
    # Complete the purchase
    click_button "Pay"
    
    # Verify receipt shows discounted premium price
    expect(page).to have_content("Thank you for your purchase")
    expect(page).to have_content("Premium")
    expect(page).to have_content("$80.00")
  end
  
  scenario "discount code from URL is preserved but manually entered codes are validated" do
    # Visit with URL discount
    visit product_path(product, offer_code: discount_code.code)
    
    # Add basic variant to cart
    find("label", text: "Basic").click
    click_button "Add to cart"
    
    # Manually add another discount code (should not transfer on upsell)
    within(".checkout-form") do
      fill_in "discount-code-input", with: "MANUAL10"
      click_button "Apply"
    end
    
    # Trigger upsell
    fill_in "Email", with: buyer_email
    fill_in "Card number", with: "4242424242424242"
    fill_in "Expiry", with: "12/30"
    fill_in "CVC", with: "123"
    click_button "Pay"
    
    # Accept upsell
    within(".modal") do
      click_button "Upgrade"
    end
    
    # Only URL discount should transfer
    within(".cart-summary") do
      expect(page).to have_content("SAVE20")
      expect(page).not_to have_content("MANUAL10")
    end
  end
  
  scenario "discount validation prevents invalid discount transfers" do
    # Create a variant-specific discount code
    variant_specific_discount = create(:offer_code,
      user: seller,
      code: "BASICONLY",
      amount_off: 30,
      offer_type: "percentage",
      universal: false,
      products: [product],
      variants: [basic_variant]
    )
    
    # Visit with variant-specific discount
    visit product_path(product, offer_code: variant_specific_discount.code)
    find("label", text: "Basic").click
    click_button "Add to cart"
    
    # Verify discount is applied to basic variant
    within(".cart-summary") do
      expect(page).to have_content("$35.00") # 50 * 0.7
      expect(page).to have_content("BASICONLY")
    end
    
    # Trigger upsell
    fill_in "Email", with: buyer_email
    fill_in "Card number", with: "4242424242424242"
    fill_in "Expiry", with: "12/30"
    fill_in "CVC", with: "123"
    click_button "Pay"
    
    # Accept upsell
    within(".modal") do
      click_button "Upgrade"
    end
    
    # Discount should not transfer since it's variant-specific
    within(".cart-summary") do
      expect(page).to have_content("$100.00") # Full price
      expect(page).not_to have_content("BASICONLY")
      expect(page).to have_content("Premium")
    end
  end
end
