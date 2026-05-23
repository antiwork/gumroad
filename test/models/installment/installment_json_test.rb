# frozen_string_literal: true

require "test_helper"

class ModelsInstallmentInstallmentJsonTest < ActiveSupport::TestCase



  context_ "InstallmentJson"  do
    before do
      @creator = create(:named_user, :with_avatar)
      @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
    end

  context_ "#installment_mobile_json_data" do
      before do
        @product_file_1 = create(:product_file, installment: @installment, link: @installment.link)
        @product_file_2 = create(:product_file, installment: @installment, link: @installment.link, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
        @installment.update!(published_at: 1.week.ago)
      end

  context_ "for a digital product purchase" do
        before do
          @purchase = create(:purchase, link: @installment.link)
          @url_redirect = @installment.generate_url_redirect_for_purchase(@purchase)
          @files_data = [@product_file_1, @product_file_2].map do |product_file|
            @url_redirect.mobile_product_file_json_data(product_file)
          end
        end

  test "returns the correct json data" do
          expected_installment_json_data = {
            files_data: @files_data,
            message: @installment.message,
            name: @installment.name,
            call_to_action_text: @installment.call_to_action_text,
            call_to_action_url: @installment.call_to_action_url,
            installment_type: @installment.installment_type,
            published_at: @installment.published_at,
            external_id: @installment.external_id,
            url_redirect_external_id: @url_redirect.external_id,
            creator_name: @creator.name_or_username,
            creator_profile_picture_url: @creator.avatar_url,
            creator_profile_url: @creator.profile_url
          }
          expect(@installment.installment_mobile_json_data(purchase: @purchase).to_json).to eq expected_installment_json_data.to_json
        end

  context_ "when the installment has been sent to the user" do
  test "returns the time sent as the published_at time" do
            sent_at = 1.day.ago
            create(:creator_contacting_customers_email_info, installment: @installment, purchase: @purchase, sent_at:)
            expect(@installment.installment_mobile_json_data(purchase: @purchase)[:published_at].to_json).to eq sent_at.to_json
          end
        end

  context_ "for an installment without files" do
  test "returns no files" do
            installment = create(:installment, link: @installment.link, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
            installment.update!(published_at: 1.week.ago)
            url_redirect = installment.generate_url_redirect_for_purchase(@purchase)
            expected_installment_json_data = {
              files_data: [],
              message: installment.message,
              name: installment.name,
              call_to_action_text: installment.call_to_action_text,
              call_to_action_url: installment.call_to_action_url,
              installment_type: installment.installment_type,
              published_at: installment.published_at,
              external_id: installment.external_id,
              url_redirect_external_id: url_redirect.external_id,
              creator_name: @creator.name_or_username,
              creator_profile_picture_url: @creator.avatar_url,
              creator_profile_url: @creator.profile_url
            }
            expect(installment.installment_mobile_json_data(purchase: @purchase).to_json).to eq expected_installment_json_data.to_json
          end
        end
      end

  context_ "for a subscription purchase" do
        before do
          @installment.link.update!(is_recurring_billing: true)
          @purchase = create(:membership_purchase, link: @installment.link)
          @subscription = @purchase.subscription
          @url_redirect = @installment.generate_url_redirect_for_subscription(@subscription)
          @files_data = [@product_file_1, @product_file_2].map do |product_file|
            @url_redirect.mobile_product_file_json_data(product_file)
          end
        end

  test "returns the correct json data" do
          expected_installment_json_data = {
            files_data: @files_data,
            message: @installment.message,
            name: @installment.name,
            call_to_action_text: @installment.call_to_action_text,
            call_to_action_url: @installment.call_to_action_url,
            installment_type: @installment.installment_type,
            published_at: @installment.published_at,
            external_id: @installment.external_id,
            url_redirect_external_id: @url_redirect.external_id,
            creator_name: @creator.name_or_username,
            creator_profile_picture_url: @creator.avatar_url,
            creator_profile_url: @creator.profile_url
          }
          expect(@installment.installment_mobile_json_data(purchase: @purchase, subscription: @subscription).to_json).to eq expected_installment_json_data.to_json
        end

  context_ "when the installment has been sent to the user" do
  test "returns the time sent as the published_at time" do
            sent_at = 1.day.ago
            create(:creator_contacting_customers_email_info, installment: @installment, purchase: @purchase, sent_at:)
            expect(@installment.installment_mobile_json_data(purchase: @purchase)[:published_at].to_json).to eq sent_at.to_json
          end
        end
      end
    end
  end
end
