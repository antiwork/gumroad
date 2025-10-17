# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/file_group_download_all"

describe("File embeds in product content editor", type: :system, js: true) do
  include ProductEditPageHelpers

  let(:seller) { create(:named_seller) }

  before :each do
    @product = create(:product_with_pdf_file, user: seller, size: 1024)
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE,
                                                              one_item_rate_cents: 0,
                                                              multiple_items_rate_cents: 0)
  end

  include_context "with switching account to user as admin for seller"

  it "allows to mark PDF files as stampable" do
    visit edit_link_path(@product.unique_permalink) + "/content"
    select_disclosure "Upload files" do
      attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
    end

    # TODO(ershad): Enable this once we have a way to slow down the upload process
    # button = find_button("Save changes", disabled: true)
    # button.hover
    # expect(button).to have_tooltip(text: "Files are still uploading...")

    wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")
    find_button("Save changes").hover
    expect(find_button("Save changes")).to_not have_tooltip(text: "Files are still uploading...")
    toggle_disclosure "Upload files"
    within find_embed(name: "Alice's Adventures in Wonderland") do
      click_on "Edit"
      check("Stamp this PDF with buyer information")
    end
    save_change

    @product = Link.find(@product.id)
    expect(@product.has_stampable_pdfs?).to eq(true)
    expect(@product.product_files.last.pdf_stamp_enabled?).to eq(true)

    visit edit_link_path(@product.unique_permalink) + "/content"
    within find_embed(name: "Alice's Adventures in Wonderland") do
      click_on "Edit"
      uncheck("Stamp this PDF with buyer information")
    end
    save_change

    @product = Link.find(@product.id)
    expect(@product.has_stampable_pdfs?).to eq(false)
    expect(@product.product_files.last.pdf_stamp_enabled?).to eq(false)
  end

  it "allows to mark video files as stream-only" do
    visit edit_link_path(@product.unique_permalink) + "/content"
    select_disclosure "Upload files" do
      attach_product_file(file_fixture("sample.mov"))
    end
    wait_for_file_embed_to_finish_uploading(name: "sample")
    within find_embed(name: "sample") do
      click_on "Edit"
      check("Disable file downloads (stream only)")
    end
    save_change

    @product = Link.find(@product.id)
    expect(@product.has_stream_only_files?).to eq(true)
    expect(@product.product_files.last.stream_only?).to eq(true)

    visit @product.long_url
    expect(page).to have_text("Watch link provided after purchase")

    visit edit_link_path(@product.unique_permalink) + "/content"
    within find_embed(name: "sample") do
      click_on "Edit"
      uncheck("Disable file downloads (stream only)")
    end
    save_change

    @product = Link.find(@product.id)
    expect(@product.has_stream_only_files?).to eq(false)
    expect(@product.product_files.last.stream_only?).to eq(false)

    visit @product.long_url
    expect(page).to have_text("Watch link provided after purchase")
  end

  it "displays file size after save properly" do
    @product.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
    visit edit_link_path(@product.unique_permalink) + "/content"
    select_disclosure "Upload files" do
      attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
    end
    wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")
    expect(page).to have_embed(name: "Alice's Adventures in Wonderland")
    save_change
    within find_embed(name: "Alice's Adventures in Wonderland") do
      expect(page).to have_text "201.3 KB"
    end
  end

  it "displays file extension" do
    @product.product_files << create(:readable_document, display_name: "Book")
    @product.product_files << create(:listenable_audio, display_name: "Music")
    @product.product_files << create(:streamable_video, display_name: "Video")
    create(:rich_content, entity: @product, description: @product.product_files.alive.map { { "type" => "fileEmbed", "attrs" => { "id" => _1.external_id, "uid" => SecureRandom.uuid } } })
    visit edit_link_path(@product.unique_permalink) + "/content"

    within find_embed(name: "Book") do
      expect(page).to have_text("PDF")
    end
    within find_embed(name: "Music") do
      expect(page).to have_text("MP3")
    end
    within find_embed(name: "Video") do
      expect(page).to have_text("MOV")
    end
  end

  it "allows users to upload subtitles with special characters in filenames" do
    allow(Aws::S3::Resource).to receive(:new).and_return(double(bucket: double(object: double(content_length: 1024, public_url: Addressable::URI.encode("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/0000063137454006b85553304efaffb7/original/[]&+.mp4")))))

    product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/0000063137454006b85553304efaffb7/original/[]&+.mp4")
    @product.product_files << product_file
    subtitle_file = create(:subtitle_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/111113dbf4a6428597332c8d2efb51fc/original/[]&+_subtitles.vtt")
    product_file.subtitle_files << subtitle_file
    create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product_file.external_id, "uid" => SecureRandom.uuid } }])
    visit edit_link_path(@product.unique_permalink)

    select_tab "Content"

    within find_embed(name: "[]&+") do
      click_on "Edit"
      expect(page).to have_subtitle_row(name: "[]&+_subtitles")
    end
    save_change
    refresh
    within find_embed(name: "[]&+") do
      click_on "Edit"
      expect(page).to have_subtitle_row(name: "[]&+_subtitles")
    end
  end

  describe "with video" do
    before do
      allow(Aws::S3::Resource).to receive(:new).and_return(double(bucket: double(object: double(content_length: 1024, public_url: Addressable::URI.encode("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/1111163137454006b85553304efaffb7/original/[]&+.mp4")))))

      product_file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/0000063137454006b85553304efaffb7/original/[]&+.mp4")
      @product.product_files << product_file
      @rich_content = create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product_file.external_id, "uid" => SecureRandom.uuid } }])
      visit edit_link_path(@product.unique_permalink) + "/content"
    end

    context "when uploading a valid subtitle file type" do
      it "displays the subtitle file and allows changing its language" do
        within find_embed(name: "[]&+") do
          click_on "Edit"
          page.attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.srt"), visible: false)
          expect(page).to have_subtitle_row(name: "sample")
          expect(page).to have_select("Language", selected: "English")
          select "Español", from: "Language"
        end
        wait_for_ajax
        save_change
        refresh
        within find_embed(name: "[]&+") do
          click_on "Edit"
          expect(page).to have_subtitle_row(name: "sample")
          expect(page).to have_select("Language", selected: "Español")
        end
      end
    end

    context "when uploading an invalid subtitle file type" do
      it "displays a flash error message" do
        within find_embed(name: "[]&+") do
          click_on "Edit"
          page.attach_file("Add subtitles", Rails.root.join("spec/support/fixtures/sample.gif"), visible: false)
        end
        wait_for_ajax
        expect(page).to have_alert(text: "Invalid file type.")
        within find_embed(name: "[]&+") do
          expect(page).to_not have_subtitle_row(name: "sample")
        end
      end
    end

    # Backwards compatibility test for existing products with invalid subtitle file types
    context "when an invalid subtitle file type" do
      before do
        @product = create(:product, user: seller)
        video_path = "attachments/43a5363194e74e9ee75b6203eaea6705/original/chapter2.mp4"
        video_uri = URI.parse("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{video_path}").to_s
        video_product_file = create(:product_file, url: video_uri.to_s)
        @product.product_files = [video_product_file]
        pdf_path = "attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/test.pdf"
        pdf_uri = URI.parse("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{pdf_path}").to_s
        subtitle_file = build(:subtitle_file, url: pdf_uri.to_s, product_file_id: video_product_file.id)
        # Skip subtitle validation to allow saving an invalid file type
        subtitle_file.save!(validate: false)
        create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => video_product_file.external_id, "uid" => SecureRandom.uuid } }])

        s3_res_double = double
        bucket_double = double
        @s3_object_double = double
        allow(Aws::S3::Resource).to receive(:new).times.and_return(s3_res_double)
        allow(s3_res_double).to receive(:bucket).times.and_return(bucket_double)
        allow(bucket_double).to receive(:object).times.and_return(@s3_object_double)
        allow(@s3_object_double).to receive(:content_length).times.and_return(1)
        allow(@s3_object_double).to receive(:public_url).times.and_return(video_uri)

        visit edit_link_path(@product.unique_permalink) + "/content"
        within find_embed(name: "chapter2") do
          click_on "Edit"
          expect(page).to have_subtitle_row(name: "test")
        end
      end

      it "displays a subtitle error message when saving a product with an invalid subtitle file type" do
        fill_in "Name", with: "some other text so that the file is marked as `modified` and does not get ignored on 'Save Changes'"
        save_change(expect_message: "Subtitle type not supported. Please upload only subtitles with extension .srt, .sub, .sbv, or .vtt.")
      end

      it "saves the product after removing the invalid subtitle file" do
        within_fieldset "Subtitles" do
          click_on "Remove"
        end
        save_change
      end
    end
  end

  it "updates a file's name, description, and ISBN right away" do
    product = create(:product, user: seller)
    product.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/jimbo.pdf")
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
    visit edit_link_path(product.unique_permalink) + "/content"
    expect(product.product_files.first.name_displayable).to eq "jimbo"
    rename_file_embed from: "jimbo", to: "jimmy"
    within find_embed(name: "jimmy") do
      click_on "Edit"
      fill_in "Description", with: "brand-new jimmy"
      fill_in "ISBN", with: "978-3-16-148410-0"
    end
    save_change
    product.reload
    expect(product.product_files.first.name_displayable).to eq "jimmy"
    expect(product.product_files.first.description).to eq "brand-new jimmy"
    expect(product.product_files.first.isbn).to eq "978-3-16-148410-0"
  end

  it "shows validation error when ISBN isn't valid" do
    product = create(:product, user: seller)
    product.product_files << create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/jimbo.pdf")
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
    visit edit_link_path(product.unique_permalink) + "/content"
    within find_embed(name: "jimbo") do
      click_on "Edit"
      fill_in "ISBN", with: "invalid isbn"
    end
    click_on "Save changes"
    wait_for_ajax
    expect(page).to have_alert(text: "Validation failed: Isbn is not a valid ISBN-10 or ISBN-13")
  end

  it "allows to rename files multiple times", :sidekiq_inline do
    visit edit_link_path(@product.unique_permalink) + "/content"
    select_disclosure "Upload files" do
      attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
    end
    wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")
    save_change

    product_file = @product.product_files.last

    refresh

    expect do
      rename_file_embed(from: "Alice's Adventures in Wonderland", to: "new name")
      save_change

      product_file.reload
      expect(product_file.display_name).to eq("new name")
      expect(product_file.url).to match(/new name.pdf\z/)

      rename_file_embed(from: "new name", to: "newest name")
      save_change

      product_file.reload
      expect(product_file.display_name).to eq("newest name")
      expect(product_file.url).to match(/newest name.pdf\z/)

      refresh
      expect(page).to have_embed(name: "newest name")
    end.not_to change(ProductFile, :count)
  end

  it "allows to rename files even if filenames have special characters [, ], &, +" do
    allow(Aws::S3::Resource).to receive(:new).and_return(double(bucket: double(object: double(content_length: 1024, public_url: Addressable::URI.encode("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/0000063137454006b85553304efaffb7/original/[]&+.mp4")))))

    product_file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/0000063137454006b85553304efaffb7/original/[]&+.mp4")
    create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => product_file.external_id, "uid" => SecureRandom.uuid } }])
    visit edit_link_path(@product.unique_permalink) + "/content"

    rename_file_embed(from: "[]&+", to: "[]&+new")
    save_change
    refresh
    expect(page).to have_embed(name: "[]&+new")
    expect(product_file.reload.display_name).to eq("[]&+new")
  end

  it "supports playing video embeds" do
    product = create(:product, user: seller)
    video = create(:streamable_video, link: product, display_name: "Pilot Episode")
    create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => video.external_id, "uid" => SecureRandom.uuid } }])

    visit edit_link_path(product)

    select_tab "Content"

    within find_embed(name: "Pilot Episode") do
      expect(page).to have_field("Upload a thumbnail", visible: false)
      expect(page).to have_text("The thumbnail image is shown as a preview in the embedded video player.")
      expect(page).to have_selector("[role=separator]")
      expect(page).to have_button("Generate a thumbnail")
      expect(page).to_not have_button("Watch")

      click_on "Edit"
      fill_in "Description", with: "Episode 1 description"
      click_on "Close drawer"
      expect(page).to have_text("Episode 1 description")
    end

    select_disclosure "Upload files" do
      attach_product_file(file_fixture("sample.mov"))
    end
    wait_for_file_embed_to_finish_uploading(name: "sample")
    sleep 0.5 # wait for the editor to update the content

    within(find_embed(name: "sample")) do
      click_on "Watch"
      expect(page).to_not have_button("Watch")
      expect(page).to have_button("Pause")
      expect(page).to have_button("Rewind 10 Seconds")
    end

    save_change
    refresh

    video_blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "ScreenRecording.mov"), "video/quicktime"), filename: "ScreenRecording.mov", key: "test/ScreenRecording.mov")

    within(find_embed(name: "sample")) do
      file = ProductFile.last
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(
        file.s3_key, file.s3_filename, is_video: true
      ).and_return(video_blob.url)
      click_on "Watch"
      expect(page).to_not have_button("Watch")
      expect(page).to have_button("Pause")
      expect(page).to have_button("Rewind 10 Seconds")
    end
  end

  it "auto-creates a file grouping when multiple files are uploaded simultaneously" do
    product = create(:product, user: seller)
    visit edit_link_path(product)

    select_tab "Content"

    select_disclosure "Upload files" do
      attach_product_file([
                            file_fixture("test.mp3"),
                            file_fixture("Alice's Adventures in Wonderland.pdf")
                          ])
    end
    sleep 0.5 # wait for the editor to update the content
    send_keys :enter
    within_file_group "Untitled" do
      expect(page).to have_embed(name: "test")
      expect(page).to have_embed(name: "Alice's Adventures in Wonderland")
    end

    within find_embed(name: "test") do
      click_on "Edit"
      fill_in "Description", with: "Pilot episode"
      click_on "Close drawer"
      expect(page).to have_text("Pilot episode")
    end
  end

  it "supports collapsing video thumbnails" do
    product = create(:product, user: seller)
    thumbnail = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
    video1 = create(:streamable_video, link: product, display_name: "Pilot Episode", thumbnail:)
    video2 = create(:streamable_video, link: product, display_name: "Second Episode")
    create(:rich_content, entity: product, description: [
             { "type" => "fileEmbed", "attrs" => { "id" => video1.external_id, "uid" => SecureRandom.uuid } },
             { "type" => "fileEmbed", "attrs" => { "id" => video2.external_id, "uid" => SecureRandom.uuid } },
           ])

    visit edit_link_path(product)
    select_tab "Content"

    find_embed(name: "Pilot Episode").click

    within find_embed(name: "Pilot Episode") do
      click_on "Thumbnail view"
      click_on "Collapse selected"
      expect(page).not_to have_selector("figure")
    end

    within find_embed(name: "Second Episode") do
      expect(page).to have_button("Generate a thumbnail")
    end

    within find_embed(name: "Pilot Episode") do
      click_on "Thumbnail view"
      click_on "Expand selected"
      expect(page).to have_selector("figure")
    end

    within find_embed(name: "Pilot Episode") do
      click_on "Thumbnail view"
      click_on "Collapse all thumbnails"
      expect(page).not_to have_selector("figure")
      expect(page).to have_image(src: video1.thumbnail_url)
    end

    within find_embed(name: "Second Episode") do
      expect(page).not_to have_button("Generate a thumbnail")
    end

    within find_embed(name: "Pilot Episode") do
      click_on "Thumbnail view"
      expect(page).to have_menuitem("Expand all thumbnails")
    end
  end

  context "file downloads" do
    it "displays inline download buttons for files before and after saving" do
      product = create(:product, user: seller)
      visit edit_link_path(product)

      select_tab "Content"

      select_disclosure "Upload files" do
        attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
      end
      wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")
      sleep 0.5 # wait for the editor to update the content

      within(find_embed(name: "Alice's Adventures in Wonderland")) do
        expect(page).to have_link("Download")
      end

      save_change
      refresh

      within(find_embed(name: "Alice's Adventures in Wonderland")) do
        file = ProductFile.last
        expect(page).to have_link("Download", href: download_product_files_path({ product_file_ids: [file.external_id], product_id: product.external_id }))
        expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(
          file.s3_key, file.s3_filename, is_video: false
        ).and_return("https://example.com/file.srt")
        click_on "Download"
      end
    end

    it_behaves_like "a product with 'Download all' buttons on file embed groups" do
      let!(:product) { @product }
      let!(:url_redirect) { nil }
      let!(:url) { edit_link_path(@product.unique_permalink) + "/content" }
    end

    it "displays download buttons for video embeds before and after saving" do
      product = create(:product, user: seller)
      visit edit_link_path(product)

      select_tab "Content"

      select_disclosure "Upload files" do
        attach_product_file(file_fixture("sample.mov"))
      end
      wait_for_file_embed_to_finish_uploading(name: "sample")
      sleep 0.5 # wait for the editor to update the content

      within(find_embed(name: "sample")) do
        click_link "Download"
      end

      save_change
      refresh

      within(find_embed(name: "sample")) do
        file = ProductFile.last
        expect(page).to have_link("Download", href: download_product_files_path({ product_file_ids: [file.external_id], product_id: product.external_id }))
        expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(
          file.s3_key, file.s3_filename, is_video: true
        ).and_return("https://example.com/sample.mov")
        click_on "Download"
      end
    end
  end

  it "allows copy-pasting content with file embeds from one product to another" do
    file1 = create(:product_file, display_name: "File 1")
    file2 = create(:product_file, display_name: "File 2")
    file3 = create(:product_file, display_name: "File 3")
    folder_uid = SecureRandom.uuid
    product1_description = [
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Paragraph 1" }] },
      { "type" => "fileEmbedGroup",
        "attrs" => { "name" => "My folder", "uid" => folder_uid },
        "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid, "collapsed" => false } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid, "collapsed" => false } },
        ] },
      { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Paragraph 2" }] },
      { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid, "collapsed" => false } }
    ]
    product1 = create(:product, user: seller)
    product1.product_files = [file1, file2, file3]
    create(:rich_content, entity: product1, description: product1_description)
    product2 = create(:product, user: seller)

    visit edit_link_path(product1)
    select_tab "Content"
    editor = find("[aria-label='Content editor']")
    rich_text_editor_select_all editor
    editor.native.send_keys(ctrl_key, "c")

    visit edit_link_path(product2)
    select_tab "Content"
    editor = find("[aria-label='Content editor']")
    rich_text_editor_select_all editor
    editor.native.send_keys(ctrl_key, "v")
    sleep 0.5 # Wait for the editor to update the content

    expect(page).to have_text("Paragraph 1")
    expect(page).to have_text("Paragraph 2")
    expect(page).to have_embed(name: "File 3")
    toggle_file_group "My folder"
    within_file_group "My folder" do
      expect(page).to have_embed(name: "File 1")
      expect(page).to have_embed(name: "File 2")
    end

    save_change

    product2_file1 = product2.product_files.find_by(display_name: "File 1")
    product2_file2 = product2.product_files.find_by(display_name: "File 2")
    product2_file3 = product2.product_files.find_by(display_name: "File 3")
    expected_product2_description = product1_description.deep_dup
    expected_product2_description[1]["content"][0]["attrs"]["id"] = product2_file1.external_id
    expected_product2_description[1]["content"][1]["attrs"]["id"] = product2_file2.external_id
    expected_product2_description[3]["attrs"]["id"] = product2_file3.external_id
    expect(product2.rich_contents.sole.description).to eq(expected_product2_description)
  end

  it "allows embedding the same existing files that were uploaded and saved to another version" do
    product = create(:product_with_digital_versions, user: seller)
    visit edit_link_path(product)

    select_tab "Content"

    select_disclosure "Upload files" do
      attach_product_file(file_fixture("Alice's Adventures in Wonderland.pdf"))
    end
    wait_for_file_embed_to_finish_uploading(name: "Alice's Adventures in Wonderland")
    save_change

    expect(page).to have_combo_box("Select a version", text: "Editing: Untitled 1")
    select_combo_box_option("Untitled 2", from: "Select a version")
    expect(page).to_not have_embed(name: "Alice's Adventures in Wonderland")

    select_disclosure "Upload files" do
      click_on "Existing product files"
    end

    within_modal "Select existing product files" do
      expect(page).to have_text("Alice's Adventures in Wonderland")
      check "Alice's Adventures in Wonderland"
      click_on "Select"
    end

    expect(page).to have_embed(name: "Alice's Adventures in Wonderland")
    save_change

    product.reload
    product_file_ids = product.alive_product_files.map(&:external_id)
    expect(product_file_ids.size).to eq(2)
    expect(product_file_ids).to include(product.alive_variants.find_by(name: "Untitled 1").alive_rich_contents.sole.description.first["attrs"]["id"])
    expect(product_file_ids).to include(product.alive_variants.find_by(name: "Untitled 2").alive_rich_contents.sole.description.first["attrs"]["id"])
  end
end
