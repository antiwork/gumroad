# frozen_string_literal: true

require "spec_helper"

describe Admin::ProductPresenter::Card do
  describe "#props" do
    let(:admin_user) { create(:user) }
    let(:user) { create(:named_user) }
    let(:product) { create(:product, user:) }
    let(:pundit_user) { SellerContext.new(user: admin_user, seller: admin_user) }
    let(:presenter) { described_class.new(product:, pundit_user:) }

    subject(:props) { presenter.props }

    describe "fields" do
      it "returns the correct values" do
        expect(props.except(:cover_placeholder_url)).to eq(
          external_id: product.external_id,
          name: product.name,
          long_url: product.long_url,
          price_cents: product.price_cents,
          currency_code: product.price_currency_type,
          unique_permalink: product.unique_permalink,
          preview_url: product.preview_url,
          price_formatted: product.price_formatted,
          created_at: product.created_at,
          user: {
            external_id: product.user.external_id,
            name: product.user.name,
            suspended: false,
            flagged_for_tos_violation: false
          },
          admins_can_generate_url_redirects: product.admins_can_generate_url_redirects,
          alive_product_files: [],
          html_safe_description: product.html_safe_description,
          alive: product.alive?,
          is_adult: product.is_adult?,
          active_integrations: [],
          admins_can_mark_as_staff_picked: false,
          admins_can_unmark_as_staff_picked: false,
          is_tiered_membership: product.is_tiered_membership?,
          comments_count: product.comments.size,
          updated_at: product.updated_at,
          deleted_at: product.deleted_at
        )

        expect(props[:cover_placeholder_url]).to match(/cover_placeholder.*\.png/)
      end
    end

    describe "alive_product_files" do
      let!(:product_file1) { create(:product_file, link: product, position: 1) }
      let!(:product_file2) { create(:product_file, link: product, position: 2) }

      it "returns formatted product files" do
        expect(props[:alive_product_files].size).to eq(2)
        expect(props[:alive_product_files].first).to include(
          external_id: product_file1.external_id,
          s3_filename: product_file1.s3_filename
        )
        expect(props[:alive_product_files].second).to include(
          external_id: product_file2.external_id,
          s3_filename: product_file2.s3_filename
        )
      end

      it "returns files in the correct order" do
        expect(props[:alive_product_files].map { |f| f[:external_id] }).to eq([product_file1.external_id, product_file2.external_id])
      end

      context "when product has deleted files" do
        let!(:deleted_file) { create(:product_file, link: product, position: 3, deleted_at: 1.day.ago) }

        it "excludes deleted files" do
          expect(props[:alive_product_files].size).to eq(2)
          expect(props[:alive_product_files].map { |f| f[:external_id] }).not_to include(deleted_file.external_id)
        end
      end
    end

    describe "active_integrations" do
      context "when product has no integrations" do
        it "returns an empty array" do
          expect(props[:active_integrations]).to eq([])
        end
      end

      context "when product has integrations" do
        let(:product) { create(:product_with_discord_integration, user:) }

        it "returns formatted integrations" do
          expect(props[:active_integrations].size).to eq(1)
          expect(props[:active_integrations].first[:type]).to eq("DiscordIntegration")
        end
      end
    end

    describe "product states" do
      context "when product is alive" do
        it "returns alive as true" do
          expect(props[:alive]).to be(true)
        end
      end

      context "when product is deleted" do
        before do
          product.mark_deleted!
        end

        it "returns alive as false" do
          expect(props[:alive]).to be(false)
        end

        it "sets deleted_at" do
          expect(props[:deleted_at]).not_to be_nil
        end
      end

      context "when product is adult" do
        before do
          product.update!(is_adult: true)
        end

        it "returns is_adult as true" do
          expect(props[:is_adult]).to be(true)
        end
      end

      context "when product is tiered membership" do
        let(:product) { create(:membership_product_with_preset_tiered_pricing) }

        it "returns is_tiered_membership as true" do
          expect(props[:is_tiered_membership]).to be(true)
        end
      end
    end

    describe "description handling" do
      context "when product has description with links" do
        let(:product) { create(:product, user:, description: "Check out http://example.com") }

        it "returns html safe description with proper link attributes" do
          expect(props[:html_safe_description]).to include('target="_blank"')
          expect(props[:html_safe_description]).to include('rel="noopener noreferrer nofollow"')
        end
      end

      context "when product has no description" do
        let(:product) { create(:product, user:, description: nil) }

        it "returns nil" do
          expect(props[:html_safe_description]).to be_nil
        end
      end
    end

    describe "url redirect generation capability" do
      context "when product has alive product files" do
        let!(:product_file) { create(:product_file, link: product) }

        it "returns admins_can_generate_url_redirects as true" do
          expect(props[:admins_can_generate_url_redirects]).to be(true)
        end
      end

      context "when product has no alive product files" do
        it "returns admins_can_generate_url_redirects as false" do
          expect(props[:admins_can_generate_url_redirects]).to be(false)
        end
      end
    end

    describe "user object" do
      it "includes all required user fields" do
        expect(props[:user]).to include(
          :external_id,
          :name,
          :suspended,
          :flagged_for_tos_violation
        )
      end

      it "returns correct user values" do
        expect(props[:user][:external_id]).to eq(product.user.external_id)
        expect(props[:user][:name]).to eq(product.user.name)
        expect(props[:user][:suspended]).to eq(false)
        expect(props[:user][:flagged_for_tos_violation]).to eq(false)
      end

      context "when user is suspended" do
        let(:user) { create(:named_user, :suspended) }

        it "returns suspended as true" do
          expect(props[:user][:suspended]).to be(true)
        end
      end

      context "when user is flagged for TOS violation" do
        let(:user) { create(:named_user, :flagged_for_tos_violation) }

        it "returns flagged_for_tos_violation as true" do
          expect(props[:user][:flagged_for_tos_violation]).to be(true)
        end
      end
    end
  end
end
