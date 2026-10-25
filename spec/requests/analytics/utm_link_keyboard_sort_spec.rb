# frozen_string_literal: true

require "spec_helper"

describe "Tracking link keyboard sorting", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  before do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1440, height: 900, deviceScaleFactor: 1, mobile: false)
    create(:utm_link, seller: seller, title: "Alpha campaign", utm_source: "zulu")
    create(:utm_link, seller: seller, title: "Beta campaign", utm_source: "alpha")
    login_as seller
    visit dashboard_utm_links_path
  end

  it "reaches the sort controls with Tab and sorts with Enter and Space" do
    find("th", text: "Link", exact_text: true).find("button").send_keys(:tab)
    source = find("th", text: "Source", exact_text: true).find("button")
    expect(page.evaluate_script("document.activeElement === arguments[0]", source)).to eq(true)
    source.send_keys(:enter)
    expect(page).to have_current_path("#{dashboard_utm_links_path}?key=source&direction=asc")
    expect(find("th", text: "Source")["aria-sort"]).to eq("ascending")
    wait_for_valid("document.querySelector('tbody tr').innerText.includes('Beta campaign')")
    source.send_keys(:space)
    expect(page).to have_current_path("#{dashboard_utm_links_path}?key=source&direction=desc")
    expect(find("th", text: "Source")["aria-sort"]).to eq("descending")
    wait_for_valid("document.querySelector('tbody tr').innerText.includes('Alpha campaign')")
  end

  it "retains mouse sorting and the existing mobile card layout" do
    find("th", text: "Source", exact_text: true).click
    expect(page).to have_current_path("#{dashboard_utm_links_path}?key=source&direction=asc")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 900, deviceScaleFactor: 1, mobile: true)
    expect(page).not_to have_selector("thead", visible: true)
    # Selenium's mobile visibility check misreads the nested display:contents spans.
    expect(page.evaluate_script("document.querySelector('tbody').innerText")).to include("Beta campaign", "Alpha campaign")
    expect(page).to have_text("Source", minimum: 2)
    expect(page).not_to have_button("Source", visible: true)
  ensure
    # The emulation override outlives the session reset, so later examples would keep this phone viewport.
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "also supports keyboard sorting in the Products table" do
    create(:product, user: seller, name: "Alpha keyboard product")
    create(:product, user: seller, name: "Beta keyboard product")
    visit products_path
    header = find("th", text: "Name", exact_text: true)
    header.find("button").send_keys(:enter)
    expect(header["aria-sort"]).to eq("ascending")
    wait_for_valid("new URL(location.href).searchParams.get('products_sort_direction') === 'asc'")
    wait_for_valid("document.querySelector('tbody tr').innerText.includes('Alpha keyboard product')")
    header.find("button").send_keys(:space)
    expect(header["aria-sort"]).to eq("descending")
    wait_for_valid("new URL(location.href).searchParams.get('products_sort_direction') === 'desc'")
    wait_for_valid("document.querySelector('tbody tr').innerText.includes('Beta keyboard product')")
  end
end
