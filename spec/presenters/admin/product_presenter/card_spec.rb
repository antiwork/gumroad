# frozen_string_literal: true

require "spec_helper"

describe Admin::ProductPresenter::Card do
  describe "#props" do
    let(:user) { create(:named_user) }
    let(:product) { create(:product, user:) }
    let(:admins_can_mark_as_staff_picked) { ->(_product) { true } }
    let(:admins_can_unmark_as_staff_picked) { ->(_product) { false } }
    let(:presenter) do
      described_class.new(
        product:,
        admins_can_mark_as_staff_picked:,
        admins_can_unmark_as_staff_picked:
      )
    end

    subject(:props) { presenter.props }

    describe "basic structure" do
      it "returns a hash with all expected keys" do
        expect(props).to include(
          :id,
          :name,
          :long_url,
          :price_cents,
          :currency_code,
          :unique_permalink,
          :preview_url,
          :cover_placeholder_url,
          :price_formatted,
          :created_at,
          :user,
          :admins_can_generate_url_redirects,
          :alive_product_files,
          :html_safe_description,
          :alive,
          :is_adult,
          :active_integrations,
          :admins_can_mark_as_staff_picked,
          :admins_can_unmark_as_staff_picked,
          :is_tiered_membership,
          :updated_at,
          :deleted_at
        )
      end
    end

    describe "fields" do
      it "returns the correct values" do
        expect(props[:id]).to eq(product.id)
        expect(props[:name]).to eq(product.name)
        expect(props[:long_url]).to eq(product.long_url)
        expect(props[:price_cents]).to eq(product.price_cents)
        expect(props[:currency_code]).to eq(product.price_currency_type)
        expect(props[:unique_permalink]).to eq(product.unique_permalink)
        expect(props[:preview_url]).to eq(product.preview_url)
        expect(props[:cover_placeholder_url]).to match(/cover_placeholder.*\.png/)
        expect(props[:price_formatted]).to eq(product.price_formatted)
        expect(props[:created_at]).to eq(product.created_at)
        expect(props[:user]).to eq(
          id: product.user_id,
          name: product.user.name,
          suspended: false,
          flagged_for_tos_violation: false
        )
        expect(props[:admins_can_generate_url_redirects]).to eq(product.admins_can_generate_url_redirects)
        expect(props[:html_safe_description]).to eq(product.html_safe_description)
        expect(props[:alive]).to eq(product.alive?)
        expect(props[:is_adult]).to eq(product.is_adult?)
        expect(props[:is_tiered_membership]).to eq(product.is_tiered_membership?)
        expect(props[:updated_at]).to eq(product.updated_at)
        expect(props[:deleted_at]).to eq(product.deleted_at)
      end
    end

    describe "alive_product_files" do
      let!(:product_file1) { create(:product_file, link: product, position: 1) }
      let!(:product_file2) { create(:product_file, link: product, position: 2) }

      it "returns formatted product files" do
        expect(props[:alive_product_files].size).to eq(2)
        expect(props[:alive_product_files].first).to include(
          id: product_file1.id,
          external_id: product_file1.external_id,
          s3_filename: product_file1.s3_filename
        )
        expect(props[:alive_product_files].second).to include(
          id: product_file2.id,
          external_id: product_file2.external_id,
          s3_filename: product_file2.s3_filename
        )
      end

      it "returns files in the correct order" do
        expect(props[:alive_product_files].map { |f| f[:id] }).to eq([product_file1.id, product_file2.id])
      end

      context "when product has deleted files" do
        let!(:deleted_file) { create(:product_file, link: product, position: 3, deleted_at: 1.day.ago) }

        it "excludes deleted files" do
          expect(props[:alive_product_files].size).to eq(2)
          expect(props[:alive_product_files].map { |f| f[:id] }).not_to include(deleted_file.id)
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

    describe "permission callbacks" do
      context "when admin can mark as staff picked" do
        let(:admins_can_mark_as_staff_picked) { ->(product) { true } }
        let(:admins_can_unmark_as_staff_picked) { ->(product) { false } }

        it "returns the correct permission values" do
          expect(props[:admins_can_mark_as_staff_picked]).to be(true)
          expect(props[:admins_can_unmark_as_staff_picked]).to be(false)
        end
      end

      context "when admin can unmark as staff picked" do
        let(:admins_can_mark_as_staff_picked) { ->(product) { false } }
        let(:admins_can_unmark_as_staff_picked) { ->(product) { true } }

        it "returns the correct permission values" do
          expect(props[:admins_can_mark_as_staff_picked]).to be(false)
          expect(props[:admins_can_unmark_as_staff_picked]).to be(true)
        end
      end

      it "calls the permission callbacks with the product" do
        expect(admins_can_mark_as_staff_picked).to receive(:call).with(product).and_return(true)
        expect(admins_can_unmark_as_staff_picked).to receive(:call).with(product).and_return(false)

        props
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
          :id,
          :name,
          :suspended,
          :flagged_for_tos_violation
        )
      end

      it "returns correct user values" do
        expect(props[:user][:id]).to eq(product.user_id)
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
