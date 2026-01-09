# frozen_string_literal: true

describe("Product Page - Shipping Scenarios Address verification", type: :system, js: true) do
  describe "US address" do
    before do
      @user = create(:user)
      @product = create(:physical_product, user: @user, require_shipping: true, price_cents: 100_00)
      @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
      @product.save!
    end

    it "shows that the address is not valid but will let the purchase through if user says yes" do
      # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
      exception = EasyPost::Errors::EasyPostError.new
      expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_raise(exception)

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product, should_verify_address: true)

      purchase = Purchase.last
      expect(purchase.street_address).to eq("1640 17th St")
      expect(purchase.city).to eq("San Francisco")
      expect(purchase.state).to eq("CA")
      expect(purchase.zip_code).to eq("94107")
    end

    it "shows that the address is missing some information" do
      # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
      easy_post = EasyPost::Client.new(api_key: GlobalConfig.get("EASYPOST_API_KEY"))
      address = easy_post.address.create(
        verify: ["delivery"],
        street1: "255 Nonexistent St",
        city: "San Francisco",
        state: "CA",
        zip: "94107",
        country: "US"
      )

      verified_address = easy_post.address.create(
        verify: ["delivery"],
        street1: "255 King St Apt 602",
        city: "San Francisco",
        state: "CA",
        zip: "94107",
        country: "US"
      )

      allow_any_instance_of(EasyPost::Services::Address).to receive(:create).and_return(address)

      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, error: true)

      expect(page).to have_text("We are unable to verify your shipping address. Is your address correct?")
      click_on "No"

      expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_return(verified_address)

      check_out(@product, address: { street: "255 King St Apt 602" })

      purchase = Purchase.last
      expect(purchase.street_address).to eq("255 KING ST APT 602")
      expect(purchase.city).to eq("SAN FRANCISCO")
      expect(purchase.state).to eq("CA")
      expect(purchase.zip_code).to eq("94107")
    end

    it "lets purchase with valid address through" do
      # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
      easy_post = EasyPost::Client.new(api_key: GlobalConfig.get("EASYPOST_API_KEY"))
      address = easy_post.address.create(
        verify: ["delivery"],
        street1: "1640 17th St",
        city: "San Francisco",
        state: "CA",
        zip: "94107",
        country: "US"
      )
      expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_return(address)

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product)

      expect(page).not_to have_text("We are unable to verify your shipping address. Is your address correct?")

      purchase = Purchase.last
      expect(purchase.street_address).to eq("1640 17TH ST")
      expect(purchase.city).to eq("SAN FRANCISCO")
      expect(purchase.state).to eq("CA")
      expect(purchase.zip_code).to eq("94107")
    end

    describe "address verification confirmation prompt" do
      it "lets a buyer choose to use a verified address to complete their purchase" do
        visit "/l/#{@product.unique_permalink}"
        add_to_cart(@product)
        check_out(@product, address: { street: "255 King St #602" }, error: true)

        expect(page).to(have_content("You entered this address:\n255 King St #602, San Francisco, CA, 94107"))
        expect(page).to(have_content("We recommend using this format:\n255 King St Apt 602, San Francisco, CA, 94107"))

        click_on "Yes, update"

        expect(page).to have_alert("Your purchase was successful!")

        purchase = Purchase.last
        expect(purchase.street_address).to eq("255 KING ST APT 602")
        expect(purchase.city).to eq("SAN FRANCISCO")
        expect(purchase.state).to eq("CA")
        expect(purchase.zip_code).to eq("94107")
      end

      it "lets a buyer choose not to use a verified address to complete their purchase" do
        visit "/l/#{@product.unique_permalink}"
        add_to_cart(@product)
        check_out(@product, address: { street: "255 King St #602" }, error: true)

        expect(page).to(have_content("You entered this address:\n255 King St #602, San Francisco, CA, 94107"))
        expect(page).to(have_content("We recommend using this format:\n255 King St Apt 602, San Francisco, CA, 94107"))

        click_on "No, continue"

        expect(page).to have_alert("Your purchase was successful!")

        purchase = Purchase.last
        expect(purchase.street_address).to eq("255 King St #602")
        expect(purchase.city).to eq("San Francisco")
        expect(purchase.state).to eq("CA")
        expect(purchase.zip_code).to eq("94107")
      end

      it "does not allow the purchase if the buyer chooses not to use a verified address and the zip code is wrong for a taxable product" do
        visit "/l/#{@product.unique_permalink}"
        add_to_cart(@product)
        check_out(@product, address: { street: "255 King St #602", zip_code: "invalid" }, error: true)

        expect(page).to(have_content("You entered this address:\n255 King St #602, San Francisco, CA, inval"))
        expect(page).to(have_content("We recommend using this format:\n255 King St Apt 602, San Francisco, CA, 94107"))

        click_on "No, continue"

        expect(page).to(have_alert("You entered a ZIP Code that doesn't exist within your country."))
        expect(Purchase.count).to eq(0)
      end
    end
  end

  describe "international address" do
    it "shows that the address is not valid but will let the purchase through if user says yes" do
      @user = create(:user)

      @product = create(:physical_product, user: @user, require_shipping: true, price_cents: 100_00)
      @product.shipping_destinations << ShippingDestination.new(country_code: "CA", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
      @product.save!

      # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
      exception = EasyPost::Errors::EasyPostError.new
      expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_raise(exception)

      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product, address: { city: "Burnaby", state: "BC", zip_code: "V3N 4H4" }, country: "Canada", should_verify_address: true)

      expect(page).to have_alert("Your purchase was successful!")

      purchase = Purchase.last
      expect(purchase.street_address).to eq("1640 17th St")
      expect(purchase.city).to eq("Burnaby")
      expect(purchase.state).to eq("BC")
      expect(purchase.zip_code).to eq("V3N 4H4")
      expect(purchase.country).to eq("Canada")
    end

    it "lets purchase with valid address through" do
      # have to mock EasyPost calls because the timeout throws before EasyPost responds in testing
      easy_post = EasyPost::Client.new(api_key: GlobalConfig.get("EASYPOST_API_KEY"))
      address = easy_post.address.create(
        verify: ["delivery"],
        street1: "9384 Cardston Ct",
        city: "Burnaby",
        state: "BC",
        zip: "V3N 4H4",
        country: "CA"
      )
      expect_any_instance_of(EasyPost::Services::Address).to receive(:create).and_return(address)

      @user = create(:user)

      @product = create(:physical_product, user: @user, require_shipping: true, price_cents: 100_00)
      @product.shipping_destinations << ShippingDestination.new(country_code: "US", one_item_rate_cents: 2000, multiple_items_rate_cents: 1000)
      @product.save!

      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)
      check_out(@product, address: { street: "9384 Cardston Ct", city: "Burnaby", state: "BC", zip_code: "V3N 4H4" }, country: "Canada")

      expect(page).not_to have_text("We are unable to verify your shipping address. Is your address correct?")

      expect(page).to have_alert("Your purchase was successful!")

      purchase = Purchase.last
      expect(purchase.street_address).to eq("9384 CARDSTON CT")
      expect(purchase.city).to eq("BURNABY")
      expect(purchase.state).to eq("BC")
      expect(purchase.zip_code).to eq("V3N 4H4")
      expect(purchase.country).to eq("Canada")
    end
  end
end
