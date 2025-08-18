# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Purchases from the product page", type: :system, js: true) do
  before do
    @user = create(:named_user)
    @product = create(:product, user: @user, custom_receipt: "<h1>Hello</h1>")
  end

  it "shows quantity selector only when quantity of the link is greater than 1" do
    physical_link = create(:physical_product, max_purchase_count: 1)
    visit "/l/#{physical_link.unique_permalink}"
    expect(page).not_to have_field("Quantity")

    physical_link.update_attribute(:max_purchase_count, 2)

    visit "/l/#{physical_link.unique_permalink}"
    expect(page).to have_field("Quantity")
  end

  describe "already bought notice" do
    it "shows already bought notice if so" do
      @product = create(:product_with_pdf_file)
      @user = create(:user, email: "bought@gumroad.com")
      @purchase = create(:purchase, link: @product, email: "bought@gumroad.com", purchaser: @user)
      @url_redirect = create(:url_redirect, purchase: @purchase)

      login_as @user
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
      expect(page).to have_link("View content", href: @url_redirect.download_page_url)
    end

    it "shows custom view content text for already bought notice" do
      @product = create(:product_with_pdf_file)
      @product.save_custom_view_content_button_text("Custom Text")
      @user = create(:user, email: "bought@gumroad.com")
      @purchase = create(:purchase, link: @product, email: "bought@gumroad.com", purchaser: @user)
      @url_redirect = create(:url_redirect, purchase: @purchase)

      login_as @user
      visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
      expect(page).to have_link("Custom Text", href: @url_redirect.download_page_url)
    end

    it "shows already bought notice and 'View content' button even when there are no files" do
      @user = create(:user, email: "bought@gumroad.com")
      @purchase = create(:purchase, link: @product, purchaser: @user)
      @url_redirect = create(:url_redirect, purchase: @purchase)

      login_as @user
      visit @product.long_url
      expect(page).to have_text("You've purchased this product")
      expect(page).to have_text("View content")
    end

    describe "autofilling email address" do
      context "when buyer is logged in" do
        before do
          @buyer = create(:user)
          login_as @buyer
        end

        context "and has an email address" do
          it "autofills the buyer's email address and prevents editing" do
            visit @product.long_url
            click_on "I want this!"
            expect(page).to have_field("Email address", with: @buyer.email, disabled: true)
          end
        end

        context "and doesn't have an email address" do
          it "doesn't autofill the email address or prevent editing" do
            @buyer.email = nil
            @buyer.save!(validate: false)
            visit @product.long_url
            click_on "I want this!"
            expect(page).to have_field("Email address", with: "", disabled: false)
          end
        end
      end

      context "when buyer is not logged in" do
        it "doesn't autofill the email address" do
          visit @product.long_url
          click_on "I want this!"
          expect(page).to have_field("Email address", with: "")
        end
      end
    end

    context "for a membership" do
      before do
        user = create(:user)
        @purchase = create(:membership_purchase, email: user.email, purchaser: user)
        @manage_membership_url = Rails.application.routes.url_helpers.manage_subscription_url(@purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
        @product = @purchase.link
        login_as user
      end

      it "shows manage membership button for an active membership" do
        visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
        expect(page).to have_link "Manage membership", href: @manage_membership_url
      end

      it "shows restart membership button for an inactive membership" do
        @purchase.subscription.update!(cancelled_at: 1.minute.ago)
        visit "#{@product.user.subdomain_with_protocol}/l/#{@product.unique_permalink}"
        expect(page).to have_link "Restart membership", href: @manage_membership_url
      end
    end
  end

  it "allows test purchase for creators" do
    creator = create(:user)
    link = create(:product, user: creator, price_cents: 200)
    login_as(creator)

    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"

    add_to_cart(link)
    check_out(link, logged_in_user: creator)
  end

  it "allows test purchase for creators with auto-filled full name" do
    creator = create(:named_user)
    link = create(:product, user: creator, price_cents: 200)
    login_as(creator)

    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"
    add_to_cart(link)
    check_out(link, logged_in_user: creator)
  end

  it "displays and saves the full name field if the user is not the product owner" do
    visit "/l/#{@product.unique_permalink}"

    add_to_cart(@product)
    check_out(@product)

    expect(Purchase.last.full_name).to eq "Gumhead Moneybags"
  end

  it "sends customer email and name to Stripe for fraud detection" do
    product = create(:product, price_cents: 2500)

    visit product.long_url

    add_to_cart(product)
    check_out(product, email: "test+stripe@gumroad.com")

    stripe_billing_details = Stripe::PaymentMethod.retrieve(Purchase.last.stripe_card_id).billing_details
    expect(stripe_billing_details.email).to eq "test+stripe@gumroad.com"
    expect(stripe_billing_details.name).to eq "Gumhead Moneybags"
  end

  context "when an active account already exists for the purchase email" do
    before do
      @purchase_email = "test@gumroad.com"
      create(:user, email: @purchase_email)
    end

    it "does not show sign up form on the checkout receipt" do
      visit "/l/#{@product.unique_permalink}"

      add_to_cart(@product)
      check_out(@product, email: @purchase_email)
    end
  end

  it "has correct recommendation info when bought via receipt" do
    allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
    visit "/l/#{@product.unique_permalink}?recommended_by=receipt"
    expect do
      add_to_cart(@product, recommended_by: "receipt")
      check_out(@product)
    end.to change { @product.sales.successful.select(&:was_discover_fee_charged?).count }.by(1)
       .and change { @product.sales.successful.select(&:was_product_recommended?).count }.by(1)
       .and change { RecommendedPurchaseInfo.where(recommendation_type: "receipt").count }.by(1)
  end

  it "retrieves the url parameters from the query string, strips out reserved url parameters and queues endpoint notification job" do
    user = create(:user, notification_endpoint: "http://www.notification_endpoint.com")
    link = create(:product, user:)

    visit("/l/#{link.unique_permalink}?source_url=http://nathanbarry.com/authority&first_param=testparam&second_param=testparamagain&code=blah")

    add_to_cart(link)
    check_out(link)


    # `"code" => "blah"` should not be considered a URL parameter because 'code' is a reserved word.
    expected_job_args = [
      Purchase.last.id,
      { "first_param" => "testparam", "second_param" => "testparamagain", "source_url" => "http://nathanbarry.com/authority" }
    ]
    expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(*expected_job_args)
  end

  it "shows the quick purchase form for a plain vanilla product with a saved CC" do
    link = create(:product, price_cents: 200)
    user = create(:user, credit_card: create(:credit_card))
    login_as(user)
    visit "#{link.user.subdomain_with_protocol}/l/#{link.unique_permalink}"
    add_to_cart(link)
    check_out(link, logged_in_user: user)
  end

  it "shows default view content button text on receipt after successful purchase" do
    product = create(:product_with_files)
    product2 = create(:product)
    expect(product.custom_view_content_button_text.blank?).to be(true)
    visit "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"
    add_to_cart(product)
    visit product2.long_url
    add_to_cart(product2)
    product2.update!(price_cents: 600)
    check_out(product2, error: "The price just changed! Refresh the page for the updated price.")
    expect(page).to have_link("View content")
  end

  it "shows the view content button on the purchase receipt for a product having rich content" do
    product = create(:product)
    product2 = create(:product)
    visit product.long_url
    add_to_cart(product)
    visit product2.long_url
    add_to_cart(product2)
    product2.update(price_cents: 600)
    check_out(product2, error: "The price just changed! Refresh the page for the updated price.")

    expect(page).to have_link("View content")

    # Should see 'View content' button on the canonical purchase receipt page
    visit receipt_purchase_url(Purchase.last.external_id, email: Purchase.last.email, host: "#{PROTOCOL}://#{DOMAIN}")
    expect(page).to have_link("View content")

    # Should see 'View content' button on the product page itself once purchased
    visit "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"
    expect(page).to have_text("You've purchased this product")
    expect(page).to have_link("View content")
  end

  describe "discord integration" do
    let(:integration) { create(:discord_integration) }
    let(:product) { create(:product, price_range: "0+", customizable_price: true) }

    def buy_product(product)
      visit "#{product.user.subdomain_with_protocol}/l/#{product.unique_permalink}"
      add_to_cart(product, pwyw_price: 0)
      check_out(product, is_free: true)
    end

    describe "Join Discord" do
      it "shows the join discord button if integration is present on purchased product" do
        product.active_integrations << integration
        buy_product(product)

        expect(page).to have_button "Join Discord"
      end

      it "does not show the join discord button if integration is not present on purchased product" do
        buy_product(product)

        expect(page).to_not have_button "Join Discord"
      end
    end
  end

  it "shows custom view content button text on receipt after successful purchase" do
    product = create(:product_with_files)
    product2 = create(:product)
    product.save_custom_view_content_button_text("Custom Text")
    visit product.long_url
    add_to_cart(product)
    visit product2.long_url
    add_to_cart(product2)
    product2.update(price_cents: 600)
    check_out(product2, error: "The price just changed! Refresh the page for the updated price.")
    expect(page).to have_link("Custom Text")
  end

  it "records product events correctly for a product with custom permalink" do
    product = create(:product_with_pdf_file, custom_permalink: "custom", description: Faker::Lorem.paragraphs(number: 100).join(" "))
    product2 = create(:product)
    user = create(:user, credit_card: create(:credit_card))
    login_as(user)

    visit product.long_url
    scroll_to first("footer")
    click_on "I want this!", match: :first

    Timeout.timeout(Capybara.default_max_wait_time) do
      until Event.where(event_name: "i_want_this", link_id: product.id).count == 1 do
        sleep 0.5
      end
    end

    visit product2.long_url
    add_to_cart(product2)

    Timeout.timeout(Capybara.default_max_wait_time) do
      until Event.where(event_name: "i_want_this", link_id: product2.id).count == 1 do
        sleep 0.5
      end
    end

    product2.update!(price_cents: 500)

    check_out(product2, logged_in_user: user, error: "The price just changed! Refresh the page for the updated price.")
    Timeout.timeout(Capybara.default_max_wait_time) do
      until Event.where(event_name: "process_payment", link_id: product.id).count == 1 do
        sleep 0.5
      end
    end

    click_on "View content"
    Timeout.timeout(Capybara.default_max_wait_time) do
      until Event.where(event_name: "receipt_view_content", link_id: product.id).count == 1 do
        sleep 0.5
      end
    end

    visit product.long_url
    click_on "View content"
    Timeout.timeout(Capybara.default_max_wait_time) do
      until Event.where(event_name: "product_information_view_product", link_id: product.id).count == 1 do
        sleep 0.5
      end
    end
  end

  it "allows the purchase for a zip code plus 4" do
    creator = create(:user)
    link = create(:product, price_cents: 200, user: creator)

    visit "/l/#{link.unique_permalink}"
    add_to_cart(link)
    check_out(link, zip_code: "94104-5401")

    purchase = Purchase.last
    expect(purchase.successful?).to be true
    expect(purchase.zip_code).to eq "94104-5401"
  end

  it "ignores native paypal card and allows purchase" do
    customer = create(:user)
    native_paypal_card = create(:credit_card, chargeable: create(:native_paypal_chargeable), user: customer)
    customer.credit_card = native_paypal_card
    customer.save!

    creator = create(:user)
    link = create(:product, price_cents: 200, user: creator)

    # Creator adds support for native paypal payments
    create(:merchant_account_paypal, user: creator, charge_processor_merchant_id: "CJS32DZ7NDN5L", currency: "gbp")

    login_as(customer)

    visit "/l/#{link.unique_permalink}"
    add_to_cart(link)
    uncheck "Save card"
    check_out(link, logged_in_user: customer)

    purchase = Purchase.last
    expect(purchase.successful?).to be true
    expect(purchase.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
    expect(purchase.credit_card).to be_nil
  end

  it "changes email to lowercase before purchase" do
    email = "test@gumroad.com"
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product, email: email.upcase)
    expect(Purchase.last.email).to eq email.downcase
  end

  it "stores a purchase event" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    check_out(@product)
    purchase = Purchase.last!
    event = Event.purchase.last!
    expect(event.purchase_id).to eq(purchase.id)
    expect(event.browser).to match(/Mozilla/)
  end

  it "assigns a license key to a purchase if the link supports it" do
    link = create(:product, user: create(:user))
    link.is_licensed = true
    link.save!
    visit("/l/#{link.unique_permalink}")
    add_to_cart(link)
    check_out(link)
    purchase = Purchase.last
    expect(purchase.license).to_not be(nil)
    expect(purchase.link.licenses.count).to eq 1
  end

  it "does not show the 'charged your card' message when purchasing a pre-order product" do
    preorder_product = create(:product, is_in_preorder_state: true)
    create(:preorder_link, link: preorder_product)
    visit "/l/#{preorder_product.unique_permalink}"

    add_to_cart(preorder_product)
    check_out(preorder_product)

    expect(page).to have_content("We sent a receipt to test@gumroad.com")
    expect(page).to have_text("$1")
  end

  describe "not for sale" do
    it "shows an alert and doesn't allow purchase when product is sold out" do
      @product = create(:product, max_purchase_count: 0)

      visit @product.long_url
      expect(page).to have_text("Sold out, please go back and pick another option.")
      expect(page).not_to have_text("I want this!")
    end

    it "shows an alert and doesn't allow purchase when product is unpublished" do
      @product = create(:product_with_pdf_file)
      @product.publish!
      @product.unpublish!

      visit @product.long_url
      expect(page).to have_text("This product is not currently for sale.")
      expect(page).not_to have_text("I want this!")
    end

    it "doesn't show an alert and allows purchase when product is a draft" do
      @product = create(:product)

      visit @product.long_url
      expect(page).not_to have_text("This product is not currently for sale.")
      expect(page).to have_text("I want this!")
    end
  end

  describe "analytics" do
    before do
      @product2 = create(:product)
    end

    context "when there is only one purchase" do
      it "doesn't mark the purchase as a bundle purchase" do
        visit @product.long_url
        add_to_cart(@product)
        check_out(@product)
        expect(Purchase.last.is_multi_buy).to eq(false)
      end
    end

    context "when there is more than one purchase" do
      it "marks the purchases as a bundle purchase" do
        visit @product.long_url
        add_to_cart(@product)
        visit @product2.long_url
        add_to_cart(@product2)
        check_out(@product2)
        expect(Purchase.last.is_multi_buy).to eq(true)
        expect(Purchase.second_to_last.is_multi_buy).to eq(true)
      end
    end

    it "sets the referrer correctly for all cart items" do
      @product3 = create(:product)
      visit "#{@product.long_url}?referrer=#{CGI.escape("https://product.com?size=M&color=red+guava")}"
      add_to_cart(@product)
      visit "#{@product2.long_url}?referrer=https://product2.com"
      add_to_cart(@product2)
      visit @product3.long_url
      add_to_cart(@product3)
      check_out(@product3)

      expect(Purchase.last.referrer).to eq("https://product.com?size=M&color=red+guava")
      expect(Purchase.second_to_last.referrer).to eq("https://product2.com")
      expect(Purchase.third_to_last.referrer).to eq("direct")
      expect(Event.last.referrer_domain).to eq("product.com")
      expect(Event.second_to_last.referrer_domain).to eq("product2.com")
      expect(Event.third_to_last.referrer_domain).to eq("direct")
    end
  end

  context "when an authenticated buyer purchases multiple products" do
    before do
      @product1 = create(:product, name: "Product 1")
      @product2 = create(:product, name: "Product 2")
      @user = create(:user)
      login_as(@user)
    end

    it "redirects to the library page on purchase success" do
      visit @product1.long_url
      add_to_cart(@product1)
      visit @product2.long_url
      add_to_cart(@product2)
      check_out(@product2, logged_in_user: @user)

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{@user.email}.")
      expect(page.current_path).to eq("/library")
      expect(page).to have_section(@product1.name)
      expect(page).to have_section(@product2.name)
    end
  end

  context "when an unauthenticated buyer purchases multiple products" do
    before do
      @product1 = create(:product, name: "Product 1")
      @product2 = create(:product_with_digital_versions, name: "Product 2")
    end

    it "redirects to the library page on purchase success" do
      visit @product1.long_url
      add_to_cart(@product1)
      visit @product2.long_url
      add_to_cart(@product2, option: "Untitled 1")
      check_out(@product2)

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
      expect(page).to have_link(@product1.name, href: Purchase.last.url_redirect.download_page_url)
      expect(page).to have_link("#{@product2.name} - Untitled 1", href: Purchase.second_to_last.url_redirect.download_page_url)
      expect(page).to have_text("Create an account to access all of your purchases in one place")
      expect(page).to have_field("Email", with: "test@gumroad.com")
    end
  end

  describe "with combined_charge feature enabled" do
    before do
      @seller = create(:user)
      @product1 = create(:product, name: "Product 1", user: @seller)
      @product2 = create(:product, name: "Product 2", user: @seller)
      @product3 = create(:product_with_digital_versions, name: "Product 3", user: @seller)

      @seller2 = create(:user)
      @product4 = create(:product, name: "Product 4", user: @seller2)
      @product5 = create(:product, name: "Product 5", user: @seller2)
      @product6 = create(:product_with_digital_versions, name: "Product 6", user: @seller2)

      @buyer = create(:user)

      expect_any_instance_of(OrdersController).to receive(:create).and_call_original
      expect(PurchasesController).not_to receive(:create)
    end

    context "when an authenticated buyer purchases multiple products from different sellers" do
      before do
        login_as(@buyer)
      end

      it "redirects to the library page on purchase success" do
        visit @product1.long_url
        add_to_cart(@product1)
        visit @product2.long_url
        add_to_cart(@product2)
        visit @product4.long_url
        add_to_cart(@product4)
        visit @product5.long_url
        add_to_cart(@product5)
        check_out(@product5, logged_in_user: @buyer)

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{@buyer.email}.")
        expect(page.current_path).to eq("/library")
        expect(page).to have_section(@product1.name)
        expect(page).to have_section(@product2.name)
        expect(page).to have_section(@product4.name)
        expect(page).to have_section(@product5.name)
      end
    end

    context "when an unauthenticated buyer purchases multiple products from different sellers" do
      it "redirects to the library page on purchase success" do
        visit @product1.long_url
        add_to_cart(@product1)
        visit @product3.long_url
        add_to_cart(@product3, option: "Untitled 1")
        visit @product4.long_url
        add_to_cart(@product4)
        visit @product6.long_url
        add_to_cart(@product6, option: "Untitled 1")
        check_out(@product6)

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
        expect(page).to have_link(@product1.name, href: Purchase.last.url_redirect.download_page_url)
        expect(page).to have_link("#{@product3.name} - Untitled 1", href: Purchase.second_to_last.url_redirect.download_page_url)
        expect(page).to have_link(@product4.name, href: Purchase.last(3).first.url_redirect.download_page_url)
        expect(page).to have_link("#{@product6.name} - Untitled 1", href: Purchase.last(4).first.url_redirect.download_page_url)
        expect(page).to have_text("Create an account to access all of your purchases in one place")
        expect(page).to have_field("Email", with: "test@gumroad.com")
      end
    end

    context "when an authenticated buyer purchases multiple products from same seller" do
      before do
        login_as(@buyer)
      end

      it "redirects to the library page on purchase success" do
        visit @product1.long_url
        add_to_cart(@product1)
        visit @product2.long_url
        add_to_cart(@product2)
        check_out(@product2, logged_in_user: @buyer)

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{@buyer.email}.")
        expect(page.current_path).to eq("/library")
        expect(page).to have_section(@product1.name)
        expect(page).to have_section(@product2.name)
      end
    end

    context "when an unauthenticated buyer purchases multiple products from same seller" do
      it "redirects to the library page on purchase success" do
        visit @product1.long_url
        add_to_cart(@product1)
        visit @product3.long_url
        add_to_cart(@product3, option: "Untitled 1")
        check_out(@product3)

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")
        expect(page).to have_link(@product1.name, href: Purchase.last.url_redirect.download_page_url)
        expect(page).to have_link("#{@product3.name} - Untitled 1", href: Purchase.second_to_last.url_redirect.download_page_url)
        expect(page).to have_text("Create an account to access all of your purchases in one place")
        expect(page).to have_field("Email", with: "test@gumroad.com")
      end
    end
  end

  describe "customer moderation" do
    context "when buyer's email is blocked by seller" do
      before do
        BlockedCustomerObject.block_email!(email: "test@gumroad.com", seller_id: @user.id)

        @buyer = create(:user, email: "test@gumroad.com")
        login_as @buyer
      end

      context "when the product is free" do
        before do
          @product.update!(price_cents: 0)
        end

        it "fails the purchase with an error" do
          visit @product.long_url
          add_to_cart(@product, pwyw_price: 0)

          expect do
            check_out(@product, logged_in_user: @buyer, is_free: true, error: "Your card was not charged, as the creator has prevented you from purchasing this item. Please contact them for more information.")
          end.to change { Purchase.count }.by(1)
          .and change { @user.blocked_customer_objects.active.count }.by(0)

          purchase = Purchase.last
          expect(purchase.successful?).to be(false)
          expect(purchase.email).to eq(@buyer.email)
          expect(purchase.error_code).to eq(PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS)
          expect(@user.blocked_customer_objects.active.pluck(:object_type, :object_value, :buyer_email)).to match_array([["email", "test@gumroad.com", nil]])
        end
      end
    end

    context "when buyer's email is unblocked by seller" do
      before do
        BlockedCustomerObject.block_email!(email: "test@gumroad.com", seller_id: @user.id)
        @user.blocked_customer_objects.active.find_each(&:unblock!)
      end

      it "succeeds the purchase" do
        visit @product.long_url
        add_to_cart(@product)

        expect do
          check_out(@product, email: "test@gumroad.com")
        end.to change { Purchase.count }.by(1)
         .and change { @user.blocked_customer_objects.active.count }.by(0)

        purchase = Purchase.last
        expect(purchase.successful?).to be(true)
        expect(purchase.email).to eq("test@gumroad.com")
      end
    end
  end
end
