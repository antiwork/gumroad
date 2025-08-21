# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Email Editing Flow", :js, :elasticsearch_wait_for_refresh, type: :system) do
  include EmailHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, name: "Sample product", user: seller) }
  let!(:product2) { create(:product, name: "Another product", user: seller) }
  let!(:purchase) { create(:purchase, link: product) }
  let!(:installment) { create(:installment, seller:, name: "Original email", message: "Original message", bought_products: [product.unique_permalink, product2.unique_permalink], link_id: nil, installment_type: "seller", created_after: "2024-01-01T00:00:00Z", created_before: "2024-01-02T23:59:59Z", paid_more_than_cents: 100, paid_less_than_cents: 1000, bought_from: "Canada", shown_on_profile: false, allow_comments: false) }

  include_context "with switching account to user as admin for seller"

  before do
    seller.update!(timezone: "UTC")

    recreate_model_indices(Purchase)
    index_model_records(Purchase)

    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
  end

  it "allows editing an unpublished email" do
    # Ensure that an archived product with successful sales is shown in the "Bought", "Has not yet bought", etc. filters
    product.update!(archived: true)

    visit emails_path

    select_tab "Drafts"
    wait_for_ajax
    find(:table_row, { name: "Original email" }).click
    click_on "Edit"
    expect(page).to have_text("Edit email")

    # Check that the form is filled in correctly and update some of the fields
    expect(page).to have_radio_button "Customers only", checked: true
    expect(page).to have_text("Audience 0 / 1", normalize_ws: true)
    expect(page).to have_checked_field("Send email")
    uncheck "Send email"
    expect(page).to have_unchecked_field("Post to profile")
    check "Post to profile"
    within :fieldset, "Bought" do
      expect(page).to have_button("Sample product")
      expect(page).to have_button("Another product")
      click_on "Another product"
      expect(page).to have_button("Sample product")
      expect(page).to_not have_button("Another product")
    end
    find(:combo_box, "Has not yet bought").click
    expect(page).to have_combo_box("Has not yet bought", expanded: true, with_options: ["Another product"])
    select_combo_box_option("Another product", from: "Has not yet bought")
    expect(page).to have_field("Paid more than", with: "1")
    fill_in "Paid more than", with: "2"
    expect(page).to have_field("Paid less than", with: "10")
    fill_in "Paid less than", with: "15"
    expect(page).to have_field("After", with: "2024-01-01")
    expect(page).to have_field("Before", with: "2024-01-02")
    expect(page).to have_select("From", selected: "Canada")
    select "United States", from: "From"
    expect(page).to have_unchecked_field("Allow comments")
    check "Allow comments"
    expect(page).to have_field("Title", with: "Original email")
    fill_in "Title", with: "Updated email"
    expect(page).to_not have_field("Publish date")
    within find("[aria-label='Email message']") do
      expect(page).to have_text "Original message"
    end
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Updated message")
    sleep 0.5 # Wait for the message editor to update
    attach_file(file_fixture("test.jpg")) do
      click_on "Insert image"
    end
    wait_for_ajax
    upload_attachment("test.mp4")
    within find_attachment("test") do
      click_on "Edit"
      attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.srt"), visible: false)
    end
    expect(page).to have_unchecked_field("Disable file downloads (stream only)")
    expect(page).to have_button("Save", disabled: false)
    create(:seller_profile_posts_section, seller:) # Create a profile section

    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    installment.reload
    expect(installment.name).to eq("Updated email")
    expect(installment.message).to include("<p>Updated message</p>")
    expect(installment.seller_type?).to be(false)
    expect(installment.product_type?).to be(true)
    expect(installment.link).to eq(product)
    expect(installment.base_variant).to be_nil
    expect(installment.seller).to eq(seller)
    expect(installment.published?).to be(false)
    expect(installment.ready_to_publish?).to be(false)
    # Although the 'product' is archived (with successful sales), it is kept on save
    expect(installment.bought_products).to eq([product.unique_permalink])
    expect(installment.bought_variants).to be_nil
    expect(installment.not_bought_products).to eq([product2.unique_permalink])
    expect(installment.not_bought_variants).to be_nil
    expect(installment.affiliate_products).to be_nil
    expect(installment.send_emails).to be(false)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.paid_more_than_cents).to eq(200)
    expect(installment.paid_less_than_cents).to eq(1500)
    expect(installment.bought_from).to eq("United States")
    expect(installment.allow_comments).to be(true)
    expect(installment.product_files.alive.map(&:s3_filename)).to eq(["test.mp4"])
    subtitle = installment.product_files.alive.last.subtitle_files.alive.sole
    expect(subtitle.url).to include("sample.srt")
    expect(subtitle.language).to include("English")
    expect(installment.stream_only?).to be(false)

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
  end

  it "allows editing and scheduling a draft email" do
    visit emails_path

    select_tab "Drafts"
    wait_for_ajax

    find(:table_row, { name: "Original email" }).click
    click_on "Edit"
    expect(page).to have_text("Edit email")

    expect(page).to have_checked_field("Send email")
    expect(page).to have_unchecked_field("Post to profile")
    expect(page).to have_field("Title", with: "Original email")
    fill_in "Title", with: "Updated email"
    expect(page).to_not have_field("Publish date")
    expect(page).to_not have_disclosure("Publish")

    # Try scheduling the email with an invalid date
    select_disclosure "Send" do
      expect(page).to have_button("Send now")
      expect(page).to_not have_button("Publish now")
      fill_in "Schedule date", with: "01/01/2021\t04:00PM"
      click_on "Schedule"
    end
    wait_for_ajax
    expect(page).to have_alert("Please select a date and time in the future.")

    expect(installment.reload.name).to eq("Original email")
    expect(installment.ready_to_publish?).to be(false)

    # Try scheduling the email with a valid date
    check "Post to profile"
    expect(page).to_not have_disclosure("Send")
    select_disclosure "Publish" do
      expect(page).to have_button("Publish now")
      expect(page).to_not have_button("Send now")
      fill_in "Schedule date", with: "01/01/#{Date.today.year.next}\t04:00PM"
      click_on "Schedule"
    end
    wait_for_ajax
    expect(page).to have_alert("Email successfully scheduled!")

    expect(installment.reload.ready_to_publish?).to be(true)
    expect(installment.installment_rule.to_be_published_at.to_date.to_s).to eq("#{Date.today.year.next}-01-01")
    expect(installment.name).to eq("Updated email")
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.published?).to be(false)
  end

  it "allows editing and publishing an email" do
    scheduled_installment = create(:scheduled_installment, seller:, name: "Scheduled email")
    scheduled_installment.installment_rule.update!(to_be_published_at: 1.year.from_now)

    visit emails_path

    # Ensure that the "Scheduled" tab is open by default on accessing the /emails page where there's at least one scheduled email
    expect(page).to have_current_path("#{emails_path}/scheduled")
    expect(page).to have_tab_button("Scheduled", open: true)
    find(:table_row, { name: "Scheduled email" }).click
    click_on "Edit"

    expect(page).to have_current_path("#{emails_path}/#{scheduled_installment.external_id}/edit")
    expect(page).to have_checked_field("Send email")
    expect(page).to have_unchecked_field("Post to profile")
    expect(page).to have_field("Title", with: "Scheduled email")
    fill_in "Title", with: "Updated scheduled email"
    expect(page).to_not have_field("Publish date")

    # Publish the scheduled email
    select_disclosure "Send" do
      expect(page).to have_button("Schedule")
      click_on "Send now"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Email successfully sent!")

    expect(scheduled_installment.reload.name).to eq("Updated scheduled email")
    expect(scheduled_installment.send_emails).to be(true)
    expect(scheduled_installment.shown_on_profile).to be(false)
    expect(scheduled_installment.published?).to be(true)
    expect(scheduled_installment.has_been_blasted?).to be(true)
    expect(scheduled_installment.ready_to_publish?).to be(true)
    expect(scheduled_installment.installment_rule.deleted?).to be(true)
    expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.sole.id)

    # Check that the publish date is displayed
    expect(page).to have_current_path("#{emails_path}/published")
    find(:table_row, { name: "Updated scheduled email" }).click
    click_on "Edit"
    expect(page).to have_checked_field("Send email", disabled: true)
    expect(page).to have_field("Publish date", with: scheduled_installment.published_at.to_date.to_s)
    click_on "Cancel"

    # Check that the email is removed from the "Scheduled" tab
    select_tab "Scheduled"
    expect(page).to have_current_path("#{emails_path}/scheduled")
    expect(page).to_not have_table_row({ "Subject" => "Scheduled email" })
    expect(page).to_not have_table_row({ "Subject" => "Updated scheduled email" })
    expect(page).to have_text("Set it and forget it.")
    expect(page).to have_text("Schedule an email to be sent exactly when you want.")

    select_tab "Drafts"
    find(:table_row, { name: "Original email" }).click
    click_on "Edit"

    expect(page).to have_current_path("#{emails_path}/#{installment.external_id}/edit")
    expect(page).to have_checked_field("Send email")
    expect(page).to have_unchecked_field("Post to profile")
    check "Post to profile"
    expect(page).to have_field("Title", with: "Original email")
    fill_in "Title", with: "Updated email"
    expect(page).to_not have_field("Publish date")

    # Publish the draft email
    select_disclosure "Publish" do
      expect(page).to have_button("Schedule")
      click_on "Publish now"
    end
    expect(page).to have_alert(text: "Email successfully published!")

    expect(installment.reload.name).to eq("Updated email")
    expect(installment.published?).to be(true)
    expect(installment.has_been_blasted?).to be(true)
    expect(installment.ready_to_publish?).to be(false)
    expect(installment.installment_rule).to be_nil
    expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last!.id)
    expect(PostEmailBlast.count).to eq(2)

    # Check that the publish date is displayed
    expect(page).to have_current_path("#{emails_path}/published")
    find(:table_row, { name: "Updated email" }).click
    click_on "Edit"
    expect(page).to have_checked_field("Send email", disabled: true)
    expect(page).to have_field("Publish date", with: installment.published_at.to_date.to_s)
    click_on "Cancel"

    # Check that the email is removed from the "Drafts" tab
    select_tab "Drafts"
    expect(page).to have_current_path("#{emails_path}/drafts")
    expect(page).to_not have_table_row({ "Subject" => "Original email" })
    expect(page).to_not have_table_row({ "Subject" => "Updated email" })
    expect(page).to have_text("Manage your drafts")
    expect(page).to have_text("Drafts allow you to save your emails and send whenever you're ready!")
  end

  it "allows editing certain fields of a published email" do
    published_installment = create(:published_installment, name: "Hello", seller: seller, published_at: "2024-01-01 12:00")
    original_published_at = published_installment.published_at

    visit emails_path

    # Ensure that the "Published" tab is open by default on accessing the /emails page where there are no scheduled emails
    expect(page).to have_tab_button("Published", open: true)
    find(:table_row, { name: "Hello" }).click
    click_on "Edit"

    expect(page).to have_current_path("#{emails_path}/#{published_installment.external_id}/edit")
    expect(page).to have_text("Edit email")
    expect(page).to have_radio_button("Customers only", checked: true, disabled: true)
    expect(page).to have_radio_button("Everyone", checked: false, disabled: true)

    # Until the email is blasted, the "Send email" field is NOT disabled
    expect(page).to have_checked_field("Send email", disabled: false)
    uncheck "Send email"
    expect(page).to have_unchecked_field("Post to profile", disabled: false)
    check "Post to profile"
    expect(page).to have_field("Paid more than", with: "", disabled: true)
    expect(page).to have_field("Paid less than", with: "", disabled: true)
    expect(page).to have_field("After", with: "", disabled: true)
    expect(page).to have_field("Before", with: "", disabled: true)
    expect(page).to have_select("From", disabled: true)
    expect(page).to have_checked_field("Allow comments", disabled: false)
    uncheck "Allow comments"
    fill_in "Title", with: "Hello - edit 1"
    # Ensure that the publish date is displayed
    expect(page).to have_field("Publish date", with: "2024-01-01")

    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    published_installment.reload
    expect(published_installment.name).to eq "Hello - edit 1"
    # It does not modify the publish date if it was unchanged
    expect(published_installment.published_at).to eq original_published_at
    expect(published_installment.send_emails).to be(false)
    expect(published_installment.shown_on_profile).to be(true)
    expect(published_installment.allow_comments).to be(false)
    check "Send email"

    # Ensure that it does not accept an invalid publish date and reject other changes as well on save
    fill_in "Publish date", with: "01/01/#{2.years.from_now.year}"
    fill_in "Title", with: "Hello - edit 2"
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Please enter a publish date in the past.")

    published_installment.reload
    expect(published_installment.published_at).to eq original_published_at
    expect(published_installment.name).to eq "Hello - edit 1"
    expect(published_installment.send_emails).to be(false)
    expect(published_installment.shown_on_profile).to be(true)
    expect(published_installment.allow_comments).to be(false)

    # Try setting the publish date to a valid date
    fill_in "Publish date", with: "01/01/2021"
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    published_installment.reload
    expect(published_installment.published_at.to_date.to_s).to eq "2021-01-01"
    expect(published_installment.name).to eq "Hello - edit 2"
    expect(published_installment.send_emails).to be(true)
    expect(published_installment.shown_on_profile).to be(true)
    expect(published_installment.has_been_blasted?).to be(false)
    expect(published_installment.allow_comments).to be(false)
    expect(page).to have_checked_field("Send email", disabled: false)
    expect(page).to have_checked_field("Post to profile", disabled: false)

    # Try publishing the already published email
    fill_in "Title", with: "Hello - edit 3"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Updated message")
    sleep 0.5 # Wait for the message editor to update
    select_disclosure "Publish" do
      expect(page).to have_button("Schedule", disabled: true)
      click_on "Publish now"
    end
    expect(page).to have_alert(text: "Email successfully published!")

    published_installment.reload
    expect(published_installment.published_at).to be_within(5.second).of(DateTime.current)
    expect(published_installment.has_been_blasted?).to be(true)
    expect(published_installment.name).to eq "Hello - edit 3"
    expect(published_installment.message).to eq("<p>Updated message</p>")

    # The "Send email" field is disabled after the email is blasted (which happens when the email is published)
    expect(page).to have_current_path("#{emails_path}/published")
    find(:table_row, { name: "Hello - edit 3" }).click
    click_on "Edit"
    expect(page).to have_checked_field("Send email", disabled: true)
    expect(page).to have_checked_field("Post to profile", disabled: false)
    expect(page).to have_field("Publish date", with: published_installment.published_at.to_date.to_s)
    expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last!.id)
  end

  it "allows editing and previewing an email" do
    allow_any_instance_of(Installment).to receive(:send_preview_email).with(user_with_role_for_seller)

    visit emails_path

    select_tab "Drafts"
    find(:table_row, { name: "Original email" }).click
    click_on "Edit"

    # Ensure that it saves the edited fields and sends a preview email
    fill_in "Title", with: "Updated original email"
    expect(page).to have_checked_field("Send email")
    expect(page).to have_unchecked_field("Post to profile")
    # When only one channel (either "Send email" or "Post to profile") is checked, the "Preview" button is not disclousre
    expect(page).to_not have_disclosure("Preview")
    click_on "Preview"
    wait_for_ajax
    expect(page).to have_alert(text: "A preview has been sent to your email.")

    expect(installment.reload.name).to eq("Updated original email")
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(false)
    expect(installment.published?).to be(false)
    expect(installment.has_been_blasted?).to be(false)
    expect(installment.ready_to_publish?).to be(false)

    # When both channels are unchecked, it does not allow saving and previewing
    fill_in "Title", with: "Updated original email - edit 2"
    uncheck "Send email"
    click_on "Preview"
    wait_for_ajax
    expect(page).to have_alert(text: "Please set at least one channel for your update.")

    # Opens the post in a new window when the "Post to profile" channel is checked
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Updated message")
    sleep 0.5 # Wait for the message editor to update
    expect(installment.reload.name).to eq("Updated original email")
    check "Post to profile"
    new_window = window_opened_by do
      click_on "Preview"
      expect(page).to have_alert(text: "Preview link opened.")
    end
    within_window new_window do
      wait_for_ajax
      expect(page).to have_text("Updated original email - edit 2")
      expect(page).to have_text("Updated message")
    end
    new_window.close

    expect(installment.reload.name).to eq("Updated original email - edit 2")
    expect(installment.message).to eq("<p>Updated message</p>")
    expect(installment.send_emails).to be(false)
    expect(installment.shown_on_profile).to be(true)
    expect(installment.published?).to be(false)
    expect(installment.has_been_blasted?).to be(false)
    expect(installment.ready_to_publish?).to be(false)

    click_on "Cancel"
    find(:table_row, { name: "Updated original email - edit 2" }).click
    click_on "Edit"
    wait_for_ajax

    # Schedule the email
    fill_in "Title", with: "Updated original email - scheduled"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Scheduled message")
    sleep 0.5 # Wait for the title editor to update
    select_disclosure "Publish" do
      click_on "Schedule"
    end
    expect(page).to have_alert(text: "Email successfully scheduled!")

    expect(installment.reload.name).to eq("Updated original email - scheduled")
    expect(installment.message).to eq("<p>Scheduled message</p>")
    expect(installment.ready_to_publish?).to be(true)

    # When both channels are checked, the "Preview" button is disclosure
    expect(page).to have_current_path("#{emails_path}/scheduled")
    find(:table_row, { name: "Updated original email - scheduled" }).click
    click_on "Edit"
    check "Send email"
    fill_in "Title", with: "Updated original email - scheduled - edit 2"
    select_disclosure "Preview" do
      click_on "Preview Email"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "A preview has been sent to your email.")

    expect(installment.reload.name).to eq("Updated original email - scheduled - edit 2")

    # Publish the email
    fill_in "Title", with: "Updated original email - published"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Published message")
    sleep 0.5 # Wait for the message editor to update
    select_disclosure "Publish" do
      click_on "Publish now"
    end
    expect(page).to have_alert(text: "Email successfully published!")

    expect(installment.reload.name).to eq("Updated original email - published")
    expect(installment.message).to eq("<p>Published message</p>")
    expect(installment.published?).to be(true)
    expect(installment.has_been_blasted?).to be(true)
    expect(installment.ready_to_publish?).to be(true)
    expect(installment.send_emails).to be(true)
    expect(installment.shown_on_profile).to be(true)

    # Preview the published post in a new window
    expect(page).to have_current_path("#{emails_path}/published")
    find(:table_row, { name: "Updated original email - published" }).click
    click_on "Edit"
    expect(page).to have_checked_field("Send email", disabled: true)
    expect(page).to have_checked_field("Post to profile", disabled: false)
    expect(page).to have_field("Publish date", with: installment.published_at.to_date.to_s)
    fill_in "Title", with: "Updated original email - published - edit 2"
    set_rich_text_editor_input(find("[aria-label='Email message']"), to_text: "Published message 2")
    sleep 0.5 # Wait for the message editor to update
    new_window = window_opened_by do
      select_disclosure "Preview" do
        click_on "Preview Post"
      end
      expect(page).to have_alert(text: "Preview link opened.")
    end
    within_window new_window do
      wait_for_ajax
      expect(page).to have_text("Updated original email - published - edit 2")
      expect(page).to have_text("Published message")
    end
    new_window.close
  end

  it "generates a new product files archive when the email name is changed" do
    follower_installment = create(:follower_installment, seller: seller, published_at: "2021-01-02 12:00")
    create(:active_follower, user: seller)

    visit "#{emails_path}/#{follower_installment.external_id}/edit"

    expect(page).to have_radio_button("Followers only", checked: true)
    fill_in "Title", with: "Updated Follower Post"
    click_on "Save"
    wait_for_ajax

    expect(follower_installment.reload.product_files_archives.alive.sole.url.split("/").last).to eq("Updated_Follower_Post.zip")
  end

  it "allows choosing which profile post sections to show an audience post in" do
    visit "#{emails_path}/#{installment.external_id}/edit"

    expect(page).to have_radio_button("Customers only", checked: true)
    expect(page).to have_unchecked_field("Post to profile")
    expect(page).to_not have_text("You currently have no sections in your profile to display this")
    expect(page).to_not have_text("The post will be shown in the selected profile sections once it is published.")

    check "Post to profile"
    expect(page).to_not have_text("You currently have no sections in your profile to display this")
    expect(page).to_not have_text("The post will be shown in the selected profile sections once it is published.")

    choose "Everyone"
    expect(page).to have_text("You currently have no sections in your profile to display this, create one here")
    expect(page).to_not have_text("The post will be shown in the selected profile sections once it is published.")

    section1 = create(:seller_profile_posts_section, seller:, header: "Posts section 1", shown_posts: [installment.id])
    section2 = create(:seller_profile_posts_section, seller:, shown_posts: [])
    refresh

    expect(page).to_not have_field("Posts section 1")
    expect(page).to_not have_field("Unnamed section")
    choose "Everyone"
    expect(page).to_not have_field("Posts section 1")
    expect(page).to_not have_field("Unnamed section")
    check "Post to profile"

    within_fieldset "Channel" do
      expect(page).to_not have_text("You currently have no sections in your profile to display this, create one here")
      expect(page).to have_checked_field("Posts section 1")
      expect(page).to have_unchecked_field("Unnamed section")
      expect(page).to have_text("The post will be shown in the selected profile sections once it is published.")
    end

    uncheck "Posts section 1"
    check "Unnamed section"
    toggle_disclosure "Publish" do
      click_on "Publish now"
    end
    wait_for_ajax
    expect(page).to have_alert(text: "Email successfully published!")

    expect(section1.reload.shown_posts).to be_empty
    expect(section2.reload.shown_posts).to eq([installment.id])

    find(:table_row, { name: "Original email" }).click
    click_on "Edit"
    expect(page).to have_unchecked_field("Posts section 1")
    expect(page).to have_checked_field("Unnamed section")
    expect(page).to_not have_text("The post will be shown in the selected profile sections once it is published.")

    uncheck "Post to profile"
    click_on "Save"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    expect(installment.reload.shown_on_profile).to be(false)
    expect(section1.reload.shown_posts).to be_empty
    expect(section2.reload.shown_posts).to be_empty
  end
end
