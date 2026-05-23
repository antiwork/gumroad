# frozen_string_literal: true

require "test_helper"
require "shared_examples/sellers_base_controller_concern"

class SellersSwitchControllerTest < ActionController::TestCase
  self.described_class = Sellers::SwitchController
  tests Sellers::SwitchController



  context_ Sellers::SwitchController do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:user) { create(:user) }
    let(:seller) { create(:named_seller) }

  context_ "POST create" do
      before do
        cookies.encrypted[:current_seller_id] = nil
        sign_in user
      end

  context_ "with invalid team membership record" do
  test "doesn't set cookie" do
          post :create, params: { team_membership_id: "foo" }

          expect(cookies.encrypted[:current_seller_id]).to eq(nil)
          expect(response).to have_http_status(:no_content)
        end
      end

  context_ "with team membership record" do
        let!(:team_membership) { create(:team_membership, user:, seller:) }

  test "sets cookie and updates last_accessed_at" do
          post :create, params: { team_membership_id: team_membership.external_id.to_s }

          expect(cookies.encrypted[:current_seller_id]).to eq(seller.id)
          expect(team_membership.reload.last_accessed_at).to be_within(2.seconds).of(Time.current)
          expect(response).to have_http_status(:no_content)
        end

  context_ "with deleted team membership" do
          before do
            team_membership.update_as_deleted!
          end

  test "doesn't set cookie" do
            post :create, params: { team_membership_id: team_membership.external_id.to_s }

            expect(cookies.encrypted[:current_seller_id]).to eq(nil)
            expect(response).to have_http_status(:no_content)
          end
        end
      end
    end
  end
end
