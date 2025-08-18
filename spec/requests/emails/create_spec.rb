# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Email Creation Flow", :js, type: :system) do
  include EmailHelpers

  let(:seller) { create(:named_seller) }

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:merchant_account_stripe_connect, user: seller)
    create(:payment_completed, user: seller)
  end

  include_context "with switching account to user as admin for seller"

  it "creates a product-type email with images and attachments" do
    product = create(:product, name: "Sample product", user: seller)
    another_product = create(:product, name: "Another product", user: seller)

    create(:purchase, link: product)
    create(:purchase, link: product, email: "john@example.com")
    create(:purchase, link: another_product, email: "john@example.com")
    create(:active_follower, user: product.user)

    visit emails_path

    wait_for_ajax
    click_on "New email", match: :first
    wait_for_ajax

    expect(page).to have_content("New email")
    # Ensure that the "Everyone" audience type is selected by default
    expect(page).to have_radio_button "Everyone", checked: true
    expect(page).to have_text("Audience 3 / 3", normalize_ws: true)

    # It updates the audience count when the audience type is changed
    choose "Customers only"
    wait_for_ajax
    expect(page).to have_text("Audience 2 / 3", normalize_ws: true)

    # It shows the correct options for bought/not bought filters and updates the audience count when those are changed
    find(:combo_box, "Bought").click
    expect(page).to have_combo_box("Bought", expanded: true, with_options: ["Sample product", "Another product"])
    select_combo_box_option "Sample product", from: "Bought"
    wait_for_ajax
    expect(page).to have_text("Audience 2 / 3", normalize_ws: true)
    select_combo_box_option "Another product", from: "Has not yet bought"
    wait_for_ajax
    expect(page).to have_text("Audience 1 / 3", normalize_ws: true)

    fill_in "Paid more than", with: "1"
    fill_in "Paid less than", with: "10"
    fill_in "After", with: "01-07-2024"
    fill_in "Before", with: "05-07-2024"

    within :fieldset, "After" do
      expect(page).to have_text("00:00 #{Time.now.in_time_zone(seller.timezone).strftime("%Z")}")
    end
    within :fieldset, "Before" do
      expect(page).to have_text("11:59 #{Time.now.in_time_zone(seller.timezone).strftime("%Z")}")
    end

    select "Canada", from: "From"
    wait_for_ajax
    expect(page).to have_text("Audience 0 / 3", normalize_ws: true)

    expect(page).to have_checked_field("Allow comments")
    uncheck "Allow comments"

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    select_disclosure "Insert" do
      click_on "Button"
    end
    within_modal do
      fill_in "Enter text", with: "Click me"
      fill_in "Enter URL", with: "https://example.com/button"
      click_on "Add button"
    end

    # Allows embedding images in the email body
    attach_file(file_fixture("test.jpg")) do
      click_on "Insert image"
    end
    wait_for_ajax

    # Allows attaching files to the email
    upload_attachment("thing.mov")
    upload_attachment("test.mp4")
    within find_attachment("test") do
      click_on "Edit"
      attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.srt"), visible: false)
    end

    # Allows disabling file downloads when the attachments contain streamable files
    expect(page).to have_unchecked_field("Disable file downloads (stream only)")
    check "Disable file downloads (stream only)"

    expect(page).to have_button("Save", disabled: false)
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to include("<p>Hello, world!</p>")
    expect(installment.message).to have_link("Click me", href: "https://example.com/button")
    image_cdn_url = "https://gumroad-specs.s3.amazonaws.com/#{ActiveStorage::Blob.last.key}"
    expect(installment.message).to include(%Q(<img src="#{image_cdn_url}"))
    expect(installment.product_type?).to be(true)
    expect(installment.link).to eq(product)
    expect(installment.base_variant).to be_nil
    expect(installment.seller).to eq(seller)
    expect(installment.published?).to be(false)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.bought_products).to eq([product.unique_permalink])
    expect(installment.bought_variants).to be_nil
    expect(installment.not_bought_products).to eq([another_product.unique_permalink])
    expect(installment.not_bought_variants).to be_nil
    expect(installment.affiliate_products).to be_nil
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.paid_more_than_cents).to eq(100)
    expect(installment.paid_less_than_cents).to eq(1000)
    expect(installment.created_after).to be_present
    expect(installment.created_before).to be_present
    expect(installment.bought_from).to eq("Canada")
    expect(installment.allow_comments?).to be(false)
    expect(installment.product_files.alive.map(&:s3_filename)).to eq(["thing.mov", "test.mp4"])
    subtitle = installment.product_files.alive.last.subtitle_files.alive.sole
    expect(subtitle.url).to include("sample.srt")
    expect(subtitle.language).to include("English")
    expect(installment.stream_only?).to be(true)

    # It redirects to the edit page on creating the email and shows the correct data
    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    expect(page).to have_text("Edit email")
    expect(page).to have_radio_button "Customers only", checked: true
    within :fieldset, "Bought" do
      expect(page).to have_button("Sample product")
    end
    expect(page).to have_unchecked_field("Allow comments")
    expect(page).to have_field("Title", with: "Hello")
    within("[aria-label='Email message']") do
      expect(page).to have_text("Hello, world!")
      expect(page).to have_link("Click me", href: "https://example.com/button")
      expect(page).to have_selector("img[src*='#{image_cdn_url}']")
    end
    expect(page).to have_attachment(name: "thing")
    within find_attachment("test") do
      expect(page).to have_attachment(name: "sample")
    end
    expect(page).to have_checked_field("Disable file downloads (stream only)")

    # On cancel, it redirects back to the tab from which "New email" was clicked
    click_on "Cancel"
    expect(page).to have_current_path("#{emails_path}/published")

    # Ensures that the just-created email is shown in the "Drafts" tab
    select_tab "Drafts"
    wait_for_ajax
    expect(page).to have_table_row({ "Subject" => "Hello", "Sent to" => "Customers of Sample product", "Audience" => "0" })

    find(:table_row, { name: "Hello" }).click
    click_on "Edit"
    expect(page).to have_attachment(name: "thing")
    expect(page).to have_checked_field("Disable file downloads (stream only)")
  end

  it "creates a variant-type email" do
    product = create(:product, name: "Sample product", user: seller)
    variant_category = create(:variant_category, link: product)
    variant1 = create(:variant, name: "V1", variant_category:)
    create(:variant, name: "V2", variant_category:)
    create(:purchase, seller:, link: product, country: "Italy", variant_attributes: [variant1])

    visit emails_path

    click_on "New email", match: :first

    choose "Customers only"
    find(:combo_box, "Bought").click

    # Ensure that the variant options are shown in bought/not-bought filters
    expect(page).to have_combo_box("Bought", expanded: true, with_options: ["Sample product", "Sample product - V1", "Sample product - V2"])

    # Select a variant option
    select_combo_box_option "Sample product - V1", from: "Bought"
    expect(page).to have_text("Audience 1 / 1", normalize_ws: true)

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to include("<p>Hello, world!</p>")
    expect(installment.variant_type?).to be(true)
    expect(installment.link).to eq(product)
    expect(installment.base_variant).to eq(variant1)
    expect(installment.seller).to eq(seller)
    expect(installment.published?).to be(false)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.bought_products).to be_nil
    expect(installment.bought_variants).to eq([variant1.external_id])
    expect(installment.not_bought_products).to be_nil
    expect(installment.not_bought_variants).to be_nil
    expect(installment.affiliate_products).to be_nil
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.paid_more_than_cents).to be_nil
    expect(installment.paid_less_than_cents).to be_nil
    expect(installment.created_after).to be_nil
    expect(installment.created_before).to be_nil
    expect(installment.bought_from).to be_nil
    expect(installment.allow_comments?).to be(true)
    expect(installment.product_files).to be_empty

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    click_on "Cancel"
    expect(page).to have_current_path("#{emails_path}/published")

    select_tab "Drafts"
    wait_for_ajax
    expect(page).to have_table_row({ "Subject" => "Hello", "Sent to" => "Customers of Sample product - V1", "Audience" => "1" })
  end

  it "creates a audience-type email" do
    product = create(:product, name: "Sample product", user: seller)
    create(:product, user: product.user, name: "Another product")
    create(:purchase, link: product)
    create_list(:active_follower, 2, user: product.user)

    visit emails_path

    click_on "New email", match: :first

    expect(page).to have_radio_button("Everyone", checked: true)
    expect(page).to have_text("Audience 3 / 3", normalize_ws: true)
    expect(page).to have_checked_field("Send email")
    expect(page).to have_checked_field("Post to profile")

    # Audience type does not show the "Bought", "Paid more/less than" and "From" filters
    expect(page).to_not have_combo_box("Bought")
    expect(page).to have_combo_box("Has not yet bought")
    expect(page).to_not have_combo_box(fieldset: "Affiliated products")
    expect(page).to_not have_field("Paid more than")
    expect(page).to_not have_field("Paid less than")
    expect(page).to have_input_labelled("After", with: "")
    expect(page).to have_input_labelled("Before", with: "")
    expect(page).to_not have_select("From")

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to include("<p>Hello, world!</p>")
    expect(installment.audience_type?).to be(true)
    expect(installment.link).to be_nil
    expect(installment.seller).to eq(seller)
    expect(installment.published?).to be(false)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.bought_products).to be_nil
    expect(installment.bought_variants).to be_nil
    expect(installment.not_bought_products).to be_nil
    expect(installment.not_bought_variants).to be_nil
    expect(installment.affiliate_products).to be_nil
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.paid_more_than_cents).to be_nil
    expect(installment.paid_less_than_cents).to be_nil
    expect(installment.created_after).to be_nil
    expect(installment.created_before).to be_nil
    expect(installment.bought_from).to be_nil
    expect(installment.allow_comments?).to be(true)
    expect(installment.product_files).to be_empty

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    click_on "Cancel"
    expect(page).to have_current_path("#{emails_path}/published")

    select_tab "Drafts"
    wait_for_ajax
    expect(page).to have_table_row({ "Subject" => "Hello", "Sent to" => "Your customers and followers", "Audience" => "3" })
  end

  it "creates a follower-type email" do
    product = create(:product, name: "Sample product", user: seller)
    create(:product, user: product.user, name: "Another product")
    create(:purchase, link: product)
    create_list(:active_follower, 2, user: product.user)

    visit emails_path

    click_on "New email", match: :first

    choose "Followers only"
    expect(page).to have_text("Audience 2 / 3", normalize_ws: true)
    expect(page).to_not have_field("Paid more than")
    expect(page).to_not have_field("Paid less than")

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to include("<p>Hello, world!</p>")
    expect(installment.follower_type?).to be(true)

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    click_on "Cancel"
    expect(page).to have_current_path("#{emails_path}/published")

    select_tab "Drafts"
    wait_for_ajax
    expect(page).to have_table_row({ "Subject" => "Hello", "Sent to" => "Your followers", "Audience" => "2" })
  end

  it "creates an affiliate-type email" do
    product = create(:product, name: "Sample product", user: seller)
    another_product = create(:product, name: "Another product", user: seller)
    create_list(:purchase, 2, link: product)
    affiliate = create(:direct_affiliate, seller: product.user)
    affiliate.products << product

    visit emails_path

    click_on "New email", match: :first

    # Ensure that the audience count is correct when the "Affiliates only"  audience type is selcted
    choose "Affiliates only"
    expect(page).to have_text("Audience 1 / 3", normalize_ws: true)

    find(:combo_box, fieldset: "Affiliated products").click
    expect(page).to have_combo_box(fieldset: "Affiliated products", expanded: true, with_options: ["Sample product", "Another product"])
    within(:fieldset, "Affiliated products") do
      expect(page).to_not have_button("Sample product")
      expect(page).to_not have_button("Another product")
    end

    # Ensure that the "All products" checkbox under the "Affiliated products" filter section works correctly
    expect(page).to have_unchecked_field("All products")
    check "All products"
    within(:fieldset, "Affiliated products") do
      expect(page).to have_button("Sample product")
      expect(page).to have_button("Another product")
    end
    wait_for_ajax

    # Unselecting a selected option from "Affiliated products" automatically unchecks "All products"
    within(:fieldset, "Affiliated products") do
      click_on "Sample product"
      expect(page).to_not have_button("Sample product")
      expect(page).to have_button("Another product")
    end
    expect(page).to have_unchecked_field("All products")

    # Ensure that the updated audience count is correct
    wait_for_ajax
    expect(page).to have_text("Audience 0 / 3", normalize_ws: true)
    check "All products"
    wait_for_ajax
    expect(page).to have_text("Audience 1 / 3", normalize_ws: true)

    # Check presence of other filters and make some changes
    expect(page).to_not have_combo_box("Bought")
    expect(page).to_not have_combo_box("Has not yet bought")
    expect(page).to_not have_field("Paid more than", with: "")
    expect(page).to_not have_field("Paid less than", with: "")
    expect(page).to have_field("After")
    expect(page).to have_field("Before")
    expect(page).to_not have_select("From")
    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update

    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to include("<p>Hello, world!</p>")
    expect(installment.affiliate_type?).to be(true)
    expect(installment.link).to be_nil
    expect(installment.seller).to eq(seller)
    expect(installment.published?).to be(false)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.bought_products).to be_nil
    expect(installment.bought_variants).to be_nil
    expect(installment.not_bought_products).to be_nil
    expect(installment.not_bought_variants).to be_nil
    expect(installment.affiliate_products).to match_array([product.unique_permalink, another_product.unique_permalink])
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.paid_more_than_cents).to be_nil
    expect(installment.paid_less_than_cents).to be_nil
    expect(installment.created_after).to be_nil
    expect(installment.created_before).to be_nil
    expect(installment.bought_from).to be_nil
    expect(installment.allow_comments?).to be(true)
    expect(installment.product_files).to be_empty

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    click_on "Cancel"
    expect(page).to have_current_path("#{emails_path}/published")

    select_tab "Drafts"
    wait_for_ajax
    expect(page).to have_table_row({ "Subject" => "Hello", "Sent to" => "Your affiliates", "Audience" => "1" })
  end

  it "does not show archived products" do
    product = create(:product, name: "Sample product", user: seller)
    archived_product = create(:product, name: "Archived product", user: seller, archived: true)

    create(:purchase, link: archived_product)
    create(:purchase, link: product)
    create(:audience_member, seller:, affiliates: [{}])

    visit emails_path

    click_on "New email", match: :first

    choose "Customers only"

    find(:combo_box, "Bought").click
    expect(page).to have_combo_box("Bought", expanded: true, with_options: ["Sample product"])

    find(:combo_box, "Has not yet bought").click
    expect(page).to have_combo_box("Has not yet bought", expanded: true, with_options: ["Sample product"])

    choose "Affiliates only"

    find(:combo_box, fieldset: "Affiliated products").click
    expect(page).to have_combo_box(fieldset: "Affiliated products", expanded: true, with_options: ["Sample product"])
  end

  it "does not upload unsupported file as a subtitle" do
    visit "#{emails_path}/new"

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    upload_attachment("test.mp4")

    within find_attachment("test") do
      click_on "Edit"
      attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.gif"), visible: false)
    end

    expect(page).to have_alert(text: "Invalid file type.")
    within find_attachment("test") do
      expect(page).to_not have_attachment(name: "sample")
    end

    click_on "Save"
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.product_files.alive.map(&:s3_filename)).to eq(["test.mp4"])
    expect(installment.product_files.alive.sole.subtitle_files).to be_empty

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    within find_attachment("test") do
      expect(page).to_not have_attachment(name: "sample")
    end
  end

  it "auto populates the new email form when URL contains 'product' query parameter" do
    product = create(:product, user: seller, name: "Sample product")
    create(:purchase, link: product)

    visit "#{emails_path}/new?product=#{product.unique_permalink}"
    wait_for_ajax

    expect(page).to have_radio_button("Customers only", checked: true)
    find(:combo_box, "Bought").click
    within(:fieldset, "Bought") do
      expect(page).to have_button(product.name)
    end
    expect(page).to have_field("Title", with: "Sample product - updated!")
    within find("[aria-label='Email message']") do
      expect(page).to have_text("I have recently updated some files associated with Sample product. They're yours for free.")
    end

    sleep 0.5 # wait for the message editor to update
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    expect(installment.name).to eq("Sample product - updated!")
    expect(installment.message).to eq("<p>I have recently updated some files associated with Sample product. They're yours for free.</p>")
    expect(installment.link).to eq(product)
    expect(installment.seller).to eq(seller)
    expect(installment.product_type?).to be(true)
    expect(installment.bought_products).to eq([product.unique_permalink])
  end

  it "auto populates the new email form when URL contains bundle product related query parameter" do
    product = create(:product, :bundle, user: seller)
    create(:purchase, link: product)

    visit edit_link_path(product.unique_permalink)

    # Create a draft email from the "Share" tab of a bundle product
    select_tab "Share"
    expect(page).to have_checked_field("Customers who have purchased at least one product in the bundle")
    new_window = window_opened_by { click_on "Draft and send" }

    within_window new_window do
      expect(page).to have_text("New email")
      expect(page).to have_radio_button("Customers only", checked: true)
      expect(page).to have_checked_field("Send email")
      expect(page).to have_unchecked_field("Post to profile")
      find(:combo_box, "Bought").click
      within(:fieldset, "Bought") do
        expect(page).to have_button("Bundle Product 1")
        expect(page).to have_button("Bundle Product 2")
      end
      expect(page).to have_field("Title", with: "Introducing Bundle")
      within find("[aria-label='Email message']") do
        expect(page).to have_text("Hey there,")
        expect(page).to have_text("I've put together a bundle of my products that I think you'll love.")
        expect(page).to have_text("Bundle")
        expect(page).to have_text("$2 $1", normalize_ws: true)
        expect(page).to have_text("Included in this bundle")
        expect(page).to have_link("Bundle Product 1", href: short_link_url(product.bundle_products.first.product, host: DOMAIN))
        expect(page).to have_link("Bundle Product 2", href: short_link_url(product.bundle_products.last.product, host: DOMAIN))
        expect(page).to have_link("Get your bundle", href: short_link_url(product, host: DOMAIN))
        expect(page).to have_text("Thanks for your support!")
      end
      sleep 0.5 # wait for the message editor to update

      click_on "Save"
      wait_for_ajax
      expect(page).to have_alert(text: "Email created!")

      installment = Installment.last
      expect(installment.name).to eq("Introducing Bundle")
      expect(installment.message).to eq(%Q(<p>Hey there,</p><p>I've put together a bundle of my products that I think you'll love.</p><hr><p><strong>Bundle</strong></p><p><s>$2</s> $1</p><p>Included in this bundle</p><ul>\n<li><a target="_blank" rel="noopener noreferrer nofollow" href="#{short_link_url(product.bundle_products.first.product, host: DOMAIN)}">Bundle Product 1</a></li>\n<li><a target="_blank" rel="noopener noreferrer nofollow" href="#{short_link_url(product.bundle_products.last.product, host: DOMAIN)}">Bundle Product 2</a></li>\n</ul><a href="#{short_link_url(product, host: DOMAIN)}" class="tiptap__button button primary" target="_blank" rel="noopener noreferrer nofollow">Get your bundle</a><hr><p>Thanks for your support!</p>))
      expect(installment.link).to be_nil
      expect(installment.seller).to eq(seller)
      expect(installment.seller_type?).to be(true)
      expect(installment.bought_products).to eq(product.bundle_products.flat_map(&:product).map(&:unique_permalink))
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(false)
    end

    new_window.close
  end

  it "creates and schedules an email"  do
    product = create(:product, name: "Sample product", user: seller)
    create(:purchase, link: product)

    visit emails_path
    click_on "New email", match: :first

    expect(page).to have_checked_field("Post to profile")
    expect(page).to have_checked_field("Send email")
    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update

    # Does not create an email if the schedule date is invalid while scheduling it
    select_disclosure "Publish" do
      expect(page).to have_button("Publish now")
      fill_in "Schedule date", with: "01/01/2021\t04:00PM"
      click_on "Schedule"
    end
    wait_for_ajax
    expect(page).to have_alert("Please select a date and time in the future.")
    expect(page).to have_current_path("#{emails_path}/new")
    expect(Installment.count).to eq(0)

    # Creates and schedules an email if the schedule date is valid
    select_disclosure "Publish" do
      expect(page).to have_button("Publish now")
      fill_in "Schedule date", with: "01/01/#{Date.today.year.next}\t04:00PM"
      click_on "Schedule"
    end
    wait_for_ajax
    expect(page).to have_alert("Email successfully scheduled!")
    expect(page).to have_current_path("#{emails_path}/scheduled")
    expect(page).to have_table_row({ "Subject" => "Hello" })
    expect(Installment.count).to eq(1)

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to eq("<p>Hello, world!</p>")
    expect(installment.reload.ready_to_publish?).to be(true)
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.published?).to be(false)
    expect(installment.installment_rule.to_be_published_at).to be_present
  end

  it "creates and publishes an email" do
    product = create(:product, name: "Sample product", user: seller)
    create(:purchase, link: product)

    visit emails_path
    click_on "New email", match: :first

    expect(page).to have_checked_field("Post to profile")
    expect(page).to have_checked_field("Send email")
    expect(page).to_not have_field("Publish date")

    fill_in "Title", with: "Hello"

    # Does not create an email if a required field is empty
    select_disclosure "Publish" do
      click_on "Publish now"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Please include a message as part of the update.")
    expect(Installment.count).to eq(0)

    # Creates and publishes an email if all required fields are present and valid
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    sleep 0.5 # wait for the message editor to update

    select_disclosure "Publish" do
      click_on "Publish now"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Email successfully published!")
    expect(Installment.count).to eq(1)

    installment = Installment.last
    expect(installment.name).to eq("Hello")
    expect(installment.message).to eq("<p>Hello, world!</p>")
    expect(installment.published?).to be(true)
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.has_been_blasted?).to be(true)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.installment_rule).to be_nil
    expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.sole.id)

    # Check that the email is shown under the "Published" tab
    expect(page).to have_current_path("#{emails_path}/published")
    expect(page).to have_table_row({ "Subject" => "Hello" })

    # Check that the "Send email" is disabled and the publish date is displayed
    find(:table_row, { "Subject" => "Hello" }).click
    click_on "Edit"
    expect(page).to have_checked_field("Send email", disabled: true)
    expect(page).to have_field("Publish date", with: installment.published_at.to_date.to_s)
  end

  it "returns an error while publishing an email if the seller is not eligible to send emails" do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

    product = create(:product, name: "Sample product", user: seller)
    create(:purchase, link: product)

    visit emails_path
    click_on "New email", match: :first

    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")

    select_disclosure "Publish" do
      click_on "Publish now"
    end
    wait_for_ajax

    expect(page).to have_alert(text: "You are not eligible to publish or schedule emails. Please ensure you have made at least $100 in sales and received a payout.")
    expect(Installment.count).to eq(0)
  end

  context "when both 'Send email' and 'Post to profile' channels are selected" do
    it "creates and previews the email" do
      product = create(:product, name: "Sample product", user: seller)
      create(:purchase, link: product)

      allow_any_instance_of(Installment).to receive(:send_preview_email).with(user_with_role_for_seller)

      visit emails_path
      click_on "New email", match: :first

      expect(page).to have_checked_field("Post to profile")
      expect(page).to have_checked_field("Send email")
      fill_in "Title", with: "Hello"
      set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
      sleep 0.5 # wait for the message editor to update

      # Sends the preview email
      select_disclosure "Preview" do
        expect(page).to have_button("Preview Post")
        click_on "Preview Email"
      end
      wait_for_ajax
      expect(page).to have_alert(text: "A preview has been sent to your email.")

      installment = Installment.last
      expect(installment.name).to eq("Hello")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.published?).to be(false)
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.has_been_blasted?).to be(false)

      expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")

      click_on "Cancel"
      click_on "New email", match: :first

      # Creates and opens the post in a new window
      fill_in "Title", with: "My post"
      set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
      sleep 0.5 # wait for the message editor to update

      new_window = window_opened_by do
        select_disclosure "Preview" do
          expect(page).to have_button("Preview Email")
          click_on "Preview Post"
        end

        wait_for_ajax
        expect(page).to have_alert(text: "Preview link opened.")
      end

      within_window new_window do
        wait_for_ajax
        expect(page).to have_text("My post")
        expect(page).to have_text("Hello, world!")
      end
      new_window.close

      installment = Installment.last
      expect(installment.name).to eq("My post")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.published?).to be(false)
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.has_been_blasted?).to be(false)

      expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    end
  end

  context "when either 'Send email' or 'Post to profile' channel is selected" do
    it "creates and previews the email" do
      product = create(:product, name: "Sample product", user: seller)
      create(:purchase, link: product)

      allow_any_instance_of(Installment).to receive(:send_preview_email).with(user_with_role_for_seller)

      visit emails_path
      click_on "New email", match: :first

      expect(page).to have_checked_field("Post to profile")
      expect(page).to have_checked_field("Send email")

      # Does not create and preview the email if both the channels are unchecked
      uncheck "Send email"
      uncheck "Post to profile"

      fill_in "Title", with: "Hello"
      set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
      sleep 0.5 # wait for the message editor to update

      click_on "Preview"
      wait_for_ajax
      expect(page).to have_alert(text: "Please set at least one channel for your update.")
      expect(Installment.count).to eq(0)


      # Creates the email and sends a preview email if "Send email" is checked
      check "Send email"
      expect(page).to_not have_disclosure("Preview")
      click_on "Preview"
      wait_for_ajax
      expect(page).to have_alert(text: "A preview has been sent to your email.")

      installment = Installment.last
      expect(installment.name).to eq("Hello")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.published?).to be(false)
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(false)
      expect(installment.has_been_blasted?).to be(false)

      expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")

      click_on "Cancel"
      click_on "New email", match: :first

      # Creates the email and opens the post in a new window when "Post to profile" is checked
      expect(page).to have_checked_field("Post to profile")
      uncheck "Send email"
      expect(page).to_not have_disclosure("Preview")
      fill_in "Title", with: "My post"
      set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
      sleep 0.5 # wait for the message editor to update

      new_window = window_opened_by do
        click_on "Preview"
        wait_for_ajax
        expect(page).to have_alert(text: "Preview link opened.")
      end

      within_window new_window do
        wait_for_ajax
        expect(page).to have_text("My post")
        expect(page).to have_text("Hello, world!")
      end
      new_window.close

      installment = Installment.last
      expect(installment.name).to eq("My post")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.published?).to be(false)
      expect(installment.send_emails).to be(false)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.has_been_blasted?).to be(false)

      expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    end
  end

  it "allows duplicating and editing an already published email" do
    product = create(:product, name: "Sample product", user: seller)

    create(:purchase, link: product)

    visit emails_path

    # Create and publish an email with attachments that we will duplicate later
    click_on "New email", match: :first
    uncheck "Allow comments"
    fill_in "Title", with: "Hello"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hello, world!")
    # Allows attaching files to the email
    upload_attachment("thing.mov")
    select_disclosure "Publish" do
      click_on "Publish now"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Email successfully published!")

    # Duplicate the email
    find(:table_row, text: "Hello").click
    click_on "Duplicate"
    wait_for_ajax
    expect(page).to have_current_path("#{emails_path}/new?copy_from=#{Installment.last.external_id}")

    # Ensure that it auto-populates the fields
    expect(page).to have_checked_field("Send email")
    expect(page).to have_checked_field("Post to profile")
    expect(page).to have_field("Title", with: "Hello")
    expect(page).to_not have_field("Publish date")
    within find("[aria-label='Email message']") do
      expect(page).to have_text("Hello, world!")
    end
    expect(page).to have_unchecked_field("Allow comments")
    expect(page).to_not have_attachment(name: "thing")

    # Allows editing the populated fields and creates a new email
    uncheck "Send email"
    fill_in "Title", with: "Hello (Copy)"
    check "Allow comments"
    click_on "Save"
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Hello (Copy)")
    expect(installment.message).to eq("<p>Hello, world!</p>")
    expect(installment.published?).to be(false)
    expect(installment.send_emails).to be(false)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.has_been_blasted?).to be(false)

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
  end

  it "shows unchecked 'Allow comments' setting if the last created email had it unchecked as well" do
    create(:installment, seller:, allow_comments: false)

    visit emails_path

    click_on "New email", match: :first

    expect(page).to have_unchecked_field("Allow comments")

    fill_in "Title", with: "Test Email"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "This is a test email.")

    sleep 0.5 # wait for the message editor to update

    click_on "Save"
    expect(page).to have_alert(text: "Email created!")

    installment = Installment.last
    expect(installment.name).to eq("Test Email")
    expect(installment.allow_comments).to be(false)
  end

  it "allows creating and deleting an upsell" do
    product = create(:product, user: seller, name: "Sample product", price_cents: 1000)
    create(:purchase, :with_review, link: product)
    visit emails_path

    click_on "New email", match: :first

    fill_in "Title", with: "Upsell!"

    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Hi there!")

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

    sleep 1
    click_on "Save"
    expect(page).to have_alert(text: "Email created!")

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

    installment = Installment.last
    expect(installment.message).to eq(%Q(<p>Hi there!</p><upsell-card productid="#{product.external_id}" discount='{"type":"fixed","cents":100}' id="#{upsell.external_id}"></upsell-card>))

    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "")
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    upsell.reload
    expect(upsell.deleted?).to be(true)
    expect(upsell.offer_code.deleted?).to be(true)
  end
end
