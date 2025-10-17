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
      allow_any_instance_of(UserBalanceStatsService).to receive(:fetch).and_return(
        {
          overview: {
            balance: 10_000,
            last_seven_days_sales_total: 5_000,
            last_28_days_sales_total: 15_000,
            sales_cents_total: 50_000
          },
          next_payout_period_data: {
            should_be_shown_currencies_always: false,
            minimum_payout_amount_cents: 1_000,
            is_user_payable: false,
            status: :not_payable
          },
          processing_payout_periods_data: []
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
    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "renders the Getting started section" do
        visit dashboard_path

        expect(page).to have_text("Getting started")
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
  end

  describe "tax form download notice" do
    before do
      freeze_time
      seller.update!(created_at: 1.year.ago)
    end

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
