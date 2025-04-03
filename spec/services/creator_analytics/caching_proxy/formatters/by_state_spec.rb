# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::CachingProxy::Formatters::ByState do
  before do
    @service = CreatorAnalytics::CachingProxy.new(build(:user))
  end

  describe "#merge_data_by_state" do
    it "returns data merged by state" do
      day_one = {
        by_state: {
          views: { "tPsrl" => { "Canada" => 1, "United States" => [1, 1, 1, 1], "France" => 1 }, "PruAb" => { "Canada" => 1 } },
          sales: { "tPsrl" => { "Canada" => 1 }, "PruAb" => { "Canada" => 1 } },
          totals: { "tPsrl" => { "Canada" => 1 }, "PruAb" => { "Canada" => 1 } },
        }
      }
      # notable: new data format + new product
      day_two = {
        by_state: {
          views: { "tPsrl" => { "Canada" => 1, "United States" => [1, 1, 1, 1], "France" => 1 }, "PruAb" => { "Brazil" => 1 }, "Mmwrc" => { "United States" => [1, 1, 1, 1], "Brazil" => 1 } },
          sales: { "tPsrl" => { "Canada" => 1 }, "PruAb" => { "Canada" => 1 }, "Mmwrc" => { "United States" => [1, 1, 1, 1], "Canada" => 1 } },
          totals: { "tPsrl" => { "Canada" => 1 }, "PruAb" => { "Canada" => 1 }, "Mmwrc" => { "France" => 1 } },
        }
      }

      expect(@service.merge_data_by_state([day_one, day_two])).to equal_with_indifferent_access(
        by_state: {
          views: { "tPsrl" => { "Canada" => 2, "United States" => [2, 2, 2, 2], "France" => 2 }, "PruAb" => { "Canada" => 1, "Brazil" => 1 }, "Mmwrc" => { "United States" => [1, 1, 1, 1], "Brazil" => 1 } },
          sales: { "tPsrl" => { "Canada" => 2 }, "PruAb" => { "Canada" => 2 }, "Mmwrc" => { "United States" => [1, 1, 1, 1], "Canada" => 1 } },
          totals: { "tPsrl" => { "Canada" => 2 }, "PruAb" => { "Canada" => 2 }, "Mmwrc" => { "France" => 1 } }
        }
      )
    end
  end
end
