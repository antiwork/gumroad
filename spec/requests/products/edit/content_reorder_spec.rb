# frozen_string_literal: true

require "spec_helper"

describe "Product Edit content page reordering", type: :system, js: true do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, name: "Touch reorder test") }
  let(:titles) { ["First edition", "Second edition", "Third edition", "Fourth edition"] }

  before do
    titles.each_with_index do |title, position|
      create(:rich_content, entity: product, title:, position:,
                            description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => title }] }])
    end
    login_as seller
  end

  def open_content
    visit "#{edit_link_path(product.unique_permalink)}/content"
    expect(page).to have_button("Save changes")
  end

  def touch_drag(handle, target)
    start = handle.evaluate_script("(() => { const r = this.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()")
    finish = target.evaluate_script("(() => { const r = this.getBoundingClientRect(); return { x: r.x + 10, y: r.y + 5 }; })()")
    browser = page.driver.browser
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [start])
    20.times do |step|
      progress = (step + 1) / 20.0
      point = { x: start["x"] + (finish["x"] - start["x"]) * progress,
                y: start["y"] + (finish["y"] - start["y"]) * progress }
      browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [point])
      page.evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(arguments[0]))")
    end
    browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
  end

  it "keeps the mobile contents unified and persists a touch drag without runtime errors", :mobile_view do
    browser = page.driver.browser
    browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: true)
    browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true)
    open_content
    expect(page.evaluate_script("window.innerWidth")).to eq(375)
    expect(page.evaluate_script("matchMedia('(pointer: coarse)').matches")).to eq(true)
    summary = find("button", text: "Table of contents:")
    summary.click
    expect(page).to have_selector("[role=tab]", text: titles.last)
    tabs = all("[role=tablist] [role=tab]:has([aria-grabbed])", count: 4)
    expect(tabs.first.evaluate_script("this.getBoundingClientRect().top") - summary.evaluate_script("this.getBoundingClientRect().bottom")).to be <= 1
    handles = tabs.map { |tab| tab.find("[aria-grabbed]", visible: :all) }
    expect(handles.map { |handle| handle.style("visibility")["visibility"] }).to eq(["visible"] * 4)
    page.execute_script("window.reorderErrors = []; window.addEventListener('error', e => window.reorderErrors.push(e.message)); window.addEventListener('unhandledrejection', e => window.reorderErrors.push(String(e.reason)));")

    touch_drag(handles.last, tabs.first)

    expected_titles = [titles.last, *titles.first(3)]
    expect(page.evaluate_script("window.reorderErrors")).to eq([])
    expect(page).to have_selector("[role=tablist] [role=tab]:has([aria-grabbed]):first-of-type", text: titles.last)
    expect(all("[role=tablist] [role=tab]:has([aria-grabbed])").map(&:text)).to eq(expected_titles)
    save_change
    expect(product.reload.alive_rich_contents.order(:position).pluck(:title)).to eq(expected_titles)
    refresh
    find("button", text: "Table of contents:").click
    expect(all("[role=tablist] [role=tab]:has([aria-grabbed])", count: 4).map(&:text)).to eq(expected_titles)
  ensure
    browser&.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
    browser&.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "shows a desktop move handle only while its row is hovered" do
    open_content
    expect(page.evaluate_script("matchMedia('(pointer: coarse)').matches")).to eq(false)
    tabs = all("[role=tablist] [role=tab]:has([aria-grabbed])", count: 4)
    handles = tabs.map { |tab| tab.find("[aria-grabbed]", visible: :all) }
    expect(handles.map { |handle| handle.style("visibility")["visibility"] }).to eq(["hidden"] * 4)

    tabs.first.hover

    expect(handles.first.style("visibility")["visibility"]).to eq("visible")
    expect(handles.drop(1).map { |handle| handle.style("visibility")["visibility"] }).to eq(["hidden"] * 3)
  end
end
