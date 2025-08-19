# frozen_string_literal: true

require("spec_helper")
require "shared_examples/file_group_download_all"

describe("Download Page – Rich Text Editor Content", type: :system, js: true) do
  def embed_files_for_product(product:, files:)
    product_rich_content = product.alive_rich_contents.first_or_initialize
    description = []
    files.each do |file|
      description << { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
    end
    product_rich_content.description = description
    product_rich_content.save!
  end

  let(:logged_in_user) { @buyer }

  before do
    @user = create(:user)
    @buyer = create(:user)
    login_as(logged_in_user)
  end

  context "digital product" do
    before do
      @product = create(:product, user: @user)
      @purchase = create(:purchase, link: @product, purchaser: @buyer)
      @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)

      @video_file = create(:streamable_video, link: @product, display_name: "Video file", description: "Video description")
      @audio_file = create(:listenable_audio, :analyze, link: @product, display_name: "Audio file", description: "Audio description")
      @pdf_file = create(:readable_document, link: @product, display_name: "PDF file", size: 1.megabyte)
      files = [@video_file, @audio_file, @pdf_file]
      @product.product_files = files
      embed_files_for_product(product: @product, files:)
    end

    it "triggers app bridge messages for file embeds in iOS" do
      visit("/d/#{@url_redirect.token}?display=mobile_app")

      page.execute_script <<~JS
        window._messages = [];
        window.webkit = {
          messageHandlers: {
            jsMessage: {
              postMessage: (message) => {
                window._messages.push(message);
              }
            }
          }
        };
      JS

      within(find_embed(name: "Video file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages")).to eq(
          [
            {
              type: "click",
              payload: { resourceId: @video_file.external_id, isDownload: true, isPost: false, type: nil, isPlaying: nil, resumeAt: nil, contentLength: nil }
            }.as_json
          ]
        )
        click_on "Watch"
        expect(page.evaluate_script("window._messages[1]")).to eq(
          {
            type: "click",
            payload: { resourceId: @video_file.external_id, isDownload: false, isPost: false, type: nil, isPlaying: nil, resumeAt: nil, contentLength: nil }
          }.as_json
        )
        expect(page).not_to have_selector("[aria-label='Video Player']")
      end

      within(find_embed(name: "Audio file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages[2]")).to eq(
          {
            type: "click",
            payload: { resourceId: @audio_file.external_id, isDownload: true, isPost: false, type: nil, isPlaying: nil, resumeAt: nil, contentLength: nil }
          }.as_json
        )
        click_on "Play"
        expect(page.evaluate_script("window._messages[3]")).to eq(
          {
            type: "click",
            payload: { resourceId: @audio_file.external_id, isDownload: false, isPost: false, type: "audio", isPlaying: "false", resumeAt: "0", contentLength: "46" }
          }.as_json
        )
        expect(page).not_to have_button("Close")
      end

      within(find_embed(name: "PDF file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages[4]")).to eq(
          {
            type: "click",
            payload: { resourceId: @pdf_file.external_id, isDownload: true, isPost: false, type: nil, isPlaying: nil, resumeAt: nil, contentLength: nil }
          }.as_json
        )
        click_on "Read"
        expect(page.evaluate_script("window._messages[5]")).to eq(
          {
            type: "click",
            payload: { resourceId: @pdf_file.external_id, isDownload: false, isPost: false, type: nil, isPlaying: nil, resumeAt: nil, contentLength: nil }
          }.as_json
        )
      end

      expect(page.evaluate_script("window._messages.length")).to eq(6)
    end

    it "triggers app bridge messages for file embeds in Android" do
      visit("/d/#{@url_redirect.token}?display=mobile_app")

      page.execute_script <<~JS
        window._messages = [];
        window.CustomJavaScriptInterface = {
          onFileClickedEvent: (resourceId, isDownload) => window._messages.push({ resourceId, isDownload })
        };
      JS

      within(find_embed(name: "Video file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages")).to eq(
          [
            { resourceId: @video_file.external_id, isDownload: true }.as_json
          ]
        )
        click_on "Watch"
        expect(page.evaluate_script("window._messages[1]")).to eq(
          { resourceId: @video_file.external_id, isDownload: false }.as_json
        )
        expect(page).not_to have_selector("[aria-label='Video Player']")
      end

      within(find_embed(name: "Audio file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages[2]")).to eq(
          { resourceId: @audio_file.external_id, isDownload: true }.as_json
        )
        click_on "Play"
        expect(page.evaluate_script("window._messages[3]")).to eq(
          { resourceId: @audio_file.external_id, isDownload: false }.as_json
        )
        expect(page).not_to have_button("Close")
      end

      within(find_embed(name: "PDF file")) do
        click_on "Download"
        expect(page.evaluate_script("window._messages[4]")).to eq(
          { resourceId: @pdf_file.external_id, isDownload: true }.as_json
        )
        click_on "Read"
        expect(page.evaluate_script("window._messages[5]")).to eq(
          { resourceId: @pdf_file.external_id, isDownload: false }.as_json
        )
      end

      expect(page.evaluate_script("window._messages.length")).to eq(6)
    end

    it "renders the customized download page for the purpose of embedding inside webview in the mobile apps" do
      visit("/d/#{@url_redirect.token}?display=mobile_app")

      within(find_embed(name: "Audio file")) do
        expect(page).to have_button("Play")
        expect(page).to have_text("MP3")
        expect(page).to have_text("0m 46s")
        expect(page).to have_text("Audio description")
        expect(page).to_not have_text("Processing...")
        expect(page).to_not have_button("Pause")
        expect(page).to_not have_text(" left")
        expect(page).to_not have_selector("meter")
        page.execute_script %Q(
          window.dispatchEvent(new CustomEvent("mobile_app_audio_player_info", { detail: { fileId: "#{@audio_file.external_id}", isPlaying: true, latestMediaLocation: "24" } }));
        ).squish
        expect(page).to have_button("Pause")
        expect(page).to have_text("0m 22s left")
        expect(page).to_not have_text("Processing...")
        expect(page).to have_selector("meter[value*='0.52']")
      end

      @audio_file.update!(duration: nil, description: nil)

      visit("/d/#{@url_redirect.token}?display=mobile_app")

      within(find_embed(name: "Audio file")) do
        expect(page).to have_button("Play", disabled: true)
        expect(page).to_not have_text("MP3")
        expect(page).to_not have_text("0m 46s")
        expect(page).to_not have_text("Audio description")
        expect(page).to have_text("Processing...")

        @audio_file.update!(duration: 46)
        expect(page).to have_text("0m 46s", wait: 10)
        expect(page).to have_text("MP3")
        expect(page).to_not have_text("Processing...")
        expect(page).to have_button("Play")
      end
    end

    it "allows sending a readable document to Kindle" do
      visit("/d/#{@url_redirect.token}")

      expect do
        expect do
          within(find_embed(name: "PDF file")) do
            expect(page).to have_text("PDF1.0 MB")
            click_on "Send to Kindle"
            fill_in "e7@kindle.com", with: "example@kindle.com"
            click_on "Send"
          end

          expect(page).to have_alert(text: "It's been sent to your Kindle.")
        end.to have_enqueued_mail(CustomerMailer, :send_to_kindle)
      end.to change(ConsumptionEvent, :count).by(1)

      event = ConsumptionEvent.last
      expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_READ)
      expect(event.purchase_id).to eq(@purchase.id)
      expect(event.link_id).to eq(@product.id)
      expect(event.product_file_id).to eq(@pdf_file.id)
    end

    it "shows file embeds if present" do
      visit("/d/#{@url_redirect.token}")

      within(find_embed(name: "Video file")) do
        expect(page).to have_link("Download")
        expect(page).to have_button("Watch")
        expect(page).to have_text("Video description")
      end

      within(find_embed(name: "Audio file")) do
        expect(page).to have_link("Download")
        expect(page).to have_button("Play")
        expect(page).to have_text("Audio description")
      end

      within(find_embed(name: "PDF file")) do
        expect(page).to have_link("Download")
        expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @pdf_file.external_id))
      end
    end

    it "shows collapsed video thumbnails" do
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(
        description: product_rich_content.description.map do |node|
          node["attrs"]["collapsed"] = true if node["attrs"]["id"] == @video_file.external_id
          node
        end
      )

      visit("/d/#{@url_redirect.token}")

      within(find_embed(name: "Video file")) do
        expect(page).not_to have_selector("figure")
        expect(page).to have_button("Play")

        click_on "Play"
        expect(page).to have_selector("[aria-label='Video Player']")
      end
    end

    context "when the logged in user is seller and the embedded videos are not yet transcoded" do
      let(:logged_in_user) { @user }

      before do
        @purchase.update!(purchaser: @user)
      end

      it "shows video transcoding notice modal" do
        visit("/d/#{@url_redirect.token}")

        expect(page).to have_modal("Your video is being transcoded.")
        within_modal("Your video is being transcoded.") do
          expect(page).to have_text("Until then, you and your future customers may experience some viewing issues. You'll get an email once it's done.", normalize_ws: true)
          click_on "Close"
        end

        expect(page).to_not have_modal("Your video is being transcoded.")
      end
    end

    it "displays embedded code blocks and allows copying them" do
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(
        description: product_rich_content.description.concat(
          [
            { "type" => "codeBlock", "attrs" => { "language" => nil }, "content" => [{ "type" => "text", "text" => "const hello = \"world\";" }] },
            { "type" => "codeBlock", "attrs" => { "language" => "ruby" }, "content" => [{ "type" => "text", "text" => "puts 'Hello, world!'" }] },
            { "type" => "codeBlock", "attrs" => { "language" => "typescript" }, "content" => [{ "type" => "text", "text" => "let greeting: string = 'Hello, world!';" }] }
          ]
        )
      )

      visit("/d/#{@url_redirect.token}")

      expect(page).to have_text("const hello = \"world\";")
      expect(page).to have_text("puts 'Hello, world!'")
      expect(page).to have_text("let greeting: string = 'Hello, world!';")

      find("pre", text: "const hello = \"world\";").hover
      within find("pre", text: "const hello = \"world\";") do
        click_on "Copy"
        expect(page).to have_text("Copied!")
      end

      find("pre", text: "puts 'Hello, world!'").hover
      within find("pre", text: "puts 'Hello, world!'") do
        click_on "Copy"
        expect(page).to have_text("Copied!")
      end

      find("pre", text: "let greeting: string = 'Hello, world!';").hover
      within find("pre", text: "let greeting: string = 'Hello, world!';") do
        click_on "Copy"
        expect(page).to have_text("Copied!")
      end
    end

    context "when video file is marked as stream only" do
      before do
        @video_file.update!(stream_only: true)
      end

      it "doesn't allow the video files to be downloaded" do
        visit("/d/#{@url_redirect.token}")

        within(find_embed(name: "Video file")) do
          expect(page).to_not have_link("Download")
          expect(page).to have_button("Watch")
        end

        within(find_embed(name: "Audio file")) do
          expect(page).to have_link("Download")
          expect(page).to have_button("Play")
        end

        within(find_embed(name: "PDF file")) do
          expect(page).to have_link("Download")
          expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @pdf_file.external_id))
        end
      end
    end

    it "shows inline preview for video file embeds" do
      subtitle_file = create(:subtitle_file, product_file: @video_file, url: "https://s3.amazonaws.com/gumroad-specs/attachments/6505430906858/ba3afa0e200b414caa6fe8b0be05ae20/original/sample.srt")
      subtitle_blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "sample.srt"), "text/plain"), filename: "sample.srt")
      allow_any_instance_of(ProductFile).to receive(:signed_download_url_for_s3_key_and_filename).with(subtitle_file.s3_key, subtitle_file.s3_filename, is_video: true).and_return(subtitle_blob.url)

      @video_file.thumbnail.attach(io: File.open(Rails.root.join("spec", "support", "fixtures", "autumn-leaves-1280x720.jpeg")), filename: "autumn-leaves-1280x720.jpeg")

      video_blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "ScreenRecording.mov"), "video/quicktime"), filename: "ScreenRecording.mov", key: "test/ScreenRecording.mov")
      allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(video_blob.url)
      allow_any_instance_of(UrlRedirect).to receive(:hls_playlist_or_smil_xml_path).and_return(video_blob.url)

      visit("/d/#{@url_redirect.token}")
      wait_for_ajax

      within(find_embed(name: "Video file")) do
        expect(page).to have_selector("img[src='https://gumroad-specs.s3.amazonaws.com/#{@video_file.thumbnail_variant.key}']")
        click_on "Watch"
        expect(page).to_not have_button("Watch")
        expect(page).to_not have_selector("img[src='https://gumroad-specs.s3.amazonaws.com/#{@video_file.thumbnail_variant.key}']")
        expect(page).to have_selector("[aria-label='Video Player']")
        expect(page).to have_button("Pause")
        expect(page).to have_button("Rewind 10 Seconds")
        expect(page).to have_button("Closed Captions")
      end
    end

    it "allow watching the video again if it encounters an error while fetching its media URLs" do
      allow_any_instance_of(UrlRedirectsController).to receive(:media_urls).and_raise(ActionController::BadRequest)

      visit("/d/#{@url_redirect.token}")

      within(find_embed(name: "Video file")) do
        click_on "Watch"
      end
      expect(page).to have_alert(text: "Sorry, something went wrong. Please try again.")
      within(find_embed(name: "Video file")) do
        expect(page).to have_button("Watch")
        expect(page).to_not have_selector("[aria-label='Video Player']")
      end
    end

    it "shows inline preview for embedded media via URL" do
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(description: product_rich_content.description << { "type" => "mediaEmbed", "attrs" => { "url" => "https://www.youtube.com/watch?v=YE7VzlLtp-4", "html" => "<iframe src=\"//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2FYE7VzlLtp-4&key=31708e31359468f73bc5b03e9dcab7da\" style=\"top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;\" allowfullscreen scrolling=\"no\" allow=\"accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;\"></iframe>", "title" => "Big Buck Bunny" } })

      visit("/d/#{@url_redirect.token}")

      within find_embed(name: "Big Buck Bunny") do
        expect(page).to have_link("https://www.youtube.com/watch?v=YE7VzlLtp-4")
        expect(page).to_not have_button("Remove")
        expect(page).to_not have_link("Download")
        expect(find("iframe")[:src]).to include "iframe.ly/api/iframe?url=#{CGI.escape("https://youtu.be/YE7VzlLtp-4")}"
      end
    end

    context "when the product is a rental" do
      before do
        @url_redirect.update!(is_rental: true)
      end

      it "doesn't allow the video files to be downloaded" do
        visit("/d/#{@url_redirect.token}")

        within(find_embed(name: "Video file")) do
          expect(page).to_not have_link("Download")
          expect(page).to have_button("Watch")
        end

        within(find_embed(name: "Audio file")) do
          expect(page).to have_link("Download")
          expect(page).to have_button("Play")
        end

        within(find_embed(name: "PDF file")) do
          expect(page).to have_link("Download")
          expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @pdf_file.external_id))
        end
      end
    end

    context "when an audio file embed exists" do
      before do
        allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@audio_file.url)
      end

      it "allows playing the content in an audio player" do
        visit("/d/#{@url_redirect.token}")

        # It does not show consumption progress if not started listening
        expect(page).to_not have_selector("[role='progressbar']")
        expect(page).to have_button("Play")

        # It does not show the audio player by default
        expect(page).to_not have_button("Rewind15")

        click_on "Play"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
        expect(page).to have_button("Close")
        expect(page).to have_button("Rewind15")

        click_on "Pause"
        expect(page).to have_button("Play")
        expect(page).to_not have_button("Pause")

        # Skip and rewind
        progress_text = find("[aria-label='Progress']").text
        progress_seconds = progress_text[3..5].to_i
        click_on "Skip30"
        click_on "Rewind15"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:#{(progress_seconds + 15).to_s.rjust(2, "0")}")
        click_on "Rewind15"
        expect(page).to have_selector("[aria-label='Progress']", text: progress_text)

        # Close audio player
        click_on "Close"
        expect(page).to_not have_button("Rewind15")
      end

      it "correctly updates consumption and playback progress" do
        media_location = create(:media_location,
                                url_redirect_id: @url_redirect.id,
                                purchase_id: @purchase.id,
                                product_file_id: @audio_file.id,
                                product_id: @product.id,
                                location: 10)

        visit("/d/#{@url_redirect.token}")

        expect(page).to have_selector("[role='progressbar'][aria-valuenow='#{(1000.0 / 46).round(2)}']")
        click_on "Play"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:10")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:12")
        click_on "Pause"

        media_location.update!(location: 46)
        visit("/d/#{@url_redirect.token}")
        expect(page).to have_selector("[role='progressbar'][aria-valuenow='100']")

        # Resumes listening from the beginning
        click_on "Play again"
        expect(page).to have_selector("[aria-label='Progress']", text: "00:00")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
      end
    end

    context "when product has rich content" do
      before do
        product_rich_content = @product.alive_rich_contents.first
        product_rich_content.update!(description: product_rich_content.description << { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Product-level content" }] })
      end

      context "when accessing the download page for a purchased variant" do
        before do
          category = create(:variant_category, link: @product, title: "Versions")
          version = create(:variant, variant_category: category, name: "Version 1")
          create(:rich_content, entity: version, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 1 content", "type" => "text" }] }])

          @purchase = create(:purchase, link: @product, purchaser: @buyer)
          @purchase.variant_attributes = [version]
          @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
        end

        it "shows the variant-level rich content" do
          visit("/d/#{@url_redirect.token}")
          expect(page).to have_text("#{@product.name} - Version 1")
          expect(page).to have_text("This is Version 1 content")
          expect(page).to_not have_text("Product-level content")
        end
      end

      context "when accessing the download page for a purchased variant belonging to a product having 'Use the same content for all versions' checkbox checked" do
        before do
          @product.update!(has_same_rich_content_for_all_variants: true)

          category = create(:variant_category, link: @product, title: "Versions")
          version1 = create(:variant, variant_category: category, name: "Version 1")
          create(:variant, variant_category: category, name: "Version 2")
          @purchase = create(:purchase, link: @product, purchaser: @buyer)
          @purchase.variant_attributes = [version1]
          @url_redirect = create(:url_redirect, link: @product, purchase: @purchase)
        end

        it "shows the product-level rich content" do
          visit("/d/#{@url_redirect.token}")
          expect(page).to have_text("#{@product.name} - Version 1")
          expect(page).to have_embed(name: @video_file.display_name)
          expect(page).to have_embed(name: @audio_file.display_name)
          expect(page).to have_embed(name: @pdf_file.display_name)
          expect(page).to have_text("Product-level content")
        end
      end

      it "shows the product-level content when accessing the download page for a purchased product having no variants" do
        visit("/d/#{@url_redirect.token}")
        expect(page).to have_text("#{@product.name}")
        expect(page).to have_embed(name: @video_file.display_name)
        expect(page).to have_embed(name: @audio_file.display_name)
        expect(page).to have_embed(name: @pdf_file.display_name)
        expect(page).to have_text("Product-level content")
        expect(page).to have_disclosure_button("Open in app")
      end
    end

    it "supports pages" do
      # When there's just one untitled page, it doesn't show table of contents
      expect(@product.alive_rich_contents.count).to eq(1)
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 1 content" }] }])
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_tablist("Table of Contents")
      expect(page).to_not have_button("Next")
      expect(page).to have_text("Page 1 content")

      # When there are multiple pages, it shows table of contents
      product_rich_content.update!(title: "Page 1", position: 0)
      create(:rich_content, entity: @product, title: "Page 2", position: 1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Page 2 content" }] }])
      refresh
      expect(page).to have_tablist("Table of Contents")
      expect(page).to have_tab_button("Page 1", open: true)
      expect(page).to have_text("Page 1 content")
      expect(page).to have_tab_button("Page 2", open: false)
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next", disabled: false)
      select_tab("Page 2")
      expect(page).to have_tab_button("Page 2", open: true)
      expect(page).to have_text("Page 2 content")
      expect(page).to have_button("Previous", disabled: false)
      expect(page).to have_button("Next", disabled: true)
      click_on "Previous"
      expect(page).to have_tab_button("Page 1", open: true)
      expect(page).to have_text("Page 1 content")
      expect(page).to have_button("Previous", disabled: true)
      expect(page).to have_button("Next", disabled: false)
      click_on "Next"
      expect(page).to have_tab_button("Page 2", open: true)
      expect(page).to have_text("Page 2 content")
      expect(page).to have_button("Previous", disabled: false)
      expect(page).to have_button("Next", disabled: true)
    end

    it "replaces the `__sale_info__` placeholder query parameter in links and buttons with the appropriate query parameters" do
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(description: [
                                     { "type" => "paragraph",
                                       "content" =>
                                        [{ "text" => "Link 1",
                                           "type" => "text",
                                           "marks" =>
                                            [{ "type" => "link",
                                               "attrs" =>
                                              { "rel" => "noopener noreferrer nofollow",
                                                "href" => "https://example.com?__sale_info__",
                                                "class" => nil,
                                                "target" => "_blank" } }] }] },
                                     { "type" => "paragraph",
                                       "content" =>
                                        [{ "text" => "Link 2 with custom query parameters",
                                           "type" => "text",
                                           "marks" =>
                                          [{ "type" => "link",
                                             "attrs" =>
                                              { "rel" => "noopener noreferrer nofollow",
                                                "href" => "https://example.com/?test=123&__sale_info__",
                                                "class" => nil,
                                                "target" => "_blank" } }] }] },
                                     { "type" => "paragraph",
                                       "content" =>
                                        [{ "type" => "tiptap-link",
                                           "attrs" => { "href" => "https://example.com/?test=123&__sale_info__" },
                                           "content" => [{ "text" => "Link 3", "type" => "text" }] }] },
                                     { "type" => "button",
                                       "attrs" =>
                                        { "href" => "https://example.com/?test=123&__sale_info__" },
                                       "content" =>
                                        [{ "text" => "Button with custom query parameters", "type" => "text" }] },
                                   ])

      visit("/d/#{@url_redirect.token}")
      sale_info_query_params = "sale_id=#{CGI.escape(@purchase.external_id)}&product_id=#{CGI.escape(@product.external_id)}&product_permalink=#{CGI.escape(@product.unique_permalink)}"
      expect(find_link("Link 1", href: "https://example.com/?#{sale_info_query_params}", target: "_blank")[:rel]).to eq("noopener noreferrer nofollow")
      expect(find_link("Link 2 with custom query parameters", href: "https://example.com/?test=123&#{sale_info_query_params}", target: "_blank")[:rel]).to eq("noopener noreferrer nofollow")
      expect(find_link("Link 3", href: "https://example.com/?test=123&#{sale_info_query_params}", target: "_blank")[:rel]).to eq("noopener noreferrer nofollow")
      expect(find_link("Button with custom query parameters", href: "https://example.com/?test=123&#{sale_info_query_params}", target: "_blank")[:rel]).to eq("noopener noreferrer nofollow")
    end

    it "shows license key within the content and not outside of the content" do
      product_rich_content = @product.alive_rich_contents.first
      product_rich_content.update!(title: "Page 1", description: [
                                     { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                                     { "type" => "licenseKey" },
                                     { "type" => "fileEmbed", "attrs" => { "id" => @video_file.external_id, "uid" => SecureRandom.uuid } }
                                   ])
      create(:rich_content, entity: @product, title: "Page 2", description: [{ "type" => "paragraph", "content" => [{ "type" => "fileEmbed", "attrs" => { "id" => @audio_file.external_id, "uid" => SecureRandom.uuid } }] }])
      @product.update!(is_licensed: true, is_multiseat_license: true)
      @purchase.update!(is_multiseat_license: true)

      create(:license, link: @product, purchase: @purchase)

      visit("/d/#{@url_redirect.token}")
      within find("[aria-label='Product content']") do
        expect(page).to have_text("Lorem ipsum")
        within find_embed(name: @purchase.license_key) do
          expect(page).to have_text("License key")
          expect(page).to have_text("1 Seat")
          expect(page).to have_button("Copy")
        end
      end

      expect(page).to have_text(@purchase.license_key, count: 1)

      expect(page).to have_tab_button("Page 1", open: true)
      within find(:tab_button, "Page 1") do
        expect(page).to have_selector("[aria-label='Page has license key']")
      end
      expect(page).to have_tab_button("Page 2", open: false)
      within find(:tab_button, "Page 2") do
        expect(page).to have_selector("[aria-label='Page has audio files']")
      end
    end

    describe "posts" do
      before do
        rich_content = @product.rich_contents.alive.first
        rich_content.update!(description: rich_content.description.unshift({ "type" => "posts" }))
        logout
      end

      it "correctly displays non-subscription purchase posts for published posts" do
        previous_post = create(:installment, link: @product, published_at: 50.days.ago, name: "my old thing")
        valid_post = create(:installment, link: @product, published_at: Time.current, name: "my new thing")
        unpublished_post = create(:installment, link: @product, name: "an unpublished thing")
        deleted_post = create(:installment, link: @product, published_at: Time.current, name: "my deleted thing", deleted_at: Time.current)
        create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: valid_post)
        create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: deleted_post)

        visit @url_redirect.download_page_url

        within find_embed(name: "Posts") do
          expect(page).to have_link(valid_post.displayed_name)
          expect(page).to_not have_link(unpublished_post.displayed_name)
          expect(page).to_not have_link(previous_post.displayed_name)
        end
      end

      it "displays cancelled membership posts" do
        @product = create(:subscription_product, user: @user)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])

        subscription_1 = create(:subscription, link_id: @product.id, user_id: @user.id)
        purchase_1 = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: subscription_1, purchaser: @user, email: @user.email)
        post_1 = create(:installment, link: @product, published_at: 3.days.ago)
        @url_redirect = create(:url_redirect, purchase: purchase_1, installment: post_1)
        create(:creator_contacting_customers_email_info_sent, purchase: purchase_1, installment: post_1)
        subscription_1.cancel!

        post_between_subscriptions = create(:installment, link: @product, published_at: 2.days.ago)

        subscription_2 = create(:subscription, link_id: @product.id, user_id: @user.id)
        purchase_2 = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: subscription_2, purchaser: @user, email: @user.email)
        post_2 = create(:installment, link: @product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: purchase_2, installment: post_2)

        sign_in @user
        visit @url_redirect.download_page_url

        within find_embed(name: "Posts") do
          expect(page).to have_text("2 posts")
          expect(page).to have_link(post_1.displayed_name)
          expect(page).to_not have_link(post_between_subscriptions.displayed_name)
          expect(page).to have_link(post_2.displayed_name)
        end
      end

      it "displays seller profile posts" do
        seller_post = create(:seller_installment, seller: @user, published_at: 1.day.ago, send_emails: false, shown_on_profile: true)

        visit @url_redirect.download_page_url

        expect(page).to_not have_selector("[aria-label=Posts]")
        within find_embed(name: "Posts") do
          expect(page).to have_link(seller_post.displayed_name)
        end
      end

      describe "membership product show all posts setting" do
        before  do
          @product = create(:membership_product_with_preset_tiered_pricing)
          @product.tiers.each do |tier|
            create(:rich_content, entity: tier, description: [{ "type" => "posts" }])
          end
          other_tier = @product.tiers.last
          expect(other_tier).not_to eq @product.default_tier
          @purchase = create(:membership_purchase, link: @product, variant_attributes: [@product.default_tier], purchaser: @user)

          @pre_purchase_product_post_1 = create(:installment, link: @product, published_at: 2.months.ago)
          @pre_purchase_product_post_2 = create(:installment, link: @product, published_at: 2.weeks.ago)
          @pre_purchase_tier_post = create(:variant_installment, link: @product, base_variant: @product.default_tier, published_at: 1.month.ago)
          @pre_purchase_other_tier_post = create(:variant_installment, link: @product, base_variant: other_tier, published_at: 1.week.ago)
          @pre_purchase_multi_product_post = create(:seller_installment, seller: @product.user, published_at: 1.day.ago, bought_products: [@product.unique_permalink])
          @pre_purchase_multi_product_variant_post = create(:seller_installment, seller: @product.user, published_at: 1.day.ago, bought_products: [@product.unique_permalink], bought_variants: [@product.default_tier.external_id])

          @post_purchase_post = create(:installment, link: @product, published_at: Time.current)
          @post_purchase_tier_post = create(:installment, link: @product, installment_type: Installment::VARIANT_TYPE, base_variant: @product.default_tier, published_at: Time.current)
          @post_purchase_other_tier_post = create(:installment, link: @product, installment_type: Installment::VARIANT_TYPE, base_variant: other_tier, published_at: Time.current)
          create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: @post_purchase_post)
          create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: @post_purchase_tier_post)

          @url_redirect = create(:url_redirect, purchase: @purchase)
          sign_in @user
        end

        it "does not display old posts for the membership product if setting is disabled" do
          visit @url_redirect.download_page_url

          within find_embed(name: "Posts") do
            expect(page).to have_text("2 posts")
            expect(page).to have_link(@post_purchase_post.displayed_name)
            expect(page).to have_link(@post_purchase_tier_post.displayed_name)
            expect(page).to_not have_link(@pre_purchase_product_post_1.displayed_name)
            expect(page).to_not have_link(@pre_purchase_product_post_2.displayed_name)
            expect(page).to_not have_link(@pre_purchase_tier_post.displayed_name)
          end
        end

        it "displays old posts for the membership product if setting is enabled" do
          @product.update!(should_show_all_posts: true)
          visit @url_redirect.download_page_url

          within find_embed(name: "Posts") do
            expect(page).to have_text("7 posts")
            expect(page).to have_link(@post_purchase_post.displayed_name)
            expect(page).to have_link(@post_purchase_tier_post.displayed_name)
            expect(page).to have_link(@pre_purchase_product_post_1.displayed_name)
            expect(page).to have_link(@pre_purchase_product_post_2.displayed_name)
            expect(page).to have_link(@pre_purchase_tier_post.displayed_name)
            expect(page).to have_link(@pre_purchase_multi_product_post.displayed_name)
            expect(page).to have_link(@pre_purchase_multi_product_variant_post.displayed_name)
            expect(page).to_not have_link(@pre_purchase_other_tier_post.displayed_name)
            expect(page).to_not have_link(@post_purchase_other_tier_post.displayed_name)
          end
        end

        it "displays old posts for membership test purchases if setting is enabled" do
          [@post_purchase_post,
           @post_purchase_tier_post,
           @pre_purchase_product_post_1,
           @pre_purchase_product_post_2,
           @pre_purchase_tier_post,
           @pre_purchase_multi_product_post,
           @pre_purchase_multi_product_variant_post,
           @pre_purchase_other_tier_post,
           @post_purchase_other_tier_post].map { |post| post.update!(seller: @user) }
          @product.update!(should_show_all_posts: true, user: @user)
          @purchase.update!(purchase_state: "test_successful", seller: @user)

          visit @url_redirect.download_page_url

          within find_embed(name: "Posts") do
            expect(page).to have_text("7 posts")
            expect(page).to have_link(@post_purchase_post.displayed_name)
            expect(page).to have_link(@post_purchase_tier_post.displayed_name)
            expect(page).to have_link(@pre_purchase_product_post_1.displayed_name)
            expect(page).to have_link(@pre_purchase_product_post_2.displayed_name)
            expect(page).to have_link(@pre_purchase_tier_post.displayed_name)
            expect(page).to have_link(@pre_purchase_multi_product_post.displayed_name)
            expect(page).to have_link(@pre_purchase_multi_product_variant_post.displayed_name)
            expect(page).to_not have_link(@pre_purchase_other_tier_post.displayed_name)
            expect(page).to_not have_link(@post_purchase_other_tier_post.displayed_name)
          end
        end
      end

      it "displays valid links to posts" do
        @product = create(:subscription_product, user: @user)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])

        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        @url_redirect = create(:url_redirect, purchase:)
        post = create(:installment, link: @product, published_at: Time.current)
        create(:creator_contacting_customers_email_info_sent, purchase:, installment: post)

        sign_in @user
        visit @url_redirect.download_page_url

        within find_embed(name: "Posts") do
          new_window = page.window_opened_by do
            click_on post.displayed_name
          end
          within_window new_window do
            expect(page).to have_section(post.displayed_name)
          end
        end
      end

      it "correctly displays proper subscription posts" do
        @product = create(:subscription_product, should_include_last_post: true, user: @user)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        sub_purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        recurring_purchase = create(:purchase, link: @product, subscription:, purchaser: @user, email: sub_purchase.email)

        previous_post = create(:installment, link: @product, published_at: 60.days.ago)
        url_redirect = create(:url_redirect, purchase_id: sub_purchase.id, subscription_id: subscription.id)
        create(:creator_contacting_customers_email_info_sent, purchase: recurring_purchase, installment: previous_post, sent_at: Time.current - 30.days)

        sign_in @user
        visit url_redirect.download_page_url

        within find_embed(name: "Posts") do
          expect(page).to have_text("1 post")
          expect(page).to have_link(previous_post.displayed_name)
          expect(page).to have_text("about 1 month ago")
        end
      end

      it "does not display any subscription posts if none exist" do
        @product = create(:subscription_product)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        sub_purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        @url_redirect = create(:url_redirect, purchase: sub_purchase)

        previous_post = create(:installment, link: @product, published_at: 50.days.ago)
        create(:url_redirect, purchase_id: sub_purchase.id, subscription_id: subscription.id, installment_id: previous_post.id)

        visit @url_redirect.download_page_url

        expect(page).to_not have_embed(name: "Posts")
        expect(page).to_not have_selector("[aria-label='Posts']")
      end

      it "correctly displays the workflow post for a subscription product and its view attachments button" do
        @product = create(:subscription_product, user: @user)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
        workflow = create(:workflow, link: @product, seller: @product.user, created_at: 1.minute.ago)
        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        sub_purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        post = create(:installment, link: @product, workflow:, published_at: Time.current)
        create(:installment_rule, installment: post, time_period: "hour", delayed_delivery_time: 0)
        create(:product_file, installment: post, link: nil)
        create(:creator_contacting_customers_email_info_sent, purchase: sub_purchase, installment: post)
        @url_redirect = post.generate_url_redirect_for_purchase(sub_purchase)

        visit @url_redirect.download_page_url

        expect(page).to have_text(sub_purchase.link.name)
        within find("[aria-label='Posts']") do
          expect(page).to have_text(post.displayed_name)
          click_on "View"
        end
        expect(page).to have_section(post.displayed_name)
        expect(page).to have_link("View content")
      end

      it "displays the member cancellation workflow post when the email has been sent" do
        @product = create(:subscription_product, user: @user, is_tiered_membership: true, should_show_all_posts: true)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
        workflow = create(:workflow, link: @product, seller: @product.user, created_at: 1.minute.ago, workflow_trigger: "member_cancellation")
        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        sub_purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        post = create(:installment, link: @product, workflow:, published_at: Time.current, workflow_trigger: "member_cancellation")
        create(:installment_rule, installment: post, time_period: "hour", delayed_delivery_time: 0)
        create(:product_file, installment: post, link: nil)
        create(:creator_contacting_customers_email_info_sent, purchase: sub_purchase, installment: post)
        url_redirect = post.generate_url_redirect_for_purchase(sub_purchase)

        visit url_redirect.download_page_url

        expect(page).to have_text(sub_purchase.link.name)
        within find("[aria-label='Posts']") do
          expect(page).to have_text(post.displayed_name)
          click_on "View"
        end
        expect(page).to have_section(post.displayed_name)
        expect(page).to have_link("View content")
      end

      it "doesn't display the member cancellation workflow post when the email hasn't been sent" do
        @product = create(:subscription_product, user: @user, is_tiered_membership: true, should_show_all_posts: true)
        create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
        workflow = create(:workflow, link: @product, seller: @product.user, created_at: 1.minute.ago, workflow_trigger: "member_cancellation")
        subscription = create(:subscription, link_id: @product.id, user_id: @user.id)
        sub_purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription:, purchaser: @user)
        post = create(:installment, link: @product, workflow:, published_at: Time.current, workflow_trigger: "member_cancellation")
        create(:installment_rule, installment: post, time_period: "hour", delayed_delivery_time: 0)
        create(:product_file, installment: post, link: nil)
        url_redirect = post.generate_url_redirect_for_purchase(sub_purchase)

        visit url_redirect.download_page_url
        expect(page).to have_text(sub_purchase.link.name)
        expect(page).to_not have_selector("[aria-label='Posts']")
        expect(page).to_not have_text(post.displayed_name)
      end

      it "displays email infos after changing subscription plan" do
        original_purchase = create(:membership_purchase, purchaser: @user, email: @user.email, is_archived_original_subscription_purchase: true)
        create(:rich_content, entity: original_purchase.link, description: [{ "type" => "posts" }])
        updated_original_purchase = create(:membership_purchase, purchaser: @user, email: @user.email, purchase_state: "not_charged", subscription: original_purchase.subscription, link: original_purchase.link)
        post = create(:installment, link: original_purchase.link, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: updated_original_purchase, installment: post)
        url_redirect = create(:url_redirect, purchase: original_purchase)

        sign_in @user
        visit url_redirect.download_page_url
        within find("[aria-label='Posts']") do
          expect(page).to have_text(post.displayed_name)
        end
      end

      context "inactive subscriptions" do
        before do
          @product = create(:subscription_product)
          create(:rich_content, entity: @product, description: [{ "type" => "posts" }])
          purchase = create(:membership_purchase, link: @product, purchaser: @user, email: @user.email)
          @post = create(:installment, link: @product, published_at: 1.day.ago)
          create(:creator_contacting_customers_email_info_sent, purchase:, installment: @post)
          @url_redirect = create(:url_redirect, purchase:)
          purchase.subscription.update!(deactivated_at: 1.minute.ago)
        end

        it "still displays posts" do
          sign_in @user
          visit @url_redirect.download_page_url

          within find_embed(name: "Posts") do
            expect(page).to have_text("1 post")
            expect(page).to have_link(@post.displayed_name)
          end
        end

        context "when users should lose access after subscription lapses" do
          it "does not display posts" do
            @product.update!(block_access_after_membership_cancellation: true)

            sign_in @user
            visit @url_redirect.download_page_url

            expect(page).to_not have_embed(name: "Posts")
            expect(page).to_not have_selector("[aria-label='Posts']")
            expect(page).to_not have_text(@post.displayed_name)
          end
        end
      end

      it "does not display posts from chargedback purchases" do
        product = create(:product)
        create(:rich_content, entity: product, description: [{ "type" => "posts" }])
        chargedback_purchase = create(:purchase, link: product, purchaser: @user, email: @user.email, chargeback_date: 1.day.ago)
        post1 = create(:installment, link: product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: chargedback_purchase, installment: post1)

        chargeback_reversed_purchase = create(:purchase, link: product, purchaser: @user, email: @user.email, chargeback_date: 1.day.ago, chargeback_reversed: true)
        post2 = create(:installment, link: product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: chargeback_reversed_purchase, installment: post2)

        url_redirect = create(:url_redirect, purchase: chargeback_reversed_purchase)

        sign_in @user
        visit url_redirect.download_page_url

        within find_embed(name: "Posts") do
          expect(page).to have_text("1 post")
          expect(page).to_not have_link(post1.displayed_name)
          expect(page).to have_link(post2.displayed_name)
        end
      end

      it "does not display posts from fully refunded purchases" do
        product = create(:product)
        create(:rich_content, entity: product, description: [{ "type" => "posts" }])
        refunded_purchase = create(:purchase, link: product, purchaser: @user, email: @user.email, stripe_refunded: true)
        post = create(:installment, link: product, published_at: 1.day.ago)
        create(:creator_contacting_customers_email_info_sent, purchase: refunded_purchase, installment: post)

        purchase = create(:purchase, link: product, purchaser: @user, email: @user.email)
        url_redirect = create(:url_redirect, purchase:)

        sign_in @user
        visit url_redirect.download_page_url

        expect(page).to_not have_embed(name: "Posts")
        expect(page).to_not have_selector("[aria-label='Posts']")
        expect(page).not_to have_text(post.displayed_name)
      end
    end
  end

  context "product with file embed groups" do
    it_behaves_like "a product with 'Download all' buttons on file embed groups" do
      let!(:product) { create(:product, user: @user) }
      let!(:url_redirect) { create(:url_redirect, link: product, purchase: create(:purchase, link: product, purchaser: @buyer)) }
      let!(:url) { "/d/#{url_redirect.token}" }
    end
  end

  context "physical product with files" do
    before do
      allow_any_instance_of(Aws::S3::Object).to receive(:content_length).and_return(1_000_000)
      @product = create(:physical_product, user: @user)
      @file_1 = create(:product_file, link: @product, size: 100, display_name: "link-1")
      @file_2 = create(:product_file, link: @product, size: 100, display_name: "link-2")
      @variant_category = @product.variant_categories.create!(title: "Color")
      @variant_category.variants.create!(name: "Red")
      @variant_category.variants.create!(name: "Blue")
      Product::SkusUpdaterService.new(product: @product).perform
      @purchase = create(:physical_purchase, link: @product, variant_attributes: [@product.skus.last])
      @url_redirect = create(:url_redirect, purchase: @purchase)

      files = [@file_1, @file_2]
      embed_files_for_product(product: @product, files:)
    end

    it "renders the download page with file embeds" do
      visit "/d/#{@url_redirect.token}"

      within(find_embed(name: "link-1")) do
        expect(page).to have_link("Download")
        expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @file_1.external_id))
      end

      within(find_embed(name: "link-2")) do
        expect(page).to have_link("Download")
        expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @file_2.external_id))
      end
    end
  end

  context "membership" do
    before do
      @membership = create(:membership_product, user: @user)
      @purchase = create(:membership_purchase, link: @membership, variant_attributes: [@membership.tiers.first])
      @url_redirect = create(:url_redirect, purchase: @purchase)

      video_file = create(:streamable_video, link: @membership, display_name: "Video file")
      audio_file = create(:listenable_audio, link: @membership, display_name: "Audio file")
      @pdf_file = create(:readable_document, link: @membership, display_name: "PDF file")
      files = [video_file, audio_file, @pdf_file]
      @membership.product_files = files
      @membership.tiers.first.product_files = files
      create(:rich_content, entity: @membership.tiers.first, description: files.map { |file| { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } } })
    end

    it "shows file embeds if present" do
      visit("/d/#{@url_redirect.token}")
      within(find_embed(name: "Video file")) do
        expect(page).to have_link("Download")
        expect(page).to have_button("Watch")
      end

      within(find_embed(name: "Audio file")) do
        expect(page).to have_link("Download")
        expect(page).to have_button("Play")
      end

      within(find_embed(name: "PDF file")) do
        expect(page).to have_link("Download")
        expect(page).to have_link("Read", href: url_redirect_read_for_product_file_path(@url_redirect.token, @pdf_file.external_id))
      end
    end
  end
end
