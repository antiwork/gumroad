# frozen_string_literal: true

require "spec_helper"

describe "WebP and WebM Support", type: :feature, js: true do
  let(:seller) { create(:named_seller) }
  let(:user) { create(:named_user) }
  let!(:product) { create(:product_with_pdf_file, user: seller, size: 1024) }

  before do
    product.shipping_destinations << ShippingDestination.new(
      country_code: Product::Shipping::ELSEWHERE,
      one_item_rate_cents: 0,
      multiple_items_rate_cents: 0
    )
  end

  describe "Thumbnail Uploads" do
    include_context "with switching account to user as admin for seller"

    it "accepts WebP images for thumbnails" do
      visit("/products/#{product.unique_permalink}/edit")

      within_section "Thumbnail", section_element: :section do
        page.attach_file("Upload", file_fixture("test.webp"), visible: false)
        expect(page).to have_selector("[role=progressbar]")
        wait_for_ajax
        expect(page).to_not have_selector("[role=progressbar]")
        expect(page).to have_image("Thumbnail image", src: product.reload.thumbnail.url)
      end
      expect(page).to have_no_alert
      expect(product.reload.thumbnail).to be_present
    end

    it "accepts WebM videos without audio for thumbnails" do
      visit("/products/#{product.unique_permalink}/edit")

      within_section "Thumbnail", section_element: :section do
        page.attach_file("Upload", file_fixture("test.webm"), visible: false)
        expect(page).to have_selector("[role=progressbar]")
        wait_for_ajax
        expect(page).to_not have_selector("[role=progressbar]")
        expect(page).to have_image("Thumbnail image", src: product.reload.thumbnail.url)
      end
      expect(page).to have_no_alert
      expect(product.reload.thumbnail).to be_present
    end

    it "rejects WebM videos with audio for thumbnails" do
      # Mock the audio check to return true (has audio)
      allow_any_instance_of(Thumbnail).to receive(:check_video_has_audio).and_return(true)

      visit("/products/#{product.unique_permalink}/edit")

      within_section "Thumbnail", section_element: :section do
        page.attach_file("Upload", file_fixture("test.webm"), visible: false)
      end
      expect(page).to have_alert(text: "WebM files must not contain audio.")
    end
  end

  describe "OAuth Application Icons" do
    before do
      login_as user
      visit settings_advanced_path
    end

    it "accepts WebP images for OAuth application icons" do
      expect do
        within_section "Applications", section_element: :section do
          fill_in("Application name", with: "test")
          fill_in("Redirect URI", with: "http://l.h:9292/callback")
          page.attach_file(file_fixture("test.webp")) do
            click_on "Upload icon"
          end
          expect(page).to have_button("Upload icon")
          expect(page).to have_selector("img[src*='s3_utility/cdn_url_for_blob?key=#{ActiveStorage::Blob.last.key}']")
          click_button("Create application")
        end
        wait_for_ajax
      end.to change { OauthApplication.count }.by(1)

      OauthApplication.last.tap do |app|
        expect(app.name).to eq "test"
        expect(app.file.filename.to_s).to eq "test.webp"
        expect(app.owner).to eq user
      end
    end

    it "accepts WebM videos without audio for OAuth application icons" do
      expect do
        within_section "Applications", section_element: :section do
          fill_in("Application name", with: "test")
          fill_in("Redirect URI", with: "http://l.h:9292/callback")
          page.attach_file(file_fixture("test.webm")) do
            click_on "Upload icon"
          end
          expect(page).to have_button("Upload icon")
          expect(page).to have_selector("img[src*='s3_utility/cdn_url_for_blob?key=#{ActiveStorage::Blob.last.key}']")
          click_button("Create application")
        end
        wait_for_ajax
      end.to change { OauthApplication.count }.by(1)

      OauthApplication.last.tap do |app|
        expect(app.name).to eq "test"
        expect(app.file.filename.to_s).to eq "test.webm"
        expect(app.owner).to eq user
      end
    end

    it "rejects WebM videos with audio for OAuth application icons" do
      # Mock the audio check to return true (has audio)
      allow_any_instance_of(OauthApplication).to receive(:check_video_has_audio).and_return(true)

      within_section "Applications", section_element: :section do
        page.attach_file(file_fixture("test.webm")) do
          click_on "Upload icon"
        end
      end
      expect(page).to have_alert(text: "WebM files must not contain audio.")
    end
  end

  describe "Product Covers" do
    include_context "with switching account to user as admin for seller"

    def upload_image(filenames)
      click_on "Upload images or videos"
      page.attach_file(filenames.map { |filename| file_fixture(filename) }) do
        select_tab "Computer files"
      end
    end

    it "accepts WebP images for product covers" do
      visit edit_link_path(product.unique_permalink)
      upload_image(["test.webp"])
      wait_for_ajax
      sleep 1

      within_section "Cover", section_element: :section do
        expect(page).to have_selector("button[role='tab']", count: 1)
      end
    end

    it "accepts WebM videos without audio for product covers" do
      visit edit_link_path(product.unique_permalink)
      upload_image(["test.webm"])
      wait_for_ajax
      sleep 1

      within_section "Cover", section_element: :section do
        expect(page).to have_selector("button[role='tab']", count: 1)
      end
    end

    it "rejects WebM videos with audio for product covers" do
      # Mock the audio check to return true (has audio)
      allow_any_instance_of(Cover).to receive(:check_video_has_audio).and_return(true)

      visit edit_link_path(product.unique_permalink)
      upload_image(["test.webm"])
      expect(page).to have_alert(text: "WebM files must not contain audio.")
    end

    it "allows mixing WebP, WebM, and traditional formats" do
      visit edit_link_path(product.unique_permalink)
      upload_image(["test.webp", "test.webm", "test.png", "test.jpg"])
      wait_for_ajax
      sleep 1

      within_section "Cover", section_element: :section do
        expect(page).to have_selector("button[role='tab']", count: 4)
      end
    end
  end

  describe "File Validation" do
    it "validates WebP file dimensions correctly" do
      thumbnail = Thumbnail.new(product: product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webp"), filename: "test.webp")
      blob.analyze
      thumbnail.file.attach(blob)
      expect(thumbnail.save).to eq(true)
      expect(thumbnail.errors.full_messages).to be_empty
    end

    it "validates WebM file dimensions correctly" do
      thumbnail = Thumbnail.new(product: product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webm"), filename: "test.webm")
      blob.analyze
      thumbnail.file.attach(blob)
      expect(thumbnail.save).to eq(true)
      expect(thumbnail.errors.full_messages).to be_empty
    end

    it "validates OAuth application WebP files" do
      app = OauthApplication.new(name: "test", redirect_uri: "http://test.com", owner: user)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webp"), filename: "test.webp")
      blob.analyze
      app.file.attach(blob)
      expect(app.save).to eq(true)
      expect(app.errors.full_messages).to be_empty
    end

    it "validates OAuth application WebM files" do
      app = OauthApplication.new(name: "test", redirect_uri: "http://test.com", owner: user)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webm"), filename: "test.webm")
      blob.analyze
      app.file.attach(blob)
      expect(app.save).to eq(true)
      expect(app.errors.full_messages).to be_empty
    end
  end

  describe "URL Generation" do
    it "generates correct URLs for WebP thumbnails" do
      thumbnail = Thumbnail.new(product: product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webp"), filename: "test.webp")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!
      expect(thumbnail.url).to eq(thumbnail.file.url)
    end

    it "generates correct URLs for WebM thumbnails" do
      thumbnail = Thumbnail.new(product: product)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.webm"), filename: "test.webm")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!
      expect(thumbnail.url).to eq(thumbnail.file.url)
    end
  end
end
