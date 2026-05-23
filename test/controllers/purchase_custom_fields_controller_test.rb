# frozen_string_literal: true

require "test_helper"

class PurchaseCustomFieldsControllerTest < ActionController::TestCase
  self.described_class = PurchaseCustomFieldsController
  tests PurchaseCustomFieldsController



  context_ PurchaseCustomFieldsController do
  context_ "POST create" do
      let(:user) { create(:user) }
      let(:product) { create(:product, user: user) }
      let(:purchase) { create(:purchase, link: product) }
      let(:custom_field) { create(:custom_field, products: [product], type: CustomField::TYPE_TEXT, is_post_purchase: true, name: "Text input") }

  context_ "with valid params" do
  test "creates a new purchase custom field" do
          post :create, params: {
            purchase_id: purchase.external_id,
            custom_field_id: custom_field.external_id,
            value: "Test value"
          }

          expect(response).to have_http_status(:no_content)

          purchase_custom_field = PurchaseCustomField.last
          expect(purchase_custom_field.custom_field_id).to eq(custom_field.id)
          expect(purchase_custom_field.value).to eq("Test value")
          expect(purchase_custom_field.field_type).to eq(CustomField::TYPE_TEXT)
          expect(purchase_custom_field.purchase_id).to eq(purchase.id)
          expect(purchase_custom_field.name).to eq("Text input")
        end

  test "updates an existing purchase custom field" do
          existing_field = create(:purchase_custom_field, purchase:, custom_field:, value: "Old value", name: "Text input")

          post :create, params: {
            purchase_id: purchase.external_id,
            custom_field_id: custom_field.external_id,
            value: "New value"
          }

          expect(response).to have_http_status(:no_content)

          existing_field.reload
          expect(existing_field.custom_field_id).to eq(custom_field.id)
          expect(existing_field.value).to eq("New value")
          expect(existing_field.field_type).to eq(CustomField::TYPE_TEXT)
          expect(existing_field.purchase_id).to eq(purchase.id)
          expect(existing_field.name).to eq("Text input")
        end
      end

  context_ "file upload" do
        let(:file_custom_field) { create(:custom_field, products: [product], type: CustomField::TYPE_FILE, is_post_purchase: true, name: nil) }

  test "attaches files to the purchase custom field" do
          file = fixture_file_upload("smilie.png", "image/png")
          blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: "smilie.png")

          post :create, params: {
            purchase_id: purchase.external_id,
            custom_field_id: file_custom_field.external_id,
            file_signed_ids: [blob.signed_id]
          }
          expect(response).to have_http_status(:no_content)

          purchase_custom_field = PurchaseCustomField.last
          expect(purchase_custom_field.custom_field_id).to eq(file_custom_field.id)
          expect(purchase_custom_field.files).to be_attached
          expect(purchase_custom_field.value).to eq("")
          expect(purchase_custom_field.field_type).to eq(CustomField::TYPE_FILE)
          expect(purchase_custom_field.purchase_id).to eq(purchase.id)
          expect(purchase_custom_field.name).to eq(CustomField::FILE_FIELD_NAME)
        end
      end

  context_ "with invalid params" do
  test "raises ActiveRecord::RecordNotFound for invalid purchase_id" do
          expect do
            post :create, params: {
              purchase_id: "invalid_id",
              custom_field_id: custom_field.external_id,
              value: "Test value"
            }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end

  test "raises ActiveRecord::RecordNotFound for invalid custom_field_id" do
          expect do
            post :create, params: {
              purchase_id: purchase.external_id,
              custom_field_id: "invalid_id",
              value: "Test value"
            }
          end.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
    end
  end
end
