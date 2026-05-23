# frozen_string_literal: true

require "test_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

class SettingsMainControllerTest < ActionController::TestCase
  self.described_class = Settings::MainController
  tests Settings::MainController



  context_ Settings::MainController, type: :controller, inertia: true do
    it_behaves_like "inherits from Sellers::BaseController"

    let(:seller) { create(:named_seller) }

    before do
      sign_in seller
    end

    it_behaves_like "authorize called for controller", Settings::Main::UserPolicy do
      let(:record) { seller }
    end

  context_ "GET show" do
      include_context "with user signed in as admin for seller"

      let(:pundit_user) { SellerContext.new(user: user_with_role_for_seller, seller:) }

  test "returns http success and renders Inertia component" do
        get :show

        expect(response).to be_successful
        expect(inertia.component).to eq("Settings/Main/Show")
        settings_presenter = SettingsPresenter.new(pundit_user:)
        expected_props = settings_presenter.main_props
        # Compare only the expected props from inertia.props (ignore shared props)
        actual_props = inertia.props.slice(*expected_props.keys)
        expect(actual_props).to eq(expected_props)
      end
    end

  context_ "PUT update" do
      let (:user_params) do
        { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: nil } }
      end

  test "submits the form successfully" do
        put :update, params: { user: user_params.merge(email: "hello@example.com") }
        expect(response).to redirect_to(settings_main_path)
        expect(response).to have_http_status :see_other
        expect(flash[:notice]).to eq("Your account has been updated!")
        expect(seller.reload.unconfirmed_email).to eq("hello@example.com")
      end

  test "returns error message and notifies Sentry when StandardError is raised" do
        allow_any_instance_of(User).to receive(:save!).and_raise(StandardError)
        expect(ErrorNotifier).to receive(:notify).with(an_instance_of(StandardError))
        put :update, params: { user: user_params.merge(email: "hello@example.com") }
        expect(response).to redirect_to(settings_main_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Something broke. We're looking into what happened. Sorry about this!")
      end

  context_ "expires products" do
        let(:product) { create(:product, user: seller) }

        before do
          product.user.update!(enable_recurring_subscription_charge_email: true)
          Rails.cache.write(product.scoped_cache_key("en"), "<html>Hello</html>")
          product.product_cached_values.create!
        end

  test "expires the user's products", :sidekiq_inline do
          put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
          expect(Rails.cache.read(product.scoped_cache_key("en"))).to be(nil)
          expect(product.reload.product_cached_values.fresh).to eq([])
        end
      end

  test "sets error message and render show on invalid record" do
        put :update, params: { user: user_params.merge(email: "BAD EMAIL") }
        expect(response).to redirect_to(settings_main_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Email is invalid")
      end

  test "does not notify Sentry when updating email to one that already exists" do
        create(:user, email: "existing@example.com")
        expect(ErrorNotifier).not_to receive(:notify)
        put :update, params: { user: user_params.merge(email: "existing@example.com") }
        expect(response).to redirect_to(settings_main_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("An account already exists with this email.")
      end

  context_ "email changing" do
  context_ "email is changed to something new" do
          before do
            seller.update_columns(email: "test@gumroad.com", unconfirmed_email: "test@gumroad.com")
          end

  test "sets unconfirmed_email column" do
            expect { put :update, params: { user: user_params.merge(email: "new@gumroad.com") } }.to change {
              seller.reload.unconfirmed_email
            }.from("test@gumroad.com").to("new@gumroad.com")
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
          end

  test "does not change email column" do
            expect do
              put :update, params: { user: user_params.merge(email: "new@gumroad.com") }
            end.not_to change { seller.reload.email }.from("test@gumroad.com")
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
          end

  test "sends email_changed notification" do
            expect do
              put :update, params: { user: user_params.merge(email: "another+email@example.com") }
            end.to have_enqueued_mail(UserSignupMailer, :email_changed)
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
          end
        end

  context_ "email is changed back to a confirmed email" do
          before(:each) do
            seller.update_columns(email: "test@gumroad.com", unconfirmed_email: "new@gumroad.com")
          end

  test "changes the unconfirmed_email to nil" do
            expect do
              put :update, params: { user: user_params.merge(email: "test@gumroad.com") }
            end.to change {
              seller.reload.unconfirmed_email
            }.from("new@gumroad.com").to(nil)
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
          end

  test "doesn't send email_changed notification" do
            expect do
              put :update, params: { user: user_params.merge(email: seller.email) }
            end.not_to have_enqueued_mail(UserSignupMailer, :email_changed)
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
          end
        end
      end

  test "updates the enable_free_downloads_email flag correctly" do
        seller.update!(enable_free_downloads_email: true)

        expect do
          put :update, params: { user: user_params.merge(enable_free_downloads_email: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_free_downloads_email
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(enable_free_downloads_email: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_free_downloads_email
        }.from(false).to(true)
      end

  test "updates the enable_free_downloads_push_notification flag correctly" do
        seller.update!(enable_free_downloads_push_notification: true)

        expect do
          put :update, params: { user: user_params.merge(enable_free_downloads_push_notification: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_free_downloads_push_notification
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(enable_free_downloads_push_notification: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_free_downloads_push_notification
        }.from(false).to(true)
      end

  test "updates the enable_recurring_subscription_charge_email flag correctly" do
        seller.update!(enable_recurring_subscription_charge_email: true)

        expect do
          put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_recurring_subscription_charge_email
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_email: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_recurring_subscription_charge_email
        }.from(false).to(true)
      end

  test "updates the enable_recurring_subscription_charge_push_notification flag correctly" do
        seller.update!(enable_recurring_subscription_charge_push_notification: true)

        expect do
          put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_push_notification: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_recurring_subscription_charge_push_notification
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(enable_recurring_subscription_charge_push_notification: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_recurring_subscription_charge_push_notification
        }.from(false).to(true)
      end

  test "updates the enable_payment_push_notification flag correctly" do
        seller.update!(enable_payment_push_notification: true)

        expect do
          put :update, params: { user: user_params.merge(enable_payment_push_notification: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_payment_push_notification
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(enable_payment_push_notification: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.enable_payment_push_notification
        }.from(false).to(true)
      end

  test "updates the disable_comments_email flag correctly" do
        seller.update!(disable_comments_email: true)

        expect do
          put :update, params: { user: user_params.merge(disable_comments_email: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.disable_comments_email
        }.from(true).to(false)

        expect do
          put :update, params: { user: user_params.merge(disable_comments_email: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.disable_comments_email
        }.from(false).to(true)
      end

  test "updates the disable_reviews_email flag correctly" do
        expect do
          put :update, params: { user: user_params.merge(disable_reviews_email: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.disable_reviews_email
        }.from(false).to(true)

        expect do
          put :update, params: { user: user_params.merge(disable_reviews_email: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.disable_reviews_email
        }.from(true).to(false)
      end

  test "updates the show_nsfw_products flag correctly" do
        expect do
          put :update, params: { user: user_params.merge(show_nsfw_products: true) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.show_nsfw_products
        }.from(false).to(true)

        expect do
          put :update, params: { user: user_params.merge(show_nsfw_products: false) }
          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Your account has been updated!")
        end.to change {
          seller.reload.show_nsfw_products
        }.from(true).to(false)
      end

  context_ "seller refund policy" do
  context_ "when enabled" do
          before do
            seller.refund_policy.update!(max_refund_period_in_days: 0)
          end

  test "updates the seller refund policy fine print" do
            put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")

            expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(30)
            expect(seller.refund_policy.fine_print).to eq("This is a fine print")
          end

  context_ "when seller_refund_policy_disabled_for_all feature flag is set to true" do
            before do
              Feature.activate(:seller_refund_policy_disabled_for_all)
            end

  test "does not update the seller refund policy" do
              put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }
              expect(response).to redirect_to(settings_main_path)
              expect(response).to have_http_status :see_other
              expect(flash[:notice]).to eq("Your account has been updated!")

              expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
            end
          end
        end

  context_ "when not enabled" do
          before do
            seller.update!(refund_policy_enabled: false)
            seller.refund_policy.update!(max_refund_period_in_days: 0)
          end

  test "does not update the seller refund policy" do
            put :update, params: { user: { seller_refund_policy: { max_refund_period_in_days: "30", fine_print: "This is a fine print" } } }
            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")

            expect(seller.refund_policy.reload.max_refund_period_in_days).to eq(0)
            expect(seller.refund_policy.fine_print).to be_nil
          end
        end

  context_ "product level support emails" do
          let(:product1) { create(:product, user: seller) }
          let(:product2) { create(:product, user: seller) }
          let(:other_seller) { create(:user) }
          let(:other_product) { create(:product, user: other_seller) }

          before do
            Feature.activate(:product_level_support_emails)
          end

  test "creates new support emails with associated products" do
            product_level_support_emails = [
              {
                email: "contact@example.com",
                product_ids: [product1.external_id, product2.external_id]
              },
              {
                email: "support@example.com",
                product_ids: []
              }
            ]

            put :update, params: { user: user_params.merge(product_level_support_emails:) }

            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
            expect(product1.reload.support_email).to eq("contact@example.com")
            expect(product2.reload.support_email).to eq("contact@example.com")
          end

  test "fails when email isn't valid" do
            product_level_support_emails = [
              { email: "invalid-email", product_ids: [product1.external_id] }
            ]
            put :update, params: { user: user_params.merge(product_level_support_emails:) }

            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :found
            expect(flash[:alert]).to eq("Something broke. We're looking into what happened. Sorry about this!")
          end

  test "only associates products belonging to current seller" do
            product_level_support_emails = [
              {
                email: "contact@example.com",
                product_ids: [product1.external_id, other_product.external_id]
              }
            ]

            put :update, params: { user: user_params.merge(product_level_support_emails:) }

            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
            expect(product1.reload.support_email).to eq("contact@example.com")
            expect(other_product.reload.support_email).to be_nil
          end

  test "clears all existing support emails if param is empty" do
            product1.update!(support_email: "support@example.com")
            product2.update!(support_email: "support@example.com")

            put :update, params: { user: user_params.merge(product_level_support_emails: []) }

            expect(response).to redirect_to(settings_main_path)
            expect(response).to have_http_status :see_other
            expect(flash[:notice]).to eq("Your account has been updated!")
            expect(product1.reload.support_email).to be_nil
            expect(product2.reload.support_email).to be_nil
          end

  context_ "when product_level_support_emails feature is disabled" do
            before do
              Feature.deactivate(:product_level_support_emails)
            end

  test "does not update product support emails" do
              product_level_support_emails = [
                { email: "contact@example.com", product_ids: [product1.external_id] }
              ]

              put :update, params: { user: user_params.merge(product_level_support_emails:) }

              expect(response).to redirect_to(settings_main_path)
              expect(response).to have_http_status :see_other
              expect(flash[:notice]).to eq("Your account has been updated!")
              expect(product1.reload.support_email).to be_nil
            end
          end
        end
      end
    end

  context_ "POST resend_confirmation_email" do
      shared_examples_for "resends email confirmation" do
  test "resends email confirmation" do
          expect { post :resend_confirmation_email }
            .to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :see_other
          expect(flash[:notice]).to eq("Confirmation email resent!")
        end
      end

      shared_examples_for "doesn't resend email confirmation" do
  test "doesn't resend email confirmation" do
          expect { post :resend_confirmation_email }
            .not_to have_enqueued_mail(UserSignupMailer)

          expect(response).to redirect_to(settings_main_path)
          expect(response).to have_http_status :found
          expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
        end
      end

  context_ "when user has email and not confirmed" do
        before do
          seller.update_columns(confirmed_at: nil)
        end

        it_behaves_like "resends email confirmation"
      end

  context_ "when user has changed email after confirmation" do
        before do
          seller.confirm
          seller.update_attribute(:email, "some@gumroad.com")
        end

        it_behaves_like "resends email confirmation"
      end

  context_ "when user is confirmed" do
        before do
          seller.confirm
        end

        it_behaves_like "doesn't resend email confirmation"
      end

  context_ "when user doesn't have email" do
        before do
          seller.update_columns(email: nil)
        end

        it_behaves_like "doesn't resend email confirmation"
      end
    end
  end
end
