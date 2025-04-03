# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::AdvancedController, :vcr do
  render_views

  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", Settings::Advanced::UserPolicy do
    let(:record) { seller }
  end

  describe "GET show" do
    it "returns http success and assigns correct instance variables" do
      get :show

      expect(response).to have_http_status(:ok)
      pundit_user = SellerContext.new(user: user_with_role_for_seller, seller:)
      expect(assigns[:react_component_props]).to eq(SettingsPresenter.new(pundit_user:).advanced_props)
    end
  end

  describe "PUT update" do
    it "submits the form successfully" do
      put :update, xhr: true, params: { user: { notification_endpoint: "https://example.com" } }

      expect(response.parsed_body["success"]).to be(true)
      expect(seller.reload.notification_endpoint).to eq("https://example.com")
    end

    it "returns error message when StandardError is raised" do
      allow_any_instance_of(User).to receive(:update).and_raise(StandardError)
      put :update, xhr: true, params: { user: { notification_endpoint: "https://example.com" } }

      expect(response.parsed_body["success"]).to be(false)
      expect(response.parsed_body["error_message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
    end

    context "when params contains a domain" do
      context "when logged_in_user has an existing custom_domain" do
        before do
          create(:custom_domain, user: seller, domain: "example-domain.com")
        end

        it "updates the custom_domain" do
          expect do
            put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" }, domain: "test-custom-domain.gumroad.com" }
          end.to change {
            seller.reload.custom_domain.domain
          }.from("example-domain.com").to("test-custom-domain.gumroad.com")

          expect(response.parsed_body["success"]).to be(true)
        end

        context "when domain verification fails" do
          before do
            seller.custom_domain.update!(failed_verification_attempts_count: 2)

            allow_any_instance_of(CustomDomainVerificationService)
              .to receive(:process)
              .and_return(false)
          end

          it "does not increment the failed verification attempts count" do
            expect do
              put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" }, domain: "invalid.example.com" }
            end.to_not change {
              seller.reload.custom_domain.failed_verification_attempts_count
            }
          end
        end
      end

      context "when logged_in_user doesn't have an existing custom_domain" do
        it "creates a new custom_domain" do
          expect do
            put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" }, domain: "test-custom-domain.gumroad.com" }
          end.to change { CustomDomain.alive.count }.by(1)

          expect(seller.custom_domain.domain).to eq "test-custom-domain.gumroad.com"
          expect(response.parsed_body["success"]).to be(true)
        end
      end
    end

    context "when params doesn't contain a domain" do
      context "when user has an existing custom_domain" do
        let(:custom_domain) { create(:custom_domain, user: seller, domain: "example.com") }

        it "doesn't delete the custom_domain" do
          expect do
            put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" } }
          end.to change {
            CustomDomain.alive.count
          }.by(0)
          expect(custom_domain.reload.deleted_at).to be_nil
          expect(seller.reload.custom_domain).to eq custom_domain
          expect(response.parsed_body["success"]).to be(true)
        end
      end
    end

    context "when domain is set to empty string in params" do
      context "when user has an existing custom_domain" do
        let(:custom_domain) { create(:custom_domain, user: seller, domain: "example.com") }

        it "deletes the custom_domain" do
          expect do
            put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" }, domain: "" }
          end.to change {
            custom_domain.reload.deleted?
          }.from(false).to(true)

          expect(seller.reload.custom_domain).to be_nil
          expect(response.parsed_body["success"]).to be(true)
        end
      end

      context "when user doesn't have an existing custom_domain" do
        it "renders success response" do
          expect { put :update, xhr: true, params: { user: { enable_verify_domain_third_party_services: "0" }, domain: "" } }.to change { CustomDomain.alive.count }.by(0)
          expect(response.parsed_body["success"]).to be(true)
        end
      end
    end

    describe "mass-block customer emails" do
      it "blocks the specified emails" do
        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "customer1@example.com\ncustomer2@example.com" }
        end.to change { seller.blocked_customer_objects.active.email.count }.by(2)

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer1@example.com", "customer2@example.com"])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "does not block the specified emails if they are already blocked" do
        ["customer1@example.com", "customer3@example.com"].each do |email|
          BlockedCustomerObject.block_email!(email:, seller_id: seller.id)
        end

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "customer3@example.com\ncustomer2@example.com\ncustomer1@example.com" }
        end.to change { seller.blocked_customer_objects.active.email.count }.by(1)

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer3@example.com", "customer2@example.com", "customer1@example.com"])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "unblocks the emails that were previously blocked but are not specified in the 'blocked_customer_emails' param" do
        BlockedCustomerObject.block_email!(email: "customer1@example.com", seller_id: seller.id)

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "customer2@example.com\njohn@example.com" }
        end.to change { seller.blocked_customer_objects.active.email.count }.from(1).to(2)

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer2@example.com", "john@example.com"])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "blocks an email again if it was previously blocked and then unblocked" do
        BlockedCustomerObject.block_email!(email: "john@example.com", seller_id: seller.id)
        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["john@example.com"])

        seller.blocked_customer_objects.active.email.first.unblock!
        expect(seller.blocked_customer_objects.active.email.count).to eq(0)

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "john@example.com\nsmith@example.com" }
        end.to change { seller.blocked_customer_objects.active.email.count }.from(0).to(2)

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["john@example.com", "smith@example.com"])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "unblocks an email for a seller even if it is blocked by another seller" do
        BlockedCustomerObject.block_email!(email: "john@example.com", seller_id: seller.id)
        another_seller = create(:user)
        BlockedCustomerObject.block_email!(email: "john@example.com", seller_id: another_seller.id)

        expect do
          expect do
            put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "customer@example.com" }
          end.to change { seller.blocked_customer_objects.active.email.pluck(:object_value) }.from(["john@example.com"]).to(["customer@example.com"])
        end.to_not change { another_seller.blocked_customer_objects.active.email.pluck(:object_value) }

        expect(another_seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["john@example.com"])
        expect(response.parsed_body["success"]).to be(true)
      end

      it "does not block or unblock any emails if one of the specified emails is invalid" do
        BlockedCustomerObject.block_email!(email: "customer1@example.com", seller_id: seller.id)

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "john@example.com\nrob@@example.com\n\njane       @example.com" }
        end.to_not change { seller.blocked_customer_objects.active.email.count }

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["customer1@example.com"])
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("The email rob@@example.com cannot be blocked as it is invalid.")
      end

      it "unblocks all emails if the 'blocked_customer_emails' param is empty" do
        ["john@example.com", "smith@example.com"].each do |email|
          BlockedCustomerObject.block_email!(email:, seller_id: seller.id)
        end

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "" }
        end.to change { seller.blocked_customer_objects.active.email.count }.from(2).to(0)

        expect(seller.blocked_customer_objects.active.email.count).to eq(0)
        expect(response.parsed_body["success"]).to be(true)
      end

      it "responds with a generic error if an unexpected error occurs" do
        expect(BlockedCustomerObject).to receive(:block_email!).and_raise(ActiveRecord::RecordInvalid)

        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "" }, blocked_customer_emails: "john@example.com" }
        end.to_not change { seller.blocked_customer_objects.active.email.count }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("Sorry, something went wrong. Please try again.")
      end

      it "blocks the specified emails even if other form fields fail validations" do
        expect do
          put :update, xhr: true, params: { user: { notification_endpoint: "https://example.com" }, blocked_customer_emails: "john@example.com\n\nrob@example.com", domain: "invalid-domain" }
        end.to change { seller.blocked_customer_objects.active.email.count }.from(0).to(2)
         .and change { seller.reload.notification_endpoint }.from(nil).to("https://example.com")

        expect(seller.blocked_customer_objects.active.email.pluck(:object_value)).to match_array(["john@example.com", "rob@example.com"])
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["error_message"]).to eq("invalid-domain is not a valid domain name.")
      end
    end
  end
end
