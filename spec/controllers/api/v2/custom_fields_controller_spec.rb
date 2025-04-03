# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::CustomFieldsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @custom_fields = [create(:custom_field, name: "country", required: true), create(:custom_field, name: "zip", required: true)]
    @product = create(:product, user: @user, description: "des1", custom_fields: @custom_fields)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = { link_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns the custom fields" do
        get @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          custom_fields: @custom_fields.map { _1.as_json.stringify_keys! }
        }.as_json(api_scopes: ["view_public"]))
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @new_custom_field_name = "blah"
      @params = { link_id: @product.external_id, name: @new_custom_field_name }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "creates a new custom field with default type" do
        post @action, params: @params
        expect(@product.custom_fields.reload.last.name).to eq(@new_custom_field_name)
        expect(@product.custom_fields.last.type).to eq("text")
      end

      it "creates a new custom checkbox field with label" do
        post @action, params: @params.merge({ type: "checkbox" })
        expect(@product.custom_fields.reload.last.name).to eq(@new_custom_field_name)
        expect(@product.custom_fields.last.type).to eq("checkbox")
      end

      it "creates a new custom terms field with url" do
        post @action, params: { link_id: @product.external_id, url: "https://www.gumroad.com", type: "terms", access_token: @token.token }
        expect(@product.custom_fields.reload.last.name).to eq("https://www.gumroad.com")
        expect(@product.custom_fields.last.type).to eq("terms")
      end

      it "returns the right response" do
        post @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          custom_field: @product.reload.custom_fields.last.as_json.stringify_keys!
        }.as_json(api_scopes: ["edit_products"]))
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @action = :update
      @params = {
        link_id: @product.external_id,
        id: @custom_fields[0]["name"],
        required: "false"
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "updates the custom field" do
        put @action, params: @params
        expect(@custom_fields.first.reload.required).to eq false
      end

      it "returns the right response" do
        put @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          custom_field: @product.reload.custom_fields.first.as_json.stringify_keys!
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "fails when the custom field doesn't exist" do
        put @action, params: @params.merge(id: "imnothere")
        expect(response.parsed_body["success"]).to be(false)
        expect(@product.reload.custom_fields).to eq(@custom_fields)
      end

      it "returns the changed custom field" do
        put @action, params: @params
        expect(response.parsed_body["custom_field"]).to eq(@custom_fields.first.reload.as_json.stringify_keys!)
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @action = :destroy
      @custom_field_name_to_delete = "country"
      @params = {
        link_id: @product.external_id,
        id: @custom_field_name_to_delete
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "deletes a custom field" do
        delete @action, params: @params
        expect(@product.reload.custom_fields).to eq([@custom_fields[1]])
        expect(CustomField.exists?(@custom_fields[0].id)).to eq false
      end

      it "only deletes the association if there are multiple products attached" do
        @custom_fields[0].products << create(:product)
        delete @action, params: @params
        expect(@product.reload.custom_fields).to eq([@custom_fields[1]])
        expect(CustomField.exists?(@custom_fields[0].id)).to eq true
      end

      it "returns the right response" do
        delete @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          message: "The custom_field was deleted successfully."
        }.as_json(api_scopes: ["edit_products"]))
      end

      it "fails when the custom field doesn't exist" do
        delete @action, params: @params.merge(id: "imnothere")
        expect(response.parsed_body["success"]).to be(false)
        expect(@product.reload.custom_fields).to eq(@custom_fields)
      end

      describe "when there are multiple of a field" do
        before do
          @product.custom_fields << create(:custom_field, name: "country")
        end

        it "deletes the last instance of the duplicated field" do
          delete @action, params: @params
          expect(@product.reload.custom_fields).to eq(@custom_fields)
        end
      end
    end
  end
end
