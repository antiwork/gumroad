# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Calls Edit", type: :system, js: true do
  def upload_image(filenames)
    click_on "Upload images or videos"
    page.attach_file(filenames.map { |filename| file_fixture(filename) }) do
      select_tab "Computer files"
    end
  end

  let(:seller) { create(:user, :eligible_for_service_products) }
  let(:call) { create(:call_product, user: seller) }

  include_context "with switching account to user as admin for seller"

  before { Feature.activate_user(:product_edit_react, seller) }

  it "supports attaching covers on calls without durations" do
    call = create(:call_product, user: seller, durations: [])
    visit edit_link_path(call.unique_permalink)
    upload_image(["test.png"])
    wait_for_ajax
    sleep 1

    select_disclosure "Add cover" do
      upload_image(["test-small.jpg"])
    end
    wait_for_ajax

    within_section "Cover", section_element: :section do
      expect(page).to have_selector("button[role='tab']", count: 2)
    end
  end

  it "allows editing durations" do
    call = create(:call_product, user: seller, durations: [])
    visit edit_link_path(call.unique_permalink)

    click_on "Add duration"

    expect(page).to have_selector("h3", text: "Untitled")
    click_on "Save changes"
    expect(page).to have_alert(text: "Calls must have at least one duration")

    fill_in "Duration", with: 30
    expect(page).to have_selector("h3", text: "30 minutes")
    fill_in "Description", with: "An epic call with me!"
    fill_in "Additional amount", with: 100
    fill_in "Maximum number of purchases", with: 10

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    thirty_minutes = call.alive_variants.first
    expect(thirty_minutes.name).to eq("30 minutes")
    expect(thirty_minutes.duration_in_minutes).to eq(30)
    expect(thirty_minutes.description).to eq("An epic call with me!")
    expect(thirty_minutes.price_difference_cents).to eq(10000)
    expect(thirty_minutes.max_purchase_count).to eq(10)

    refresh

    within "[role='listitem']", text: "30 minutes" do
      expect(page).to have_field("Duration", with: 30)
      expect(page).to have_field("Description", with: "An epic call with me!")
      expect(page).to have_field("Additional amount", with: "100")
      expect(page).to have_field("Maximum number of purchases", with: "10")
      click_on "Remove"
    end
    click_on "Yes, remove"

    click_on "Add duration"

    fill_in "Duration", with: 60
    expect(page).to have_selector("h3", text: "60 minutes")

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    expect(thirty_minutes.reload).to be_deleted

    sixty_minutes = call.reload.alive_variants.first
    expect(sixty_minutes.name).to eq("60 minutes")
    expect(sixty_minutes.duration_in_minutes).to eq(60)
    expect(sixty_minutes.description).to eq("")
    expect(sixty_minutes.price_difference_cents).to eq(0)
    expect(sixty_minutes.max_purchase_count).to eq(nil)
  end

  it "allows editing availabilities" do
    visit edit_link_path(call.unique_permalink)
    click_on "Add day of availability"

    within "[aria-label='Availability 1']" do
      fill_in "Date", with: "01/01/2024"
      find_field("From", with: "09:00").fill_in with: "1000AM"
      find_field("To", with: "17:00").fill_in with: "1100AM"
    end

    click_on "Save changes"
    expect(page).to have_alert(text: "Changes saved!")

    availability1 = call.call_availabilities.first
    expect(availability1.start_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-01 10:00"))
    expect(availability1.end_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-01 11:00"))

    click_on "Add day of availability"

    within "[aria-label='1/2/2024']" do
      within "[aria-label='Availability 1']" do
        expect(page).to have_field("Date", with: "2024-01-02")
        find_field("From", with: "09:00").fill_in with: "1200PM"
        find_field("To", with: "17:00").fill_in with: "1300PM"
        click_on "Add hours"
      end

      within "[aria-label='Availability 2']" do
        expect(page).to_not have_button("Add hours")
        expect(page).to_not have_field("Date")

        find_field("From", with: "13:00").fill_in with: "1400PM"
        find_field("To", with: "14:00").fill_in with: "1500PM"
      end
    end

    within "[aria-label='1/1/2024']" do
      within "[aria-label='Availability 1']" do
        click_on "Delete hours"
      end
    end

    click_on "Save changes"
    wait_for_ajax
    expect(page).to have_alert(text: "Changes saved!")

    expect { availability1.reload }.to raise_error(ActiveRecord::RecordNotFound)

    call.call_availabilities.reload
    availability2 = call.call_availabilities.first
    expect(availability2.start_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-02 12:00"))
    expect(availability2.end_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-02 13:00"))

    availability3 = call.call_availabilities.second
    expect(availability3.start_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-02 14:00"))
    expect(availability3.end_time).to eq(ActiveSupport::TimeZone[seller.timezone].parse("2024-01-02 15:00"))
  end

  it "allows editing call limitations" do
    visit edit_link_path(call.unique_permalink)

    expect(page).to have_field("Notice period", with: 3)
    find_field("Units", with: "hours", visible: false).find(:option, "minutes").select_option
    fill_in "Notice period", with: 1440
    find_field("Daily limit", with: "").fill_in with: 5

    # Outside click to trigger notice period field update
    click_on "Save changes"
    expect(page).to have_select("Units", selected: "days", visible: false)
    expect(page).to have_field("Notice period", with: 1)
    expect(page).to have_alert(text: "Changes saved!")

    call_limitation_info = call.call_limitation_info.reload
    expect(call_limitation_info.minimum_notice_in_minutes).to eq(1440)
    expect(call_limitation_info.maximum_calls_per_day).to eq(5)
  end
end
