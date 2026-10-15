# frozen_string_literal: true

class CommunityPolicy < ApplicationPolicy
  EXISTENCE_CHECK_FLAG = :community_nav_existence_check

  def index?
    treatment = Feature.active?(EXISTENCE_CHECK_FLAG, user)
    ramp_percentage = Flipper[EXISTENCE_CHECK_FLAG].percentage_of_actors_value
    return has_communities?(treatment) unless ramp_percentage > 0 && ramp_percentage < 100

    result = nil
    elapsed_seconds = Benchmark.realtime { result = has_communities?(treatment) }
    log_existence_check(treatment:, result:, elapsed_ms: (elapsed_seconds * 1000).round(2))
    result
  end

  def show?
    user.accessible_communities_ids.include?(record.id)
  end

  private
    def has_communities?(treatment)
      treatment ? user.has_accessible_communities? : user.accessible_communities_ids.any?
    end

    def log_existence_check(treatment:, result:, elapsed_ms:)
      Rails.logger.info(
        {
          event: EXISTENCE_CHECK_FLAG,
          arm: treatment ? "treatment" : "control",
          elapsed_ms:,
          has_communities: result,
          user_id: user.id,
        }.to_json,
      )
    end
end
