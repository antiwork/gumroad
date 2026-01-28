# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe SecureRedirectController, type: :controller, inertia: true do
  let(:destination_url) { user_unsubscribe_url(id: "sample-id", email_type: "notify") }
  let(:confirmation_text) { "user@example.com" }
  let(:secure_payload) do
    {
      destination: destination_url,
      confirmation_texts: [confirmation_text],
      created_at: Time.current.to_i
    }
  end
  let(:encrypted_payload) { SecureEncryptService.encrypt(secure_payload.to_json) }
  let(:message) { "Please confirm your email address" }
  let(:field_name) { "Email address" }
  let(:error_message) { "Email address does not match" }

  describe "GET #new" do
    context "with valid params" do
      it "renders the new template with inertia" do
        get :new, params: {
          encrypted_payload: encrypted_payload,
          message: message,
          field_name: field_name,
          error_message: error_message
        }

        expect(response).to have_http_status(:success)
        expect(inertia).to render_component("SecureRedirect/New")
        expect(inertia.props).to include(
          message: message,
          field_name: field_name,
          error_message: error_message,
          encrypted_payload: encrypted_payload
        )
      end

      it "uses default values when optional params are missing" do
        get :new, params: {
          encrypted_payload: encrypted_payload
        }

        expect(inertia.props).to include(
          message: "Please enter the confirmation text to continue to your destination.",
          field_name: "Confirmation text",
          error_message: "Confirmation text does not match"
        )
      end
    end

    context "with missing required params" do
      it "redirects to root when encrypted_payload is missing" do
        get :new

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        encrypted_payload: encrypted_payload,
        confirmation_text: confirmation_text,
        message: message,
        field_name: field_name,
        error_message: error_message
      }
    end

    context "with valid confirmation text" do
      it "redirects to the destination" do
        post :create, params: valid_params

        expect(response).to redirect_to(destination_url)
        expect(response).to have_http_status(:see_other)
      end

      context "with send_confirmation_text parameter" do
        let(:secure_payload_with_send_confirmation) do
          {
            destination: destination_url,
            confirmation_texts: [confirmation_text],
            created_at: Time.current.to_i,
            send_confirmation_text: true
          }
        end
        let(:encrypted_payload_with_send_confirmation) { SecureEncryptService.encrypt(secure_payload_with_send_confirmation.to_json) }

        it "appends confirmation_text to destination URL when send_confirmation_text is true" do
          params_with_send_confirmation = valid_params.merge(encrypted_payload: encrypted_payload_with_send_confirmation)
          post :create, params: params_with_send_confirmation

          expected_url = "#{destination_url.split('?').first}?confirmation_text=#{CGI.escape(confirmation_text)}&#{destination_url.split('?').last}"
          expect(response).to redirect_to(expected_url)
        end

        it "does not append confirmation_text when send_confirmation_text is false or missing" do
          post :create, params: valid_params

          expect(response).to redirect_to(destination_url)
        end
      end
    end

    context "with multiple confirmation texts" do
      let(:confirmation_text_1) { "user1@example.com" }
      let(:confirmation_text_2) { "user2@example.com" }
      let(:confirmation_text_3) { "user3@example.com" }
      let(:secure_payload_multiple) do
        {
          destination: destination_url,
          confirmation_texts: [confirmation_text_1, confirmation_text_2, confirmation_text_3],
          created_at: Time.current.to_i
        }
      end
      let(:encrypted_payload_multiple) { SecureEncryptService.encrypt(secure_payload_multiple.to_json) }

      it "accepts confirmation text that matches any of the allowed texts" do
        post :create, params: valid_params.merge(
          encrypted_payload: encrypted_payload_multiple,
          confirmation_text: confirmation_text_3
        )

        expect(response).to redirect_to(destination_url)
      end

      it "rejects confirmation text that doesn't match any allowed text" do
        post :create, params: valid_params.merge(
          encrypted_payload: encrypted_payload_multiple,
          confirmation_text: "nomatch@example.com"
        )

        expect(response).to have_http_status(:unprocessable_entity)
        expect(inertia).to render_component("SecureRedirect/New")
        expect(flash.now[:alert]).to eq(error_message)
      end
    end

    context "with blank confirmation text" do
      it "renders with validation error" do
        post :create, params: valid_params.merge(confirmation_text: "")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(inertia).to render_component("SecureRedirect/New")
        expect(flash.now[:alert]).to eq("Please enter the confirmation text")
      end
    end

    context "with incorrect confirmation text" do
      it "renders with custom error message" do
        post :create, params: valid_params.merge(confirmation_text: "wrong@example.com")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(inertia).to render_component("SecureRedirect/New")
        expect(flash.now[:alert]).to eq(error_message)
      end
    end

    context "with tampered encrypted data" do
      it "renders with error when encrypted_payload is tampered" do
        tampered_encrypted = encrypted_payload + "tamper"
        post :create, params: valid_params.merge(encrypted_payload: tampered_encrypted)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(flash.now[:alert]).to eq("Invalid request")
      end
    end

    context "with expired payload" do
      let(:expired_secure_payload) do
        {
          destination: destination_url,
          confirmation_texts: [confirmation_text],
          created_at: (Time.current - 25.hours).to_i
        }
      end
      let(:expired_encrypted_payload) { SecureEncryptService.encrypt(expired_secure_payload.to_json) }

      it "renders with error when payload is expired" do
        post :create, params: valid_params.merge(encrypted_payload: expired_encrypted_payload)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(flash.now[:alert]).to eq("This link has expired")
      end
    end

    context "with missing required params" do
      it "redirects to root when encrypted_payload is missing" do
        post :create, params: valid_params.except(:encrypted_payload)

        expect(response).to redirect_to(root_path)
      end
    end

    context "when destination is empty" do
      let(:empty_destination_payload) do
        {
          destination: "",
          confirmation_texts: [confirmation_text],
          created_at: Time.current.to_i
        }
      end
      let(:empty_destination_encrypted_payload) { SecureEncryptService.encrypt(empty_destination_payload.to_json) }

      it "renders with invalid destination error" do
        post :create, params: valid_params.merge(encrypted_payload: empty_destination_encrypted_payload)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(flash.now[:alert]).to eq("Invalid destination")
      end
    end
  end
end
