# frozen_string_literal: true

require "spec_helper"

describe User::AsJson do
  describe "#as_json" do
    let(:user) { create(:named_user, *user_traits) }
    let(:user_traits) { [] }
    let(:options) { {} }

    subject(:as_json) { user.as_json(options) }

    before do
      create(:product, user:, custom_permalink: "boo")
    end

    context "for api :edit_products" do
      let(:options) { { api_scopes: ["edit_products"] } }

      it "returns the correct hash" do
        %w[name email].each do |key|
          expect(as_json.key?(key)).to be(true)
        end
        expect(as_json["links"]).to eq(["boo"])
      end

      it "returns an alphanumeric id in all situations" do
        expect(as_json["user_id"]).to eq ObfuscateIds.encrypt(user.id)
      end
    end

    context "for public" do
      it "returns the correct hash" do
        expect(as_json.key?("name")).to be(true)
      end

      it "returns an alphanumeric id" do
        expect(as_json["user_id"]).to eq ObfuscateIds.encrypt(user.id)
      end
    end

    context "if the 'view_sales' API scope is present" do
      let(:options) { { api_scopes: ["view_sales"] } }

      it "returns the email" do
        expect(as_json.key?("email")).to be(true)
      end
    end

    context "for 'view_profile' scope" do
      let(:options) { { api_scopes: ["view_profile"] } }

      it "returns values for 'view_profile' scope"  do
        expect(as_json).to include("email", "profile_url", "display_name", "id")
      end
    end

    describe "returned keys" do
      subject(:returned_keys) { as_json.keys.collect(&:to_s) }

      let(:options) { {} }
      let(:common_keys) { %w[name bio twitter_handle id user_id url links] }
      let(:api_scope_keys) { %w[currency_type profile_url email] }
      let(:internal_use_keys) { %w[created_at sign_in_count current_sign_in_at last_sign_in_at current_sign_in_ip last_sign_in_ip purchases_count successful_purchases_count] }

      context "when no options are provided" do
        context "when the bio and twitter_handle are NOT set" do
          it "returns common values" do
            expect(returned_keys).to contain_exactly(*common_keys - %w[bio twitter_handle])
          end
        end

        context "when the bio is set" do
          let(:user_traits) { [:with_bio] }

          it "returns common values expect twitter_handle" do
            expect(returned_keys).to contain_exactly(*common_keys - %w[twitter_handle])
          end
        end

        context "when the twitter_handle is set" do
          let(:user_traits) { [:with_twitter_handle] }

          it "returns common values expect bio" do
            expect(returned_keys).to contain_exactly(*common_keys - %w[bio])
          end
        end
      end

      context "when only the :internal_use option is provided" do
        let(:options) { { internal_use: true } }

        it { expect(returned_keys).to contain_exactly(*(common_keys + api_scope_keys + internal_use_keys)) }
      end

      %w[edit_products view_sales revenue_share ifttt view_profile].each do |api_scope|
        context "when the '#{api_scope}' api scope is provided" do
          context "when :internal_use is provided" do
            let(:options) { { api_scopes: [api_scope], internal_use: true } }

            if api_scope == "view_profile"
              it { expect(returned_keys).to contain_exactly(*(common_keys + (api_scope_keys + %w[display_name]) + internal_use_keys)) }
            else
              it { expect(returned_keys).to contain_exactly(*(common_keys + api_scope_keys + internal_use_keys)) }
            end
          end

          context "when :internal_use is NOT provided" do
            let(:options) { { api_scopes: [api_scope] } }

            if api_scope == "view_profile"
              it { expect(returned_keys).to contain_exactly(*(common_keys + (api_scope_keys + %w[display_name]))) }
            else
              it { expect(returned_keys).to contain_exactly(*(common_keys + api_scope_keys)) }
            end
          end
        end
      end
    end
  end
end
