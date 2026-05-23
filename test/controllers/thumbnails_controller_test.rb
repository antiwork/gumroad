# frozen_string_literal: true

require "test_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

class ThumbnailsControllerTest < ActionController::TestCase
  self.described_class = ThumbnailsController
  self.rspec_metadata = { vcr: true }
  tests ThumbnailsController



  context_ ThumbnailsController, :vcr do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    include_context "with user signed in as admin for seller"

  context_ "POST create" do
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

  context_ "when signed in user is not the owner" do
        before do
          sign_in(create(:user))
        end

  test "raises RoutingError" do
          expect do
            expect do
              post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id } })
            end.to raise_error(ActionController::RoutingError, "Not Found")
          end.not_to change { Thumbnail.count }
        end
      end

  test "returns error when thumbnail param is a raw file upload instead of signed_blob_id" do
        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: fixture_file_upload("Austin's Mojo.png", "image/png"), format: :json })
        end.not_to change { Thumbnail.count }

        expect(response.status).to eq(400)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Invalid thumbnail parameter. Expected signed_blob_id." })
      end

  context_ "with using image file" do
  test "fails for an invalid thumbnail" do
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

  test "creates a thumbnail" do
          expect(product.thumbnail).to eq(nil)

          expect do
            post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
          end.to change { Thumbnail.count }.by(1)

          expect(product.reload.thumbnail.file.blob).to eq(blob)
          expect(response.status).to eq(200)
          expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
        end

  test "modifies thumbnail if one created from file already exists" do
          product.update!(thumbnail: create(:thumbnail))

          expect do
            post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
          end.to change { Thumbnail.count }.by(0)

          expect(product.reload.thumbnail.file.blob).to eq(blob)
          expect(response.status).to eq(200)
          expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
        end
      end

  test "returns an error when thumbnail analysis times out" do
        allow_any_instance_of(ActiveStorage::Blob).to receive(:analyze).and_raise(Timeout::Error)

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
        end.not_to change { Thumbnail.count }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Thumbnail processing took too long, please try again with a smaller image." })
      end

  test "returns an error when the file is not found in storage" do
        allow_any_instance_of(ActiveStorage::Blob).to receive(:analyze).and_raise(ActiveStorage::FileNotFoundError)

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
        end.not_to change { Thumbnail.count }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Could not process your thumbnail, please try again." })
      end

  test "returns an error when the blob is purged before attach completes" do
        allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_raise(
          ActiveRecord::InvalidForeignKey.new("Cannot add or update a child row: a foreign key constraint fails")
        )

        expect do
          post(:create, params: { link_id: product.unique_permalink, thumbnail: { signed_blob_id: blob.signed_id }, format: :json })
        end.not_to change { Thumbnail.count }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false, "error" => "Could not process your thumbnail, please try again." })
      end

  test "restores deleted thumbnail if exists" do
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

  context_ "DELETE destroy" do
      let(:product) { create(:thumbnail).product }

      before do
        sign_in(product.user)
      end

      it_behaves_like "authorize called for action", :delete, :destroy do
        let(:record) { Thumbnail }
        let(:request_params) { { link_id: product.unique_permalink, id: product.thumbnail.guid } }
      end

  context_ "when logged in user is admin of seller account" do
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

  test "fails if user is not the owner" do
        sign_in(create(:user))
        expect do
          expect do
            delete(:destroy, params: { link_id: product.unique_permalink, id: product.thumbnail.guid })
          end.to raise_error(ActionController::RoutingError, "Not Found")
        end.not_to change { Thumbnail.alive.count }
      end

  test "fails for an invalid thumbnail" do
        expect do
          delete(:destroy, params: { link_id: product.unique_permalink, id: "invalid_id" })
        end.not_to change { Thumbnail.alive.count }

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => false })
      end

  test "removes the thumbnail" do
        expect do
          delete(:destroy, params: { link_id: product.unique_permalink, id: product.thumbnail.guid })
        end.to change { Thumbnail.alive.count }.from(1).to(0)
           .and change { product.reload.thumbnail.deleted? }.from(false).to(true)

        expect(response.status).to eq(200)
        expect(response.parsed_body).to eq({ "success" => true, "thumbnail" => product.thumbnail.as_json.stringify_keys })
      end
    end
  end
end
