# frozen_string_literal: true

require "spec_helper"

describe("Secure Redirect", js: true, type: :system) do
  let(:user) { create(:user) }
  let(:destination_url) { api_url(host: UrlService.domain_with_protocol) }
  let(:confirmation_text_1) { "example@example.com" }
  let(:confirmation_text_2) { user.email }
  let(:message) { "Please enter your email address to unsubscribe" }
  let(:field_name) { "Email address" }
  let(:error_message) { "Email address does not match" }

  let(:secure_payload) do
    {
      destination: destination_url,
      confirmation_texts: [confirmation_text_1, confirmation_text_2],
      created_at: Time.current.to_i
    }
  end
  let(:encrypted_payload) { SecureEncryptService.encrypt(secure_payload.to_json) }

  describe "GET /secure_url_redirect" do
    context "with valid parameters" do
      it "displays the confirmation page with custom messages" do
        visit secure_url_redirect_path(
          encrypted_payload: encrypted_payload,
          message: message,
          field_name: field_name,
          error_message: error_message
        )

        expect(page).to have_content(message)
        expect(page).to have_field(field_name)
      end

      it "displays the confirmation page with default messages" do
        visit secure_url_redirect_path(
          encrypted_payload: encrypted_payload
        )

        expect(page).to have_content("Please enter the confirmation text to continue to your destination.")
        expect(page).to have_field("Confirmation text")
      end
    end

    context "with invalid parameters" do
      it "redirects to the root path if encrypted_payload is missing" do
        visit secure_url_redirect_path
        expect(page).to have_current_path(login_path)
      end
    end
  end

  describe "POST /secure_url_redirect" do
    before do
      visit secure_url_redirect_path(
        encrypted_payload: encrypted_payload,
        message: message,
        field_name: field_name,
        error_message: error_message
      )
    end

    context "with correct confirmation text" do
      it "redirects to the destination" do
        fill_in field_name, with: confirmation_text_2
        click_button "Continue"

        expect(page).to have_current_path(destination_url)
      end
    end

    context "with incorrect confirmation text" do
      it "shows an error message" do
        fill_in field_name, with: "wrong text"
        click_button "Continue"
        wait_for_ajax

        expect(page).to have_content(error_message)
        expect(page).to have_current_path(secure_url_redirect_path, ignore_query: true)
      end
    end

    context "with blank confirmation text" do
      it "shows an error message" do
        fill_in field_name, with: ""
        click_button "Continue"
        wait_for_ajax

        expect(page).to have_content("Please enter your email address to unsubscribe")
        expect(page).to have_current_path(secure_url_redirect_path, ignore_query: true)
      end
    end

    context "with an invalid payload" do
      let(:invalid_secure_payload) do
        {
          destination: nil,
          confirmation_texts: [confirmation_text_2],
          created_at: Time.current.to_i
        }
      end
      let(:invalid_encrypted_payload) { SecureEncryptService.encrypt(invalid_secure_payload.to_json) }

      before do
        visit secure_url_redirect_path(
          encrypted_payload: invalid_encrypted_payload,
          message: message,
          field_name: field_name,
          error_message: error_message
        )
      end

      it "shows an error message" do
        fill_in field_name, with: confirmation_text_2
        click_button "Continue"
        wait_for_ajax

        expect(page).to have_content("Invalid destination")
        expect(page).to have_current_path(secure_url_redirect_path, ignore_query: true)
      end
    end

    context "with a tampered payload" do
      let(:tampered_encrypted_payload) { "tampered" }

      before do
        visit secure_url_redirect_path(
          encrypted_payload: tampered_encrypted_payload,
          message: message,
          field_name: field_name,
          error_message: error_message
        )
      end

      it "shows an error message" do
        fill_in field_name, with: confirmation_text_2
        click_button "Continue"
        wait_for_ajax

        expect(page).to have_content("Invalid request")
        expect(page).to have_current_path(secure_url_redirect_path, ignore_query: true)
      end
    end
  end
end
