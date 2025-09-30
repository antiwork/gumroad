# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe("Bundle edit page", type: :system, js: true) do
  let(:seller) { create(:named_seller) }
  let(:bundle) { create(:product, :bundle, user: seller, price_cents: 200) }
  let!(:asset_preview1) { create(:asset_preview, link: bundle) }
  let!(:asset_preview2) { create(:asset_preview_gif, link: bundle) }

  include_context "with switching account to user as admin for seller"

  it_behaves_like "creator dashboard page", "Products" do
    let(:path) { bundle_path(bundle.external_id) }
  end

  it "updates the bundle" do
    Feature.activate_user(:audio_previews, seller)

    visit bundle_path(bundle.external_id)

    in_preview { expect(page).to have_section("Bundle") }
    find_field("Name", with: "Bundle").fill_in with: "New bundle"
    in_preview { expect(page).to have_section("New bundle") }

    rich_text_editor_input = find("[aria-label='Description']")
    expect(rich_text_editor_input).to have_text("This is a bundle of products")
    in_preview { expect(page).to have_text("This is a bundle of products") }
    set_rich_text_editor_input rich_text_editor_input, to_text: "This is a new bundle of products"
    in_preview { expect(page).to have_text("This is a new bundle of products") }
    page.attach_file(file_fixture("test.jpg")) do
      click_on "Insert image"
    end
    attach_file file_fixture("test.mp3") do
      click_on "Insert audio"
    end
    expect(page).to have_button("Save changes", disabled: true)
    expect(page).to have_button("Unpublish", disabled: true)
    wait_for_file_embed_to_finish_uploading(name: "test")
    wait_for_ajax
    in_preview { expect(page).to have_selector("img[src*='gumroad-specs.s3.amazonaws.com']") }
    in_preview { expect(page).to have_embed(name: "test") }

    find_field("URL", with: "").fill_in with: "bundle"

    in_preview { expect(page).to have_selector("[itemprop='price']", text: "$2") }
    find_field("Amount", with: "2").fill_in with: "1"
    in_preview { expect(page).to have_selector("[itemprop='price']", text: "$2 $1") }

    in_preview { expect(page).to_not have_field("Name a fair price:") }
    expect(page).to have_unchecked_field("Allow customers to pay what they want")
    check "Allow customers to pay what they want"
    in_preview { expect(page).to have_field("Name a fair price:", placeholder: "1+") }
    in_preview { expect(page).to have_selector("[itemprop='price']", text: "$2 $1+") }
    expect(page).to have_field("Minimum amount", with: "1", disabled: true)

    find_field("Suggested amount", with: "").fill_in with: "5"
    in_preview { expect(page).to have_field("Name a fair price:", placeholder: "5+") }

    in_preview { expect(page).to have_selector("img[src*='#{asset_preview1.url}']") }
    within_section "Cover", section_element: :section do
      first("[role='tab'][aria-selected='true']").drag_to first("[role='tab'][aria-selected='false']")
    end
    in_preview { expect(page).to have_selector("img[src*='#{asset_preview2.url}']") }

    in_preview { expect(page).to have_link("I want this!") }
    find_field("Call to action", with: "i_want_this_prompt").find(:option, "Buy this").select_option
    in_preview { expect(page).to have_link("Buy this") }

    find_field("Summary", with: "").fill_in with: "To summarize, I am a bundle."
    in_preview { expect(page).to have_text("To summarize, I am a bundle.") }

    click_on "Add detail"
    within_fieldset "Additional details" do
      inputs = all("input[type='text']")
      inputs[0].fill_in with: "Attribute"
      inputs[1].fill_in with: "Value"
    end
    in_preview { expect(page).to have_text("Attribute Value", normalize_ws: true) }

    in_preview { expect(page).to_not have_text("20 left") }
    check("Limit product sales", unchecked: true)
    fill_in "Maximum number of purchases", with: "20"
    in_preview { expect(page).to have_text("20 left") }

    in_preview { expect(page).to_not have_field("Quantity") }
    check("Allow customers to choose a quantity", unchecked: true)
    in_preview { expect(page).to have_field("Quantity", with: "1") }

    in_preview { expect(page).to_not have_selector("[role='status']") }
    check("Publicly show the number of sales on your product page", unchecked: true)
    in_preview { expect(page).to have_selector("[role='status']", text: "0 sales") }

    check("Mark product as e-publication for VAT purposes", unchecked: true)
    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    product_page = window_opened_by { click_on "Preview" }
    bundle.reload
    within_window(product_page) { expect(page.current_url).to eq(bundle.long_url) }

    expect(bundle.name).to eq("New bundle")
    public_file = bundle.alive_public_files.sole
    expect(bundle.description).to include("<p>This is a new bundle of products</p>")
    expect(bundle.description).to include(%{<figure><img src="https://gumroad-specs.s3.amazonaws.com/#{ActiveStorage::Blob.find_by(filename: "test.jpg").key}"><p class="figcaption"></p></figure>})
    expect(bundle.description).to include(%{<public-file-embed id="#{public_file.public_id}"></public-file-embed>})
    expect(bundle.custom_permalink).to eq("bundle")
    expect(bundle.price_cents).to eq(100)
    expect(bundle.customizable_price).to eq(true)
    expect(bundle.suggested_price_cents).to eq(500)
    expect(bundle.display_asset_previews).to eq([asset_preview2, asset_preview1])
    expect(bundle.custom_button_text_option).to eq("buy_this_prompt")
    expect(bundle.custom_summary).to eq("To summarize, I am a bundle.")
    expect(bundle.custom_attributes).to eq([{ "name" => "Attribute", "value" => "Value" }])
    expect(bundle.max_purchase_count).to eq(20)
    expect(bundle.quantity_enabled).to eq(true)
    expect(bundle.should_show_sales_count).to eq(true)
    expect(bundle.is_epublication?).to eq(true)
  end

  context "when seller refund is set to false" do
    before do
      seller.update!(refund_policy_enabled: false)
      create(:product_refund_policy, seller:, product: create(:product, user: seller, name: "Other product"))
    end

    it "allows updating the bundle refund policy" do
      visit bundle_path(bundle.external_id)

      find_field("Specify a refund policy for this product", unchecked: true).check
      select_disclosure "Copy from other products" do
        select_combo_box_option "Other product"
        click_on "Copy"
      end
      select "7-day money back guarantee", from: "Refund period"
      find_field("Fine print (optional)", with: "This is a product-level refund policy").fill_in with: "I hate being small"
      in_preview { expect(page).to have_modal("7-day money back guarantee", text: "I hate being small") }

      product_page = window_opened_by { click_on "Preview" }
      expect(page).to have_alert(text: "Changes saved!")
      bundle.reload
      within_window(product_page) { expect(page.current_url).to eq(bundle.long_url) }

      expect(bundle.product_refund_policy_enabled?).to eq(true)
      expect(bundle.product_refund_policy.max_refund_period_in_days).to eq(7)
      expect(bundle.product_refund_policy.title).to eq("7-day money back guarantee")
      expect(bundle.product_refund_policy.fine_print).to eq("I hate being small")
    end
  end

  it "updates the covers" do
    visit bundle_path(bundle.external_id)

    within_section "Cover", section_element: :section do
      first("[role='tab']").hover
      find(".remove-button[aria-label='Remove cover']").click
      wait_for_ajax
      first("[role='tab']").hover
      find(".remove-button[aria-label='Remove cover']").click
      wait_for_ajax
      expect(bundle.reload.display_asset_previews).to be_empty

      vcr_turned_on do
        VCR.use_cassette("Update bundle covers") do
          click_on "Upload images or videos"

          attach_file file_fixture("test.png") do
            select_tab "Computer files"
          end
          wait_for_ajax
          expect(page).to have_selector("img[src*='gumroad-specs.s3.amazonaws.com']")
          expect(bundle.reload.display_asset_previews.alive.first.url).to match("gumroad-specs.s3.amazonaws.com")

          select_disclosure "Add cover" do
            click_on "Upload images or videos"
            select_tab "External link"
            fill_in "https://", with: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            click_on "Upload"
          end
          wait_for_ajax
          all("img[src*='gumroad-specs.s3.amazonaws.com']").last.hover
          click_on "Show next cover"
          expect(page).to have_selector("iframe[src*='youtube.com']")
          expect(bundle.reload.display_asset_previews.alive.second.url).to match("youtube.com")
        end
      end
    end
  end

  describe "content tab" do
    let!(:versioned_product) { create(:product_with_digital_versions, name: "Versioned product", user: seller, created_at: 1.month.ago) }
    let!(:products) do
      create_list(:product, 10, user: seller, quantity_enabled: true) do |product, i|
        product.update(name: "Product #{i}", created_at: i.days.ago)
      end
    end

    before do
      index_model_records(Link)
    end

    it "updates the bundle products" do
      visit "#{bundle_path(bundle.external_id)}/content"

      within "[aria-label='Product selector']" do
        check("Product 1", unchecked: true)
      end

      expect(page).to_not have_field("Versioned product")
      fill_in "Search products", with: "Versioned product"
      within "[aria-label='Product selector']" do
        check("Versioned product", unchecked: true)
      end

      within "[aria-label='Bundle products']" do
        within_cart_item "Bundle Product 1" do
          click_on "Remove"
        end
        within_cart_item "Versioned product" do
          expect(page).to have_text("Qty: 1")
          expect(page).to have_text("Version: Untitled 1")

          select_disclosure "Configure" do
            choose "Untitled 2"
            click_on "Apply"
          end

          expect(page).to have_text("Version: Untitled 2")
        end

        within_cart_item "Product 1" do
          expect(page).to have_text("Qty: 1")

          select_disclosure "Configure" do
            fill_in "Quantity", with: 2
            click_on "Apply"
          end

          expect(page).to have_text("Qty: 2")
        end
      end
      select_tab "Product"
      in_preview { expect(page).to have_selector("[itemprop='price']", text: "$4 $2") }
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      bundle.reload
      expect(bundle.bundle_products.first.deleted_at).to_not be_nil
      expect(bundle.bundle_products.second.deleted_at).to be_nil
      expect(bundle.bundle_products.second.position).to eq(0)

      expect(bundle.bundle_products.third.product).to eq(products[1])
      expect(bundle.bundle_products.third.variant).to be_nil
      expect(bundle.bundle_products.third.quantity).to eq(2)
      expect(bundle.bundle_products.third.position).to eq(1)

      expect(bundle.bundle_products.fourth.product).to eq(versioned_product)
      expect(bundle.bundle_products.fourth.variant).to eq(versioned_product.alive_variants.second)
      expect(bundle.bundle_products.fourth.quantity).to eq(1)
      expect(bundle.bundle_products.fourth.position).to eq(2)
    end

    it "loads more products when scrolled to the bottom" do
      visit "#{bundle_path(bundle.external_id)}/content"
      wait_for_ajax
      expect(page).to_not have_selector("[role='progressbar']")
      expect(page).to_not have_field("Product 8")
      scroll_to find_field("Product 7")
      expect(page).to have_field("Product 8")
    end

    it "allows selecting and unselecting all products" do
      visit "#{bundle_path(bundle.external_id)}/content"
      check "All products", unchecked: true
      expect(page).to have_field("All products", disabled: true)
      wait_for_ajax
      within "[aria-label='Bundle products']" do
        (0..9).each do |i|
          expect(page).to have_section("Product #{i}")
        end
        expect(page).to have_section("Versioned product")
        expect(page).to have_section("Bundle Product 1")
        expect(page).to have_section("Bundle Product 2")
      end
      within "[aria-label='Product selector']" do
        (0..9).each do |i|
          expect(page).to have_section("Product #{i}")
        end
        expect(page).to have_section("Versioned product")
        expect(page).to have_section("Bundle Product 1")
        expect(page).to have_section("Bundle Product 2")
      end
      uncheck "All products", checked: true
      expect(page).to_not have_selector("[aria-label='Bundle products']")

      click_on "Save changes"
      expect(page).to have_alert(text: "Bundles must have at least one product.")
    end

    context "when the bundle has no products" do
      let(:empty_bundle) { create(:product, :unpublished, user: seller, is_bundle: true) }

      it "displays a placeholder" do
        visit "#{bundle_path(empty_bundle.external_id)}/content"
        expect(page).to_not have_selector("[aria-label='Product selector']")
        within_section "Select products", section_element: :section, match: :first do
          expect(page).to have_text("Choose the products you want to include in your bundle")
          click_on "Add products"
        end

        expect(page).to_not have_section("Select products")
        expect(page).to have_selector("[aria-label='Product selector']")

        click_on "Publish and continue"
        expect(page).to have_alert(text: "Bundles must have at least one product.")
      end
    end
  end

  describe "share tab" do
    it "updates the bundle share settings" do
      visit "#{bundle_path(bundle.external_id)}/share"

      encoded_url = CGI.escape(bundle.long_url)
      expect(page).to have_link("Share on X", href: "https://twitter.com/intent/tweet?url=#{encoded_url}&text=Buy%20Bundle%20on%20%40Gumroad")
      expect(page).to have_link("Share on Facebook", href: "https://www.facebook.com/sharer/sharer.php?u=#{encoded_url}&quote=Bundle")
      expect(page).to have_button("Copy URL")

      within_fieldset "Category" do
        select_combo_box_option search: "3D > 3D Modeling", from: "Category"
      end

      within_fieldset "Tags" do
        5.times do |index|
          select_combo_box_option search: "Test#{index}", from: "Tags"
          expect(page).to have_button("test#{index}")
        end
        fill_in "Tags", with: "Test6"
        expect(page).to_not have_combo_box "Tags", expanded: true
        click_on "test2"
        click_on "test3"
        click_on "test4"
      end

      uncheck("Display your product's 1-5 star rating to prospective customers", checked: true)
      check("This product contains content meant only for adults, including the preview", checked: false)

      expect(page).to have_text "You currently have no sections in your profile to display this"
      expect(page).to have_link "create one here", href: root_url(host: seller.subdomain)

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      bundle.reload
      expect(bundle.taxonomy.slug).to eq("3d-modeling")
      expect(bundle.tags.size).to eq(2)
      expect(bundle.tags.first.name).to eq("test0")
      expect(bundle.tags.second.name).to eq("test1")
      expect(bundle.display_product_reviews?).to eq(false)
      expect(bundle.is_adult?).to eq(true)
      expect(bundle.discover_fee_per_thousand).to eq(100)

      section = create(:seller_profile_products_section, seller:)
      visit "#{bundle_path(bundle.external_id)}/share"

      within_fieldset "Category" do
        click_on "Clear value"
      end
      # Unfocus input
      find("h2", text: "Gumroad Discover").click

      within_fieldset "Tags" do
        click_on "test0"
      end

      check("Display your product's 1-5 star rating to prospective customers", checked: false)
      uncheck("This product contains content meant only for adults, including the preview", checked: true)
      check("Unnamed section", checked: false)

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      bundle.reload
      expect(bundle.taxonomy).to be_nil
      expect(bundle.tags.size).to eq(1)
      expect(bundle.tags.first.name).to eq("test1")
      expect(bundle.display_product_reviews?).to eq(true)
      expect(bundle.is_adult?).to eq(false)
      expect(bundle.discover_fee_per_thousand).to eq(100)
      expect(section.reload.shown_products).to include bundle.id

      visit "#{bundle_path(bundle.external_id)}/share"
      uncheck("Unnamed section", checked: true)
      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")
      expect(section.reload.shown_products).to_not include bundle.id
    end
  end

  it "allows unpublishing and publishing the bundle" do
    bundle.publish!
    visit "#{bundle_path(bundle.external_id)}"
    click_on "Unpublish"
    expect(page).to have_alert(text: "Unpublished!")
    expect(bundle.reload.purchase_disabled_at).to_not be_nil

    click_on "Save and continue"
    wait_for_ajax
    expect(page.current_path).to eq("#{bundle_path(bundle.external_id)}/content")

    select_tab "Share"
    expect(page).to have_alert(text: "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.")

    select_tab "Product"
    fill_in "Name", with: "New bundle"
    select_tab "Content"

    click_on "Publish and continue"
    expect(page).to have_alert(text: "Published!")
    bundle.reload
    expect(bundle.purchase_disabled_at).to be_nil
    expect(bundle.name).to eq("New bundle")
    expect(page.current_path).to eq("#{bundle_path(bundle.external_id)}/share")

    click_on "Unpublish"
    expect(page).to have_alert(text: "Unpublished!")
    expect(bundle.reload.purchase_disabled_at).to_not be_nil
    expect(page.current_path).to eq("#{bundle_path(bundle.external_id)}/content")
  end

  context "product is not a bundle" do
    let(:product) { create(:product, user: seller) }

    it "converts the product to a bundle on save" do
      visit bundle_path(product.external_id)

      expect(page).to have_alert(text: "Select products and save your changes to finish converting this product to a bundle.")

      select_tab "Content"
      click_on "Add products"

      check "Bundle Product 1"

      click_on "Save changes"
      expect(page).to have_alert(text: "Changes saved!")

      product.reload
      expect(product.is_bundle).to eq(true)
      expect(product.native_type).to eq(Link::NATIVE_TYPE_BUNDLE)
      expect(product.bundle_products.map(&:product)).to eq([bundle.bundle_products.first.product])
    end
  end

  context "bundle has purchases with outdated content" do
    before { bundle.update!(has_outdated_purchases: true) }

    it "shows a notice from which the seller can update the purchases" do
      visit "#{bundle_path(bundle.external_id)}/content"
      expect(page).to have_text("Some of your customers don't have access to the latest content in your bundle.")
      expect(page).to have_text("Would you like to give them access and send them an email notification?")

      click_on "Yes, update"
      expect(page).to have_alert(text: "Queued an update to the content of all outdated purchases.")

      expect(page).to_not have_text("Some of your customers don't have access to the latest content in your bundle.")

      expect(UpdateBundlePurchasesContentJob).to have_enqueued_sidekiq_job(bundle.id)
    end
  end

  it "shows marketing status" do
    bundle.update!(price_cents: 100)
    create(:audience_member, seller:, purchases: [{}])
    visit "#{bundle_path(bundle.external_id)}/share"
    original_window = page.current_window

    expect(page).to have_text("Your product bundle is ready. Would you like to send an email about this offer to existing customers?")
    expect(page).to have_radio_button("Customers who have purchased at least one product in the bundle", checked: true)
    expect(page).to have_radio_button("All customers", unchecked: true)

    within_window(window_opened_by { click_on "Draft and send" }) do
      expect(page).to have_field("Title", with: "Introducing Bundle")
      within "[aria-label='Email message']" do
        expect(page).to have_text("Hey there,")
        expect(page).to have_text("I've put together a bundle of my products that I think you'll love.")
        expect(page).to have_text("Bundle")
        expect(page).to have_text("$2 $1")
        expect(page).to have_text("Included in this bundle")
        within "ul" do
          expect(page).to have_link("Bundle Product 1", href: short_link_url(bundle.bundle_products.first.product.unique_permalink, host: DOMAIN))
          expect(page).to have_link("Bundle Product 2", href: short_link_url(bundle.bundle_products.second.product.unique_permalink, host: DOMAIN))
        end
        expect(page).to have_link("Get your bundle", href: short_link_url(bundle.unique_permalink, host: DOMAIN))
        expect(page).to have_text("Thanks for your support!")
      end
      expect(page).to have_radio_button("Everyone", unchecked: true)
      expect(page).to have_radio_button("Customers only", checked: true)
      find(:combo_box, "Bought").click
      within(:fieldset, "Bought") do
        expect(page).to have_button("Bundle Product 1")
        expect(page).to have_button("Bundle Product 2")
        expect(page).to have_combo_box "Bought", options: ["Bundle"]
      end
      find(:combo_box, "Has not yet bought").click
      within(:fieldset, "Has not yet bought") do
        expect(page).to_not have_button("Bundle Product 1")
        expect(page).to_not have_button("Bundle Product 2")
        expect(page).to have_combo_box "Has not yet bought", options: ["Bundle Product 1", "Bundle Product 2", "Bundle"]
      end
    end

    page.switch_to_window(original_window)

    choose "All customers"

    within_window(window_opened_by { click_on "Draft and send" }) do
      expect(page).to have_radio_button("Everyone", unchecked: true)
      expect(page).to have_radio_button("Customers only", checked: true)
      find(:combo_box, "Bought").click
      within(:fieldset, "Bought") do
        expect(page).to_not have_button("Bundle Product 1")
        expect(page).to_not have_button("Bundle Product 2")
        expect(page).to have_combo_box "Bought", options: ["Bundle Product 1", "Bundle Product 2", "Bundle"]
      end
      send_keys :escape
      find(:combo_box, "Has not yet bought").click
      find(:combo_box, "Has not yet bought").click
      within(:fieldset, "Has not yet bought") do
        expect(page).to_not have_button("Bundle Product 1")
        expect(page).to_not have_button("Bundle Product 2")
        expect(page).to have_combo_box "Has not yet bought", options: ["Bundle Product 1", "Bundle Product 2", "Bundle"]
      end
    end
  end
end
