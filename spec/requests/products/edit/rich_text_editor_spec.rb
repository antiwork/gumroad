# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Rich Text Editor", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller, :eligible_for_service_products) }

  before do
    @product = create(:product_with_pdf_file, user: seller, size: 1024)
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE,
                                                              one_item_rate_cents: 0,
                                                              multiple_items_rate_cents: 0)
  end

  include_context "with switching account to user as admin for seller"

  it "instantly preview changes to product description" do
    visit("/products/#{@product.unique_permalink}/edit")

    in_preview do
      expect(page).to have_text @product.description
    end

    set_rich_text_editor_input find("[aria-label='Description']"), to_text: "New description line"

    in_preview do
      expect(page).to have_text "New description line"
    end
  end

  it "trims leading/trailing spaces for description" do
    visit("/products/#{@product.unique_permalink}/edit")
    set_rich_text_editor_input find("[aria-label='Description']"), to_text: "   New description line.   "

    in_preview do
      expect(page).to_not have_text "   New description line.   "
      expect(page).to have_text "New description line."
    end
  end

  it "removes data URLs from description on content update or save" do
    description = "<p>Text1</p><p>Text2<figure><img class='img-data-uri' src='data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAASABIAAD'/></figure></p>"
    visit("/products/#{@product.unique_permalink}/edit")
    page.execute_script("$(\"[aria-label='Description']\").html(\"#{description}\");")
    sleep 1
    in_preview do
      expect(page).to have_content "Text1"
      expect(page).to have_content "Text2"
      expect(page).to_not have_selector("figure img")
    end
    save_change
    expect(@product.reload.description).to_not include("data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAASABIAAD")
  end

  it "shows loading spinner over an image while it is being uploaded" do
    visit edit_link_path(@product)
    rich_text_editor_input = find("[aria-label='Description']")
    attach_file file_fixture("smilie.png") do
      click_on "Insert image"
    end
    expect(rich_text_editor_input).to have_selector("img[src^='blob:']")
    expect(rich_text_editor_input).to have_selector("figure [role='progressbar']")
    expect(rich_text_editor_input).to have_selector("img[src^='https://']")
    expect(rich_text_editor_input).to_not have_selector("figure [role='progressbar']")
  end

  it "shows a warning when switching to other tabs while images or files are still uploading" do
    Feature.activate_user(:audio_previews, @product.user)

    visit edit_link_path(@product)

    rich_text_editor_input = find("[aria-label='Description']")

    # When images are uploading
    attach_file file_fixture("smilie.png") do
      click_on "Insert image"
    end
    expect(rich_text_editor_input).to have_selector("img[src^='blob:']")
    select_tab "Content"
    expect(page).to have_alert(text: "Some images are still uploading, please wait...")
    expect(page).to have_current_path(edit_link_path(@product))
    expect(page).to have_tab_button("Product", open: true)
    expect(rich_text_editor_input).to have_selector("img[src^='https://']")
    select_tab "Content"
    expect(page).to_not have_alert(text: "Some images are still uploading, please wait...")
    expect(page).to have_current_path(edit_link_path(@product) + "/content")
    expect(page).to have_tab_button("Content", open: true)

    # When files are uploading
    select_tab "Product"
    attach_file file_fixture("test.mp3") do
      click_on "Insert audio"
    end
    select_tab "Content"
    expect(page).to have_alert(text: "Some files are still uploading, please wait...")
    wait_for_file_embed_to_finish_uploading(name: "test")
    select_tab "Content"
    expect(page).to_not have_alert(text: "Some files are still uploading, please wait...")
    expect(page).to have_current_path(edit_link_path(@product) + "/content")
    expect(page).to have_tab_button("Content", open: true)
  end

  it "ignores overlay links" do
    url = "#{@product.long_url}?wanted=true"
    visit edit_link_path(@product)
    select_disclosure "Insert" do
      click_on "Button"
    end
    within_modal do
      fill_in "Enter text", with: "Buy button"
      fill_in "Enter URL", with: url
      send_keys :enter
    end

    click_on "Insert link"
    within_modal do
      fill_in "Enter URL", with: url
      fill_in "Enter text", with: "Buy link"
      click_on "Add link"
    end

    in_preview do
      expect(page).to have_link "Buy button"
      expect(page).to have_link "Buy link"
    end
  end

  it "supports adding external links" do
    visit("/products/#{@product.unique_permalink}/edit")

    rich_text_editor_input = find("[aria-label='Description']")

    click_on "Insert link"
    within_modal do
      fill_in "Enter URL", with: "https://example.com/link1"
      click_on "Add link"
    end

    click_on "Insert link"
    within_modal do
      fill_in "Enter URL", with: "https://example.com/link2"
      send_keys :enter
    end

    expect(rich_text_editor_input).to have_link("https://example.com/link1", href: "https://example.com/link1")
    expect(rich_text_editor_input).to have_link("https://example.com/link2", href: "https://example.com/link2")
    sleep 1
    save_change
    expect(@product.reload.description).to have_link("https://example.com/link1", href: "https://example.com/link1")
    expect(@product.description).to have_link("https://example.com/link2", href: "https://example.com/link2")
  end

  it "supports adding an external link with label" do
    visit("/products/#{@product.unique_permalink}/edit")

    external_link = "https://gumroad.com/"
    rich_text_editor_input = find("[aria-label='Description']")

    click_on "Insert link"
    within_modal do
      fill_in "Enter text", with: "Gumroad"
      fill_in "Enter URL", with: external_link
      click_on "Add link"
    end

    expect(rich_text_editor_input).to have_link("Gumroad", href: external_link)
    sleep 1
    save_change
    expect(@product.reload.description).to include("<a href=\"#{external_link}\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">Gumroad</a>")

    rich_text_editor_select_all(rich_text_editor_input)
    click_on "Bold"
    click_on "Italic"

    new_link = "https://notgumroad.com/"
    within rich_text_editor_input do
      click_on "Gumroad"
      within_disclosure "Gumroad" do
        fill_in "Enter text", with: "Not Gumroad"
        click_on "Save"
      end

      click_on "Not Gumroad"
      within_disclosure "Not Gumroad" do
        fill_in "Enter URL", with: new_link
        click_on "Save"
      end

      expect(page).to have_link("Not Gumroad", href: new_link)
      expect(page).to_not have_link("Not Gumroad", href: external_link)
    end

    expect(page).to have_selector("strong", text: "Not Gumroad")
    expect(page).to have_selector("em", text: "Not Gumroad")

    save_change
    expect(@product.reload.description).to include new_link
    expect(@product.description).to_not include external_link

    visit @product.long_url
    expect(page).to have_link("Not Gumroad", href: new_link)
    expect(page).to_not have_disclosure("Not Gumroad")
    expect(page).to have_selector("strong", text: "Not Gumroad")
    expect(page).to have_selector("em", text: "Not Gumroad")

    visit edit_link_path(@product)
    within find("[aria-label='Description']") do
      click_on "Not Gumroad"
      within_disclosure "Not Gumroad" do
        click_on "Remove link"
      end
      expect(page).to_not have_link("Not Gumroad", href: new_link)
    end
  end

  it "converts legacy links to the links with edit support on clicking a legacy link" do
    rich_content = create(
      :product_rich_content,
      entity: @product,
      description: [
        {
          "type" => "paragraph",
          "content" => [
            { "type" => "text", "text" => "Visit " },
            { "type" => "text", "text" => "Google", "marks" => [{ "type" => "link", "attrs" => { "href" => "https://google.com" } }] },
            { "type" => "text", "text" => " to explore the web" }
          ]
        },
        {
          "type" => "paragraph",
          "content" => [
            { "type" => "text", "text" => "And also visit " },
            { "type" => "text", "text" => "Gumroad", "marks" => [{ "type" => "link", "attrs" => { "href" => "https://gumroad.com" } }] },
            { "type" => "text", "text" => " to buy products from indie creators" }
          ]
        }
      ]
    )
    Feature.activate(:product_edit_react)
    visit("#{edit_link_path(@product)}/content")
    within find("[aria-label='Content editor']") do
      expect(page).to have_link("Gumroad", href: "https://gumroad.com")
      expect(page).to have_link("Google", href: "https://google.com")
      expect(page).to have_text("Visit Google to explore the web", normalize_ws: true)
      expect(page).to have_text("And also visit Gumroad to buy products from indie creators", normalize_ws: true)
    end
    click_on "Google"
    sleep 0.5 # Wait for the editor to update the content
    save_change
    wait_for_ajax
    expect(rich_content.reload.description).to eq([
                                                    {
                                                      "type" => "paragraph",
                                                      "content" => [
                                                        { "type" => "text", "text" => "Visit " },
                                                        { "type" => "tiptap-link", "attrs" => { "href" => "https://google.com" }, "content" => [{ "text" => "Google", "type" => "text" }] },
                                                        { "type" => "text", "text" => " to explore the web" }
                                                      ]
                                                    },
                                                    {
                                                      "type" => "paragraph",
                                                      "content" => [
                                                        { "type" => "text", "text" => "And also visit " },
                                                        { "type" => "tiptap-link", "attrs" => { "href" => "https://gumroad.com" }, "content" => [{ "text" => "Gumroad", "type" => "text" }] },
                                                        { "type" => "text", "text" => " to buy products from indie creators" }
                                                      ]
                                                    }
                                                  ])
    refresh
    within find("[aria-label='Content editor']") do
      expect(page).to have_link("Gumroad", href: "https://gumroad.com")
      expect(page).to have_link("Google", href: "https://google.com")
      expect(page).to have_text("Visit Google to explore the web", normalize_ws: true)
      expect(page).to have_text("And also visit Gumroad to buy products from indie creators", normalize_ws: true)
    end
    click_on "Gumroad"
    within_disclosure "Gumroad" do
      expect(page).to have_field("Enter text", with: "Gumroad")
      expect(page).to have_field("Enter URL", with: "https://gumroad.com")
    end
  end

  it "does not open a new tab when an external link is clicked" do
    @product.update!(description: '<a href="https://gumroad.com" target="_blank">Gumroad</a>')

    visit("/products/#{@product.unique_permalink}/edit")

    within("[aria-label='Description']") do
      # Need to double click in order to ensure we have the editor input focused first
      find("a").double_click
    end
    expect(page.driver.browser.window_handles.size).to eq(1)
  end

  it "validates links, fixing links with invalid protocols and adding https where necessary" do
    visit("/products/#{@product.unique_permalink}/edit")

    rich_text_editor_input = find("[aria-label='Description']")

    click_on "Insert link"
    within_modal do
      fill_in "Enter text", with: "An invalid link 1"
      fill_in "Enter URL", with: ""
      click_on "Add link"
    end
    expect(page).to have_alert(text: "Please enter a valid URL.")

    expect(page).to_not have_alert(text: "Please enter a valid URL.")
    fill_in "Enter text", with: "An invalid link 2"
    fill_in "Enter URL", with: "/broken:link"
    click_on "Add link"
    expect(page).to have_alert(text: "Please enter a valid URL.")

    expect(page).to_not have_alert(text: "Please enter a valid URL.")
    fill_in "Enter text", with: "Valid link 1"
    fill_in "Enter URL", with: "    gumroad.com      "
    click_on "Add link"

    expect(page).to_not have_alert(text: "Please enter a valid URL.")
    rich_text_editor_input.native.send_keys(:control, "e") # Move cursor to end of line
    rich_text_editor_input.native.send_keys(:enter)
    click_on "Insert link"
    within_modal do
      fill_in "Enter text", with: "Valid link 2"
      fill_in "Enter URL", with: "  https//example.com/1?q=hello"
      click_on "Add link"
    end

    expect(page).to_not have_alert(text: "Please enter a valid URL.")
    rich_text_editor_input.native.send_keys(:control, "e") # Move cursor to end of line
    rich_text_editor_input.native.send_keys(:enter)
    click_on "Insert link"
    within_modal do
      fill_in "Enter text", with: "Valid link 3"
      fill_in "Enter URL", with: "http:example.com/2?q=hello"
      click_on "Add link"
    end
    expect(page).to_not have_alert(text: "Please enter a valid URL.")

    expect(rich_text_editor_input).to_not have_text("An invalid link 1")
    expect(rich_text_editor_input).to_not have_text("An invalid link 2")
    expect(rich_text_editor_input).to have_link("Valid link 1", href: "https://gumroad.com/")
    expect(rich_text_editor_input).to have_link("Valid link 2", href: "https://example.com/1?q=hello")
    expect(rich_text_editor_input).to have_link("Valid link 3", href: "https://example.com/2?q=hello")
    sleep 1
    save_change
    expect(@product.reload.description).to_not include("An invalid link 1")
    expect(@product.reload.description).to_not include("An invalid link 2")
    expect(@product.reload.description).to include("https://gumroad.com/")
    expect(@product.reload.description).to include("https://example.com/1?q=hello")
    expect(@product.reload.description).to include("https://example.com/2?q=hello")
  end

  it "supports twitter embeds" do
    visit("/products/#{@product.unique_permalink}/edit")
    rich_text_editor_input = find("[aria-label='Description']")
    select_disclosure "Insert" do
      click_on "Twitter post"
    end
    within_modal do
      fill_in "URL", with: "https://twitter.com/gumroad/status/1380521414818557955"
      click_on "Insert"
    end
    wait_for_ajax
    sleep 1
    expect(rich_text_editor_input.find("iframe")[:src]).to include "1380521414818557955"
    save_change
    expect(@product.reload.description).to include "iframe.ly/api/iframe?app=1&amp;url=#{CGI.escape("https://twitter.com/gumroad/status/1380521414818557955")}"
  end

  it "supports button embeds" do
    visit("/products/#{@product.unique_permalink}/edit")
    external_link = "https://gumroad.com/"
    rich_text_editor_input = find("[aria-label='Description']")
    select_disclosure "Insert" do
      click_on "Button"
    end
    within_modal do
      fill_in "Enter text", with: "Gumroad"
      fill_in "Enter URL", with: external_link
      click_on "Add button"
    end
    wait_for_ajax
    expect(rich_text_editor_input).to have_link("Gumroad", href: external_link)
    save_change
    expect(@product.reload.description).to include external_link

    rich_text_editor_select_all(rich_text_editor_input)
    click_on "Bold"
    click_on "Italic"
    rich_text_editor_input.click

    new_link = "https://notgumroad.com/"
    within rich_text_editor_input do
      select_disclosure "Gumroad" do
        fill_in "Enter URL", with: new_link
        click_on "Save"
      end

      select_disclosure "Gumroad" do
        fill_in "Enter text", with: "Not Gumroad"
        click_on "Save"
      end
      expect(page).to have_link("Not Gumroad", href: new_link)
      expect(page).not_to have_link("Gumroad", href: external_link)
    end

    expect(page).to have_selector("strong", text: "Not Gumroad")
    expect(page).to have_selector("em", text: "Not Gumroad")

    save_change
    expect(@product.reload.description).to include new_link
    expect(@product.description).not_to include external_link

    visit @product.long_url
    expect(page).to have_link("Not Gumroad", href: new_link)
    expect(page).to_not have_disclosure("Not Gumroad")
    expect(page).to have_selector("strong", text: "Not Gumroad")
    expect(page).to have_selector("em", text: "Not Gumroad")
  end

  it "stores editor history actions" do
    visit("/products/#{@product.unique_permalink}/edit")

    expect(page).to have_selector("[aria-label='Undo last change']")
    expect(page).to have_selector("[aria-label='Redo last undone change']")

    rich_text_editor_input = find("[aria-label='Description']")
    rich_text_editor_input.native.clear

    expect(rich_text_editor_input).to have_content("")
    expect(page).to have_selector("[aria-label='Undo last change']")
    expect(page).to have_selector("[aria-label='Redo last undone change']")

    click_on "Undo last change"
    expect(rich_text_editor_input).to have_content(@product.plaintext_description)
    expect(page).to have_selector("[aria-label='Undo last change']")
    expect(page).to have_selector("[aria-label='Redo last undone change']")

    click_on "Redo last undone change"
    expect(rich_text_editor_input).to have_content("")
    expect(page).to have_selector("[aria-label='Undo last change']")
    expect(page).to have_selector("[aria-label='Redo last undone change']")
  end

  it "fixes blocks containing blocks so TipTap doesn't discard them" do
    @product.update(description: "<h4><p>test</p><p><figure><img src=\"http://fake/\"><p class=\"figcaption\">Caption</p></figure></p><p>test 2</p></h4>")
    visit("/products/#{@product.unique_permalink}/edit")
    rich_text_editor_input = find("[aria-label='Description']")
    expect(rich_text_editor_input).to have_selector("p", text: "test")
    expect(rich_text_editor_input).to have_selector("img[src=\"http://fake/\"]")
    expect(rich_text_editor_input).to have_selector("p.figcaption", text: "Caption")
    expect(rich_text_editor_input).to have_selector("p", text: "test 2")
    rich_text_editor_input.send_keys("more text")
    sleep 1
    save_change
    expect(@product.reload.description).to eq "<h4><br></h4><p>test</p><p><br></p><figure><img src=\"http://fake/\"><p class=\"figcaption\">Caption</p></figure><p><br></p><p>test 2more text</p>"
  end

  describe "Dynamic product content editor" do
    it "does not show Insert video popover and external link tab within Insert link popover" do
      visit edit_link_path(@product) + "/content"

      expect(page).not_to have_button("Insert video")

      select_disclosure "Upload files" do
        expect(page).not_to have_tab_button("Link to external page")
      end
    end

    it "supports embedding tweets" do
      tweet_url = "https://x.com/gumroad/status/1743053631640006693"
      product = create(:product, user: seller)
      visit edit_link_path(product) + "/content"
      rich_text_editor_input = find("[aria-label='Content editor']")
      select_disclosure "Insert" do
        click_on "Twitter post"
      end
      expect(page).to have_content("Insert Twitter post")
      fill_in "URL", with: tweet_url
      click_on "Insert"
      expect(page).to_not have_text("URL")
      sleep 0.5 # wait for the editor to update the content
      escaped_url = CGI.escape(tweet_url)
      iframely_base = "https://cdn.iframe.ly/api/iframe"

      expect(rich_text_editor_input.find("iframe")[:src]).to include(iframely_base)
      expect(rich_text_editor_input.find("iframe")[:src]).to include("url=#{escaped_url}")

      save_change

      description = product.reload.rich_contents.first.description.first
      expect(description["type"]).to eq("raw")
      expect(description["attrs"]["html"]).to include(iframely_base)
      expect(description["attrs"]["html"]).to include("url=#{escaped_url}")
    end
  end

  describe "public files in the product description" do
    before do
      Feature.activate_user(:audio_previews, @product.user)
    end

    it "uploads and embeds public audio files" do
      visit edit_link_path(@product)

      # Validate that non-audio files are not allowed
      attach_file file_fixture("test.pdf") do
        click_on "Insert audio"
      end
      expect(page).to have_alert(text: "Only audio files are allowed")
      expect(page).to_not have_embed(name: "test")

      # Validate that large files are not allowed
      attach_file file_fixture("big-music-file.mp3") do
        click_on "Insert audio"
      end
      expect(page).to have_alert(text: "File is too large (max allowed size is 5.0 MB)")
      expect(page).to_not have_embed(name: "big-music-file")

      # Upload a valid audio file
      attach_file file_fixture("test.mp3") do
        click_on "Insert audio"
      end
      expect(page).to have_button("Save changes", disabled: true)
      wait_for_file_embed_to_finish_uploading(name: "test")
      expect(page).to have_button("Save changes", disabled: false)
      within find_embed(name: "test") do
        expect(page).to have_text("MP3")
        expect(page).to have_button("Play")
        click_on "Edit"
        expect(page).to have_field("Name", with: "test")

        # Allow renaming the file
        fill_in "Enter file name", with: "My awesome track"
        expect(page).to have_text("My awesome track")
        click_on "Close drawer"

        # Allow playing the file
        click_on "Play"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:00")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
        expect(page).to have_selector("[aria-label='Pause']")
        click_on "Pause"
        expect(page).to have_selector("[aria-label='Rewind15']")
        click_on "Close"
        expect(page).to_not have_selector("[aria-label='Rewind15']")
      end

      # Validate that only a certain number of files are allowed
      attach_file file_fixture("test.mp3") do
        click_on "Insert audio"
      end
      wait_for_file_embed_to_finish_uploading(name: "test")
      rename_file_embed(from: "test", to: "My MP3 track")
      attach_file file_fixture("test.wav") do
        click_on "Insert audio"
      end
      expect(page).not_to have_selector("[role='progressbar']")
      attach_file file_fixture("magic.mp3") do
        click_on "Insert audio"
      end
      expect(page).not_to have_selector("[role='progressbar']")
      attach_file file_fixture("sample.flac") do
        click_on "Insert audio"
      end
      expect(page).not_to have_selector("[role='progressbar']")
      attach_file file_fixture("test-with-tags.wav") do
        click_on "Insert audio"
      end
      expect(page).to have_alert(text: "You can only upload up to 5 audio previews in the description")

      # Ensure that embedded files are visible in the preview pane
      within_section("Preview", section_element: :aside) do
        expect(page).to have_embed(name: "My awesome track")
        expect(page).to have_embed(name: "test")
        expect(page).to have_embed(name: "magic")
        expect(page).to have_embed(name: "sample")
        expect(page).to have_embed(name: "My MP3 track")
      end

      save_change

      # Validate that the files are embedded correctly and saved in the database
      @product.reload
      expect(@product.description.scan(/<public-file-embed/).size).to eq(5)
      expect(@product.alive_public_files.pluck(:display_name, :file_type, :file_group)).to match_array([
                                                                                                         ["My awesome track", "mp3", "audio"],
                                                                                                         ["My MP3 track", "mp3", "audio"],
                                                                                                         ["test", "wav", "audio"],
                                                                                                         ["magic", "mp3", "audio"],
                                                                                                         ["sample", "flac", "audio"],
                                                                                                       ])
      @product.alive_public_files.pluck(:public_id).each do |public_id|
        expect(@product.description).to include("<public-file-embed id=\"#{public_id}\"></public-file-embed>")
      end

      # Validate that the files persist after a page reload
      refresh
      within find("[aria-label='Description']") do
        expect(page).to have_embed(name: "My awesome track")
        expect(page).to have_embed(name: "My MP3 track")
        expect(page).to have_embed(name: "test")
        expect(page).to have_embed(name: "magic")
        expect(page).to have_embed(name: "sample")
      end

      # Ensure that files render correctly in the description on the product page
      visit @product.long_url
      expect(page).to have_embed(name: "My awesome track")
      expect(page).to have_embed(name: "My MP3 track")
      expect(page).to have_embed(name: "test")
      expect(page).to have_embed(name: "magic")
      expect(page).to have_embed(name: "sample")
      within find_embed(name: "test") do
        click_on "Play"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:00")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
        expect(page).to have_selector("[aria-label='Pause']")
        click_on "Pause"
        expect(page).to have_selector("[aria-label='Rewind15']")
        click_on "Close"
        expect(page).to_not have_selector("[aria-label='Rewind15']")
      end
    end
  end

  describe "More like this block" do
    let(:product) { create(:product, user: seller) }
    before { visit edit_link_path(product) + "/content" }

    it "allows inserting the More like this block with recommended products" do
      select_disclosure "Insert" do
        click_on "More like this"
      end

      expect(page).to have_selector("h2", text: "Customers who bought this product also bought")

      within ".node-moreLikeThis" do
        wait_for_ajax
        expect(page).to have_selector(".product-card")

        find("[aria-label='Actions']").click
        within("[role='menu']") do
          click_on "Settings"
        end
        expect(page).to have_checked_field("Only my products")
      end
    end

    it "allows updating the More like this block with directly affiliated products" do
      select_disclosure "Insert" do
        click_on "More like this"
      end

      within ".node-moreLikeThis" do
        find("[aria-label='Actions']").click
        within("[role='menu']") do
          click_on "Settings"
        end
        find("label", text: "My products and affiliated").click
        expect(page).not_to have_selector("[role='menu']")
      end
    end

    it "shows a placeholder when no product recommendations are received" do
      allow(RecommendedProducts::CheckoutService).to receive(:fetch_for_cart).and_return([])

      select_disclosure "Insert" do
        click_on "More like this"
      end

      within ".node-moreLikeThis" do
        wait_for_ajax
        expect(page).to have_content("No products found")
      end
    end
  end

  describe "post-purchase custom fields" do
    let!(:long_answer) { create(:custom_field, seller: @product.user, products: [@product], field_type: CustomField::TYPE_LONG_TEXT, is_post_purchase: true, name: "Long answer") }
    let!(:short_answer) { create(:custom_field, seller: @product.user, products: [@product], field_type: CustomField::TYPE_TEXT, is_post_purchase: true, name: "Short answer") }
    let!(:file_upload) { create(:custom_field, seller: @product.user, products: [@product], field_type: CustomField::TYPE_FILE, is_post_purchase: true) }
    let!(:rich_content) do
      create(
        :product_rich_content,
        entity: @product,
        description: [
          {
            "type" => RichContent::LONG_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => long_answer.external_id,
              "label" => "Long answer"
            }
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => short_answer.external_id,
              "label" => "Short answer"
            },
          },
          {
            "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            "attrs" => {
              "id" => file_upload.external_id
            }
          },
        ]
      )
    end

    before { Feature.activate(:product_edit_react) }

    it "allows creating and modifying post-purchase custom fields" do
      visit "#{edit_link_path(@product)}/content"

      expect(page).to have_field("Title", with: "Long answer")
      expect(page).to have_field("Long answer", with: "", type: "textarea")
      expect(page).to have_field("Title", with: "Short answer")
      expect(page).to have_field("Short answer", with: "")
      expect(page).to have_button("Upload files")

      set_rich_text_editor_input find("[aria-label='Content editor']"), to_text: ""
      save_change

      @product.reload
      expect(@product.custom_fields).to eq([])
      expect(@product.rich_contents.alive.flat_map(&:custom_field_nodes)).to eq([])

      select_disclosure "Insert" do
        click_on "Input"
        within("[role='menu']") do
          click_on "Short answer"
        end
      end
      click_on "Save changes"
      expect(page).to have_alert(text: "You must add titles to all of your inputs")
      fill_in "Title", with: "New short answer"

      select_disclosure "Insert" do
        click_on "Input"
        within("[role='menu']") do
          click_on "Long answer"
        end
      end
      find_field("Title", with: "").fill_in with: "New long answer"

      select_disclosure "Insert" do
        click_on "Input"
        within("[role='menu']") do
          click_on "Upload file"
        end
      end

      save_change

      @product.reload
      new_short_answer = @product.custom_fields.last
      expect(new_short_answer.name).to eq("New short answer")
      expect(new_short_answer.field_type).to eq(CustomField::TYPE_TEXT)
      expect(new_short_answer.is_post_purchase).to eq(true)
      expect(new_short_answer.products).to eq([@product])
      expect(new_short_answer.seller).to eq(@product.user)
      new_long_answer = @product.custom_fields.second_to_last
      expect(new_long_answer.name).to eq("New long answer")
      expect(new_long_answer.field_type).to eq(CustomField::TYPE_LONG_TEXT)
      expect(new_long_answer.is_post_purchase).to eq(true)
      expect(new_long_answer.products).to eq([@product])
      expect(new_long_answer.seller).to eq(@product.user)
      new_file_upload = @product.custom_fields.third_to_last
      expect(new_file_upload.name).to eq(CustomField::FILE_FIELD_NAME)
      expect(new_file_upload.field_type).to eq(CustomField::TYPE_FILE)
      expect(new_file_upload.is_post_purchase).to eq(true)
      expect(new_file_upload.products).to eq([@product])
      expect(new_file_upload.seller).to eq(@product.user)
      expect(@product.rich_contents.alive.flat_map(&:description)).to eq(
        [
          {
            "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            "attrs" => {
              "id" => new_file_upload.external_id
            }
          },
          {
            "type" => RichContent::LONG_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => new_long_answer.external_id,
              "label" => "New long answer"
            }
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => new_short_answer.external_id,
              "label" => "New short answer"
            },
          },
          { "type" => "paragraph" },
        ]
      )

      # So that we get the content with the new custom field IDs filled in
      refresh

      find_field("Title", with: "New short answer").fill_in with: "Newer short answer"
      find_field("Title", with: "New long answer").fill_in with: "Newer long answer"
      # Trigger an update
      rich_text_editor_select_all find("[aria-label='Content editor']")
      save_change


      expect(@product.reload.rich_contents.alive.flat_map(&:description)).to eq(
        [
          {
            "type" => RichContent::FILE_UPLOAD_NODE_TYPE,
            "attrs" => {
              "id" => new_file_upload.external_id
            }
          },
          {
            "type" => RichContent::LONG_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => new_long_answer.external_id,
              "label" => "Newer long answer"
            }
          },
          {
            "type" => RichContent::SHORT_ANSWER_NODE_TYPE,
            "attrs" => {
              "id" => new_short_answer.external_id,
              "label" => "Newer short answer"
            },
          },
          { "type" => "paragraph" },
        ]
      )
      expect(new_short_answer.reload.name).to eq("Newer short answer")
      expect(new_long_answer.reload.name).to eq("Newer long answer")
    end
  end

  describe "moving nodes" do
    let(:file1) { create(:product_file, display_name: "First file", link: @product) }
    let(:file2) { create(:product_file, display_name: "Second file", link: @product) }
    let(:file3) { create(:product_file, display_name: "Third file", link: @product) }
    let(:file1_uid) { SecureRandom.uuid }
    let(:file2_uid) { SecureRandom.uuid }
    let(:file3_uid) { SecureRandom.uuid }
    let(:file_group_uid) { SecureRandom.uuid }
    let!(:rich_content) do
      create(
        :product_rich_content,
        entity: @product,
        description: [
          {
            "type" => RichContent::FILE_EMBED_NODE_TYPE,
            "attrs" => {
              "id" => file1.external_id,
              "uid" => file1_uid
            }
          },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "Folder 1",
              "uid" => file_group_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid } },
            ]
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          { "type" => RichContent::POSTS_NODE_TYPE },
        ]
      )
    end

    it "supports moving nodes with the arrow keys" do
      visit edit_link_path(@product) + "/content"

      rich_text_editor_input = find("[aria-label='Content editor']")

      toggle_file_group("Folder 1")
      find_embed(name: "Second file").click
      rich_text_editor_input.native.send_keys([ctrl_key, :arrow_down])

      find_embed(name: "First file").click
      rich_text_editor_input.native.send_keys([ctrl_key, :arrow_down])

      find_embed(name: "Posts (emails) sent to customers of this product will appear here").click
      rich_text_editor_input.native.send_keys([ctrl_key, :arrow_up], [ctrl_key, :arrow_up])

      save_change

      expect(@product.reload.rich_contents.first.description).to eq(
        [
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "Folder 1",
              "uid" => file_group_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid, "collapsed" => false } },
            ]
          },
          { "type" => RichContent::POSTS_NODE_TYPE },
          {
            "type" => RichContent::FILE_EMBED_NODE_TYPE,
            "attrs" => {
              "id" => file1.external_id,
              "uid" => file1_uid,
              "collapsed" => false
            }
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
        ]
      )
    end

    it "supports moving and deleting nodes with the popover" do
      visit edit_link_path(@product) + "/content"

      within find_file_group("Folder 1").hover do
        select_disclosure "Actions" do
          click_on "Move down"
          click_on "Move down"
        end
      end

      toggle_file_group("Folder 1")
      within find_embed(name: "Second file").hover do
        select_disclosure "Actions" do
          click_on "Delete"
        end
      end

      within find_embed(name: "Posts (emails) sent to customers of this product will appear here").hover do
        select_disclosure "Actions" do
          click_on "Move up"
          click_on "Move up"
        end
      end

      save_change

      expect(@product.reload.rich_contents.first.description).to eq(
        [
          { "type" => RichContent::POSTS_NODE_TYPE },
          {
            "type" => RichContent::FILE_EMBED_NODE_TYPE,
            "attrs" => {
              "id" => file1.external_id,
              "uid" => file1_uid,
              "collapsed" => false
            }
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "Folder 1",
              "uid" => file_group_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
            ]
          },
        ]
      )
    end

    describe "moving file embeds to folders" do
      it "does not show 'Move to folder' action for embeds other than file embeds" do
        visit edit_link_path(@product) + "/content"

        within find_embed(name: "First file").hover do
          select_disclosure "Actions" do
            expect(page).to have_menuitem("Move to folder...")
          end
        end

        within find_file_group("Folder 1").hover do
          select_disclosure "Actions" do
            expect(page).to_not have_menuitem("Move to folder...")
          end
        end

        within find_embed(name: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7").hover do
          select_disclosure "Actions" do
            expect(page).to_not have_menuitem("Move to folder...")
          end
        end

        within find_embed(name: "Posts (emails) sent to customers of this product will appear here").hover do
          select_disclosure "Actions" do
            expect(page).to_not have_menuitem("Move to folder...")
          end
        end
      end
    end

    it "supports moving non-nested file embeds to existing folders" do
      visit edit_link_path(@product) + "/content"

      within find_embed(name: "First file").hover do
        select_disclosure "Actions" do
          click_on "Move to folder..."
          expect(page).to_not have_text("Move to folder...")
          expect(page).to have_menuitem("New folder")
          expect(page).to have_menuitem("Folder 1")
          click_on "Back"
          click_on "Move to folder..."
          click_on "Folder 1"
        end
      end

      expect(page).to have_alert(text: 'Moved "First file" to "Folder 1".')

      toggle_file_group "Folder 1"
      within_file_group "Folder 1" do
        expect(page).to have_embed(name: "First file")
      end

      save_change

      expect(@product.reload.rich_contents.first.description).to eq(
        [
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => { "name" => "Folder 1", "uid" => file_group_uid },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid, "collapsed" => false } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file1.external_id, "uid" => file1_uid, "collapsed" => false } },
            ]
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          { "type" => RichContent::POSTS_NODE_TYPE },
        ]
      )
    end

    it "supports moving file embeds from one folder to another existing folder" do
      file_group_2_uid = SecureRandom.uuid
      rich_content.update!(description: [
                             {
                               "type" => RichContent::FILE_EMBED_NODE_TYPE,
                               "attrs" => {
                                 "id" => file1.external_id,
                                 "uid" => file1_uid
                               }
                             },
                             {
                               "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
                               "attrs" => {
                                 "name" => "Folder 1",
                                 "uid" => file_group_uid
                               },
                               "content" => [
                                 { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid } },
                               ]
                             },
                             { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
                             { "type" => RichContent::POSTS_NODE_TYPE },
                             {
                               "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
                               "attrs" => { "name" => "Folder 2", "uid" => file_group_2_uid },
                               "content" => [
                                 { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid } },
                               ]
                             }
                           ])
      visit edit_link_path(@product) + "/content"

      toggle_file_group "Folder 1"
      within_file_group "Folder 1" do
        within find_embed(name: "Second file").hover do
          select_disclosure "Actions" do
            click_on "Move to folder..."
            expect(page).to_not have_menuitem("Folder 1")
            click_on "Folder 2"
          end
        end
      end

      expect(page).to have_alert(text: 'Moved "Second file" to "Folder 2".')

      toggle_file_group "Folder 2"
      within_file_group("Folder 2") do
        expect(page).to have_embed(name: "Third file")
        expect(page).to have_embed(name: "Second file")
      end

      expect(page).to_not have_file_group("Folder 1")

      save_change

      expect(@product.reload.rich_contents.first.description).to eq(
        [
          {
            "type" => RichContent::FILE_EMBED_NODE_TYPE,
            "attrs" => {
              "id" => file1.external_id,
              "uid" => file1_uid,
              "collapsed" => false,
            }
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          { "type" => RichContent::POSTS_NODE_TYPE },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => { "name" => "Folder 2", "uid" => file_group_2_uid },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid, "collapsed" => false } },
            ]
          },
        ]
      )
    end

    it "supports moving non-nested file embeds to a new folder" do
      visit edit_link_path(@product) + "/content"

      within find_embed(name: "First file").hover do
        select_disclosure "Actions" do
          click_on "Move to folder..."
          click_on "New folder"
        end
      end

      fill_in "Folder name", with: "My folder"
      send_keys(:enter)
      within_file_group("My folder") do
        expect(page).to have_embed(name: "First file")
      end

      sleep 0.5 # Wait for the editor to update
      save_change

      new_folder_uid = @product.reload.rich_contents.first.description.first["attrs"]["uid"]
      expect(@product.reload.rich_contents.first.description).to eq(
        [
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => { "name" => "My folder", "uid" => new_folder_uid },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file1.external_id, "uid" => file1_uid, "collapsed" => false } },
            ]
          },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "Folder 1",
              "uid" => file_group_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid, "collapsed" => false } },
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
            ]
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          { "type" => RichContent::POSTS_NODE_TYPE },
        ]
      )
    end

    it "supports moving file embeds from one folder to a new folder" do
      visit edit_link_path(@product) + "/content"

      toggle_file_group "Folder 1"
      within_file_group("Folder 1") do
        within find_embed(name: "Second file").hover do
          select_disclosure "Actions" do
            click_on "Move to folder..."
            click_on "New folder"
          end
        end
      end

      # Ensure folders with numeric names are saved as strings.
      fill_in "Folder name", with: "100"
      send_keys(:enter)
      within_file_group("100") do
        expect(page).to have_embed(name: "Second file")
      end

      within_file_group("Folder 1") do
        expect(page).to_not have_embed(name: "Second file")
        expect(page).to have_embed(name: "Third file")
      end

      sleep 0.5 # Wait for the editor to update
      save_change

      new_folder_uid = @product.reload.rich_contents.first.description.find { |node| node["type"] == RichContent::FILE_EMBED_GROUP_NODE_TYPE && node["attrs"]["name"] == "100" }["attrs"]["uid"]
      expect(@product.reload.rich_contents.first.description).to eq(
        [
          {
            "type" => RichContent::FILE_EMBED_NODE_TYPE,
            "attrs" => {
              "id" => file1.external_id,
              "uid" => file1_uid,
              "collapsed" => false,
            }
          },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "Folder 1",
              "uid" => file_group_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file3.external_id, "uid" => file3_uid, "collapsed" => false } },
            ]
          },
          {
            "type" => RichContent::FILE_EMBED_GROUP_NODE_TYPE,
            "attrs" => {
              "name" => "100",
              "uid" => new_folder_uid
            },
            "content" => [
              { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file2.external_id, "uid" => file2_uid, "collapsed" => false } },
            ]
          },
          { "type" => RichContent::LICENSE_KEY_NODE_TYPE },
          { "type" => RichContent::POSTS_NODE_TYPE },
        ]
      )
    end

    it "does not allow moving the file embed to a new folder if it's the only file embed in the folder" do
      visit edit_link_path(@product) + "/content"

      toggle_file_group "Folder 1"
      within_file_group("Folder 1") do
        within find_embed(name: "Second file").hover do
          select_disclosure "Actions" do
            click_on "Move to folder..."
            click_on "New folder"
          end
        end
      end

      fill_in "Folder name", with: "My folder"
      send_keys(:enter)

      within_file_group("Folder 1") do
        expect(page).to_not have_embed(name: "Second file")
        within find_embed(name: "Third file").hover do
          select_disclosure "Actions" do
            click_on "Move to folder..."
            expect(page).to_not have_menuitem("New folder")
            expect(page).to have_menuitem("My folder")
          end
        end
      end
    end

    it "does not allow moving the file embed to a folder if it's the only file embed in the only folder in the content" do
      visit edit_link_path(@product) + "/content"

      toggle_file_group "Folder 1"
      within_file_group("Folder 1") do
        within find_embed(name: "Second file").hover do
          select_disclosure "Actions" do
            click_on "Delete"
          end
        end
        within find_embed(name: "Third file").hover do
          select_disclosure "Actions" do
            expect(page).to_not have_menuitem("Move to folder...")
          end
        end
      end
    end
  end

  describe "versioned content" do
    let(:product) { create(:product, user: seller) }
    let(:category) { create(:variant_category, link: product, title: "Versions") }
    let(:version1) { create(:variant, variant_category: category, name: "Version 1") }
    let(:version2) { create(:variant, variant_category: category, name: "Version 2") }
    let!(:rich_content1) do
      create(
        :rich_content,
        entity: version1,
        description: [
          {
            "type" => "paragraph",
            "content" => [{ "text" => "This is Version 1 content", "type" => "text" }]
          }
        ]
      )
    end

    let!(:rich_content2) do
      create(
        :rich_content,
        entity: version2,
        description: [
          {
            "type" => "paragraph",
            "content" => [{ "text" => "This is Version 2 content", "type" => "text" }]
          }
        ]
      )
    end

    it "shows the last edited time for each version" do
      visit edit_link_path(product) + "/content"

      find(:combo_box, "Select a version").click
      expect(page).to have_selector("[role='option']", text: "Version 1 Editing", normalize_ws: true)
      expect(page).to have_selector("[role='option']", text: "Version 2 Last edited on #{rich_content2.updated_at.strftime("%B %-d, %Y at %-I:%M %p")}", normalize_ws: true)
    end
  end

  describe "commission content" do
    let(:commission) { create(:commission_product, user: seller) }

    it "shows the commission content editor with a non-editable Downloads page" do
      visit "#{edit_link_path(commission)}/content"

      downloads_tab = find("[role='tab']", text: "Downloads")
      downloads_tab.hover
      expect(downloads_tab).to have_tooltip(text: "Commission files will appear on this page upon completion")
    end
  end
end
