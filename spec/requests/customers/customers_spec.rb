# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Sales page", type: :system, js: true do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:product1) { create(:product, user: seller, name: "Product 1", price_cents: 100) }
  let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller, name: "Membership", is_multiseat_license: true, is_licensed: true) }
  let(:offer_code) { create(:offer_code, code: "code", products: [membership]) }
  let(:product2) { create(:product_with_digital_versions, user: seller, name: "Product 2", price_cents: 300) }
  let!(:purchase1) { create(:purchase, link: product1, full_name: "Customer 1", email: "customer1@gumroad.com", created_at: 1.day.ago, seller:) }
  let!(:purchase2) { create(:membership_purchase, link: membership, price_cents: 200, full_name: "Customer 2", email: "customer2@gumroad.com", created_at: 2.days.ago, seller:, is_original_subscription_purchase: true, offer_code:, was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, quantity: 2, license: create(:license)) }
  let!(:purchase3) { create(:purchase, link: product2, full_name: "Customer 3", email: "customer3hasaninsanelylongemailaddress@gumroad.com", created_at: 3.days.ago, country: "Uganda", seller:, variant_attributes: [product2.alive_variants.first], is_bundle_purchase: true) }
  let!(:purchases) do
    create_list(:purchase, 3, link: product1) do |customer, i|
      i += 4
      customer.update(full_name: "Customer #{i}", email: "customer#{i}@gumroad.com", created_at: i.days.ago)
    end
  end

  before do
    index_model_records(Purchase)
    stub_const("CustomersController::CUSTOMERS_PER_PAGE", 3)

    create(:upsell_purchase, purchase: purchase1, upsell: create(:upsell, seller:, product: product1, cross_sell: true))
  end

  def fill_in_date(field_label, date)
    fill_in field_label, with: date.strftime("%Y")
    find_field(field_label).send_keys(:tab)
    fill_in field_label, with: date.strftime("%m")
    # It appears that once the month is provided, the cursor moves automaticaly to date, without the need to use tab
    # MacOS 14.5 (23F79), Google Chrome Version 124.0.6367.208 (Official Build) (arm64)
    fill_in field_label, with: date.strftime("%d")
  end

  include_context "with switching account to user as admin for seller"

  describe "table" do
    it "displays the seller's sales in the table" do
      login_as seller
      visit customers_path

      expect(page).to have_table("All sales (6)")
      expect(page).to have_table_row({ "Email" => "customer1@gumroad.com", "Name" => "Customer 1", "Product" => "Product 1", "Price" => "$1" })
      expect(page).to have_table_row({ "Email" => "customer2@gumroad.com", "Name" => "Customer 2", "Product" => "Membership", "Price" => "$2 a month" })
      expect(page).to have_table_row({ "Email" => "customer3hasaninsanelylonge...", "Name" => "Customer 3", "Product" => "Product 2Bundle", "Price" => "$3" })
    end

    it "sorts and paginates sales in the table" do
      login_as seller
      visit customers_path

      expect(page).to have_selector("th[aria-sort='descending']", text: "Purchase Date")
      expect(page).to have_selector("[aria-current='page']", text: "1")
      expect(page).to have_nth_table_row_record(1, "Customer 1")
      expect(page).to have_nth_table_row_record(2, "Customer 2")
      expect(page).to have_nth_table_row_record(3, "Customer 3")
      click_on "Next"
      expect(page).to have_selector("[aria-current='page']", text: "2")
      expect(page).to have_nth_table_row_record(1, "Customer 4")
      expect(page).to have_nth_table_row_record(2, "Customer 5")
      expect(page).to have_nth_table_row_record(3, "Customer 6")

      find(:columnheader, "Price").click
      expect(page).to have_selector("[aria-current='page']", text: "1")
      expect(page).to have_selector("th[aria-sort='ascending']", text: "Price")
      find(:columnheader, "Price").click
      expect(page).to have_selector("th[aria-sort='descending']", text: "Price")
      expect(page).to have_nth_table_row_record(1, "Customer 3")
      expect(page).to have_nth_table_row_record(2, "Customer 2")
      expect(page).to have_nth_table_row_record(3, "Customer 1")

      click_on "2"
      expect(page).to have_selector("[aria-current='page']", text: "2")
      expect(page).to have_nth_table_row_record(1, "Customer 4")
      expect(page).to have_nth_table_row_record(2, "Customer 5")
      expect(page).to have_nth_table_row_record(3, "Customer 6")
    end

    it "allows searching the table" do
      create(:purchase, link: product1, full_name: "Customer 11", email: "customer11@gumroad.com", created_at: 11.days.ago, seller:)
      index_model_records(Purchase)

      login_as seller
      visit customers_path(query: "customer11@gumroad.com")

      expect(page).to have_table_row({ "Email" => "customer11@gumroad.com", "Name" => "Customer 11" })
      expect(page).to have_text("All sales (1)")
      select_disclosure "Search" do
        expect(page).to have_field("Search sales", with: "customer11@gumroad.com")
        fill_in "Search sales", with: "customer1"
      end
      wait_for_ajax
      expect(page).to have_nth_table_row_record(1, "Customer 1")
      expect(page).to have_nth_table_row_record(2, "Customer 11")

      find(:columnheader, "Purchase Date").click
      expect(page).to have_nth_table_row_record(1, "Customer 11")
      expect(page).to have_nth_table_row_record(2, "Customer 1")

      select_disclosure "Search" do
        fill_in "Search sales", with: ""
      end
      expect(page).to have_nth_table_row_record(1, "Customer 11")
      expect(page).to have_nth_table_row_record(2, "Customer 6")
      expect(page).to have_nth_table_row_record(3, "Customer 5")

      fill_in "Search sales", with: "nononono"
      expect(page).to have_section("No sales found")
    end

    it "includes the transaction URL link" do
      allow_any_instance_of(Purchase).to receive(:transaction_url_for_seller).and_return("https://www.google.com")
      visit customers_path
      expect(page).to have_link("$1", href: "https://www.google.com")
      expect(page).to have_link("$2 a month", href: "https://www.google.com")
      expect(page).to have_link("$3", href: "https://www.google.com")
    end

    context "when the seller has no sales" do
      let(:user) { create(:user) }

      before do
        Feature.activate_user(:react_customers_page, user)
        login_as user
      end

      it "displays a placeholder message" do
        visit customers_path

        within_section "Manage all of your sales in one place." do
          expect(page).to have_text("Every time a new customer purchases a product from your Gumroad, their email address and other details are added here.")
          expect(page).to have_link("Start selling today", href: new_product_path)
        end
      end
    end

    describe "filtering" do
      before do
        create(:membership_purchase, created_at: 1.month.ago, link: create(:membership_product, user: seller, name: "Membership", price_cents: 100), seller:).subscription.deactivate!
        index_model_records(Purchase)
      end

      it "filters products correctly" do
        login_as seller
        visit customers_path

        toggle_disclosure "Filter"

        select_combo_box_option search: "Product 1", from: "Customers who bought"
        expect(page).to have_nth_table_row_record(1, "Customer 1")
        expect(page).to have_nth_table_row_record(2, "Customer 4")
        expect(page).to have_nth_table_row_record(3, "Customer 5")
        click_on "2"
        expect(page).to have_nth_table_row_record(1, "Customer 6")
        toggle_disclosure "Filter"
        click_on "Clear value"

        select_combo_box_option search: "Product 1", from: "Customers who have not bought"
        expect(page).to have_nth_table_row_record(1, "Customer 2")
        expect(page).to have_nth_table_row_record(2, "Customer 3")
        click_on "Clear value"

        fill_in "Paid more than", with: "2"
        expect(page).to have_nth_table_row_record(1, "Customer 3")
        fill_in "Paid more than", with: ""

        fill_in "Paid less than", with: "2"
        expect(page).to have_nth_table_row_record(1, "Customer 1")
        expect(page).to have_nth_table_row_record(2, "Customer 4")
        expect(page).to have_nth_table_row_record(3, "Customer 5")
        click_on "2"
        expect(page).to have_nth_table_row_record(1, "Customer 6")
        toggle_disclosure "Filter"
        fill_in "Paid less than", with: ""

        fill_in_date("Before", purchase1.created_at)
        find(:label, "Before").click
        expect(page).to have_nth_table_row_record(1, "Customer 1")
        expect(page).to have_nth_table_row_record(2, "Customer 2")
        expect(page).to have_nth_table_row_record(3, "Customer 3")
        click_on "2"
        expect(page).to have_nth_table_row_record(1, "Customer 4")
        expect(page).to have_nth_table_row_record(2, "Customer 5")
        expect(page).to have_nth_table_row_record(3, "Customer 6")
        toggle_disclosure "Filter"
        fill_in "Before", with: ""

        select "Uganda", from: "From"
        expect(page).to have_nth_table_row_record(1, "Customer 3")
        select "Anywhere", from: "From"

        fill_in_date("After", purchase3.created_at)
        find(:label, "After").click
        expect(page).to have_nth_table_row_record(1, "Customer 1")
        expect(page).to have_nth_table_row_record(2, "Customer 2")
        fill_in "After", with: ""
        find(:label, "Before").click

        expect(page).to have_button("3")
        check "Show active customers only"
        expect(page).to_not have_button("3")
        uncheck "Show active customers only"
        expect(page).to have_button("3")
      end
    end

    describe "exporting" do
      it "downloads the CSV" do
        expect(Exports::PurchaseExportService).to receive(:export).with(
          seller:,
          recipient: user_with_role_for_seller,
          filters: ActionController::Parameters.new(
            {
              start_time: 1.month.ago.strftime("%Y-%m-%d"),
              end_time: Date.today.strftime("%Y-%m-%d"),
            }
          )
        )
        visit customers_path
        select_disclosure "Export" do
          expect(page).to have_text("This will download a CSV with each purchase on its own row.")
          click_on "Download"
        end
      end

      context "when there are products selected" do
        it "downloads the correct CSV" do
          expect(Exports::PurchaseExportService).to receive(:export).with(
            seller:,
            recipient: user_with_role_for_seller,
            filters: ActionController::Parameters.new(
              {
                start_time: 1.month.ago.strftime("%Y-%m-%d"),
                end_time: Date.today.strftime("%Y-%m-%d"),
                product_ids: [product1.external_id],
                variant_ids: [membership.alive_variants.first.external_id]
              }
            )
          )
          visit customers_path
          select_disclosure "Filter" do
            select_combo_box_option search: "Product 1", from: "Customers who bought"
            select_combo_box_option search: "Membership - First Tier", from: "Customers who bought"
          end

          select_disclosure "Export" do
            expect(page).to have_text("This will download sales of 'Product 1, Membership - First Tier' as a CSV, with each purchase on its own row.")
            click_on "Download"
          end
        end
      end

      context "when the CSV is too large to generate synchronously" do
        before do
          stub_const("Exports::PurchaseExportService::SYNCHRONOUS_EXPORT_THRESHOLD", 1)
        end

        it "displays a flash message" do
          visit customers_path
          select_disclosure "Export" do
            click_on "Download"
          end
          expect(page).to have_alert(text: "You will receive an email in your inbox with the data you've requested shortly.")
        end
      end
    end

    context "when the purchase has a utm link" do
      let(:utm_link) { create(:utm_link, utm_source: "twitter", utm_medium: "social", utm_campaign: "gumroad-twitter", utm_term: "gumroad-123", utm_content: "gumroad-456") }
      let(:purchase) { create(:purchase, link: product1, email: "john@example.com", seller:) }
      let!(:utm_link_driven_sale) { create(:utm_link_driven_sale, purchase:, utm_link:) }

      before do
        index_model_records(Purchase)
      end

      it "shows the utm link pill and details in the drawer" do
        login_as seller
        visit customers_path
        row = find(:table_row, { "Email" => "john@example.com" })
        within row do
          expect(page).to have_text("UTM")
        end
        row.click
        within_section "Product 1", section_element: :aside do
          within_section "UTM link", section_element: :section, match: :first do
            expect(page).to have_text("This sale was driven by a UTM link.")
            expect(page).to have_link("UTM link", href: utm_link.utm_url)
            expect(page).to have_text("Title #{utm_link.title}", normalize_ws: true)
            expect(page).to have_text("Source twitter", normalize_ws: true)
            expect(page).to have_text("Medium social", normalize_ws: true)
            expect(page).to have_text("Campaign gumroad-twitter", normalize_ws: true)
            expect(page).to have_text("Term gumroad-123", normalize_ws: true)
            expect(page).to have_text("Content gumroad-456", normalize_ws: true)
          end
        end
      end
    end

    describe "installment plans" do
      let(:product_with_installment_plan) { create(:product, :with_installment_plan, price_cents: 3000, name: "Awesome Product", user: seller) }
      let!(:installment_plan_purchase) { create(:installment_plan_purchase, link: product_with_installment_plan, email: "installment_buyer@gumroad.com") }

      before { index_model_records(Purchase) }

      it "displays the correct information" do
        login_as seller
        visit customers_path

        row = find(:table_row, { "Email" => installment_plan_purchase.email })
        within row do
          expect(page).to have_text("Awesome ProductInstallments")
          expect(page).to have_text("$10 a month")
        end
        row.click

        within_section product_with_installment_plan.name, section_element: :aside do
          within_section "Order information" do
            expect(page).to have_text("Installment plan status In progress", normalize_ws: true)
          end

          within_section "Charges", section_element: :section do
            expect(page).to have_text("2 charges remaining", normalize_ws: true)
          end

          expect(page).to have_button("Cancel installment plan")
        end
      end
    end
  end

  describe "drawer" do
    it "displays all attributes correctly" do
      allow_any_instance_of(Purchase).to receive(:transaction_url_for_seller).and_return("https://www.google.com")
      review = create(:product_review, purchase: purchase1, message: "Amazing!")
      create(:product_review_response, product_review: review, message: "Thank you!", user: seller)
      create(:tip, purchase: purchase1, value_cents: 100)
      visit customers_path

      find(:table_row, { "Email" => "customer1@gumroad.com" }).click
      within_section "Product 1", section_element: :aside do
        within_section "Order information" do
          expect(page).to have_link("Transaction", href: "https://www.google.com")
          expect(page).to have_text("Customer name Customer 1", normalize_ws: true)
          expect(page).to have_text("Quantity 1", normalize_ws: true)
          expect(page).to have_text("Price $0", normalize_ws: true)
          expect(page).to have_text("Upsell Upsell", normalize_ws: true)
          expect(page).to have_text("Tip $1", normalize_ws: true)
        end

        within_section "Review" do
          within_section "Rating" do
            expect(page).to have_selector("[aria-label='1 star']")
          end
          within_section "Message" do
            expect(page).to have_text("Amazing!")
          end
          within_section "Response" do
            expect(page).to have_text("Thank you!")
          end
        end
      end
      click_on "Close"

      find(:table_row, { "Email" => "customer2@gumroad.com" }).click
      within_section "Membership", section_element: :aside do
        within_section "Order information" do
          expect(page).to have_text("Customer name Customer 2", normalize_ws: true)
          expect(page).to have_text("Seats 2", normalize_ws: true)
          expect(page).to have_text("Price $6 a month $2 a month", normalize_ws: true)
          expect(page).to have_text("Discount $1 off with code CODE", normalize_ws: true)
          expect(page).to have_text("Membership status Active", normalize_ws: true)
          expect(page).to have_text("Referrer Gumroad Product Recommendations", normalize_ws: true)
        end
      end
    end

    describe "missed posts" do
      let!(:posts) do
        create_list(:installment, 11, link: product1, published_at: Time.current) do |post, i|
          post.update!(name: "Post #{i}")
        end
      end

      before do
        create(:customer_email_info_opened, purchase: purchase1)
      end

      it "displays the missed posts and allows re-sending them" do
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        stripe_connect_account = create(:merchant_account_stripe_connect, user: seller)
        create(:purchase, seller:, link: product1, merchant_account: stripe_connect_account)

        post = posts.last
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          within_section "Send missed posts", section_element: :section do
            10.times do |i|
              expect(page).to have_section("Post #{i}")
            end
            expect(page).to_not have_section("Post 10")
            click_on "Show more"
            expect(page).to_not have_button("Show more")
            within_section "Post 10" do
              expect(page).to have_link("Post 10", href: post.full_url)
              expect(page).to have_text("Originally sent on #{post.published_at.strftime("%b %-d")}")
              click_on "Send"
              expect(page).to have_button("Sending...", disabled: true)
            end
          end
        end
        expect(page).to have_alert(text: "Email Sent")
        within_section("Post 10") { expect(page).to have_button("Sent", disabled: true) }
        expect(EmailInfo.last.installment).to eq(post)

        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          within_section "Send missed posts", section_element: :section do
            expect(page).to_not have_button("Show more")
            expect(page).to_not have_section("Post 10")
          end
          within_section "Emails received", section_element: :section do
            within_section "Post 10" do
              expect(page).to have_text("Sent #{post.published_at.strftime("%b %-d")}")
              click_on "Resend email"
              expect(page).to have_button("Sending...", disabled: true)
            end
          end
        end

        expect(page).to have_alert(text: "Sent")
        within_section("Post 10") { expect(page).to have_button("Sent", disabled: true) }
      end

      it "does not allow re-sending an email if the seller is not eligible to send emails" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          within_section "Send missed posts", section_element: :section do
            click_on "Show more"
            within_section "Post 10" do
              click_on "Send"
              expect(page).to have_button("Sending...", disabled: true)
            end
          end
        end
        expect(page).to have_alert(text: "You are not eligible to resend this email.")
        expect(EmailInfo.last.installment).to be_nil
      end
    end

    describe "receipts" do
      let!(:membership_purchase) { create(:membership_purchase, link: membership, subscription: purchase2.subscription, created_at: 1.day.ago) }

      it "displays the receipts and allows re-sending them" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click
        within_section "Membership", section_element: :aside do
          within_section "Emails received", section_element: :section do
            expect(page).to have_section("Receipt", text: "Delivered #{purchase2.created_at.strftime("%b %-d")}")
            within_section "Receipt", text: "Delivered #{membership_purchase.created_at.strftime("%b %-d")}" do
              click_on "Resend receipt"
              expect(page).to have_button("Resending receipt...", disabled: true)
            end
          end
        end
        expect(page).to have_alert(text: "Receipt resent")

        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(membership_purchase.id).on("critical")
        within_section "Receipt", text: "Delivered #{membership_purchase.created_at.strftime("%b %-d")}" do
          expect(page).to have_button("Receipt resent", disabled: true)
        end
      end
    end

    describe "additional contributions" do
      before do
        purchase1.update!(is_additional_contribution: true)
      end

      it "includes an additional contribution status" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          expect(page).to have_selector("[role='status']", text: "Additional amount: This is an additional contribution, added to a previous purchase of this product.")
        end
      end
    end

    describe "PPP purchases" do
      before do
        purchase1.update!(is_purchasing_power_parity_discounted: true, ip_country: "United States")
        purchase1.create_purchasing_power_parity_info!(factor: 0.5)
      end

      it "includes a PPP status" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          expect(page).to have_selector("[role='status']", text: "This customer received a purchasing power parity discount of 50% because they are located in United States.")
        end
      end
    end

    describe "gifts" do
      let(:giftee_purchase) { purchase1 }
      let(:gifter_purchase) { purchase2 }
      let!(:gift) { create(:gift, giftee_email: giftee_purchase.email, gifter_email: gifter_purchase.email, giftee_purchase:, gifter_purchase:) }

      before do
        gifter_purchase.update!(is_gift_sender_purchase: true)
        giftee_purchase.update!(is_gift_receiver_purchase: true)
      end

      it "includes gift statuses" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click
        within_section "Membership", section_element: :aside do
          expect(page).to have_selector("[role='status']", text: "customer2@gumroad.com purchased this for customer1@gumroad.com.")
        end
      end

      it "shows review from the giftee purchase" do
        review = create(:product_review, purchase: giftee_purchase, message: "Giftee review")
        create(:product_review_response, product_review: review, message: "Giftee review response", user: seller)

        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click

        within_section "Membership", section_element: :aside do
          within_section "Review" do
            within_section "Rating" do
              expect(page).to have_selector("[aria-label='1 star']")
            end
            within_section "Message" do
              expect(page).to have_text("Giftee review")
            end
            within_section "Response" do
              expect(page).to have_text("Giftee review response")
            end
          end
        end
      end
    end

    describe "preorders" do
      before do
        purchase1.update!(is_preorder_authorization: true, preorder: create(:preorder))
      end

      it "includes a preorder status" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          expect(page).to have_selector("[role='status']", text: "Pre-order: This is a pre-order authorization. The customer's card has not been charged yet.")
        end
      end
    end

    describe "affiliates" do
      it "includes an affiliate status" do
        purchase1.update!(affiliate: create(:direct_affiliate))

        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          expect(page).to have_selector("[role='status']", text: "Affiliate: An affiliate (#{purchase1.affiliate.affiliate_user.form_email}) helped you make this sale and received $0.")
        end
      end

      it "does not include affiliate status if the affiliate is a collaborator" do
        purchase1.update!(affiliate: create(:collaborator))

        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          expect(page).not_to have_selector("[role='status']", text: "Affiliate: An affiliate (#{purchase1.affiliate.affiliate_user.form_email}) helped you make this sale and received $0.")
        end
      end
    end

    describe "email updates" do
      before do
        purchase2.update!(is_gift_sender_purchase: true)
        create(:gift, giftee_email: purchase1.email, gifter_email: purchase2.email, giftee_purchase: purchase1, gifter_purchase: purchase2)
      end

      it "allows updating emails" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click

        within_section "Membership", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_text("customer2@gumroad.com")
            click_on "Edit"
            fill_in "Email", with: "newcustomer2@gumroad.com"
            click_on "Save"
          end
        end
        expect(page).to have_alert(text: "Email updated successfully.")

        within_section "Membership", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_button("Edit")
            expect(page).to have_text("newcustomer2@gumroad.com")

            click_on "Edit"
            expect(page).to have_field("Email", with: "newcustomer2@gumroad.com")
            click_on "Cancel"
            expect(page).to have_button("Edit")

            uncheck "Receives emails", checked: true
          end
        end
        expect(page).to have_alert(text: "Your customer will no longer receive your posts.")

        within_section "Membership", section_element: :aside do
          within_section "Giftee email", section_element: :section do
            expect(page).to have_text("customer1@gumroad.com")
            click_on "Edit"
            fill_in "Giftee email", with: "newcustomer1@gumroad.com"
            click_on "Save"
          end
        end
        expect(page).to have_alert(text: "Email updated successfully.")
        expect(page).to have_selector("[role='status']", text: "newcustomer2@gumroad.com purchased this for newcustomer1@gumroad.com.")

        purchase2.reload
        expect(purchase2.email).to eq("newcustomer2@gumroad.com")
        expect(purchase2.giftee_email).to eq("newcustomer1@gumroad.com")
        expect(purchase2.can_contact).to eq(false)

        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click

        within_section "Membership", section_element: :aside do
          within_section "Email", section_element: :section do
            check "Receives emails", unchecked: true
          end
        end
        expect(page).to have_alert(text: "Your customer will now receive your posts.")

        expect(purchase2.reload.can_contact).to eq(true)
      end

      it "shows an error when entering an invalid email" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 2" }).click

        within_section "Membership", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_text("customer2@gumroad.com")
            click_on "Edit"
            fill_in "Email", with: "invalid-email"
            click_on "Save"
          end
        end

        expect(page).to have_alert(text: "Please enter a valid email")
      end

      context "customer has a Gumroad account" do
        before { purchase3.update!(purchaser: create(:user)) }

        it "doesn't allow updating the email" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 3" }).click
          within_section "Product 2", section_element: :aside do
            within_section "Email", section_element: :section do
              expect(page).to have_text("customer3hasaninsanelylongemailaddress@gumroad.com")
              expect(page).to have_text("You cannot change the email of this purchase, because it was made by an existing user. Please ask them to go to gumroad.com/settings to update their email.")
              expect(page).to_not have_button("Edit")
              expect(page).to have_checked_field("Receives emails")
            end

            expect(page).to_not have_section("Giftee email")
          end
        end
      end
    end

    describe "bundle products" do
      before do
        purchase1.update(link: create(:product, :bundle, user: seller))
        purchase1.create_artifacts_and_send_receipt!
      end

      it "allows management of bundle product purchases" do
        login_as seller
        visit customers_path

        expect(page).to_not have_table_row({ "Product" => "Bundle Product 1" })
        expect(page).to_not have_table_row({ "Product" => "Bundle Product 2" })

        find(:table_row, { "Product" => "BundleBundle" }).click

        expect(page).to have_section("Emails received")

        within_section "Bundle", section_element: :aside do
          within_section "Content", section_element: :section do
            within_section "Bundle Product 1" do
              click_on "Manage"
            end
          end
        end

        expect(page).to have_section("Bundle Product 1", section_element: :aside)
        expect(page).to_not have_section("Emails received")

        click_on "Return to bundle"

        within_section "Bundle", section_element: :aside do
          within_section "Content", section_element: :section do
            within_section "Bundle Product 2" do
              click_on "Manage"
            end
          end
        end

        within_section "Bundle Product 2", section_element: :aside do
          expect(page).to_not have_section("Emails received")
          click_on "Edit"
          fill_in "Email", with: "stoleyourbundle@gumroad.com"
          click_on "Save"
          wait_for_ajax
          expect(page).to_not have_text("buyer@gumroad.com")
          expect(purchase1.product_purchases.second.email).to eq("stoleyourbundle@gumroad.com")
        end

        click_on "Close"

        expect(page).to_not have_selector("aside")

        find(:table_row, { "Product" => "BundleBundle" }).click
        expect(page).to have_section("Bundle", section_element: :aside)
      end

      it "updates the email for all bundle purchases" do
        login_as seller
        visit customers_path

        find(:table_row, { "Name" => "Customer 1" }).click

        within_section "Bundle", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_text("customer1@gumroad.com")
            click_on "Edit"
            fill_in "Email", with: "customer2@gumroad.com"
            click_on "Save"
          end
        end
        expect(page).to have_alert(text: "Email updated successfully.")

        refresh
        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Bundle", section_element: :aside do
          within_section "Content", section_element: :section do
            within_section "Bundle Product 1" do
              click_on "Manage"
            end
          end
        end
        within_section "Bundle Product 1", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_text("customer2@gumroad.com")
          end
        end

        click_on "Return to bundle"
        within_section "Bundle", section_element: :aside do
          within_section "Content", section_element: :section do
            within_section "Bundle Product 2" do
              click_on "Manage"
            end
          end
        end
        within_section "Bundle Product 2", section_element: :aside do
          within_section "Email", section_element: :section do
            expect(page).to have_text("customer2@gumroad.com")
          end
        end

        expect(purchase1.reload.email).to eq("customer2@gumroad.com")
        expect(purchase1.product_purchases.map(&:email)).to all(eq("customer2@gumroad.com"))
      end
    end

    describe "licenses" do
      it "allows management of licenses" do
        visit customers_path
        find(:table_row, { "Product" => "Membership" }).click

        within_section "Membership", section_element: :aside do
          within_section "License key", section_element: :section do
            click_on "Disable"
          end
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        expect(purchase2.license.reload.disabled_at).to_not be_nil

        within_section "Membership", section_element: :aside do
          within_section "License key", section_element: :section do
            click_on "Enable"
          end
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        expect(purchase2.license.reload.disabled_at).to be_nil

        within_section "Membership", section_element: :aside do
          within_section "Seats", section_element: :section do
            expect(page).to have_text("2")
            click_on "Edit"
            fill_in "Seats", with: 3
            click_on "Save"
          end
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Successfully updated seats!")

        within_section "Membership", section_element: :aside do
          within_section "Seats", section_element: :section do
            expect(page).to have_text("3")
          end
        end
      end
    end

    describe "shipping" do
      before do
        purchase1.update!(street_address: "123 Main St", city: "San Francisco", state: "CA", zip_code: "94105", country: "United States", variant_attributes: [create(:sku, link: product1)], shipment: create(:shipment))
        product1.update!(is_physical: true, require_shipping: true)
      end

      it "allows management of shipping" do
        visit customers_path

        table_row = find(:table_row, { "Name" => "Customer 1" })
        icon = table_row.find("[aria-label='Not Shipped']")
        expect(icon).to have_tooltip(text: "Not Shipped", visible: false)
        table_row.click
        within_section "Product 1", section_element: :aside do
          within_section "Order information", section_element: :section do
            expect(page).to have_text("SKU #{purchase1.sku.custom_name_or_external_id}", normalize_ws: true)
            expect(page).to have_text("Order number #{purchase1.external_id_numeric}", normalize_ws: true)
          end

          within_section "Shipping address", section_element: :section do
            expect(page).to have_text("Customer 1")
            expect(page).to have_text("123 Main St")
            expect(page).to have_text("San Francisco, CA 94105")
            expect(page).to have_text("United States")
            expect(page).to have_text("Shipping charged $0", normalize_ws: true)

            click_on "Edit"
            fill_in "Full name", with: "New Customer 1"
            fill_in "Street address", with: "456 Main St"
            fill_in "City", with: "New York"
            fill_in "State", with: "NY"
            fill_in "ZIP code", with: "10001"
            select "United States Minor Outlying Islands", from: "Country"

            click_on "Save"
          end
        end
        expect(page).to have_alert(text: "Changes saved!")

        purchase1.reload
        expect(purchase1.full_name).to eq("New Customer 1")
        expect(purchase1.street_address).to eq("456 Main St")
        expect(purchase1.city).to eq("New York")
        expect(purchase1.state).to eq("NY")
        expect(purchase1.zip_code).to eq("10001")
        expect(purchase1.country).to eq("United States Minor Outlying Islands")

        within_section "Product 1", section_element: :aside do
          within_section "Shipping address", section_element: :section do
            expect(page).to have_text("New Customer 1")
            expect(page).to have_text("456 Main St")
            expect(page).to have_text("New York, NY 10001")
            expect(page).to have_text("United States Minor Outlying Islands")
          end
        end

        within_section "Product 1", section_element: :aside do
          within_section "Tracking information", section_element: :section do
            fill_in "Tracking URL (optional)", with: "https://www.google.com"
            click_on "Mark as shipped"
          end
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Changes saved!")
        shipment = purchase1.reload.shipment
        expect(shipment.shipped?).to eq(true)
        expect(shipment.tracking_url).to eq("https://www.google.com")

        within_section "Product 1", section_element: :aside do
          within_section "Tracking information", section_element: :section do
            expect(page).to have_link("Track shipment", href: "https://www.google.com", target: "_blank")
          end
        end
      end

      context "when the product has been shipped but doesn't have a tracking URL" do
        before do
          purchase1.shipment.update!(shipped_at: Time.current)
        end

        it "displays a status" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click
          within_section "Product 1", section_element: :aside do
            within_section "Tracking information", section_element: :section do
              expect(page).to have_selector("[role='status']", text: "Shipped")
            end
          end
        end
      end
    end

    describe "subscription management" do
      it "allows cancelling a subscription" do
        visit customers_path

        find(:table_row, { "Name" => "Customer 2" }).click
        within_section "Membership", section_element: :aside do
          click_on "Cancel subscription"
          within_modal("Cancel subscription") { click_on "Close" }
          expect(page).to_not have_modal("Cancel subscription")
          click_on "Cancel subscription"
          within_modal("Cancel subscription") { click_on "Cancel" }
          expect(page).to_not have_modal("Cancel subscription")
          click_on "Cancel subscription"
          within_modal("Cancel subscription") { click_on "Cancel subscription" }
        end

        expect(page).to have_alert(text: "Changes saved!")
        within_section "Membership", section_element: :aside do
          within_section "Order information", section_element: :section do
            expect(page).to have_text("Membership status Cancellation pending", normalize_ws: true)
          end
        end

        expect(purchase2.subscription.reload.cancelled_at).to_not be_nil
      end
    end

    describe "ping" do
      context "when a ping endpoint is set up" do
        before do
          purchase2.subscription.purchases << create(:recurring_membership_purchase, seller:, link: membership)
          seller.update!(notification_endpoint: "http://local/host")
        end

        it "allows resending the ping" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click

          click_on "Resend ping"
          expect(page).to have_alert(text: "Ping resent.")
          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase1.id, nil)

          find(:table_row, { "Name" => "Customer 2" }).click
          within_section "$2", match: :first do
            click_on "Resend ping"
          end
          wait_for_ajax
          expect(page).to have_alert(text: "Ping resent.")
          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase2.id, nil)

          within_section "$0", match: :first do
            click_on "Resend ping"
          end
          wait_for_ajax
          expect(page).to have_alert(text: "Ping resent.")
          expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase2.subscription.purchases.second.id, nil)
        end
      end

      context "when a ping endpoint isn't set up" do
        it "doesn't allow resending a ping" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click
          expect(page).to_not have_button("Resend ping")

          find(:table_row, { "Name" => "Customer 2" }).click
          expect(page).to_not have_button("Resend ping")
        end
      end
    end

    describe "custom fields" do
      before do
        purchase1.purchase_custom_fields << [
          build(:purchase_custom_field, name: "String field", value: "I'm a string"),
          build(:purchase_custom_field, name: "Boolean field", value: false, field_type: CustomField::TYPE_CHECKBOX),
        ]
      end

      it "displays the custom field values" do
        visit customers_path

        find(:table_row, { "Name" => "Customer 1" }).click
        within_section "Product 1", section_element: :aside do
          within_section "Information provided", section_element: :section do
            expect(page).to have_text("String field I'm a string", normalize_ws: true)
            expect(page).to have_text("Boolean field false", normalize_ws: true)
          end
        end
      end
    end

    describe "subscription purchases" do
      before do
        purchase2.update!(purchase_state: "in_progress", created_at: ActiveSupport::TimeZone[seller.timezone].local(2022, 1, 1), chargeable: create(:chargeable))
        purchase2.process!
        purchase2.mark_successful!
        purchase2.subscription.update!(charge_occurrence_count: 2, deactivated_at: Time.current)
        seller.update!(refund_fee_notice_shown: false)
      end

      it "allows management of subscription purchases" do
        visit customers_path
        row = find(:table_row, { "Name" => "Customer 2" })
        within row do
          expect(page).to have_text("Inactive")
        end
        row.click

        within_section "Membership", section_element: :aside do
          within_section "Charges", section_element: :section do
            expect(page).to have_selector("[role='status']", text: "1 charge remaining")
            expect(page).to have_text("$4 on 1/1/2022")
            expect(page).to have_link("Transaction", href: receipt_purchase_path(purchase2.external_id, email: purchase2.email), target: "_blank")
            click_on "Refund Options"
            click_on "Cancel"
            expect(page).to_not have_field("4")
            click_on "Refund Options"
            fill_in "4", with: "2"
            click_on "Issue partial refund"
            within_modal "Charge refund" do
              expect(page).to have_text("Would you like to confirm this charge refund?")
              click_on "Cancel"
            end
            expect(page).to_not have_modal("Charge refund")
            click_on "Issue partial refund"
            within_modal "Charge refund" do
              click_on "Confirm refund"
            end
          end
        end
        expect(page).to have_alert(text: "Purchase successfully refunded.")
        expect(page).to have_text("Partial refund")
        purchase2.reload
        expect(purchase2.amount_refunded_cents).to eq(200)
        expect(purchase2.stripe_partially_refunded?).to eq(true)
        expect(purchase2.stripe_refunded?).to eq(false)

        within_section "Membership", section_element: :aside do
          within_section "Charges", section_element: :section do
            click_on "Refund Options"
            expect(page).to have_selector("[role='status']", text: "Going forward, Gumroad does not return any fees when a payment is refunded. Learn more")
            find_field("2", with: "2").fill_in with: "3"
            click_on "Refund fully"
            within_modal "Charge refund" do
              click_on "Confirm refund"
            end
          end
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Refund amount cannot be greater than the purchase price.")

        within_section "Membership", section_element: :aside do
          within_section "Charges", section_element: :section do
            find_field("2", with: "3").fill_in with: "2"
            click_on "Refund fully"
            within_modal "Charge refund" do
              click_on "Confirm refund"
            end
          end
        end
        expect(page).to have_alert(text: "Purchase successfully refunded.")
        within_section "Membership", section_element: :aside do
          within_section "Charges", section_element: :section do
            expect(page).to have_text("Refunded")
          end
        end

        within find(:table_row, { "Name" => "Customer 2" }) do
          expect(page).to_not have_text("Refunded")
        end

        purchase2.reload
        expect(purchase2.amount_refunded_cents).to eq(400)
        expect(purchase2.stripe_partially_refunded?).to eq(false)
        expect(purchase2.stripe_refunded?).to eq(true)

        purchase2.update!(chargeback_date: Time.current)

        allow_any_instance_of(Purchase).to receive(:transaction_url_for_seller).and_return("https://www.google.com")
        visit customers_path
        row = find(:table_row, { "Name" => "Customer 2" })
        within row do
          expect(page).to_not have_text("Chargedback")
        end
        row.click

        within_section "Membership", section_element: :aside do
          within_section "Charges", section_element: :section do
            expect(page).to have_text("Chargedback")
            expect(page).to have_link("Transaction", href: "https://www.google.com", target: "_blank")
            expect(page).to_not have_button("Refund Options")
          end
        end
      end

      context "when PayPal refunds are no longer allowed" do
        before do
          purchase2.update!(card_type: CardType::PAYPAL, created_at: 7.months.ago)
        end

        it "disables the refund button and displays a tooltip" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 2" }).click
          within_section "Membership", section_element: :aside do
            within_section "Charges", section_element: :section do
              click_on "Refund Options"
              refund_button = find_button("Refund fully", disabled: true)
              refund_button.hover
              expect(refund_button).to have_tooltip(text: "PayPal refunds aren't available after 6 months.")
            end
          end
        end
      end
    end

    describe "commissions" do
      let!(:commission) { create(:commission) }

      before do
        commission.deposit_purchase.link.update!(user: seller, name: "Commission")
        commission.deposit_purchase.update!(seller:, full_name: "Commissionee")
        index_model_records(Purchase)
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      end

      it "allows updating commission files" do
        visit customers_path
        find(:table_row, { "Name" => "Commissionee" }).click

        within_section "Commission", section_element: :aside do
          within_section "Files", section_element: :section do
            expect(page).to have_text("Files")
            expect(page).not_to have_selector("[role='tree']")

            attach_file("Upload files", [file_fixture("smilie.png"), file_fixture("test.pdf")], visible: false)
          end
        end
        expect(page).to have_alert(text: "Uploaded successfully!")
        expect(commission.files.count).to eq(2)
        expect(commission.files.first.filename).to eq("smilie.png")
        expect(commission.files.last.filename).to eq("test.pdf")

        within_section "Commission", section_element: :aside do
          within_section "Files", section_element: :section do
            within "[role='tree']" do
              expect(page).to have_selector("[role='treeitem']", count: 2)

              within(find("[role='treeitem']", text: "smilie")) do
                expect(page).to have_text("PNG")
                expect(page).to have_text("98.1 KB")
                expect(page).to have_button("Delete")
                expect(page).to have_link("Download", href: s3_utility_cdn_url_for_blob_path(key: commission.files.first.key), target: "_blank")
              end

              within(find("[role='treeitem']", text: "test")) do
                expect(page).to have_text("PDF")
                expect(page).to have_text("8.1 KB")
                expect(page).to have_button("Delete")
                expect(page).to have_link("Download", href: s3_utility_cdn_url_for_blob_path(key: commission.files.last.key), target: "_blank")
              end
            end

            within(find("[role='treeitem']", text: "smilie")) do
              click_button "Delete"
            end
          end
        end
        expect(page).to have_alert(text: "File deleted successfully!")
        expect(commission.files.count).to eq(1)
        expect(commission.files.first.filename).to eq("test.pdf")

        within_section "Commission", section_element: :aside do
          within_section "Files", section_element: :section do
            within "[role='tree']" do
              expect(page).to have_selector("[role='treeitem']", count: 1)
              expect(page).to have_selector("[role='treeitem']", text: "test")
              expect(page).not_to have_selector("[role='treeitem']", text: "smilie")
            end
          end
        end
      end

      it "allows completing a commission" do
        visit customers_path
        find(:table_row, { "Name" => "Commissionee" }).click
        within_section "Commission", section_element: :aside do
          expect(page).to have_text("In progress")
          click_on "Submit and mark as complete"
        end
        expect(page).to have_alert(text: "Commission completed!")
        within_section "Commission", section_element: :aside do
          expect(page).to have_text("Completed")
        end
        click_on "Close"
        find(:table_row, { "Name" => "Commissionee" }).click
        within_section "Commission", section_element: :aside do
          expect(page).to have_text("Completed")
        end

        commission.reload
        expect(commission.status).to eq(Commission::STATUS_COMPLETED)
        expect(commission.completion_purchase).to be_successful
      end

      describe "refunding" do
        let(:deposit_purchase) { commission.deposit_purchase }

        before do
          deposit_purchase.update!(purchase_state: "in_progress", credit_card: create(:credit_card))
          deposit_purchase.process!
          deposit_purchase.mark_successful!
          commission.create_completion_purchase!
        end

        it "allows refunding commission purchases" do
          visit customers_path
          find(:table_row, { "Name" => "Commissionee" }).click
          within_section "Commission", section_element: :aside do
            within_section "Charges", section_element: :section do
              within_section "$1", match: :first do
                click_on "Refund Options"
              end
              expect(page).to have_field("1", with: "1")
              click_on "Refund fully"
              within_modal "Charge refund" do
                click_on "Confirm refund"
              end
            end
          end
          expect(page).to have_alert(text: "Purchase successfully refunded.")
          deposit_purchase = commission.deposit_purchase.reload
          expect(deposit_purchase.amount_refunded_cents).to eq(100)
          expect(deposit_purchase.stripe_partially_refunded?).to eq(false)
          expect(deposit_purchase.stripe_refunded?).to eq(true)

          within_section "Commission", section_element: :aside do
            within_section "Charges", section_element: :section do
              within_section "$1", match: :first do
                click_on "Refund Options"
              end
              fill_in "1", with: "0.5"
              click_on "Issue partial refund"
              within_modal "Charge refund" do
                click_on "Confirm refund"
              end
            end
          end
          wait_for_ajax
          expect(page).to have_alert(text: "Purchase successfully refunded.")
          completion_purchase = commission.completion_purchase.reload
          expect(completion_purchase.amount_refunded_cents).to eq(50)
          expect(completion_purchase.stripe_partially_refunded?).to eq(true)
          expect(completion_purchase.stripe_refunded?).to eq(false)
        end
      end

      describe "custom fields" do
        let!(:purchase_custom_field_text) { create(:purchase_custom_field, purchase: commission.deposit_purchase, name: "What's your pet's name?", value: "Fido") }
        let!(:purchase_custom_field_file) { create(:purchase_custom_field, field_type: CustomField::TYPE_FILE, purchase: commission.deposit_purchase, name: CustomField::FILE_FIELD_NAME, value: nil) }

        before do
          purchase_custom_field_file.files.attach(file_fixture("test.pdf"))
          purchase_custom_field_file.files.attach(file_fixture("smilie.png"))
        end

        it "displays custom field values and files" do
          visit customers_path
          find(:table_row, { "Name" => "Commissionee" }).click
          within_section "Commission", section_element: :aside do
            within_section "Information provided", section_element: :section do
              within_section "What's your pet's name?", section_element: :section do
                expect(page).to have_text("Fido")
              end

              within_section "File upload", section_element: :section do
                within "[role='tree']" do
                  expect(page).to have_selector("[role='treeitem']", count: 2)

                  within(find("[role='treeitem']", text: "test")) do
                    expect(page).to have_text("PDF")
                    expect(page).to have_text("8.1 KB")
                    expect(page).to_not have_button("Delete")
                    expect(page).to have_link("Download", href: s3_utility_cdn_url_for_blob_path(key: purchase_custom_field_file.files.first.key), target: "_blank")
                  end

                  within(find("[role='treeitem']", text: "smilie")) do
                    expect(page).to have_text("PNG")
                    expect(page).to have_text("98.1 KB")
                    expect(page).to_not have_button("Delete")
                    expect(page).to have_link("Download", href: s3_utility_cdn_url_for_blob_path(key: purchase_custom_field_file.files.last.key), target: "_blank")
                  end
                end
              end
            end
          end
        end
      end
    end

    describe "access" do
      it "allows revoking and re-enabling access" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click
        click_on "Revoke access"
        expect(page).to have_alert(text: "Access revoked")
        expect(purchase1.reload.is_access_revoked?).to eq(true)
        click_on "Re-enable access"
        expect(page).to have_alert(text: "Access re-enabled")
        expect(purchase1.reload.is_access_revoked?).to eq(false)
      end

      context "coffee product" do
        let(:coffee) { create(:coffee_product) }
        before do
          purchase1.update!(link: coffee, seller: coffee.user)
        end

        it "does not allow revoking access" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click
          expect(page).to_not have_button("Revoke access")
        end
      end
    end

    describe "refunds" do
      before do
        purchase3.update!(purchase_state: "in_progress", created_at: ActiveSupport::TimeZone[seller.timezone].local(2022, 1, 1), chargeable: create(:chargeable))
        purchase3.process!
        purchase3.mark_successful!
      end

      it "allows refunding a customer" do
        visit customers_path
        find(:table_row, { "Name" => "Customer 3" }).click

        within_section "Product 2", section_element: :aside do
          within_section "Refund", section_element: :section do
            fill_in "3", with: "1"
            click_on "Issue partial refund"
            within_modal "Purchase refund" do
              click_on "Cancel"
            end
            expect(page).to_not have_modal("Purchase refund")
            click_on "Issue partial refund"
            within_modal "Purchase refund" do
              click_on "Confirm refund"
            end
          end
        end
        expect(page).to have_alert(text: "Purchase successfully refunded.")
        within find(:table_row, { "Name" => "Customer 3" }) do
          expect(page).to have_text("Partially refunded")
          expect(page).to_not have_text("Refunded")
        end
        purchase3.reload
        expect(purchase3.stripe_partially_refunded?).to eq(true)
        expect(purchase3.stripe_refunded?).to eq(false)
        expect(purchase3.amount_refundable_cents).to eq(200)

        within_section "Product 2", section_element: :aside do
          within_section "Refund", section_element: :section do
            find_field("2", with: "2").fill_in with: "3"
            click_on "Refund fully"
            within_modal "Purchase refund" do
              click_on "Confirm refund"
            end
          end
        end
        expect(page).to have_alert(text: "Refund amount cannot be greater than the purchase price.")

        within_section "Product 2", section_element: :aside do
          within_section "Refund", section_element: :section do
            fill_in "2", with: "2"
            click_on "Refund fully"
            within_modal "Purchase refund" do
              click_on "Confirm refund"
            end
          end
        end
        expect(page).to have_alert(text: "Purchase successfully refunded.")
        within find(:table_row, { "Name" => "Customer 3" }) do
          expect(page).to_not have_text("Partially refunded")
          expect(page).to have_text("Refunded")
        end
        purchase3.reload
        expect(purchase3.stripe_partially_refunded?).to eq(false)
        expect(purchase3.stripe_refunded?).to eq(true)
        expect(purchase3.amount_refundable_cents).to eq(0)
        within_section "Product 2", section_element: :aside do
          expect(page).to_not have_section("Refund")
        end

        purchase1.update!(charge_processor_id: StripeChargeProcessor.charge_processor_id, chargeback_date: Time.current)
        visit customers_path
        row = find(:table_row, { "Name" => "Customer 1" })
        within row do
          expect(page).to have_text("Chargedback")
        end
        row.click
        within_section "Product 1", section_element: :aside do
          expect(page).to_not have_section("Refund")
        end
        find(:table_row, { "Name" => "Customer 2" }).click
        within_section "Membership", section_element: :aside do
          expect(page).to_not have_section("Refund")
        end
      end

      context "for non-USD purchases" do
        before do
          purchase1.update!(purchase_state: "in_progress", chargeable: create(:chargeable))
          purchase1.link.update!(price_currency_type: Currency::EUR, price_cents: 100)
          purchase1.process!
          purchase1.mark_successful!
        end

        it "allows refunding a customer" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click

          within_section "Product 1", section_element: :aside do
            within_section "Refund", section_element: :section do
              expect(page).to have_field("1", with: "1")
              click_on "Refund fully"
              within_modal "Purchase refund" do
                click_on "Confirm refund"
              end
            end
          end
          expect(page).to have_alert(text: "Purchase successfully refunded.")

          purchase1.reload
          expect(purchase1.stripe_partially_refunded?).to eq(false)
          expect(purchase1.stripe_refunded?).to eq(true)
          expect(purchase1.amount_refundable_cents).to eq(0)
        end
      end

      context "when PayPal refunds are no longer allowed" do
        before do
          purchase3.update!(card_type: CardType::PAYPAL, created_at: 7.months.ago)
        end

        it "disables the refund button and displays a tooltip" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 3" }).click
          within_section "Product 2", section_element: :aside do
            within_section "Refund", section_element: :section do
              refund_button = find_button("Refund fully", disabled: true)
              refund_button.hover
              expect(refund_button).to have_tooltip(text: "PayPal refunds aren't available after 6 months.")
            end
          end
        end
      end
    end

    describe "option" do
      it "allows updating the option" do
        visit customers_path

        find(:table_row, { "Name" => "Customer 2" }).click

        within_section "Membership", section_element: :aside do
          within_section "Tier", section_element: :section do
            expect(page).to have_section("First Tier")
            click_on "Edit"
            expect(page).to have_field("Tier", with: membership.alive_variants.first.external_id)
            click_on "Cancel"
            expect(page).to_not have_field("Tier")
            click_on "Edit"
            select "Second Tier", from: "Tier"
            click_on "Save"
          end
        end

        expect(page).to have_alert(text: "Saved variant")

        within_section "Membership", section_element: :aside do
          within_section "Tier", section_element: :section do
            expect(page).to have_section("Second Tier")
          end
        end

        expect(purchase2.reload.variant_attributes.first).to eq(membership.variants.second)
      end

      context "when the purchase is missing an option" do
        before do
          purchase2.update!(variant_attributes: [])
        end

        it "allows updating the option" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 2" }).click

          within_section "Membership", section_element: :aside do
            within_section "Tier", section_element: :section do
              expect(page).to have_section("None selected")
              click_on "Edit"
              expect(page).to have_field("Tier", with: "None selected")
              click_on "Cancel"
              expect(page).to_not have_field("Tier")
              click_on "Edit"
              click_on "Save"
              expect(page).to have_field("Tier", aria: { invalid: true })
              select "Second Tier", from: "Tier"
              click_on "Save"
            end
          end

          expect(page).to have_alert(text: "Saved variant")

          within_section "Membership", section_element: :aside do
            within_section "Tier", section_element: :section do
              expect(page).to have_section("Second Tier")
            end
          end

          expect(purchase2.reload.variant_attributes.first).to eq(membership.variants.second)
        end
      end

      context "coffee product" do
        let(:coffee) { create(:coffee_product) }
        before do
          purchase1.update!(link: coffee, seller: coffee.user)
        end

        it "does not allow changing version" do
          visit customers_path
          find(:table_row, { "Name" => "Customer 1" }).click
          expect(page).to_not have_section("Version")
        end
      end
    end

    describe "product review response" do
      it "allows creating, updating, and deleting a response" do
        review = create(:product_review, purchase: purchase1, message: "Amazing!")

        visit customers_path
        find(:table_row, { "Name" => "Customer 1" }).click

        within_section "Review" do
          click_on "Add response"
          fill_in "Add a response to the review", with: "Thank you!"
          click_on "Submit"
        end
        expect(page).to have_alert(text: "Response submitted successfully!")
        expect(review.response.reload.message).to eq("Thank you!")

        within_section "Review" do
          click_on "Edit"
          fill_in "Add a response to the review", with: "Thank you, again!"
          click_on "Update"
        end
        expect(page).to have_alert(text: "Response updated successfully!")
        expect(review.response.reload.message).to eq("Thank you, again!")

        within_section "Review" do
          click_on "Delete"
          within_modal "Delete this response?" do
            click_on "Delete"
          end
        end
        expect(page).to have_alert(text: "Response deleted successfully!")
        expect(page).to have_button("Add response")
        expect(review.reload.response).to be_nil
      end
    end

    describe "product review videos" do
      let(:review) { create(:product_review, purchase: purchase1, message: "Amazing!") }
      let!(:pending_video) do
        create(
          :product_review_video,
          :pending_review,
          product_review: review,
          video_file: create(:video_file, :with_thumbnail)
        )
      end
      let!(:approved_video) do
        create(
          :product_review_video,
          :approved,
          product_review: review,
          video_file: create(:video_file, :with_thumbnail)
        )
      end

      it "allows approving a video" do
        visit customers_path
        find(:table_row, { "Email" => purchase1.email }).click

        within_section "Review" do
          within_section "Approved video" do
            expect(page).to have_image(src: approved_video.video_file.thumbnail_url)
            expect(page).to have_text("Remove")
          end

          within_section "Pending video" do
            expect(page).to have_image(src: pending_video.video_file.thumbnail_url)
            expect(page).to have_text("Approve")
            expect(page).to have_text("Reject")
          end
        end

        click_on "Approve"
        expect(page).to have_alert(text: "This video is now live!")
        expect(pending_video.reload.approved?).to eq(true)

        within_section "Review" do
          within_section "Approved video" do
            expect(page).to have_image(src: pending_video.video_file.thumbnail_url)
          end
          expect(page).to_not have_section("Pending video")
        end
      end

      it "allows rejecting a video" do
        visit customers_path
        find(:table_row, { "Email" => purchase1.email }).click

        within_section "Review" do
          within_section "Approved video" do
            expect(page).to have_image(src: approved_video.video_file.thumbnail_url)
            expect(page).to have_text("Remove")
          end

          within_section "Pending video" do
            expect(page).to have_image(src: pending_video.video_file.thumbnail_url)
            expect(page).to have_text("Reject")
            expect(page).to have_text("Approve")
          end
        end

        # Rejecting the pending video should not affect the approved video.
        within_section "Review" do
          within_section "Approved video" do
            expect(page).to have_image(src: approved_video.video_file.thumbnail_url)
            expect(page).to have_text("Remove")
          end

          within_section "Pending video" do
            expect(page).to have_image(src: pending_video.video_file.thumbnail_url)
            expect(page).to have_text("Reject")
            expect(page).to have_text("Approve")

            click_on "Reject"
          end
        end

        expect(page).to have_alert(text: "This video has been removed.")
        expect(pending_video.reload.rejected?).to eq(true)

        within_section "Review" do
          expect(page).to_not have_section("Pending video")
        end

        # Removing the approved video requires confirmation.
        within_section "Review" do
          within_section "Approved video" do
            expect(page).to have_image(src: approved_video.video_file.thumbnail_url)
            expect(page).to have_text("Remove")

            click_on "Remove"

            within_modal "Remove approved video?" do
              click_on "Remove video"
            end
          end
        end

        expect(page).to_not have_section("Approved video")
        expect(approved_video.reload.rejected?).to eq(true)
      end
    end

    describe "call" do
      let(:call_product) { create(:call_product, :available_for_a_year, user: seller) }
      let!(:call_purchase) { create(:call_purchase, seller:, link: call_product, full_name: "Call Customer", created_at: Time.current) }

      before do
        allow_any_instance_of(Call).to receive(:start_time).and_return(DateTime.parse("January 1 2024 12:00"))
        allow_any_instance_of(Call).to receive(:end_time).and_return(DateTime.parse("January 1 2024 12:30"))
        index_model_records(Purchase)
      end

      it "displays the call details and doesn't allow editing the variant" do
        visit customers_path
        find(:table_row, { "Name" => "Call Customer" }).click

        expect(page).to_not have_section("Version")

        expect(page).to have_text("Start time Monday, January 1, 2024 at 04:00 AM PST", normalize_ws: true)
        expect(page).to have_text("End time Monday, January 1, 2024 at 04:30 AM PST", normalize_ws: true)

        fill_in "Call URL", with: "https://zoom.us/j/dumb"
        click_on "Save"
        expect(page).to have_alert(text: "Call URL updated!")
        expect(call_purchase.call.reload.call_url).to eq("https://zoom.us/j/dumb")

        refresh
        find(:table_row, { "Name" => "Call Customer" }).click
        fill_in "Call URL", with: "https://zoom.us/j/dumber"
        click_on "Save"
        expect(page).to have_alert(text: "Call URL updated!")
        expect(call_purchase.call.reload.call_url).to eq("https://zoom.us/j/dumber")
      end
    end
  end
end
