# frozen_string_literal: true

require "spec_helper"

describe ThirdPartyAnalytic do
  before do
    @user = create(:user)
    @product = create(:product, user: @user)
  end

  describe "#save_third_party_analytics" do
    describe "new analytics" do
      it "creates a new third_party_analytic for creator" do
        params = [{
          name: "Snippet 1",
          location: "product",
          product: "#all_products",
          code: "<span>The first analytics</span>"
        }]

        expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq([ThirdPartyAnalytic.last.external_id])
        expect(@user.third_party_analytics.count).to eq(1)
        expect(@user.third_party_analytics.first.name).to eq("Snippet 1")
        expect(@user.third_party_analytics.first.location).to eq("product")
        expect(@user.third_party_analytics.first.analytics_code).to eq("<span>The first analytics</span>")
        expect(@product.third_party_analytics.count).to eq(0)
      end

      it "creates a new third_party_analytic for product" do
        params = [{
          name: "Snippet 1",
          location: "product",
          product: @product.unique_permalink,
          code: "<span>The first analytics</span>"
        }]

        expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq([ThirdPartyAnalytic.last.external_id])
        expect(@product.third_party_analytics.count).to eq(1)
        expect(@user.third_party_analytics.first.name).to eq("Snippet 1")
        expect(@user.third_party_analytics.first.location).to eq("product")
        expect(@product.third_party_analytics.first.analytics_code).to eq("<span>The first analytics</span>")
        expect(@user.third_party_analytics.count).to eq(1)
      end

      context "when two snippets have the same location" do
        it "doesn't allow them to belong to the same user" do
          params = [
            {
              name: "Snippet 1",
              location: "product",
              product: "#all_products",
              code: "<span>The first analytics</span>"
            },
            {
              name: "Snippet 2",
              location: "product",
              product: "#all_products",
              code: "<span>number 2</span>"
            }
          ]

          expect { ThirdPartyAnalytic.save_third_party_analytics(params, @user) }.to raise_error(ThirdPartyAnalytic::ThirdPartyAnalyticInvalid)
          expect(ThirdPartyAnalytic.count).to eq(0)
        end

        it "doesn't allow them to belong to the same product" do
          params = [
            {
              name: "Snippet 1",
              location: "product",
              product: @product.unique_permalink,
              code: "<span>The first analytics</span>"
            },
            {
              name: "Snippet 2",
              location: "product",
              product: @product.unique_permalink,
              code: "<span>number 2</span>"
            }
          ]

          expect { ThirdPartyAnalytic.save_third_party_analytics(params, @user) }.to raise_error(ThirdPartyAnalytic::ThirdPartyAnalyticInvalid)
          expect(ThirdPartyAnalytic.count).to eq(0)
        end
      end

      context "when two snippets have different locations" do
        it "allows them to belong to the same user" do
          params = [
            {
              name: "Snippet 1",
              location: "product",
              product: "#all_products",
              code: "<span>The first analytics</span>"
            },
            {
              name: "Snippet 2",
              location: "all",
              product: "#all_products",
              code: "<span>number 2</span>"
            }
          ]

          expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq [ThirdPartyAnalytic.second_to_last.external_id, ThirdPartyAnalytic.last.external_id]
          expect(ThirdPartyAnalytic.count).to eq(2)
        end

        it "doesn't allow them to belong to the same product" do
          params = [
            {
              name: "Snippet 1",
              location: "product",
              product: @product.unique_permalink,
              code: "<span>The first analytics</span>"
            },
            {
              name: "Snippet 2",
              location: "receipt",
              product: @product.unique_permalink,
              code: "<span>number 2</span>"
            }
          ]

          expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq [ThirdPartyAnalytic.second_to_last.external_id, ThirdPartyAnalytic.last.external_id]
          expect(ThirdPartyAnalytic.count).to eq(2)
        end
      end
    end

    describe "existing analytics" do
      before do
        @third_party_analytics = create(:third_party_analytic, user: @user, link: nil)
      end

      it "updates the new third_party_analytic for creator" do
        params = [{
          id: @third_party_analytics.external_id,
          name: "Snippet 1",
          location: "product",
          product: "#all_products",
          code: "HERE COMES THE PARTY"
        }]

        expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq([@third_party_analytics.external_id])
        @third_party_analytics.reload
        expect(@user.third_party_analytics.count).to eq(1)
        expect(@third_party_analytics.name).to eq("Snippet 1")
        expect(@third_party_analytics.location).to eq("product")
        expect(@third_party_analytics.analytics_code).to eq("HERE COMES THE PARTY")
        expect(@product.third_party_analytics.count).to eq(0)
      end

      it "updates the new third_party_analytic for product" do
        @third_party_analytics.update_attribute(:link, @product)
        params = [{
          id: @third_party_analytics.external_id,
          name: "Snippet 1",
          location: "product",
          product: @product.unique_permalink,
          code: "HERE COMES THE PARTY!"
        }]

        expect(ThirdPartyAnalytic.save_third_party_analytics(params, @user)).to eq([@third_party_analytics.external_id])
        @third_party_analytics.reload
        expect(@product.third_party_analytics.count).to eq(1)
        expect(@third_party_analytics.name).to eq("Snippet 1")
        expect(@third_party_analytics.location).to eq("product")
        expect(@third_party_analytics.analytics_code).to eq("HERE COMES THE PARTY!")
        expect(@user.third_party_analytics.count).to eq(1)
      end

      it "deletes the users third_party_analytics" do
        expect(ThirdPartyAnalytic.save_third_party_analytics({}, @user)).to eq([])
        expect(@user.third_party_analytics.alive.count).to eq(0)
      end
    end
  end

  describe "#clear_related_products_cache" do
    before do
      create(:product, user: @user)
      @tpa = create(:third_party_analytic, user: @user, link: @product)
    end

    it "calls cache invalidate on all user's links" do
      expect(@user).to receive(:clear_products_cache).once
      @tpa.link = nil
      @tpa.save!
    end
  end
end
