# frozen_string_literal: true

require "spec_helper"

describe "Admin::LinksController Scenario", type: :system, js: true do
  let(:product) { create(:product) }
  before do
    login_as(create(:admin_user))
  end

  xdescribe "views and sales async" do
    before do
      recreate_model_index(ProductPageView)
      2.times { add_page_view(product) }
      4.times { create(:purchase_event, purchase: create(:purchase, link: product)) }
    end

    it "renders stats", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      visit admin_link_path(product.unique_permalink)

      expect(page).to have_text(product.name)
      expect(page).to have_text("2 views")
      expect(page).to have_text("4 sales")
      expect(page).to have_text("$4 total")
    end
  end

  describe "purchases async" do
    context "with no purchases" do
      it "renders info message" do
        visit admin_link_path(product.unique_permalink)

        toggle_disclosure("Purchases")
        wait_for_ajax
        expect(page).to have_text("No purchases have been made")
      end
    end

    context "with purchases" do
      let(:purchase_count) { 25 }

      before do
        purchase_count.times.map do |n|
          create(:purchase, price_cents: 299, link: product)
        end
      end

      it "renders purchases" do
        visit admin_link_path(product.unique_permalink)

        toggle_disclosure("Purchases")
        wait_for_ajax
        click_on("Load more")
        wait_for_ajax
        expect(page).to_not have_text("Load more")
        expect(page).to have_text("$2.99", count: purchase_count)
      end
    end
  end

  describe "Staff pick" do
    let(:product) { create(:product, :recommendable) }

    it "marks product as staff-picked" do
      visit admin_link_path(product.unique_permalink)

      within_section(product.name, section_element: :article) do
        accept_confirm do
          click_on("Mark as staff-picked")
        end
      end

      wait_for_ajax
      expect(page).to have_alert(text: "Marked as staff-picked!")
      expect(product.reload.staff_picked?).to eq(true)
    end
  end

  describe "Product files display" do
    context "when product has files with and without s3_filename" do
      let!(:regular_file) { create(:product_file, link: product, position: 1) }
      let!(:external_link_file) { create(:product_file, link: product, position: 2, filetype: "link", url: "https://example.com/external-resource") }

      it "renders product card with all files showing correct fallback text" do
        visit admin_link_path(product.unique_permalink)

        expect(page).to have_link(regular_file.s3_filename)
        expect(page).to have_link(external_link_file.external_id)
      end
    end
  end
end
