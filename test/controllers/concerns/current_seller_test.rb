# frozen_string_literal: true

require "test_helper"

class CurrentSellerTest < ActionController::TestCase
  self.described_class = CurrentSeller



  context_ CurrentSeller, type: :controller do
    controller(ApplicationController) do
      include CurrentSeller

      before_action :authenticate_user!

      def action
        head :ok
      end
    end

    before do
      routes.draw { get :action, to: "anonymous#action" }
    end

    let(:seller) { create(:named_seller) }
    let(:other_seller) { create(:user) }

    shared_examples_for "invalid cookie" do
  test "deletes cookie and assigns seller as current_seller" do
        get :action

        expect(controller.current_seller).to eq(seller)
        expect(cookies.encrypted[:current_seller_id]).to eq(nil)
      end
    end

  context_ "with seller signed in" do
      before do
        sign_in(seller)
      end

  context_ "when cookie is set" do
  context_ "with correct value" do
          before do
            cookies.encrypted[:current_seller_id] = seller.id
          end

  test "keeps cookie and assigns seller as current_seller" do
            get :action

            expect(controller.current_seller).to eq(seller)
            expect(cookies.encrypted[:current_seller_id]). to eq(seller.id)
          end
        end

  context_ "with incorrect value" do
  context_ "when cookie uses other seller that is not alive" do
            before do
              other_seller.update!(deleted_at: Time.current)
              cookies.encrypted[:current_seller_id] = other_seller.id
            end

            it_behaves_like "invalid cookie"
          end

  context_ "when cookie uses an invalid value" do
            before do
              cookies.encrypted[:current_seller_id] = "foo"
            end

            it_behaves_like "invalid cookie"
          end

  context_ "when cookie uses another valid seller that is not a member of" do
            before do
              cookies.encrypted[:current_seller_id] = other_seller.id
            end

            it_behaves_like "invalid cookie"
          end
        end
      end

  context_ "when cookie is not set" do
  test "assigns seller as current_seller" do
          get :action

          expect(controller.current_seller).to eq(seller)
          expect(cookies.encrypted[:current_seller_id]).to eq(nil)
        end
      end
    end

  context_ "without seller signed in" do
  context_ "when cookie is set" do
        before do
          cookies.encrypted[:current_seller_id] = seller.id
        end

  test "doesn't assign current_seller and don't destroy the cookie" do
          get :action

          expect(controller.current_seller).to eq(nil)
          expect(cookies.encrypted[:current_seller_id]). to eq(seller.id)
        end
      end

  context_ "when cookie is not set" do
  test "doesn't assign current_seller and cookie" do
          get :action

          expect(controller.current_seller).to eq(nil)
          expect(cookies.encrypted[:current_seller_id]).to eq(nil)
        end
      end
    end
  end
end
