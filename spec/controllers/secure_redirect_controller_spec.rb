# frozen_string_literal: true

require "spec_helper"

describe SecureRedirectController, type: :controller do
  let(:destination_url) { user_unsubscribe_url(id: "sample-id", email_type: "notify") }
  let(:confirmation_text) { "user@example.com" }
  let(:encrypted_destination) { SecureEncryptService.encrypt(destination_url) }
  let(:encrypted_confirmation_text) { SecureEncryptService.encrypt(confirmation_text) }
  let(:message) { "Please confirm your email address" }
  let(:field_name) { "Email address" }
  let(:error_message) { "Email address does not match" }

  describe "GET #new" do
    context "with valid params" do
      it "renders the new template" do
        get :new, params: {
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text,
          message: message,
          field_name: field_name,
          error_message: error_message
        }

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:new)
      end

      it "sets react component props" do
        get :new, params: {
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text,
          message: message,
          field_name: field_name,
          error_message: error_message
        }

        expect(assigns(:react_component_props)).to include(
          message: message,
          field_name: field_name,
          error_message: error_message,
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text,
          form_action: secure_url_redirect_path
        )
        expect(assigns(:react_component_props)[:authenticity_token]).to be_present
      end

      it "uses default values when optional params are missing" do
        get :new, params: {
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text
        }

        expect(assigns(:react_component_props)).to include(
          message: "Please enter the confirmation text to continue to your destination.",
          field_name: "Confirmation text",
          error_message: "Confirmation text does not match"
        )
      end

      it "includes flash error in props when present" do
        # Simulate a previous request that set flash error
        request.session["flash"] = ActionDispatch::Flash::FlashHash.new
        request.session["flash"]["error"] = "Test error message"

        get :new, params: {
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text
        }

        expect(assigns(:react_component_props)[:flash_error]).to eq("Test error message")
      end

      it "does not include flash_error in props when not present" do
        get :new, params: {
          encrypted_destination: encrypted_destination,
          encrypted_confirmation_text: encrypted_confirmation_text
        }

        expect(assigns(:react_component_props)).not_to have_key(:flash_error)
      end
    end

    context "with missing required params" do
      it "redirects to root when encrypted_destination is missing" do
        get :new, params: {
          encrypted_confirmation_text: encrypted_confirmation_text
        }

        expect(response).to redirect_to(root_path)
      end

      it "redirects to root when encrypted_confirmation_text is missing" do
        get :new, params: {
          encrypted_destination: encrypted_destination
        }

        expect(response).to redirect_to(root_path)
      end

      it "redirects to root when both required params are missing" do
        get :new

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        encrypted_destination: encrypted_destination,
        encrypted_confirmation_text: encrypted_confirmation_text,
        confirmation_text: confirmation_text,
        message: message,
        field_name: field_name,
        error_message: error_message
      }
    end

    context "with valid confirmation text" do
      it "redirects to the decrypted destination" do
        post :create, params: valid_params

        expect(response).to redirect_to(destination_url)
      end
    end

    context "with blank confirmation text" do
      it "returns unprocessable entity with error message" do
        post :create, params: valid_params.merge(confirmation_text: "")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Please enter the confirmation text" })
      end

      it "returns unprocessable entity when confirmation text is nil" do
        post :create, params: valid_params.except(:confirmation_text)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Please enter the confirmation text" })
      end

      it "returns unprocessable entity when confirmation text is whitespace only" do
        post :create, params: valid_params.merge(confirmation_text: "   ")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Please enter the confirmation text" })
      end
    end

    context "with incorrect confirmation text" do
      it "returns unprocessable entity with custom error message" do
        post :create, params: valid_params.merge(confirmation_text: "wrong@example.com")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => error_message })
      end

      it "uses default error message when not provided" do
        params_without_error_message = valid_params.except(:error_message).merge(confirmation_text: "wrong@example.com")
        post :create, params: params_without_error_message

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Confirmation text does not match" })
      end
    end

    context "with tampered encrypted data" do
      it "returns unprocessable entity when encrypted_confirmation_text is tampered" do
        tampered_encrypted = encrypted_confirmation_text + "tamper"
        post :create, params: valid_params.merge(encrypted_confirmation_text: tampered_encrypted)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => error_message })
      end

      it "returns unprocessable entity when encrypted_destination is tampered" do
        tampered_destination = encrypted_destination + "tamper"
        post :create, params: valid_params.merge(encrypted_destination: tampered_destination)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Invalid destination" })
      end
    end

    context "with missing required params" do
      it "redirects to root when encrypted_destination is missing" do
        post :create, params: valid_params.except(:encrypted_destination)

        expect(response).to redirect_to(root_path)
      end

      it "redirects to root when encrypted_confirmation_text is missing" do
        post :create, params: valid_params.except(:encrypted_confirmation_text)

        expect(response).to redirect_to(root_path)
      end
    end

    context "when destination decryption returns nil" do
      it "returns unprocessable entity with invalid destination error" do
        allow(SecureEncryptService).to receive(:decrypt).with(encrypted_destination).and_return(nil)
        allow(SecureEncryptService).to receive(:verify).and_return(true)

        post :create, params: valid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Invalid destination" })
      end
    end

    context "when destination decryption returns empty string" do
      it "returns unprocessable entity with invalid destination error" do
        allow(SecureEncryptService).to receive(:decrypt).with(encrypted_destination).and_return("")
        allow(SecureEncryptService).to receive(:verify).and_return(true)

        post :create, params: valid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)).to eq({ "error" => "Invalid destination" })
      end
    end
  end
end
