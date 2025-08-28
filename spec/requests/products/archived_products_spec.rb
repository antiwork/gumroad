# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/products_navigation"
require "shared_examples/with_sorting_and_pagination"

describe "Archived Products", type: :system, js: true do
  let(:seller) { create(:named_seller) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "tab navigation on products page" do
    let(:url) { products_archived_index_path }
  end

  describe "pagination" do
    before do
      stub_const("Products::ArchivedController::PER_PAGE", 1)
    end

    it "paginates archived memberships" do
      membership1 = create(:membership_product, created_at: 3.days.ago, name: "Name 1", user: seller, archived: true)
      membership2 = create(:membership_product, created_at: 2.days.ago, name: "Name 2", user: seller, archived: true)
      membership3 = create(:membership_product, created_at: 1.day.ago, name: "Name 3", user: seller, archived: true)

      visit products_archived_index_path

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
      click_on "2"
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

    it "paginates archived products" do
      products = {}

      15.times do |i|
        products[i] = create(:product, created_at: i.days.ago, name: "Name #{i}", user: seller, archived: true)
      end

      visit products_archived_index_path

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
      expect(page).to have_button("15", exact: true)
    end
  end

  describe "archived product sorting" do
    include_context "with products and memberships", true

    it_behaves_like "a table with sorting", "Products" do
      before do
        visit(products_archived_index_path)
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

  describe "archived membership sorting" do
    include_context "with products and memberships", true

    it_behaves_like "a table with sorting", "Memberships" do
      before do
        visit(products_archived_index_path)
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

  describe "Unarchiving" do
    let!(:archived_membership) { create(:membership_product, user: seller, name: "archived_membership", archived: true) }
    let!(:archived_product) { create(:product, user: seller, name: "archived_product", archived: true) }

    it "unarchives a membership" do
      visit(products_archived_index_path)

      within find(:table_row, { "Name" => archived_membership.name }) do
        select_disclosure "Open product action menu" do
          click_on "Unarchive"
        end
      end
      wait_for_ajax

      expect(page).to have_alert(text: "Product was unarchived successfully")
      expect(page).not_to have_content(archived_membership.name)
      expect(archived_membership.reload.archived).to eq(false)
    end

    it "unarchives a product" do
      visit(products_archived_index_path)

      within find(:table_row, { "Name" => archived_product.name }) do
        select_disclosure "Open product action menu" do
          click_on "Unarchive"
        end
      end
      wait_for_ajax

      expect(page).to have_alert(text: "Product was unarchived successfully")
      expect(page).not_to have_content(archived_product.name)
      expect(archived_product.reload.archived).to eq(false)
    end

    context "with one product left on the page" do
      before do
        archived_membership.update!(archived: false)
      end

      it "redirects to the products page after unarchiving" do
        visit(products_archived_index_path)

        within find(:table_row, { "Name" => archived_product.name }) do
          select_disclosure "Open product action menu" do
            click_on "Unarchive"
          end
        end
        wait_for_ajax

        expect(page).to have_current_path(products_path)
      end
    end
  end
end
