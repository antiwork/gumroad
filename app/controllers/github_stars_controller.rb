# frozen_string_literal: true

class GithubStarsController < ApplicationController
  def show
    expires_in 1.hour, public: true

    render json: { stars: fetch_cached_stars }
  end

  private

  def fetch_cached_stars
    Rails.cache.fetch(
      "github_stars_antiwork/gumroad",
      expires_in: 1.hour,
      race_condition_ttl: 10.seconds
    ) do
      fetch_stars
    end
  end

  def fetch_stars
    response = HTTParty.get(
      "https://api.github.com/repos/antiwork/gumroad",
      headers: { "X-GitHub-Api-Version" => "2022-11-28" }
    )
    response.parsed_response["stargazers_count"] if response.success?
  end
end
