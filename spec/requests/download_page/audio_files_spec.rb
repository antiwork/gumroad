# frozen_string_literal: true

require("spec_helper")

describe("Download Page Audio files", type: :system, js: true) do
  before do
    @url_redirect = create(:listenable_url_redirect)
    @product = @url_redirect.referenced_link
    login_as(@url_redirect.purchase.purchaser)
    Link.import(refresh: true)
  end

  describe "Play button" do
    it "shows Play button" do
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_button("Play")
    end

    it "hides Play button on click and shows Close button" do
      allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_button("Play")
      click_button("Play")
      expect(page).to have_button("Close")
    end

    it "shows Play again button for a file which has been listened to completely" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 46)
      allow_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).and_return(@product.product_files.first.url)
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_button("Play again")
    end

    it "is absent for product files with non-listenable urls" do
      @product.product_files.delete_all
      create(:non_listenable_audio, :analyze, link: @product)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_button("Play")
    end
  end

  describe "consumption progress pie" do
    it "does not show progress pie if not started listening" do
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_selector("[role='progressbar']")
    end

    it "shows progress pie if listening in progress" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 10)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar'][aria-valuenow='#{(1000.0 / 46).round(2)}']")
    end

    it "shows completed progress pie if listening is done" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 46)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar'][aria-valuenow='100']")
    end
  end

  describe "listening to a file" do
    before do
      url = @product.product_files.first.url
      allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).and_return(url)
    end

    it "shows the audio player on clicking Play" do
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_selector("[aria-label='Rewind15']")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Rewind15']")
    end

    it "closes audio player on clicking Close" do
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_selector("[aria-label='Rewind15']")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Rewind15']")
      click_button("Close")
      expect(page).to_not have_selector("[aria-label='Rewind15']")
    end

    it "resumes from previous location if media_location exists" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id, product_id: @product.id, location: 23)
      visit("/d/#{@url_redirect.token}")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:23")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:25")
    end

    it "resumes from start if listening was complete" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id, product_id: @product.id, location: 46)
      visit("/d/#{@url_redirect.token}")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:00")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
    end

    it "pauses the player on clicking the pause icon" do
      visit("/d/#{@url_redirect.token}")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
      find_and_click("[aria-label='Pause']")
      expect(page).to have_selector("[aria-label='Play']")
      expect(page).to_not have_selector("[aria-label='Pause']")
    end

    it "rewind button rewinds the playback by 15 seconds" do
      visit("/d/#{@url_redirect.token}")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
      find_and_click("[aria-label='Pause']")
      progress_text = find("[aria-label='Progress']").text
      progress_seconds = progress_text[3..5].to_i
      find_and_click("[aria-label='Skip30']")
      find_and_click("[aria-label='Rewind15']")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:#{(progress_seconds + 15).to_s.rjust(2, "0")}")
      find_and_click("[aria-label='Rewind15']")
      expect(page).to have_selector("[aria-label='Progress']", text: progress_text)
    end

    it "skip button forwards playback by 30 seconds" do
      visit("/d/#{@url_redirect.token}")
      click_button("Play")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
      find_and_click("[aria-label='Pause']")
      progress_text = find("[aria-label='Progress']").text
      progress_seconds = progress_text[3..5].to_i
      find_and_click("[aria-label='Skip30']")
      expect(page).to have_selector("[aria-label='Progress']", text: "00:#{(progress_seconds + 30).to_s.rjust(2, "0")}")
    end

    context "multiple audio players" do
      before do
        @listenable2 = create(:listenable_audio, :analyze, link: @product)
        @listenable3 = create(:listenable_audio, :analyze, link: @product)
        allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).and_return(@product.product_files.first.url)
      end

      it "pauses other audio players on play" do
        visit("/d/#{@url_redirect.token}")

        page.all("[aria-label='Play Button']")[0].click
        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")

        page.all("[aria-label='Play Button']")[1].click
        progress_text_0 = page.all("[aria-label='Progress']")[0].text
        progress_seconds_0 = progress_text_0[3..5].to_i
        expect(page).to have_selector("[aria-label='Play']")
        expect(page).to have_selector("[aria-label='Pause']")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:#{(progress_seconds_0 + 1).to_s.rjust(2, "0")}")

        page.all("[aria-label='Play Button']")[2].click
        progress_text_1 = page.all("[aria-label='Progress']")[1].text
        progress_seconds_1 = progress_text_1[3..5].to_i
        expect(page).to have_selector("[aria-label='Play']", count: 2)
        expect(page).to have_selector("[aria-label='Pause']")
        expect(page).to have_selector("[aria-label='Progress']", text: "00:#{(progress_seconds_1 + 1).to_s.rjust(2, "0")}")

        expect(page).to have_selector("[aria-label='Progress']", text: progress_text_1)
        expect(page).to have_selector("[aria-label='Progress']", text: progress_text_0)
      end
    end

    context "triggers the correct consumption events" do
      it "creates consumption events on viewing the page and playing an audio file" do
        expect do
          visit("/d/#{@url_redirect.token}")
        end.to change(ConsumptionEvent, :count).by(1)
        download_event = ConsumptionEvent.last
        expect(download_event.event_type).to eq ConsumptionEvent::EVENT_TYPE_VIEW
        expect(download_event.link_id).to eq @product.id
        expect(download_event.product_file_id).to be_nil
        expect(download_event.url_redirect_id).to eq @url_redirect.id
        expect(download_event.ip_address).to eq "127.0.0.1"

        expect do
          click_button("Play")
          expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
          find_and_click("[aria-label='Pause']")
        end.to change(ConsumptionEvent, :count).by(1)

        listen_event = ConsumptionEvent.last
        expect(listen_event.event_type).to eq ConsumptionEvent::EVENT_TYPE_LISTEN
        expect(listen_event.link_id).to eq @product.id
        expect(listen_event.product_file_id).to eq @product.product_files.first.id
        expect(listen_event.url_redirect_id).to eq @url_redirect.id
        expect(listen_event.ip_address).to eq "127.0.0.1"
      end

      it "does not record media_location if purchase is nil" do
        listenable_url = "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3"
        installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.gum.co", seller: @product.user)
        create(:product_file, :analyze, installment:, url: listenable_url)
        no_purchase_url_redirect = installment.generate_url_redirect_for_follower
        visit("/d/#{no_purchase_url_redirect.token}")
        click_button("Play")

        expect(page).to have_selector("[aria-label='Progress']", text: "00:01")
        find_and_click("[aria-label='Pause']")

        wait_for_ajax
        expect(MediaLocation.count).to eq 0
      end

      it "creates listen progress location on continuing playback audio file" do
        visit("/d/#{@url_redirect.token}")
        click_button("Play")

        expect(page).to have_selector("[aria-label='Progress']", text: "00:05")
        find_and_click("[aria-label='Pause']")

        wait_for_ajax

        media_location = MediaLocation.last
        expect(media_location.product_id).to eq @product.id
        expect(media_location.product_file_id).to eq @product.product_files.first.id
        expect(media_location.url_redirect_id).to eq @url_redirect.id
        expect(media_location.location).to be < 3
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end

      it "updates watch progress on completion of stream with the backend duration" do
        @product.product_files.first.update!(duration: 1000)
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                product_file_id: @product.product_files.first.id,
                                product_id: @product.id, location: 45)

        visit("/d/#{@url_redirect.token}")
        click_button("Play")

        expect(page).to have_selector("[aria-label='Play']")

        wait_for_ajax
        sleep 5

        expect(MediaLocation.count).to eq 1

        media_location = MediaLocation.last
        expect(media_location.product_id).to eq @product.id
        expect(media_location.product_file_id).to eq @product.product_files.first.id
        expect(media_location.url_redirect_id).to eq @url_redirect.id
        expect(media_location.location).to eq(1000)
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end
    end
  end
end
