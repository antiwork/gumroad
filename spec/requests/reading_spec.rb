# frozen_string_literal: true

require("spec_helper")

describe "Reading Scenario", type: :system, js: true do
  before do
    @url_redirect = create(:readable_url_redirect)
    @product = @url_redirect.referenced_link
    login_as(@url_redirect.purchase.purchaser)
    Link.import(refresh: true)
  end

  describe "read button" do
    describe "for a link with a product file" do
      it "is present when url is a pdf" do
        allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
        Link.import(refresh: true)
        visit("/library")
        find_product_card(@product).click
        expect(page).to have_link("Read")
      end

      context "for a product file with a pdf url" do
        it "shows read button for a file which has not been read" do
          allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
          visit("/d/#{@url_redirect.token}")
          expect(page).to have_link("Read")
        end

        it "shows read again button for a file which has been read completely" do
          create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                  product_file_id: @product.product_files.first.id,
                                  product_id: @product.id, location: 6)
          allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
          visit("/d/#{@url_redirect.token}")
          expect(page).to have_link("Read again")
        end
      end

      it "is absent for product files with non-pdf urls" do
        @product.product_files.delete_all
        create(:non_readable_document, :analyze, link: @product)
        allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
        visit("/d/#{@url_redirect.token}")
        expect(page).to_not have_link("Read")
      end
    end
  end

  describe "consumption progress pie" do
    it "does not show progress pie if not started reading" do
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_selector("[role='progressbar']")
    end

    it "shows progress pie if reading in progress" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 1)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar']")
    end

    it "shows completed progress pie if reading is done" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 6)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar'][aria-valuenow='100']")
    end
  end

  describe "readable document" do
    it "shows the proper layout for a PDF" do
      file = @product.product_files.first
      allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(file.url)
      visit("/read/#{@url_redirect.token}/#{file.external_id}")
      expect(page).to have_text("One moment while we prepare your reading experience")
      expect(page).to have_text("Building a billion-dollar company.")
    end
  end

  describe "resuming from previous location" do
    it "starts from first page if no media_location is present" do
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
      expect(page).to have_content("1 of 6")
    end

    it "uses cookie if media_location only available in cookie" do
      visit("/read/fake_url_redirect_id/fake_read_id")
      cookie_id = CGI.escape(@product.product_files.first.external_id)
      browser = Capybara.current_session.driver.browser
      browser.manage.delete_cookie(cookie_id)
      browser.manage.add_cookie(name: cookie_id, value: { location: 3, timestamp: Time.current }.to_json)

      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
      expect(page).to have_content("3 of 6")
    end

    it "uses backend if media_location only available in backend" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id, product_id: @product.id, location: 2)
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
      expect(page).to have_content("2 of 6")
    end

    context "media_location available in both backend and cookie" do
      it "uses backend location if backend media_location is latest one" do
        timestamp = Time.current
        visit("/read/fake_url_redirect_id/fake_read_id")
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, consumed_at: timestamp + 1.second,
                                product_file_id: @product.product_files.first.id, product_id: @product.id, location: 2)
        cookie_id = CGI.escape(@url_redirect.external_id)
        browser = Capybara.current_session.driver.browser
        browser.manage.delete_cookie(cookie_id)
        browser.manage.add_cookie(name: cookie_id, value: { location: 3, timestamp: }.to_json)

        expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
        visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
        expect(page).to have_content("2 of 6")
      end

      it "uses cookie location if cookie media_location is latest one" do
        timestamp = Time.current
        visit("/read/fake_url_redirect_id/fake_read_id")
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id, consumed_at: timestamp,
                                product_file_id: @product.product_files.first.id, product_id: @product.id, location: 2)
        cookie_id = CGI.escape(@product.product_files.first.external_id)
        browser = Capybara.current_session.driver.browser
        browser.manage.delete_cookie(cookie_id)
        browser.manage.add_cookie(name: cookie_id, value: { location: 3, timestamp: timestamp + 1.second }.to_json)

        expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
        visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
        expect(page).to have_content("3 of 6")
      end
    end

    it "resumes from start if reading was complete as per media_location in backend" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id, product_id: @product.id, location: 6)
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
      expect(page).to have_content("1 of 6")
    end

    it "resumes from start if reading was complete as per media_location in cookie" do
      visit("/read/fake_url_redirect_id/fake_read_id")
      cookie_id = CGI.escape(@url_redirect.external_id)
      browser = Capybara.current_session.driver.browser
      browser.manage.delete_cookie(cookie_id)
      browser.manage.add_cookie(name: cookie_id, value: { location: 6, timestamp: Time.current }.to_json)
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/read/#{@url_redirect.token}/#{@product.product_files.first.external_id}")
      expect(page).to have_content("1 of 6")
    end
  end

  describe "readable document consumption analytics", type: :system, js: true do
    it "does not record media_location if purchase is nil" do
      readable_url = "https://s3.amazonaws.com/gumroad-specs/specs/billion-dollar-company-chapter-0.pdf"
      installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.gum.co", seller: @product.user)
      installment_product_file = create(:product_file, :analyze, installment:, url: readable_url)
      no_purchase_url_redirect = installment.generate_url_redirect_for_follower
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(readable_url)
      visit("/read/#{no_purchase_url_redirect.token}/#{installment_product_file.external_id}")
      expect(page).to have_content("1 of 6")
      wait_for_ajax
      expect(MediaLocation.count).to eq 0
    end

    it "records the proper consumption analytics for the pdf file" do
      file = @product.product_files.first
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(file.url)
      visit("/read/#{@url_redirect.token}/#{file.external_id}")
      expect(page).to have_content("1 of 6")

      # Wait until js has made async calls for tracking read consumptions.
      wait_for_ajax
      expect(ConsumptionEvent.count).to eq 1

      read_event = ConsumptionEvent.first
      expect(read_event.event_type).to eq ConsumptionEvent::EVENT_TYPE_READ
      expect(read_event.link_id).to eq @product.id
      expect(read_event.product_file_id).to eq file.id
      expect(read_event.url_redirect_id).to eq @url_redirect.id
      expect(read_event.ip_address).to eq "127.0.0.1"

      expect(MediaLocation.count).to eq 1
      media_location = MediaLocation.last
      expect(media_location.product_id).to eq @product.id
      expect(media_location.product_file_id).to eq file.id
      expect(media_location.url_redirect_id).to eq @url_redirect.id
      expect(media_location.location).to eq 1
      expect(media_location.unit).to eq MediaLocation::Unit::PAGE_NUMBER
    end
  end

  describe "redirect" do
    it "redirects to library if no token" do
      visit("/read")
      expect(page).to have_section("Library", section_element: :header)
    end
  end
end
