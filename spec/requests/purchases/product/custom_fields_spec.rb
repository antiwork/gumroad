# frozen_string_literal: true

require("spec_helper")

describe("Product checkout - custom fields", type: :system, js: true) do
  before do
    @product = create(:product)
  end

  it "prefills custom fields from query params, except for terms acceptance" do
    @product.custom_fields << [
      create(:custom_field, type: "text", name: "your nickname"),
      create(:custom_field, type: "checkbox", name: "extras"),
      create(:custom_field, type: "terms", name: "http://example.com")
    ]
    @product.save!

    visit "/l/#{@product.unique_permalink}?your%20nickname=test&extras=true&#{CGI.escape "http://example.com"}=true"
    add_to_cart(@product)
    wait_for_ajax

    expect(page).to have_field("your nickname (optional)", with: "test")

    expect(page).to have_checked_field("extras (optional)")

    expect(page).not_to have_checked_field("I accept Terms and Conditions")
  end

  it "validates required text and checkbox fields, and always validates terms acceptance, lets purchase when all valid" do
    @product.custom_fields << [
      create(:custom_field, type: "text", name: "your nickname", required: true),
      create(:custom_field, type: "checkbox", name: "extras", required: true),
      create(:custom_field, type: "terms", name: "http://example.com")
    ]
    @product.save!

    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product, error: true)
    expect(find_field("your nickname")["aria-invalid"]).to eq "true"

    fill_in "your nickname", with: "test"
    check_out(@product, error: true)
    expect(find_field("extras")["aria-invalid"]).to eq "true"

    check "extras"
    check_out(@product, error: true)
    expect(find_field("I accept")["aria-invalid"]).to eq "true"

    check "I accept"
    check_out(@product)

    purchase = Purchase.last
    expect(purchase.custom_fields).to eq(
      [
        { name: "your nickname", value: "test", type: CustomField::TYPE_TEXT },
        { name: "extras", value: true, type: CustomField::TYPE_CHECKBOX },
        { name: "http://example.com", value: true, type: CustomField::TYPE_TERMS }
      ]
    )
  end

  it "does not require optional inputs to be filled or optional checkboxes to be checked, purchase goes through" do
    @product.custom_fields << [
      create(:custom_field, type: "text", name: "your nickname"),
      create(:custom_field, type: "checkbox", name: "extras"),
    ]
    @product.save!

    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product)

    purchase = Purchase.last
    expect(purchase.custom_fields).to eq([{ name: "extras", value: false, type: CustomField::TYPE_CHECKBOX }])
  end

  context "with multiple products" do
    let(:seller1) { create(:user, custom_fields: [create(:custom_field, name: "Full Name", global: true, required: true)]) }
    let(:seller2) { create(:user, custom_fields: [create(:custom_field, name: "Full Name", global: true)]) }
    let(:seller1_product1) { create(:product, name: "Product 1-1", user: seller1) }
    let(:seller1_product2) { create(:product, name: "Product 1-2", user: seller1) }
    let(:seller2_product1) { create(:product, name: "Product 2-1", user: seller2) }
    let(:seller2_product2) { create(:product, name: "Product 2-2", user: seller2) }

    before do
      create(:custom_field, type: CustomField::TYPE_CHECKBOX, name: "Business?", seller: seller1, products: [seller1_product1, seller1_product2])
      create(:custom_field, type: CustomField::TYPE_TERMS, name: "https://example.com", seller: seller2, products: [seller2_product1, seller2_product2], collect_per_product: true)
      create(:custom_field, type: CustomField::TYPE_TEXT, name: "Only one product", seller: seller2, products: [seller2_product1], collect_per_product: true)
    end

    it "groups custom fields by seller" do
      [seller1_product1, seller1_product2, seller2_product1, seller2_product2].each do |product|
        visit product.long_url
        add_to_cart(product)
      end

      within_section seller1.username, section_element: :section do
        fill_in "Full Name", with: "John Doe"
        expect(page).to have_unchecked_field("Business? (optional)")
        expect(page).not_to have_selector(:fieldset, seller1_product1.name)
        expect(page).not_to have_selector(:fieldset, seller1_product2.name)
      end

      within_section seller2.username, section_element: :section do
        expect(page).to have_field("Full Name")
        within_fieldset(seller2_product1.name) do
          check "I accept"
          fill_in "Only one product", with: "test"
        end
        within_fieldset(seller2_product2.name) do
          check "I accept"
        end
      end

      check_out(seller1_product1)

      order = Order.last
      expect(order.purchases.find_by(link: seller1_product1).custom_fields).to eq(
        [{ name: "Full Name", value: "John Doe", type: CustomField::TYPE_TEXT }, { name: "Business?", value: false, type: CustomField::TYPE_CHECKBOX }]
      )
      expect(order.purchases.find_by(link: seller1_product2).custom_fields).to eq(
        [{ name: "Full Name", value: "John Doe", type: CustomField::TYPE_TEXT }, { name: "Business?", value: false, type: CustomField::TYPE_CHECKBOX }]
      )
      expect(order.purchases.find_by(link: seller2_product1).custom_fields).to eq(
        [{ name: "https://example.com", value: true, type: CustomField::TYPE_TERMS }, { name: "Only one product", value: "test", type: CustomField::TYPE_TEXT }]
      )
      expect(order.purchases.find_by(link: seller2_product2).custom_fields).to eq(
        [{ name: "https://example.com", value: true, type: CustomField::TYPE_TERMS }]
      )
    end
  end
end
