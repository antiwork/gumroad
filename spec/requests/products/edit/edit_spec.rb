# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Scenario", type: :system, js: true) do
  include ManageSubscriptionHelpers
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let!(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  before :each do
    product.shipping_destinations << ShippingDestination.new(
      country_code: Product::Shipping::ELSEWHERE,
      one_item_rate_cents: 0,
      multiple_items_rate_cents: 0
    )
  end

  include_context "with switching account to user as admin for seller"

  it "allows a Gumroad admin to view a seller's product edit page" do
    product = create(:product_with_digital_versions)
    admin = create(:admin_user)
    login_as(admin)
    visit edit_link_path(product.unique_permalink)
    expect(page).to have_text product.name
  end

  it "allows user to update their custom permalinks and then immediately view their products" do
    visit edit_link_path(product.unique_permalink)
    fill_in product.unique_permalink, with: "woof"
    save_change
  end

  describe "Custom domain" do
    let(:valid_domain) { "valid-domain.com" }
    let(:invalid_domain) { "invalid-domain.com" }

    it "saves a valid custom domain" do
      expect(CustomDomainVerificationService)
        .to receive(:new)
        .twice
        .with(domain: valid_domain)
        .and_return(double(process: true))

      visit edit_link_path(product.unique_permalink)

      fill_in "Custom domain", with: valid_domain
      click_on "Verify"
      wait_for_ajax

      expect(page).to have_text("valid-domain.com domain is correctly configured!")

      save_change

      expect(product.custom_domain.domain).to eq("valid-domain.com")
      expect(product.custom_domain.verified?).to eq(true)
    end

    it "shows a validation error for an invalid domain" do
      expect(CustomDomainVerificationService)
        .to receive(:new)
        .with(domain: invalid_domain)
        .and_return(double(process: false))

      visit edit_link_path(product.unique_permalink)

      fill_in "Custom domain", with: invalid_domain
      expect do
        click_on "Save changes"
        wait_for_ajax
      end.to change { product.reload.custom_domain&.domain }.from(nil).to(invalid_domain)
      expect(product.reload.custom_domain.failed_verification_attempts_count).to eq(0)
      expect(product.custom_domain.verified?).to eq(false)

      visit edit_link_path(product.unique_permalink)
      expect(page).to have_text("Domain verification failed. Please make sure you have correctly configured the DNS" \
                                  " record for invalid-domain.com.")
    end

    it "does not enable the verify button for an empty domain" do
      visit edit_link_path(product.unique_permalink)

      fill_in "Custom domain", with: "      "
      expect(page).not_to have_button("Verify")
    end
  end

  it "allows users to edit their physical product's content" do
    product.update!(is_physical: true, require_shipping: true)

    visit edit_link_path(product.unique_permalink) + "/content"

    select_disclosure "Upload files" do
      attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
    end

    expect(page).to have_embed(name: "Alice's Adventures in Wonderland")
    wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")

    save_change

    file = product.reload.alive_product_files.sole
    expect(file.is_linked_to_existing_file).to eq false
    rich_content = [{ "type" => "fileEmbed", "attrs" => a_hash_including({ "id" => file.external_id }) }, { "type" => "paragraph" }]
    expect(product.rich_contents.alive.sole.description).to match rich_content

    select_tab "Product"
    click_on "Add version"
    click_on "Add version"
    within_section "Versions" do
      all(:field, "Name").last.set "Version 2"
    end
    select_tab "Content"
    find(:combo_box, "Select a version").click
    uncheck "Use the same content for all versions"
    find(:combo_box, "Select a version").click
    select_combo_box_option "Version 2", from: "Select a version"
    rich_text_editor = find("[contenteditable=true]")
    rich_text_editor.send_keys "Text!"
    save_change

    expect(product.rich_contents.alive.count).to eq 0
    variants = product.alive_variants
    rich_content[0]["attrs"] = a_hash_including({ "id" => variants.first.alive_product_files.sole.external_id })
    expect(variants.first.rich_contents.alive.sole.description).to match rich_content
    rich_content[1]["content"] = [{ "type" => "text", "text" => "Text!" }]
    expect(variants.last.rich_contents.alive.sole.description).to match rich_content
  end

  it "allows creating and deleting an upsell in the product description" do
    product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
    create(:purchase, :with_review, link: product)

    visit edit_link_path(product.unique_permalink)

    set_rich_text_editor_input(find("[aria-label='Description']"), to_text: "Hi there!")

    select_disclosure "Insert" do
      click_on "Upsell"
    end
    select_combo_box_option search: "Sample product", from: "Product"
    check "Add a discount to the offered product"
    choose "Fixed amount"
    fill_in "Fixed amount", with: "1"
    click_on "Insert"

    within("[aria-label='Description']") do
      within_section "Sample product", section_element: :article do
        expect(page).to have_text("5.0 (1)", normalize_ws: true)
        expect(page).to have_text("$10 $9")
      end
    end

    click_on "Save"
    expect(page).to have_alert(text: "Changes saved!")

    upsell = Upsell.last
    expect(upsell.product_id).to eq(product.id)
    expect(upsell.is_content_upsell).to be(true)
    expect(upsell.cross_sell).to be(true)
    expect(upsell.name).to eq(nil)
    expect(upsell.description).to eq(nil)

    expect(upsell.offer_code.amount_cents).to eq(100)
    expect(upsell.offer_code.amount_percentage).to be_nil
    expect(upsell.offer_code.universal).to be(false)
    expect(upsell.offer_code.product_ids).to eq([product.id])

    product.reload
    expect(product.description).to eq("<p>Hi there!</p><upsell-card productid=\"#{product.external_id}\" discount='{\"type\":\"fixed\",\"cents\":100}' id=\"#{upsell.external_id}\"></upsell-card>")

    set_rich_text_editor_input(find("[aria-label='Description']"), to_text: "")
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    upsell.reload
    expect(upsell.deleted?).to be(true)
    expect(upsell.offer_code.deleted?).to be(true)

    product.reload
    expect(product.description).to eq("<p><br></p>")
  end

  it "allows creating and deleting an upsell with variants in the product description" do
    product = create(:product_with_digital_versions_with_price_difference_cents, user: seller, name: "Sample product", price_cents: 1000)
    variant1 = product.alive_variants.first
    variant2 = product.alive_variants.last
    create(:purchase, :with_review, link: product)

    visit edit_link_path(product.unique_permalink)

    set_rich_text_editor_input(find("[aria-label='Description']"), to_text: "Hi there!")

    select_disclosure "Insert" do
      click_on "Upsell"
    end

    # The product itself should be listed but disabled, variants listed with icon
    within "dialog" do
      find(:combo_box, "Product").click
      product_option = find("[role='option']", text: "Sample product", exact_text: true)
      expect(product_option).not_to have_selector("span.icon.icon-arrow-right-reply"); # icon for variant

      variant1_option = find("[role='option']", text: "Sample product (#{variant1.name})")
      expect(variant1_option).to have_selector("span.icon.icon-arrow-right-reply"); # icon for variant

      variant2_option = find("[role='option']", text: "Sample product (#{variant2.name})")
      expect(variant2_option).to have_selector("span.icon.icon-arrow-right-reply"); # icon for variant
    end

    # When searching, only variants should appear, not the product itself, and no icon
    within "dialog" do
      fill_in "Product", with: "Sample product"
      expect(page).not_to have_selector("[role='option']", text: "Sample product", exact_text: true)

      variant1_option = find("[role='option']", text: "Sample product (#{variant1.name})")
      expect(variant1_option).not_to have_selector("span.icon.icon-arrow-right-reply"); # icon for variant

      variant2_option = find("[role='option']", text: "Sample product (#{variant2.name})")
      expect(variant2_option).not_to have_selector("span.icon.icon-arrow-right-reply"); # icon for variant
    end

    # Select the first variant
    select_combo_box_option search: "Sample product (#{variant1.name})", from: "Product"
    check "Add a discount to the offered product"
    choose "Fixed amount"
    discount_amount_cents = 100
    discount_amount = discount_amount_cents / 100.0
    fill_in "Fixed amount", with: discount_amount
    click_on "Insert"

    within_section "Sample product", section_element: :article do
      expect(page).to have_selector("span", text: "(#{variant1.name})")
      expect(page).to have_text("5.0 (1)", normalize_ws: true)

      price_cents = variant1.price_difference_cents + product.price_cents
      price = price_cents / 100

      discounted_price = price_cents - discount_amount_cents
      discounted_price = discounted_price / 100

      expect(page).to have_text("$#{price} $#{discounted_price}")
    end

    click_on "Save"
    expect(page).to have_alert(text: "Changes saved!")

    upsell = Upsell.last
    expect(upsell.product_id).to eq(product.id)
    expect(upsell.variant_id).to eq(variant1.id)
    expect(upsell.is_content_upsell).to be(true)
    expect(upsell.cross_sell).to be(true)
    expect(upsell.name).to eq(nil)
    expect(upsell.description).to eq(nil)
    expect(upsell.offer_code.amount_cents).to eq(100)
    expect(upsell.offer_code.amount_percentage).to be_nil
    expect(upsell.offer_code.universal).to be(false)
    expect(upsell.offer_code.product_ids).to eq([product.id])

    product.reload
    expect(product.description).to eq("<p>Hi there!</p><upsell-card productid=\"#{product.external_id}\" variantid=\"#{variant1.external_id}\" discount='{\"type\":\"fixed\",\"cents\":100}' id=\"#{upsell.external_id}\"></upsell-card>")

    set_rich_text_editor_input(find("[aria-label='Description']"), to_text: "")
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    upsell.reload
    expect(upsell.deleted?).to be(true)
    expect(upsell.offer_code.deleted?).to be(true)

    product.reload
    expect(product.description).to eq("<p><br></p>")
  end

  it "allows creating and deleting an upsell in the product rich content" do
    product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
    create(:purchase, :with_review, link: product)

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"

    set_rich_text_editor_input(find("[aria-label='Content editor']"), to_text: "Hi there!")

    select_disclosure "Insert" do
      click_on "Upsell"
    end
    select_combo_box_option search: "Sample product", from: "Product"
    check "Add a discount to the offered product"
    choose "Fixed amount"
    fill_in "Fixed amount", with: "1"
    click_on "Insert"

    within_section "Sample product", section_element: :article do
      expect(page).to have_text("5.0 (1)", normalize_ws: true)
      expect(page).to have_text("$10 $9")
    end

    click_on "Save"
    expect(page).to have_alert(text: "Changes saved!")

    upsell = Upsell.last
    expect(upsell.product_id).to eq(product.id)
    expect(upsell.is_content_upsell).to be(true)
    expect(upsell.cross_sell).to be(true)
    expect(upsell.name).to eq(nil)
    expect(upsell.description).to eq(nil)

    expect(upsell.offer_code.amount_cents).to eq(100)
    expect(upsell.offer_code.amount_percentage).to be_nil
    expect(upsell.offer_code.universal).to be(false)
    expect(upsell.offer_code.product_ids).to eq([product.id])

    product.reload
    expect(product.rich_contents.alive.map(&:description)).to eq(
      [
        [
          { "type" => "paragraph", "content" => [{ "text" => "Hi there!", "type" => "text" }] },
          { "type" => "upsellCard", "attrs" => { "id" => upsell.external_id, "discount" => { "type" => "fixed", "cents" => 100 }, "productId" => product.external_id, "variantId" => nil } }
        ]
      ]
    )

    refresh
    set_rich_text_editor_input(find("[aria-label='Content editor']"), to_text: "")
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    upsell.reload
    expect(upsell.deleted?).to be(true)
    expect(upsell.offer_code.deleted?).to be(true)

    product.reload
    expect(product.rich_contents.alive.map(&:description)).to eq(
      [
        [
          {
            "type" => "paragraph"
          }
        ]
      ]
    )
  end

  it "displays video transcoding notice" do
    product = create(:product_with_video_file, user: seller)
    video_file = product.product_files.first
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => video_file.external_id, "uid" => SecureRandom.uuid } }])
    create(:transcoded_video, streamable: video_file, original_video_key: video_file.s3_key, state: "processing")
    visit edit_link_path(product) + "/content"
    within find_embed(name: video_file.display_name) do
      expect(page).to have_text("Transcoding in progress")
    end
    video_file.transcoded_videos.first.mark_completed
    refresh
    within find_embed(name: video_file.display_name) do
      expect(page).not_to have_text("Transcoding in progress")
    end
  end

  it "allows to edit suggested price of PWYW products" do
    visit edit_link_path(product.unique_permalink)

    fill_in "Amount", with: "20"
    check "Allow customers to pay what they want"
    fill_in "Suggested amount", with: "50"
    save_change

    expect(page).to have_text("$20+")
    product.reload
    expect(product.suggested_price_cents).to be(50_00)

    visit edit_link_path(product.unique_permalink)

    expect(page).to have_field("Suggested amount", with: "50")

    find_field("Suggested amount", with: "50").fill_in with: ""
    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    expect(product.reload.suggested_price_cents).to be_nil
  end

  it "allows user to update name and price", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    visit edit_link_path(product.unique_permalink)
    new_name = "Slot machine"
    fill_in("Name", with: new_name)
    fill_in("Amount", with: 777)
    save_change
    expect(product.reload.name).to eq new_name
    expect(product.price_cents).to eq 77_700
    document = EsClient.get(id: product.id, index: Link.index_name)["_source"]
    expect(document["name"]).to eq(new_name)
    expect(document["price_cents"]).to eq(77_700)
  end

  it "allows updating installment plans for paid product" do
    product.installment_plan&.destroy!

    visit edit_link_path(product.unique_permalink)

    within_section "Pricing" do
      fill_in "Amount", with: 100
      check "Allow customers to pay in installments"
      fill_in "Number of installments", with: 3
    end

    save_change
    expect(product.reload.installment_plan.number_of_installments).to eq(3)

    within_section "Pricing" do
      fill_in "Amount", with: 100
      check "Allow customers to pay in installments"
      fill_in "Number of installments", with: 4
    end

    save_change
    expect(product.reload.installment_plan.number_of_installments).to eq(4)

    within_section "Pricing" do
      fill_in "Amount", with: 0
    end

    save_change
    expect(product.reload.installment_plan).to be_nil
  end

  it "allows user to update custom permalink and limit product sales" do
    visit edit_link_path(product.unique_permalink)
    new_custom_permalink = "cba"
    new_limit = 12

    fill_in(product.unique_permalink, with: new_custom_permalink)
    check "Limit product sales"
    fill_in("Maximum number of purchases", with: new_limit)
    expect do
      expect do
        save_change
        product.reload
      end.to(change { product.custom_permalink }.to(new_custom_permalink))
    end.to(change { product.max_purchase_count }.to(new_limit))

    uncheck "Limit product sales"
    expect do
      save_change
      product.reload
    end.to(change { product.max_purchase_count }.to(nil))
  end

  it "allows a product to be edited and published without files" do
    product = create(:product, user: seller, draft: true, purchase_disabled_at: Time.current)
    visit edit_link_path(product.unique_permalink)

    expect(product.has_files?).to be(false)
    fill_in "Amount", with: 1
    click_on "Save and continue"
    expect(page).to have_alert(text: "Changes saved!")

    click_on "Publish and continue"
    expect(page).to have_alert(text: "Published!")
    expect(page).to have_button "Unpublish"
    expect(product.reload.alive?).to be(true)
  end

  it "does not allow publishing when creator's email is empty" do
    allow_any_instance_of(User).to receive(:email).and_return("")
    product = create(:product, user: seller, draft: true, purchase_disabled_at: Time.current)
    visit edit_link_path(product.unique_permalink) + "/content"

    click_on "Publish and continue"
    wait_for_ajax

    within :alert, text: "To publish a product, we need you to have an email. Set an email to continue." do
      expect(page).to have_link("Set an email", href: settings_main_url(host: UrlService.domain_with_protocol))
    end
    expect(page).to have_current_path(edit_link_path(product.unique_permalink) + "/content")
    expect(page).to have_button "Publish and continue"
    expect(product.reload.alive?).to be(false)
  end

  describe "tier supporters count", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    before do
      shared_setup
      login_as(@product.user)
    end

    context "without any tier members subscribed" do
      it "does not display a text count" do
        visit edit_link_path(@product.unique_permalink)
        wait_for_ajax
        expect(page).to_not have_text("0 supporters")
      end
    end

    context "when one tier member subscribed" do
      before do
        create_subscription(product_price: @monthly_product_price,
                            tier: @original_tier,
                            tier_price: @original_tier_monthly_price)
        index_model_records(Purchase)
      end

      it "shows singular supporter version with count" do
        visit edit_link_path(@product.unique_permalink)
        wait_for_ajax
        expect(page).to have_text("1 supporter")
      end
    end

    context "when multiple tier members subscribed" do
      before do
        create_subscription(product_price: @monthly_product_price,
                            tier: @original_tier,
                            tier_price: @original_tier_monthly_price)
        create_subscription(product_price: @monthly_product_price,
                            tier: @original_tier,
                            tier_price: @original_tier_monthly_price)
        index_model_records(Purchase)
      end

      it "shows pluralized supporter version with count" do
        visit edit_link_path(@product.unique_permalink)
        wait_for_ajax
        expect(page).to have_text("2 supporters")
      end
    end
  end

  it "allows creator to show or hide the sales count" do
    index_model_records(Purchase)
    product = create(:product, user: seller)
    product.product_files << create(:product_file)
    expect(product.should_show_sales_count).to eq false

    visit edit_link_path(product.unique_permalink)
    check "Publicly show the number of sales on your product page"
    expect(page).to have_text("0 sales")
    expect do
      save_change
    end.to(change { product.reload.should_show_sales_count }.to(true))

    uncheck "Publicly show the number of sales on your product page"
    expect(page).not_to have_text("0 sales")
    expect do
      save_change
    end.to(change { product.reload.should_show_sales_count }.to(false))
  end

  it "allows creator to limit the number of sales" do
    product = create(:product, user: seller)
    product.product_files << create(:product_file)
    expect(product.quantity_enabled).to eq false

    visit edit_link_path(product.unique_permalink)
    expect(page).not_to have_field("Quantity")

    check "Allow customers to choose a quantity"
    expect(page).to have_field("Quantity")
    expect do
      save_change
    end.to(change { product.reload.quantity_enabled }.to(true))

    uncheck "Allow customers to choose a quantity"
    expect(page).not_to have_field("Quantity")
    expect do
      save_change
    end.to(change { product.reload.quantity_enabled }.to(false))
  end

  it "allows creator to show or hide the supporters count" do
    index_model_records(Purchase)
    product = create(:membership_product, user: seller)
    expect(product.should_show_sales_count).to eq false

    visit edit_link_path(product.unique_permalink)
    check "Publicly show the number of members on your product page"
    expect(page).to have_text("0 members")
    expect do
      save_change
    end.to(change { product.reload.should_show_sales_count }.to(true))

    uncheck "Publicly show the number of members on your product page"
    expect(page).not_to have_text("0 members")
    expect do
      save_change
    end.to(change { product.reload.should_show_sales_count }.to(false))
  end

  describe "membership ui vs non membership ui" do
    before do
      @non_membership_product = create(:physical_product)
      user = @non_membership_product.user
      login_as user
      @membership_product = create(:membership_product, user:)
    end

    it "doesn't show the option to show supporter count for non-membership products" do
      visit "/products/#{@non_membership_product.unique_permalink}/edit"
      wait_for_ajax
      expect(page).not_to have_text("Publicly show the number of members on your product page")
    end

    it "shows the option to show sales count for non-membership products" do
      visit "/products/#{@non_membership_product.unique_permalink}/edit"
      wait_for_ajax
      expect(page).to have_text("Publicly show the number of sales on your product page")
    end

    it "shows the option to show supporter count for membership products" do
      visit "/products/#{@membership_product.unique_permalink}/edit"
      wait_for_ajax
      expect(page).to have_text("Publicly show the number of members on your product page")
    end

    it "doesn't show the option to show sales count for membership products" do
      visit "/products/#{@membership_product.unique_permalink}/edit"
      wait_for_ajax
      expect(page).not_to have_text("Publicly show the number of sales on your product page")
    end

    it "doesn't show the option to change currency code for membership products" do
      visit "/products/#{@membership_product.unique_permalink}/edit"
      wait_for_ajax
      expect(page).not_to have_select("Currency", visible: :all)
    end
  end

  describe "discover notices" do
    let(:recommendable_seller) { create(:recommendable_user, name: "Seller") }
    let(:recommendable_product) { create(:product, :recommendable, user: recommendable_seller, name: "product 1") }

    it "shows eligibility notice until dismissed and success notice if recommendable product" do
      expect(product.recommendable?).to be(false)
      visit edit_link_path(product.unique_permalink) + "/share"
      expect(page).not_to have_status(text: "#{product.name} is listed on Gumroad Discover.")

      click_on "Close"
      expect(page).not_to have_status(text: "To appear on Gumroad Discover, make sure to meet all the")

      visit edit_link_path(product.unique_permalink) + "/share"
      expect(page).not_to have_status(text: "To appear on Gumroad Discover, make sure to meet all the")

      login_as(recommendable_seller)

      expect(recommendable_product.recommendable?).to be(true)
      visit edit_link_path(recommendable_product.unique_permalink) + "/share"
      expect(page).to have_status(text: "#{recommendable_product.name} is listed on Gumroad Discover.")

      within(:status, text: "#{recommendable_product.name} is listed on Gumroad Discover.") do
        click_on "View"
      end
      expect(current_url).to include(UrlService.discover_domain_with_protocol)
      expect_product_cards_with_names("product 1")
    end
  end

  describe "changing product tags" do
    it "allows user to add a tag" do
      visit edit_link_path(product.unique_permalink) + "/share"

      within :fieldset, "Tags" do
        select_combo_box_option search: "Test1", from: "Tags"
        expect(page).to have_button "test1"
        select_combo_box_option search: "Test2", from: "Tags"
        expect(page).to have_button "test2"
      end

      save_change

      expect(product.tags.size).to eq 2
      expect(product.tags[0].name).to eq "test1"
      expect(product.tags[1].name).to eq "test2"
    end

    it "allows to add no more than five tags" do
      visit edit_link_path(product.unique_permalink) + "/share"

      expect(page).to have_combo_box "Tags"

      select_combo_box_option search: "Test1", from: "Tags"
      select_combo_box_option search: "Test2", from: "Tags"
      select_combo_box_option search: "Test3", from: "Tags"
      select_combo_box_option search: "Test4", from: "Tags"
      select_combo_box_option search: "Test5", from: "Tags"

      %w[test1 test2 test3 test4 test5].each do |tag|
        within :fieldset, "Tags" do
          expect(page).to have_button(tag)
        end
      end

      fill_in "Tags", with: "Test6"
      expect(page).to_not have_combo_box "Tags", expanded: true
    end

    it "recommends tag suggestions from other products" do
      tag = create(:tag, name: "other-product-tag")
      create(:product, tags: [tag])
      create(:product, tags: [tag])

      visit edit_link_path(product.unique_permalink) + "/share"

      fill_in("Tags", with: "oth")
      expect(page).to have_combo_box "Tags", expanded: true, with_options: ["other-product-tag (2)"]
    end

    it "displays existing product tags" do
      product.tags.create(name: "test1")
      product.tags.create(name: "test2")

      visit edit_link_path(product.unique_permalink) + "/share"

      expect(page).to have_combo_box "Tags"
      within :fieldset, "Tags" do
        expect(page).to have_button "test1"
        expect(page).to have_button "test2"
      end
    end

    it "deletes existing product tag" do
      product.tags.create(name: "test1")
      product.tags.create(name: "test2")

      visit edit_link_path(product.unique_permalink) + "/share"

      expect(page).to have_combo_box "Tags"
      within :fieldset, "Tags" do
        expect(page).to have_button "test2"
        click_on "test2"
        expect(page).not_to have_button "test2"
      end

      save_change

      expect(product.tags.size).to eq 1
      expect(product.tags[0].name).to eq "test1"
    end
  end

  describe "changing discover taxonomy settings" do
    it "shows previously selected category, shows all available categories, and saves a newly selected category" do
      product.update_attribute(:taxonomy, Taxonomy.find_by(slug: "design"))
      visit edit_link_path(product.unique_permalink) + "/share"
      within :fieldset, "Category" do
        expect(page).to have_text("Design")
      end

      click_on "Clear value"
      expect(page).to have_combo_box "Category", expanded: true, with_options: [
        "3D",
        "3D > 3D Modeling",
        "3D > Character Design",
        "Design",
        "Design > Entertainment Design",
        "Design > Industrial Design"
      ]

      within :fieldset, "Category" do
        select_combo_box_option search: "3D > 3D Modeling", from: "Category"
      end
      save_change

      product.reload
      expect(product.taxonomy.slug).to eq("3d-modeling")
    end

    it "searches for category by partial text regardless of hierarchy" do
      visit edit_link_path(product.unique_permalink) + "/share"
      within :fieldset, "Category" do
        select_combo_box_option search: "Entertainment", from: "Category"
      end
      save_change

      product.reload
      expect(product.taxonomy.slug).to eq("entertainment-design")
    end

    it "unsets category when value is cleared" do
      product.update_attribute(:taxonomy, Taxonomy.find_by(slug: "design"))
      visit edit_link_path(product.unique_permalink) + "/share"
      within :fieldset, "Category" do
        click_on "Clear value"
      end
      save_change

      product.reload
      expect(product.taxonomy_id).to be_nil
      expect(product.taxonomy).to be_nil
    end
  end

  describe "changing discover fee settings" do
    describe "profile sections" do
      it "allows updating profile sections" do
        product2 = create(:product, user: seller, name: "Product 2")
        product3 = create(:product, user: seller, name: "Product 3")
        section1 = create(:seller_profile_products_section, seller:, header: "Section 1", add_new_products: false, shown_products: [product, product2, product3].map(&:id))
        section2 = create(:seller_profile_products_section, seller:, header: "Section 2", hide_header: true, shown_products: [product.id])
        section3 = create(:seller_profile_products_section, seller:, add_new_products: false, shown_products: [product2.id])
        visit edit_link_path(product.unique_permalink) + "/share"
        expect(page).to_not have_text "You currently have no sections in your profile to display this"
        within_section "Profile", section_element: :section do
          expect(page).to have_selector(:checkbox, count: 3)
          # these assertions don't work in the field selectors below for some reason
          expect(page).to have_text "Section 1\n#{product.name}, #{product2.name}, and 1 other"
          expect(page).to have_text "Section 2 (Default)\n#{product.name}"
          expect(page).to have_text "Unnamed section\n#{product2.name}"
          uncheck "Section 1"
          uncheck "Section 2"
          check "Unnamed section"
        end
        click_on "Save changes"
        wait_for_ajax
        expect(section1.reload.shown_products).to eq [product2.id, product3.id]
        expect(section2.reload.shown_products).to eq []
        expect(section3.reload.shown_products).to eq [product2, product].map(&:id)

        within_section "Profile", section_element: :section do
          uncheck "Unnamed section"
        end
        click_on "Save changes"
        wait_for_ajax
        expect([section1, section2, section3].any? { _1.reload.shown_products.include?(product.id) }).to eq false
      end

      it "shows an info message when none exists" do
        visit edit_link_path(product.unique_permalink) + "/share"
        expect(page).to have_text "You currently have no sections in your profile to display this"
        expect(page).to have_link "create one here", href: root_url(host: seller.subdomain)
      end
    end
  end

  describe "offer code validation" do
    context "when the price invalidates an offer code" do
      context "amount validations" do
        before do
          create(:offer_code, user: seller, products: [product], code: "bad", amount_cents: 100)
        end

        it "displays a warning message" do
          visit edit_link_path(product.unique_permalink)

          fill_in "Amount", with: "1.50"
          click_on "Save changes"
          expect(page).to have_alert(text: "The following offer code discounts this product below $0.99, but not to $0: bad. Please update it or it will not work at checkout.")
        end
      end

      context "currency validations" do
        before do
          create(:offer_code, user: seller, products: [product], code: "usd", amount_cents: 100)
        end

        it "displays a warning message" do
          visit edit_link_path(product.unique_permalink)

          select "£", from: "Currency", visible: false
          expect(page).to have_select("Currency", selected: "£", visible: false)

          click_on "Save changes"
          expect(page).to have_alert(text: "The following offer code has currency mismatch with this product: usd. Please update it or it will not work at checkout.")
          expect(product.reload.price_currency_type).to eq "gbp"
        end
      end
    end
  end

  context "product currency" do
    it "allows updating currency" do
      visit edit_link_path(product.unique_permalink)

      select "£", from: "Currency", visible: false
      expect(page).to have_select("Currency", selected: "£", visible: false)

      click_on "Save changes"
      wait_for_ajax
      expect(product.reload.price_currency_type).to eq "gbp"
    end
  end

  describe "as a collaborator" do
    let(:collaborator) { create(:collaborator, seller:, products: [product]) }

    it "allows updating the product" do
      login_as(collaborator.affiliate_user)

      visit edit_link_path(product.unique_permalink)

      new_name = "Slot machine"
      expect do
        fill_in("Name", with: new_name)
        fill_in("Amount", with: 777)
        save_change
      end.to change { product.reload.name }.to(new_name)
    end
  end

  context "when the product has 'bundle' or 'pack' in its name" do
    it "shows a notice offering bundle conversion" do
      visit edit_link_path(product.unique_permalink)

      expect(page).to_not have_selector("[role='status']", text: "Looks like this product could be a great bundle!")

      fill_in "Name", with: "Bundle"
      expect(page).to have_selector("[role='status']", text: "Looks like this product could be a great bundle!")

      fill_in "Name", with: ""
      expect(page).to_not have_selector("[role='status']", text: "Looks like this product could be a great bundle!")

      fill_in "Name", with: "Pack"
      within "[role='status']", text: "Looks like this product could be a great bundle!" do
        expect(page).to have_text("With bundles, your customers can get access to multiple products at once at a discounted price, without the need to duplicate content or workflows.")
        click_on "Switch to bundle"
      end

      within_modal 'Transform "Pack" into a bundle?' do
        expect(page).to have_text("A bundle is a special type of product that allows you to offer multiple products together at a discounted price. Here's what you can expect by making the switch:")

        within "ol" do
          expect(page).to have_selector("li", text: "The current content of your product will no longer be editable.")
          expect(page).to have_selector("li", text: "You'll select the products to include in your new bundle.")
          expect(page).to have_selector("li", text: "After you save your product, new customers will get access to the selected products.")
          expect(page).to have_selector("li", text: "Your previous customers will retain access to the original content. They will not have access to the new content.")
          expect(page).to have_selector("li", text: "All your sales data will remain intact.")
        end
        expect(page).to have_text("Conversion is not reversible once completed.")

        expect(page).to have_link("Yes, let's select the products", href: "#{bundle_path(product.external_id)}/content")
        click_on "No, cancel"
      end

      expect(page).to_not have_modal('Transform "Pack" into a bundle?')
    end
  end

  it "allows creating and deleting a testimonial in the product rich content" do
    product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
    purchase1 = create(:purchase, link: product, email: "reviewer1@example.com", full_name: "Reviewer 1")
    purchase2 = create(:purchase, link: product, email: "reviewer2@example.com", full_name: "Reviewer 2")

    visit edit_link_path(product.unique_permalink)
    select_tab "Content"

    set_rich_text_editor_input(find("[aria-label='Content editor']"), to_text: "Hi there!")

    select_disclosure "Insert" do
      click_on "Review"
    end

    within_modal "Insert reviews" do
      expect(page).to have_text("No reviews with text or video yet.")
      expect(page).not_to have_button "Insert"
      click_on "Cancel"
    end

    review1 = create(:product_review, purchase: purchase1, rating: 5, message: "This is amazing! Highly recommended.")
    review2 = create(:product_review, purchase: purchase2, rating: 4, message: "Very good product with great features.")

    select_disclosure "Insert" do
      click_on "Review"
    end

    within_modal "Insert reviews" do
      expect(page).to have_button "Insert", disabled: true
      check "Select all"
      click_on "Insert"
    end

    within ".rich-text" do
      within_section "Reviewer 1", match: :first do
        expect(page).to have_text("This is amazing! Highly recommended.")
      end
      within_section "Reviewer 2", match: :first do
        expect(page).to have_text("Very good product with great features.")
      end
    end

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    product.reload
    rich_content = product.rich_contents.alive.sole
    expect(rich_content.description).to eq(
      [
        { "type" => "paragraph", "content" => [{ "text" => "Hi there!", "type" => "text" }] },
        { "type" => "reviewCard", "attrs" => { "reviewId" => review2.external_id } },
        { "type" => "reviewCard", "attrs" => { "reviewId" => review1.external_id } },
      ]
    )
  end

  it "allows creating and deleting a testimonial in the product description" do
    product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
    purchase1 = create(:purchase, link: product, email: "reviewer1@example.com", full_name: "Reviewer 1")
    purchase2 = create(:purchase, link: product, email: "reviewer2@example.com", full_name: "Reviewer 2")

    visit edit_link_path(product.unique_permalink)

    set_rich_text_editor_input(find("[aria-label='Description']"), to_text: "Hi there!")

    select_disclosure "Insert" do
      click_on "Review"
    end

    within_modal "Insert reviews" do
      expect(page).to have_text("No reviews with text or video yet.")
      expect(page).not_to have_button "Insert"
      click_on "Cancel"
    end

    review1 = create(:product_review, purchase: purchase1, rating: 5, message: "This is amazing! Highly recommended.")
    review2 = create(:product_review, purchase: purchase2, rating: 4, message: "Very good product with great features.")

    select_disclosure "Insert" do
      click_on "Review"
    end

    within_modal "Insert reviews" do
      expect(page).to have_button "Insert", disabled: true
      check "Select all"
      click_on "Insert"
    end

    within ".textarea" do
      within_section "Reviewer 1", match: :first do
        expect(page).to have_text("This is amazing! Highly recommended.")
      end
      within_section "Reviewer 2", match: :first do
        expect(page).to have_text("Very good product with great features.")
      end
    end

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    product.reload
    expect(product.description).to eq("<p>Hi there!</p><review-card reviewid=\"#{review2.external_id}\"></review-card><review-card reviewid=\"#{review1.external_id}\"></review-card>")
  end

  describe "Content updates" do
    before do
      create(:purchase, link: product)
      index_model_records(Purchase)
    end

    context "when non-content update" do
      let(:product) { create(:product, user: seller, name: "Sample product", price_cents: 1000) }

      it "doesn't allow notifying users" do
        visit edit_link_path(product.unique_permalink)

        description_input = find("[aria-label='Description']")
        set_rich_text_editor_input(description_input, to_text: "Hi there!")
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        set_rich_text_editor_input(description_input, to_text: "New description")
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")
        expect(page).not_to have_alert(text: "Changes saved! Would you like to notify your customers about those changes?")
      end
    end

    context "product with no variants" do
      let(:product) { create(:product, user: seller, name: "Sample product", price_cents: 1000) }

      it "allows notifying users" do
        visit edit_link_path(product.unique_permalink)
        select_tab "Content"

        editor = find("[aria-label='Content editor']")
        set_rich_text_editor_input(editor, to_text: "Hi there!")

        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        set_rich_text_editor_input(editor, to_text: "New content")
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved! Would you like to notify your customers about those changes?")

        new_window = window_opened_by { click_on "Send notification" }
        within_window new_window do
          expect(page).to have_field("Title", with: "New content added to #{product.name}")
          expect(page).to have_radio_button "Customers only", checked: true
          expect(page).to have_checked_field("Send email")
          expect(page).to have_unchecked_field("Post to profile")
          within(:fieldset, "Bought") do
            expect(page).to have_button(product.name)
          end
          within find("[aria-label='Email message']") do
            expect(page).to have_text("New content has been added to")
            expect(page).to have_link("#{product.name}", href: product.long_url)
            expect(page).to have_text("You can access it by visiting your Gumroad Library or through the link in your email receipt.")
          end
        end
      end
    end

    context "product with variants" do
      let(:product) { create(:product_with_digital_versions, user: seller, name: "Sample product", price_cents: 1000) }

      it "allows notifying users" do
        visit edit_link_path(product.unique_permalink)
        select_tab "Content"

        editor = find("[aria-label='Content editor']")
        set_rich_text_editor_input(editor, to_text: "Hi there!")

        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved!")

        set_rich_text_editor_input(editor, to_text: "New content")
        click_on "Save changes"
        expect(page).to have_alert(text: "Changes saved! Would you like to notify your customers about those changes?")

        new_window = window_opened_by { click_on "Send notification" }
        within_window new_window do
          expect(page).to have_field("Title", with: "New content added to #{product.name}")
          expect(page).to have_radio_button "Customers only", checked: true
          expect(page).to have_checked_field("Send email")
          expect(page).to have_unchecked_field("Post to profile")
          within(:fieldset, "Bought") do
            expect(page).to have_button("#{product.name} - #{product.alive_variants.first.name}")
            expect(page).not_to have_selector(:button, exact_text: product.name)
            expect(page).not_to have_button("#{product.name} - #{product.alive_variants.last.name}")
          end
          within find("[aria-label='Email message']") do
            expect(page).to have_text("New content has been added to")
            expect(page).to have_link("#{product.name}", href: product.long_url)
            expect(page).to have_text("You can access it by visiting your Gumroad Library or through the link in your email receipt.")
          end
        end
      end
    end
  end

  it "allows toggling the community chat integration on and off" do
    Feature.activate_user(:communities, seller)

    visit edit_link_path(product.unique_permalink)

    check "Invite your customers to your Gumroad community chat", unchecked: true, allow_label_click: true
    save_change
    product.reload
    expect(product.community_chat_enabled?).to be(true)
    expect(product.active_community).to be_present

    uncheck "Invite your customers to your Gumroad community chat", checked: true, allow_label_click: true
    save_change
    product.reload
    expect(product.community_chat_enabled?).to be(false)
    expect(product.active_community).to be_nil
  end
end
