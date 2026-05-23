# frozen_string_literal: true

require "test_helper"

class ApiInternalHomePageNumbersControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::HomePageNumbersController
  tests Api::Internal::HomePageNumbersController



  context_ Api::Internal::HomePageNumbersController do
  context_ "when the return value is cached" do
      let(:cached_value) do
        {
          prev_week_payout_usd: "$37,537"
        }
      end

      before do
        Rails.cache.write("homepage_numbers", cached_value)
      end

  test "returns the cached result as JSON" do
        get :index

        expect(response).to be_successful
        expect(response.parsed_body).to eq(cached_value.as_json)
      end
    end

  context_ "when the return value is not cached" do
      let(:expected_value) do
        {
          prev_week_payout_usd: "$37,437"
        }
      end

      before do
        $redis.set(RedisKey.prev_week_payout_usd, "37437")
      end

  test "fetches the values from HomePagePresenter" do
        get :index

        expect(response).to be_successful
        expect(response.parsed_body).to eq(expected_value.as_json)
      end
    end
  end
end
