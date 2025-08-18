# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/products_navigation"
require "shared_examples/with_sorting_and_pagination"

describe "Products Page Scenario", type: :system, js: true do
  include ProductEditPageHelpers

  def find_product_row(product, hover: false)
    row = find(:table_row, { "Name" => product.name })
    row.hover if hover
    row
  end

  let(:seller) { create(:named_seller) }

  include_context "with switching account to user as admin for seller"

  describe "navigation" do
    it_behaves_like "tab navigation on products page" do
      let(:url) { products_path }
    end

    it "navigates to filtered customers page when sales count is clicked" do
      product = create(:product, user: seller)

      visit(products_path)
      within find_product_row product do
        find_and_click("[data-label='Sales'] a")
      end

      expect(page).to have_section("Sales")
      select_disclosure "Filter" do
        expect(page).to have_button(product.name)
      end
    end

    context "product edit page" do
      it "navigates from title and description" do
        product = create(:product, user: seller)
        visit(products_path)

        within find_product_row(product) do
          click_on product.name
        end

        expect(page).to have_current_path(edit_link_path(product))
      end
    end
  end

  describe "deletion" do
    it "deletes a membership" do
      membership = create(:subscription_product, user: seller)

      visit(products_path)

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Cancel"
      end

      expect(page).not_to have_alert(text: "Product deleted!")

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Confirm"
      end

      expect(page).to have_alert(text: "Product deleted!")
    end

    it "deletes a product" do
      product = create(:product, user: seller)

      visit(products_path)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Cancel"
      end

      expect(page).not_to have_alert(text: "Product deleted!")

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Confirm"
      end

      expect(page).to have_alert(text: "Product deleted!")
    end

    it "disables the delete menuitem if the user isn't authorized" do
      expect_any_instance_of(LinkPolicy).to receive(:destroy?).and_return(false)
      product = create(:product, user: seller)

      visit products_path

      within find_product_row(product) do
        select_disclosure "Open product action menu" do
          expect(page).to have_menuitem("Delete", disabled: true)
        end
      end
    end
  end

  describe "duplication" do
    it "duplicates a membership" do
      membership = create(:subscription_product, user: seller)

      visit(products_path)

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end

      wait_for_ajax

      # This is less flaky compared to using Sidekiq inline
      DuplicateProductWorker.new.perform(membership.id)

      expect(page).to have_content("#{membership.name} (copy)")
    end

    it "duplicates a product" do
      product = create(:product, user: seller)

      visit(products_path)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end

      wait_for_ajax

      # This is less flaky compared to using Sidekiq inline
      DuplicateProductWorker.new.perform(product.id)

      expect(page).to have_content("#{product.name} (copy)")
    end

    it "shows loading state when creator requests to duplicate a product" do
      product = create(:product, user: seller)
      visit(products_path)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
        expect(page).to have_menuitem("Duplicating...", disabled: true)
      end
      expect(page).to have_alert(text: "Duplicating the product. You will be notified once it's ready.")
    end

    it "shows loading state on page load when product is duplicating" do
      product = create(:product, user: seller, is_duplicating: true)
      visit(products_path)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
        expect(page).to have_menuitem("Duplicating...", disabled: true)
      end
    end

    it "shows error flash message on request to duplicate a product that is still processing" do
      product = create(:product, user: seller, is_duplicating: true)
      visit(products_path)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
        expect(page).to have_menuitem("Duplicating...", disabled: true)
      end
      expect(page).to have_alert(text: "Duplication in progress...")
    end

    it "shows error flash message when product duplication fails" do
      product = create(:product, user: seller)
      expect(seller.links.alive.count).to eq 1
      allow_any_instance_of(ProductDuplicatorService).to receive(:duplicate_third_party_analytics).and_raise(RuntimeError)
      visit(products_path)
      expect do
        within find_product_row(product) do
          select_disclosure "Open product action menu" do
            click_on "Duplicate"
          end
        end
        expect(page).to have_alert(text: "Duplicating the product. You will be notified once it's ready.")
      end.to(change { Link.count }.by(0))
    end

    it "succeeds if the product has buy and rental prices" do
      product = create(:product, user: seller, purchase_type: "buy_and_rent", price_cents: 500, rental_price_cents: 300)
      create(:price, link: product, price_cents: 300, is_rental: true)

      visit products_path
      within find_product_row(product) do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end

      wait_for_ajax

      expect(DuplicateProductWorker).to have_enqueued_sidekiq_job(product.id)

      # Doing this manually instead of sidekiq inline to have better control over assertions/non flaky waits
      DuplicateProductWorker.new.perform(product.id)

      wait_for_ajax

      expect(page).to have_alert(text: "#{product.name} is duplicated")
      expect(page).to have_content("#{product.name} (copy)")

      duplicate_product = Link.last
      expect(duplicate_product.rental_price_cents).to eq 300
      expect(duplicate_product.buy_price_cents).to eq 500
    end

    it "duplicates the product-level rich content along with the file embeds" do
      product = create(:product, user: seller)
      product_file1 = create(:product_file, link: product)
      product_file2 = create(:readable_document, link: product)
      content = [
        { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => "product-file-1-uid" } },
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
        { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => "product-file-2-uid" } },
      ]
      create(:rich_content, entity: product, description: content)

      visit products_path
      within find_product_row(product) do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end
      wait_for_ajax
      expect(DuplicateProductWorker).to have_enqueued_sidekiq_job(product.id)
      DuplicateProductWorker.new.perform(product.id)

      expect(page).to have_alert(text: "#{product.name} is duplicated")
      click_on "#{product.name} (copy)"
      select_tab "Content"

      expect(page).to have_text("Lorem ipsum")
      expect(page).to have_embed(name: product_file1.name_displayable)
      expect(page).to have_embed(name: product_file2.name_displayable)
    end

    it "duplicates the variant-level rich content along with the file embeds" do
      product = create(:product, user: seller)
      product_file1 = create(:product_file, link: product)
      product_file2 = create(:readable_document, link: product)
      category = create(:variant_category, link: product, title: "Versions")
      version1 = create(:variant, variant_category: category, name: "Version 1")
      version1.product_files << product_file1
      version2 = create(:variant, variant_category: category, name: "Version 2")
      version2.product_files << product_file2
      create(:rich_content, entity: version1, description: [
               { "type" => "paragraph", "content" => [{ "text" => "This is Version 1 content", "type" => "text" }] },
               { "type" => "fileEmbed", "attrs" => { "id" => product_file1.external_id, "uid" => "product-file-1-uid" } }
             ])
      create(:rich_content, entity: version2, description: [
               { "type" => "paragraph", "content" => [{ "text" => "This is Version 2 content", "type" => "text" }] },
               { "type" => "fileEmbed", "attrs" => { "id" => product_file2.external_id, "uid" => "product-file-2-uid" } }
             ])

      visit products_path
      within find_product_row(product) do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end
      wait_for_ajax
      expect(DuplicateProductWorker).to have_enqueued_sidekiq_job(product.id)
      DuplicateProductWorker.new.perform(product.id)

      expect(page).to have_alert(text: "#{product.name} is duplicated")
      click_on "#{product.name} (copy)"
      select_tab "Content"

      expect(page).to have_combo_box("Select a version", text: "Editing: Version 1")
      expect(page).to have_text("This is Version 1 content")
      expect(page).to have_embed(name: product_file1.name_displayable)
      expect(page).to_not have_embed(name: product_file2.name_displayable)

      select_combo_box_option("Version 2", from: "Select a version")
      expect(page).to have_text("This is Version 2 content")
      expect(page).to_not have_embed(name: product_file1.name_displayable)
      expect(page).to have_embed(name: product_file2.name_displayable)
    end

    it "disables the duplicate menuitem if the user isn't authorized" do
      expect_any_instance_of(ProductDuplicates::LinkPolicy).to receive(:create?).and_return(false)
      product = create(:product, user: seller)

      visit products_path

      within find_product_row(product) do
        select_disclosure "Open product action menu" do
          expect(page).to have_menuitem("Duplicate", disabled: true)
        end
      end
    end
  end

  describe "actions popover" do
    it "is hidden if the use isn't authorized to delete or duplicate" do
      expect_any_instance_of(LinkPolicy).to receive(:destroy?).and_return(false)
      expect_any_instance_of(ProductDuplicates::LinkPolicy).to receive(:create?).and_return(false)
      product = create(:product, user: seller)

      visit products_path

      within find_product_row(product) do
        expect(page).to_not have_disclosure "Open product action menu"
      end
    end
  end

  describe "pagination" do
    before do
      stub_const("LinksController::PER_PAGE", 1)
    end

    it "paginates memberships" do
      membership1 = create(:membership_product, created_at: 3.days.ago, name: "Name 1", user: seller)
      membership2 = create(:membership_product, created_at: 2.days.ago, name: "Name 2", user: seller)
      membership3 = create(:membership_product, created_at: 1.day.ago, name: "Name 3", user: seller)

      visit products_path

      # Page 1
      expect(page).to have_nth_table_row_record(1, membership3.name, exact_text: false)
      expect(page).not_to have_nth_table_row_record(1, membership2.name, exact_text: false)
      expect(page).not_to have_nth_table_row_record(1, membership1.name, exact_text: false)
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next")
      expect(find_button("1")["aria-current"]).to eq("page")
      expect(find_button("2")["aria-current"]).to be_nil
      expect(find_button("3")["aria-current"]).to be_nil

      # Page 2
      click_on "Next"
      wait_for_ajax

      expect(page).not_to have_nth_table_row_record(1, membership3.name, exact_text: false)
      expect(page).to have_nth_table_row_record(1, membership2.name, exact_text: false)
      expect(page).not_to have_nth_table_row_record(1, membership1.name, exact_text: false)
      expect(page).to have_button("Previous")
      expect(page).to have_button("Next")
      expect(find_button("1")["aria-current"]).to be_nil
      expect(find_button("2")["aria-current"]).to eq("page")
      expect(find_button("3")["aria-current"]).to be_nil

      # Page 3
      click_on "3"
      wait_for_ajax

      expect(page).not_to have_nth_table_row_record(1, membership3.name, exact_text: false)
      expect(page).not_to have_nth_table_row_record(1, membership2.name, exact_text: false)
      expect(page).to have_nth_table_row_record(1, membership1.name, exact_text: false)
      expect(page).to have_button("Previous")
      expect(page).to have_button("Next", disabled: true)
      expect(find_button("1")["aria-current"]).to be_nil
      expect(find_button("2")["aria-current"]).to be_nil
      expect(find_button("3")["aria-current"]).to eq("page")
    end

    it "paginates products" do
      products = {}

      15.times do |i|
        products[i] = create(:product, created_at: i.days.ago, name: "Name #{i}", user: seller)
      end

      visit products_path

      # Page 1
      expect(page).to have_selector(:table_row, { "Name" => products[0].name })
      expect(page).not_to have_selector(:table_row, { "Name" => products[1].name })
      expect(page).not_to have_selector(:table_row, { "Name" => products[2].name })
      expect(page).to have_button("1", exact: true)
      expect(page).to have_button("9", exact: true)
      expect(page).not_to have_button("10", exact: true)
      expect(page).to have_button("15", exact: true)


      # Page 2
      click_on "Next"
      wait_for_ajax

      expect(page).to have_selector(:table_row, { "Name" => products[1].name })

      # Page 15
      click_on "15"
      wait_for_ajax

      expect(page).to have_selector(:table_row, { "Name" => products[14].name })
      expect(page).to have_button("7", exact: true)
      expect(page).to have_button("15", exact: true)
      expect(page).not_to have_button("6", exact: true)
      expect(page).to have_button("1", exact: true)

      # Page 14
      click_on "Previous"
      wait_for_ajax

      expect(page).to have_selector(:table_row, { "Name" => products[13].name })

      # Page 7
      click_on "7"
      wait_for_ajax

      expect(page).to have_selector(:table_row, { "Name" => products[6].name })
      expect(page).to have_button("3", exact: true)
      expect(page).to have_button("10", exact: true)
      expect(page).not_to have_button("2", exact: true)
      expect(page).not_to have_button("11", exact: true)
      expect(page).to have_button("1", exact: true)
      expect(page).to have_button("15", exact: true)
    end
  end

  describe "product sorting" do
    include_context "with products and memberships"

    it_behaves_like "a table with sorting", "Products" do
      before do
        visit(products_path)
      end

      let!(:default_order) { [product1, product3, product4, product2] }
      let!(:columns) do
        {
          "Name" => [product1, product2, product3, product4],
          "Sales" => [product1, product2, product3, product4],
        }
      end
      let!(:boolean_columns) { { "Status" => [product3, product4, product1, product2] } }
    end
  end

  describe "membership sorting" do
    include_context "with products and memberships"

    it_behaves_like "a table with sorting", "Memberships" do
      before do
        visit(products_path)
      end

      let!(:default_order) { [membership2, membership3, membership4, membership1] }
      let!(:columns) do
        {
          "Name" => [membership1, membership2, membership3, membership4],
          "Members" => [membership4, membership1, membership3, membership2],
        }
      end
      let!(:boolean_columns) { { "Status" => [membership3, membership4, membership2, membership1] } }
    end
  end

  describe "searching" do
    before do
      per_page = 2
      per_page.times do
        create(:product, user: seller, name: "Pig")
      end
      stub_const("LinksController::PER_PAGE", per_page)
    end

    it "shows the search results" do
      product = create(:product, user: seller, name: "Chicken", unique_permalink: "chicken")
      visit(products_path)

      expect(page).to have_field("Search products", visible: false)
      table = find(:table, "Products").find("tbody")
      expect(table).to have_selector(:table_row, count: 2)
      expect(page).to have_selector("[aria-label='Pagination']")

      select_disclosure "Toggle Search" do
        expect(page).to have_field("Search products")
      end
      fill_in "Search products", with: "Chicken"
      find_product_row product
      expect(table).to have_selector(:table_row, count: 1)
      expect(page).not_to have_selector("[aria-label='Pagination']")
    end

    it "duplicates a product" do
      product = create(:product, user: seller, name: "Test product")
      stub_const("LinksController::PER_PAGE", 1)
      visit(products_path)

      select_disclosure "Toggle Search" do
        fill_in "Search products", with: "product"
      end
      expect(page).to have_link(product.long_url, href: product.long_url)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end
      expect(page).to have_alert(text: "Duplicating the product. You will be notified once it's ready.")
    end

    it "duplicates a membership" do
      membership = create(:subscription_product, user: seller, name: "Test membership")
      stub_const("LinksController::PER_PAGE", 1)
      visit(products_path)

      select_disclosure "Toggle Search" do
        fill_in "Search products", with: "membership"
      end
      expect(page).to have_link(membership.long_url, href: membership.long_url)

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Duplicate"
        end
      end
      expect(page).to have_alert(text: "Duplicating the product. You will be notified once it's ready.")
    end

    it "deletes a product" do
      product = create(:product, user: seller, name: "Test product")
      stub_const("LinksController::PER_PAGE", 1)
      visit(products_path)

      select_disclosure "Toggle Search" do
        fill_in "Search products", with: "product"
      end
      expect(page).to have_link(product.long_url, href: product.long_url)

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Confirm"
      end
      expect(page).to have_alert(text: "Product deleted!")
    end

    it "deletes a membership" do
      membership = create(:subscription_product, user: seller, name: "Test membership")
      stub_const("LinksController::PER_PAGE", 1)
      visit(products_path)

      select_disclosure "Toggle Search" do
        fill_in "Search products", with: "membership"
      end
      expect(page).to have_link(membership.long_url, href: membership.long_url)

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Delete"
        end
        click_on "Confirm"
      end
      expect(page).to have_alert(text: "Product deleted!")
    end
  end

  describe "dashboard stats" do
    before do
      @digital_product = create(:product, user: seller, price_cents: 10_00, name: "Product 1")
      create(:purchase, link: @digital_product)
      create(:purchase, link: @digital_product)
      create(:refunded_purchase, link: @digital_product)
      create(:purchase, link: @digital_product, purchase_state: "in_progress")

      @membership = create(:membership_product_with_preset_tiered_pricing, user: seller, name: "My membership")
      create(:membership_purchase, link: @membership, price_cents: 10_00, variant_attributes: [@membership.default_tier])
      create(:membership_purchase, link: @membership, price_cents: 10_00, variant_attributes: [@membership.default_tier])
      create(:membership_purchase, link: @membership, price_cents: 10_00, variant_attributes: [@membership.default_tier], purchase_state: "in_progress")
      cancelled_membership = create(:membership_purchase, link: @membership, price_cents: 10_00, variant_attributes: [@membership.default_tier])
      cancelled_membership.subscription.update!(cancelled_at: 1.day.ago)

      index_model_records(Purchase)
      index_model_records(Link)
    end

    context "when data is not cached" do
      it "renders the correct stats" do
        expect do
          visit(products_path)
        end.to change { CacheProductDataWorker.jobs.size }.by(2)

        expect(page).to have_table("Memberships", with_rows: [
                                     { "Name" => @membership.name, "Members" => "3", "Revenue" => "$30" }
                                   ])

        expect(page).to have_table("Products", with_rows: [
                                     { "Name" => @digital_product.name, "Sales" => "2", "Revenue" => "$20" }
                                   ])
      end
    end

    context "when data is cached" do
      before do
        @digital_product.product_cached_values.create!
        @membership.product_cached_values.create!
      end

      it "renders the correct stats" do
        expect do
          visit(products_path)
        end.to_not change { CacheProductDataWorker.jobs.size }

        expect(page).to have_table("Memberships", with_rows: [
                                     { "Name" => @membership.name, "Members" => "3", "Revenue" => "$30" }
                                   ])

        expect(page).to have_table("Products", with_rows: [
                                     { "Name" => @digital_product.name, "Sales" => "2", "Revenue" => "$20" }
                                   ])
      end
    end
  end

  describe "Archiving" do
    it "archives a membership" do
      membership = create(:subscription_product, user: seller)

      visit(products_path)

      expect(page).not_to have_tab_button("Archived")

      within find_product_row membership do
        select_disclosure "Open product action menu" do
          click_on "Archive"
        end
      end
      wait_for_ajax

      expect(page).to have_tab_button("Archived")
      expect(page).not_to have_content(membership.name)

      find(:tab_button, "Archived").click

      expect(page).to have_content(membership.name)
    end

    it "archives a product" do
      product = create(:product, user: seller)

      visit(products_path)

      expect(page).not_to have_tab_button("Archived")

      within find_product_row product do
        select_disclosure "Open product action menu" do
          click_on "Archive"
        end
      end
      wait_for_ajax

      expect(page).to have_tab_button("Archived")
      expect(page).not_to have_content(product.name)

      find(:tab_button, "Archived").click

      expect(page).to have_content(product.name)
    end
  end
end
