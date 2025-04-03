# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe ThumbnailsController, :vcr do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(
        io: fixture_file_upload("Austin's Mojo.png", "image/png"),
        filename: "Austin's Mojo.png"
      )
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Thumbnail }
      let(:request_params) { { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id } } }
    end

    context "when signed in user is not the owner" do
      before do
        sign_in(create(:user))
      end

      it "raises RoutingError" do
        expect do
          expect do
            post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id } })
          end.to raise_error(ActionController::RoutingError, "Not Found")
        end.to_not change { Thumbnail.count }
      end
    end

    context "with using image file" do
      it "fails for an invalid thumbnail" do
        expect(product.thumbnail).to eq(nil)

        invalid_blob = ActiveStorage::Blob.create_and_upload!(
          io: fixture_file_upload("test-squashed.png", "image/png"),
          filename: "test-squashed.png"
        )

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: invalid_blob.signed_id }, format: :json })
        end.to change { Thumbnail.count }.by(0)

        expect(product.reload.thumbnail).to eq(nil)
        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Please upload a square thumbnail." })
      end

      it "creates a thumbnail" do
        expect(product.thumbnail).to eq(nil)

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
        end.to change { Thumbnail.count }.by(1)

        expect(product.reload.thumbnail.file.blob).to eq(blob)
        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
      end

      it "modifies thumbnail if one created from file already exists" do
        product.update!(thumbnail: create(:thumbnail))

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
        end.to change { Thumbnail.count }.by(0)

        expect(product.reload.thumbnail.file.blob).to eq(blob)
        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
      end
    end

    it "restores deleted thumbnail if exists" do
      product.update!(thumbnail: create(:thumbnail))
      product.thumbnail.mark_deleted!

      expect do
        post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
      end.to change { Thumbnail.alive.count }.by(1)
         .and change { Thumbnail.count }.by(0)
         .and change { product.reload.thumbnail.deleted? }.from(true).to(false)

      expect(product.reload.thumbnail.file.blob).to eq(blob)
      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
    end
  end

  describe "DELETE destroy" do
    let(:product) { create(:thumbnail).product }

    before do
      sign_in(product.user)
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { Thumbnail }
      let(:request_params) { { link_id: product.unique_permalink, id: product.thumbnail.guid } }
    end

    context "when logged in user is admin of seller account" do
      let(:admin) { create(:user) }

      before do
        create(:team_membership, user: admin, seller: product.user, role: TeamMembership::ROLE_ADMIN)

        cookies.encrypted[:current_seller_id] = product.user.id
        sign_in admin
      end

      it_behaves_like "authorize called for action", :delete, :destroy do
        let(:record) { Thumbnail }
        let(:request_params) { { link_id: product.unique_permalink, id: product.thumbnail.guid } }
      end
    end

    it "fails if user is not the owner" do
      sign_in(create(:user))
      expect do
        expect do
          delete(:destroy, params: { link_id: product.unique_permalink, id: product.thumbnail.guid })
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end.to_not change { Thumbnail.alive.count }
    end

    it "fails for an invalid thumbnail" do
      expect do
        delete(:destroy, params: { link_id: product.unique_permalink, id: "invalid_id" })
      end.to_not change { Thumbnail.alive.count }

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => false })
    end

    it "removes the thumbnail" do
      expect do
        delete(:destroy, params: { link_id: product.unique_permalink, id: product.thumbnail.guid })
      end.to change { Thumbnail.alive.count }.from(1).to(0)
         .and change { product.reload.thumbnail.deleted? }.from(false).to(true)

      expect(response.status).to eq(200)
      expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
    end
  end
end
