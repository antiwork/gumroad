# frozen_string_literal: true

require("spec_helper")

describe "Video stream scenario", type: :system, js: true do
  before do
    @url_redirect = create(:streamable_url_redirect)
    @product = @url_redirect.referenced_link
    login_as(@url_redirect.purchase.purchaser)
    Link.import(refresh: true)
  end

  describe "Watch button" do
    it "shows Watch button for a file which has not been watched" do
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_link("Watch")
    end

    it "shows watch again button for a file which has been watched completely" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 12)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_link("Watch again")
    end

    it "is absent for product files with non-watchable urls" do
      @product.product_files.delete_all
      create(:non_streamable_video, :analyze, link: @product)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_link("Watch")
    end
  end

  describe "consumption progress pie" do
    it "does not show progress pie if not started watching" do
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to_not have_selector("[role='progressbar']")
    end

    it "shows progress pie if video has been watched partly" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 5)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar']")
    end

    it "shows completed progress pie if the complete video has been watched" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 12)
      allow(@url_redirect).to receive(:redirect_or_s3_location).and_return("fakelink")
      visit("/d/#{@url_redirect.token}")
      expect(page).to have_selector("[role='progressbar'][aria-valuenow='100']")
    end
  end

  describe "streaming a file" do
    before do
      allow_any_instance_of(UrlRedirect).to receive(:html5_video_url_and_guid_for_product_file).and_return([@product.product_files.first.url, "DONT_MATCH_THIS_GUID"])
    end

    it "shows the player for a streamable file" do
      visit("/d/#{@url_redirect.token}/")
      new_window = window_opened_by { click_on("Watch") }
      within_window new_window do
        expect(page).to have_selector(".jwplayer")
        expect(page).to have_selector("[aria-label^='Video Player']")
        click_on "Play"
        expect(page).to have_selector(".jw-text-duration", text: "00:12", visible: :all)
      end
    end

    it "resumes from previous location if media_location exists" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 6)
      visit("/s/#{@url_redirect.token}/#{@product.product_files.first.external_id}/")
      expect(page).to have_selector(".jw-text-duration", text: "00:12", visible: :all)
      click_on "Play" # need to start playback if directly going to the url as chrome blocks autoplay
      # video should start directly from 00:06
      (0..5).each do |i|
        expect(page).to_not have_selector(".jw-text-elapsed", text: "00:0#{i}", visible: :all)
      end
      expect(page).to have_selector(".jw-text-elapsed", text: "00:06", visible: :all)
      expect(page).to have_selector(".jw-text-elapsed", text: "00:07", visible: :all) # to test if it continues playing
    end

    it "resumes from start if video has been watched completely" do
      create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                              product_file_id: @product.product_files.first.id,
                              product_id: @product.id, location: 12)
      visit("/s/#{@url_redirect.token}/#{@product.product_files.first.external_id}/")
      expect(page).to have_selector(".jw-text-duration", text: "00:12", visible: :all)
      click_on "Play" # need to start playback if directly going to the url as chrome blocks autoplay
      expect(page).to have_selector(".jw-text-elapsed", text: "00:00", visible: :all)
      expect(page).to have_selector(".jw-text-elapsed", text: "00:01", visible: :all) # to test if it continues playing
    end

    context "triggers the correct consumption events" do
      it "creates consumption events on viewing the page and starting the stream" do
        expect do
          visit("/d/#{@url_redirect.token}/")
        end.to change(ConsumptionEvent, :count).by(1)
        view_event = ConsumptionEvent.last
        expect(view_event.event_type).to eq ConsumptionEvent::EVENT_TYPE_VIEW
        expect(view_event.link_id).to eq @product.id
        expect(view_event.product_file_id).to be_nil
        expect(view_event.url_redirect_id).to eq @url_redirect.id

        expect do
          new_window = window_opened_by { click_on("Watch") }
          within_window new_window do
            expect(page).to have_selector(".jwplayer")
            expect(page).to have_selector("[aria-label^='Video Player']")
            find(".jw-icon-playback", visible: :all).hover # the controls disappear otherwise, and click is flaky for visible:false

            expect(page).to have_selector(".jw-text-elapsed", text: "00:01", visible: :all) # let playback start
            find(".jw-icon-playback", visible: :all).click # Pause
          end
          # Wait until js has made async calls for tracking listen consumptions.
          wait_for_ajax
        end.to change(ConsumptionEvent, :count).by(1)

        watch_event = ConsumptionEvent.last
        expect(watch_event.event_type).to eq ConsumptionEvent::EVENT_TYPE_WATCH
        expect(watch_event.link_id).to eq @product.id
        expect(watch_event.product_file_id).to eq @product.product_files.first.id
        expect(watch_event.url_redirect_id).to eq @url_redirect.id
      end

      it "does not record media_location if purchase is nil" do
        streamable_url = "https://s3.amazonaws.com/gumroad-specs/specs/ScreenRecording.mov"
        installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.gum.co", seller: @product.user)
        installment_product_file = create(:product_file, :analyze, installment:, url: streamable_url)
        installment_product_file.save!(validate: false)
        no_purchase_url_redirect = installment.generate_url_redirect_for_follower
        visit("/d/#{no_purchase_url_redirect.token}/")
        new_window = window_opened_by { click_on "Watch" }
        within_window new_window do
          expect(page).to have_selector(".jwplayer")
          expect(page).to have_selector("[aria-label^='Video Player']")
          find(".jw-icon-playback", visible: :all).hover

          expect(page).to have_selector(".jw-text-elapsed", text: "00:01", visible: :all)
          find(".jw-icon-playback", visible: :all).click
        end
        wait_for_ajax

        expect(MediaLocation.count).to eq 0
      end

      it "updates watch progress location on watching the stream" do
        visit("/d/#{@url_redirect.token}/")
        new_window = window_opened_by { click_on "Watch" }
        within_window new_window do
          expect(page).to have_selector(".jwplayer")
          expect(page).to have_selector("[aria-label^='Video Player']")
          find(".jw-icon-playback", visible: :all).hover # the controls disappear otherwise, and click is flaky for visible:false

          expect(page).to have_selector(".jw-text-elapsed", text: "00:04", visible: :all) # wait for 4 seconds of playback
          find(".jw-icon-playback", visible: :all).click # Pause
        end
        # Wait until js has made async calls for tracking listen consumptions.
        wait_for_ajax

        expect(MediaLocation.count).to eq 1

        media_location = MediaLocation.last
        expect(media_location.product_id).to eq @product.id
        expect(media_location.product_file_id).to eq @product.product_files.first.id
        expect(media_location.url_redirect_id).to eq @url_redirect.id
        expect(media_location.location).to be < 2
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end

      it "updates watch progress on completion of stream with the backend duration" do
        @product.product_files.first.update!(duration: 1000)
        create(:media_location, url_redirect_id: @url_redirect.id, purchase_id: @url_redirect.purchase.id,
                                product_file_id: @product.product_files.first.id,
                                product_id: @product.id, location: 10)

        visit("/d/#{@url_redirect.token}/")
        new_window = window_opened_by { click_on("Watch") }
        within_window new_window do
          expect(page).to have_selector(".jwplayer")
          expect(page).to have_selector("[aria-label^='Video Player']")

          within ".jw-display-icon-container" do
            expect(page).to have_selector("[aria-label='Replay']")
          end
          wait_for_ajax
        end

        expect(MediaLocation.count).to eq 1

        media_location = MediaLocation.last
        expect(media_location.product_id).to eq @product.id
        expect(media_location.product_file_id).to eq @product.product_files.first.id
        expect(media_location.url_redirect_id).to eq @url_redirect.id
        expect(media_location.location).to eq(1000)
        expect(media_location.unit).to eq MediaLocation::Unit::SECONDS
      end
    end

    describe "transcode on purchase" do
      before do
        @product_file = create(:streamable_video)
        @product = @product_file.link
        @url_redirect = @product.url_redirects.create
        login_as @product_file.link.user

        @product.enable_transcode_videos_on_purchase!
        allow_any_instance_of(UrlRedirect).to receive(:html5_video_url_and_guid_for_product_file).and_return([@product_file.url, "123"])
      end

      context "when no purchases are made" do
        it "shows transcode on purchase notice" do
          visit url_redirect_stream_page_for_product_file_path(@url_redirect.token, @product.product_files.first.external_id)

          expect(page).to have_content("Your video will be transcoded on first sale.")
          expect(page).to have_content("Until then, you may experience some viewing issues. You'll get an email once it's done.")
        end
      end

      context "when a purchase is made" do
        before do
          purchase = create(:purchase_in_progress, link: @product)
          purchase.mark_successful!
        end

        it "shows video being transcoded notice" do
          visit url_redirect_stream_page_for_product_file_path(@url_redirect.token, @product.product_files.first.external_id)

          expect(@product.transcode_videos_on_purchase?).to eq false
          expect(page).to have_content("Your video is being transcoded.")
          expect(page).to have_content("Until then, you and your future customers may experience some viewing issues. You'll get an email once it's done.")
        end
      end
    end
  end
end
