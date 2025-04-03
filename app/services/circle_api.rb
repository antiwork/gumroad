# frozen_string_literal: true

class CircleApi
  include HTTParty

  base_uri "https://app.circle.so/api/v1"

  def initialize(api_key)
    @api_key = api_key
  end

  def get_communities
    rate_limited_call { self.class.get("/communities", headers:) }
  end

  def get_spaces(community_id)
    rate_limited_call { self.class.get("/spaces", query: { "community_id" => community_id }, headers:) }
  end

  def get_space_groups(community_id)
    rate_limited_call { self.class.get("/space_groups", query: { "community_id" => community_id }, headers:) }
  end

  def add_member(community_id, space_group_id, email)
    rate_limited_call { self.class.post("/community_members", query: { "community_id" => community_id, "space_group_ids[]" => space_group_id, "email" => email }, headers:) }
  end

  def remove_member(community_id, email)
    rate_limited_call { self.class.delete("/community_members", query: { "community_id" => community_id, "email" => email }, headers:) }
  end

  private
    def headers
      {
        "Authorization" => "Token #{@api_key}"
      }
    end

    def rate_limited_call(&block)
      key = "CIRCLE_API_RATE_LIMIT"
      ratelimit = Ratelimit.new(key, { redis: $redis })

      ratelimit.exec_within_threshold key, threshold: 100, interval: 60 do
        ratelimit.add(key)
        block.call
      end
    end
end
