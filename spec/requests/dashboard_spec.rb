# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Dashboard", js: true, type: :system do
  let(:seller) { create(:named_seller) }

  before do
    login_as seller
  end

  describe "dashboard stats" do
    before do
      create(:product, user: seller)
      allow_any_instance_of(UserBalanceStatsService).to receive(:fetch_overview).and_return(
        {
          balance: 10_000,
          last_seven_days_sales_total: 5_000,
          last_28_days_sales_total: 15_000,
          sales_cents_total: 50_000
        }
      )
    end

    it "displays correct values and headings for stats" do
      visit dashboard_path

      within "main" do
        expect(page).to have_text("Balance $100", normalize_ws: true)
        expect(page).to have_text("Last 7 days $50", normalize_ws: true)
        expect(page).to have_text("Last 28 days $150", normalize_ws: true)
        expect(page).to have_text("Total earnings $500", normalize_ws: true)
      end
    end

    it "displays currency symbol and headings when seller should be shown currencies always" do
      allow(seller).to receive(:should_be_shown_currencies_always?).and_return(true)
      visit dashboard_path

      within "main" do
        expect(page).to have_text("Balance $100 USD", normalize_ws: true)
        expect(page).to have_text("Last 7 days $50 USD", normalize_ws: true)
        expect(page).to have_text("Last 28 days $150 USD", normalize_ws: true)
        expect(page).to have_text("Total earnings $500 USD", normalize_ws: true)
      end
    end
  end

  describe "Greeter" do
    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "renders the greeter placeholder" do
        visit dashboard_path

        expect(page).to have_text("We're here to help you get paid for your work")
      end
    end

    context "with switching account to user as marketing for seller" do
      include_context "with switching account to user as marketing for seller"

      it "renders the greeter placeholder" do
        visit dashboard_path

        expect(page).to have_text("We're here to help you get paid for your work")
      end
    end
  end

  describe "Getting started" do
    it "offers optional social connections and opens the Social connections settings page" do
      Feature.deactivate(:youtube_connect)
      Feature.deactivate(:instagram_connect)
      seller.update!(twitter_handle: "example_creator")
      visit dashboard_path

      expect(page).to have_text("Connect a social account (optional)")
      expect(page).to have_text("If we ever review your account, a connected social account gives us more to go on.")
      expect(page).not_to have_text("Connected:")
      click_on "Connect an account"
      expect(page).to have_current_path(settings_social_connections_path(social_connect_origin: "onboarding"))
      expect(page).to have_text("Social connections")
      expect(page).to have_button("Connect to X")
      expect(page).not_to have_button("Connect to YouTube")
      expect(page).not_to have_button("Connect to Instagram")
      expect(page).not_to have_button("Disconnect @example_creator from X")
    end

    it "shows a connected account without making social connections required for checklist completion" do
      seller.update!(twitter_user_id: "example-social-id")
      visit dashboard_path
      expect(page).to have_text("Connected: X")
      click_on "Manage connections"
      click_on "Disconnect X"
      expect(page).to have_button("Connect to X")
      expect(seller.reload.twitter_user_id).to be_nil
      visit dashboard_path
      expect(page).not_to have_text("Connected:")
      expect(page).to have_link("Connect an account")
      click_on "Minimize getting started"
      expect(page).not_to have_text("Connect a social account (optional)")
      click_on "Expand getting started"
      expect(page).to have_link("Connect an account")

      click_on "Dismiss getting started"
      click_on "Yes, hide it"
      expect(page).not_to have_text("Connect a social account (optional)")
      visit dashboard_path
      expect(page).not_to have_text("Connect a social account (optional)")
    end

    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "renders the Getting started section" do
        visit dashboard_path

        expect(page).to have_text("Getting started")
        expect(page).not_to have_text("Connect a social account (optional)")
      end
    end

    context "with switching account to user as marketing for seller" do
      include_context "with switching account to user as marketing for seller"

      it "doesn't render the Getting started section" do
        visit dashboard_path

        expect(page).not_to have_text("Getting started")
      end
    end
  end

  describe "Activity" do
    context "with no data" do
      context "with switching account to user as admin for seller" do
        include_context "with switching account to user as admin for seller"

        it "renders placeholder text with links" do
          visit dashboard_path

          expect(page).to have_text("Followers and sales will show up here as they come in. For now, create a product or customize your profile")
        end
      end

      context "with switching account to user as marketing for seller" do
        include_context "with switching account to user as marketing for seller"

        it "renders placeholder text with links only" do
          visit dashboard_path

          expect(page).to have_text("Followers and sales will show up here as they come in.")
          expect(page).not_to have_text("For now, create a profile or customize your profile")
        end
      end
    end
  end

  describe "Stripe verification message" do
    it "displays the verification error message from Stripe" do
      create(:merchant_account, user: seller)
      create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
                                            verification_error: { code: "verification_document_name_missing" })

      visit dashboard_path

      expect(page).to have_text("The uploaded document is missing the name. Please upload another document that contains the name.")
    end

    it "explains the P.O. Box deadlock instead of asking for another document upload" do
      create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_po_box_#{SecureRandom.hex(8)}")
      create(:user_compliance_info, user: seller, street_address: "PO Box 65")
      create(:user_compliance_info_request, user: seller, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID,
                                            verification_error: { code: "verification_document_address_mismatch" })

      visit dashboard_path

      expect(page).to have_text("Your registered address appears to be a P.O. Box")
      expect(page).to have_text("uploading it again won't help")
      expect(page).not_to have_text("upload a document with address that matches the account")
    end
  end

  describe "tax form download notice" do
    before do
      freeze_time
      seller.update!(created_at: 1.year.ago)
    end

    context "when seller is not US-based (tax center disabled)" do
      it "displays a 1099 form ready notice with a link to download if eligible" do
        download_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/test.pdf"
        allow_any_instance_of(User).to receive(:eligible_for_1099?).and_return(true)
        allow_any_instance_of(User).to receive(:tax_form_1099_download_url).and_return(download_url)

        visit dashboard_path

        expect(page).to have_text("Your 1099 tax form for #{Time.current.prev_year.year} is ready!")
        expect(page).to have_link("Click here to download", href: dashboard_download_tax_form_path)
      end

      it "does not display a 1099 form ready notice if not eligible" do
        allow_any_instance_of(User).to receive(:eligible_for_1099?).and_return(false)

        visit dashboard_path

        expect(page).not_to have_text("Your 1099 tax form for #{Time.current.prev_year.year} is ready!")
        expect(page).not_to have_link("Click here to download", href: dashboard_download_tax_form_path)
      end
    end

    context "when seller is US-based (tax center enabled)" do
      before do
        create(:user_compliance_info, user: seller)
      end

      it "displays notice with link to tax center when user has tax form for previous year" do
        create(:user_tax_form, user: seller, tax_year: Time.current.prev_year.year, tax_form_type: "us_1099_k")

        visit dashboard_path

        expect(page).to have_text("Your 1099 tax form for #{Time.current.prev_year.year} is ready!")
        expect(page).to have_link("Click here to download", href: tax_center_path(year: Time.current.prev_year.year))
      end

      it "does not display notice when user has no tax form for previous year" do
        visit dashboard_path

        expect(page).not_to have_text("Your 1099 tax form for")
        expect(page).not_to have_link("Click here to download")
      end
    end
  end

  describe "download tax forms button" do
    download_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/23b2d41ac63a40b5afa1a99bf38a0982/original/test.pdf"

    before do
      freeze_time
      seller.update!(created_at: 1.year.ago)
      allow(seller).to receive(:eligible_for_1099?).and_return(true)
      allow(seller).to receive(:tax_form_1099_download_url).and_return(download_url)
    end

    it "displays button when there are tax forms" do
      visit dashboard_path

      expect(page).to have_button("Tax forms")
    end

    it "opens a popover with a checkbox for each year with a tax form" do
      visit dashboard_path

      click_button("Tax forms")

      expect(page).to have_text("Download tax forms")
      expect(page).to have_text("Select the tax years you want to download.")
      expect(page).to have_unchecked_field(Time.current.year.to_s)
      expect(page).to have_unchecked_field(Time.current.prev_year.year.to_s)
    end

    it "allows selecting all years and deselecting all years" do
      visit dashboard_path

      click_button("Tax forms")
      click_button("Select all")

      expect(page).to have_checked_field(Time.current.year.to_s)
      expect(page).to have_checked_field(Time.current.prev_year.year.to_s)

      click_button("Deselect all")

      expect(page).to have_unchecked_field(Time.current.year.to_s)
      expect(page).to have_unchecked_field(Time.current.prev_year.year.to_s)
    end

    it "downloads selected tax forms" do
      visit dashboard_path

      click_button("Tax forms")
      check(Time.current.prev_year.year.to_s)
      new_window = window_opened_by { click_button("Download") }

      within_window new_window do
        expect(current_url).to eq(download_url)
      end
    end

    it "does not display button if there are no tax forms" do
      allow(seller).to receive(:eligible_for_1099?).and_return(false)

      visit dashboard_path

      expect(page).not_to have_button("Tax forms")
    end
  end
end
