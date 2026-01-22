# frozen_string_literal: true

require "spec_helper"

describe "Admin::LinksController Scenario", type: :system, js: true do
  let(:admin_user) { create(:admin_user) }
  let(:product) { create(:product) }

  before do
    login_as(admin_user)
  end

  it "renders the product page", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    # It renders stats
    purchases = Purchase.where(link: product)
    Event.destroy_by(purchase: purchases)
    purchases.destroy_all
    recreate_model_index(ProductPageView)
    2.times { add_page_view(product) }
    25.times { create(:purchase_event, purchase: create(:purchase, link: product, price_cents: 200)) }
    visit admin_product_path(product.external_id)
    expect(page).to have_text(product.name)
    expect(page).to have_text("2 views")
    expect(page).to have_text("25 sales")
    expect(page).to have_text("$50 total")

    # With purchases, it renders purchases list
    toggle_disclosure("Purchases")
    wait_for_ajax
    click_on("Load more")
    wait_for_ajax
    expect(page).to_not have_text("Load more")
    expect(page).to have_text("$2", count: 25)

    # Product files display
    regular_file = create(:product_file, link: product, position: 1)
    external_link_file = create(:product_file, link: product, position: 2, filetype: "link", url: "https://example.com/external-resource")
    page.refresh
    expect(page).to have_link(regular_file.s3_filename)
    expect(page).to have_link(external_link_file.external_id)

    # It marks the product as staff-picked
    product = create(:product, :recommendable)
    visit admin_product_path(product.external_id)
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Mark as staff-picked")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Marked as staff-picked!")
    expect(product.reload.staff_picked?).to eq(true)

    # It deletes the product
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Delete")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Deleted!")
    expect(product.reload.deleted_at?).to eq(true)

    # It restores the product
    page.refresh
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Undelete")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Undeleted!")
    expect(product.reload.deleted_at?).to eq(false)

    # It publishes the product
    product.update!(purchase_disabled_at: Time.current)
    page.refresh
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Publish")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Published!")
    expect(product.reload.purchase_disabled_at?).to eq(false)

    # It unpublishes the product
    page.refresh
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Unpublish")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Unpublished!")
    expect(product.reload.purchase_disabled_at?).to eq(true)

    # It marks the product as adult
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Make adult")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "It's adult!")
    expect(product.reload.is_adult?).to eq(true)

    # It marks the product as non-adult
    page.refresh
    within_section(product.name, section_element: :article) do
      accept_confirm do
        click_on("Make non-adult")
      end
    end
    wait_for_ajax
    expect(page).to have_alert(text: "It's not adult!")
    expect(product.reload.is_adult?).to eq(false)

    # it shows and post comments
    within_section(product.name, section_element: :article) do
      toggle_disclosure("0 comments")
      expect(page).to have_text("No comments created")
      fill_in("comment[content]", with: "Good article!")
      accept_confirm do
        click_on("Add comment")
      end
      wait_for_ajax
      expect(page).to have_text("1 comment")
      expect(page).to have_text("Good article!")
    end
    expect(page).to have_alert(text: "Successfully added comment.")
  end

  describe "mass refund for fraud" do
    let!(:purchase1) { create(:purchase, link: product) }
    let!(:purchase2) { create(:purchase, link: product) }

    it "allows selecting purchases and refunding for fraud" do
      visit admin_product_path(product.external_id)

      toggle_disclosure("Purchases")
      expect(page).to have_text("Select purchases to refund for fraud")
      expect(page).to have_button("Refund for Fraud", disabled: true)

      checkboxes = all("input[type='checkbox']")
      checkboxes.first.check

      expect(page).to have_text("1 purchase selected")
      expect(page).to have_button("Refund for Fraud", disabled: false)
      expect(page).to have_button("Clear selection")
    end

    it "allows selecting all purchases" do
      visit admin_product_path(product.external_id)

      toggle_disclosure("Purchases")
      expect(page).to have_text("Select purchases to refund for fraud")

      click_on("Select all")

      expect(page).to have_text("2 purchases selected")
      expect(page).to have_button("Clear selection")
      expect(page).not_to have_button("Select all")
    end

    it "clears selection when clicking clear selection" do
      visit admin_product_path(product.external_id)

      toggle_disclosure("Purchases")
      expect(page).to have_text("Select purchases to refund for fraud")

      click_on("Select all")
      expect(page).to have_text("2 purchases selected")

      click_on("Clear selection")

      expect(page).to have_text("Select purchases to refund for fraud")
      expect(page).to have_button("Refund for Fraud", disabled: true)
    end

    it "enqueues mass refund job when confirmed" do
      visit admin_product_path(product.external_id)

      toggle_disclosure("Purchases")
      expect(page).to have_text("Select purchases to refund for fraud")

      click_on("Select all")
      expect(page).to have_text("2 purchases selected")

      accept_confirm do
        click_on("Refund for Fraud")
      end

      expect(page).to have_alert(text: "Processing 2 fraud refunds")
      expect(MassRefundForFraudJob).to have_enqueued_sidekiq_job(
        product.id,
        array_including(purchase1.external_id, purchase2.external_id),
        admin_user.id
      ).on("default")
    end
  end
end
