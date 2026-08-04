# frozen_string_literal: true

class SubmitToIndexnowJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  ENDPOINT = "https://api.indexnow.org/indexnow"
  MAX_URLS_PER_SUBMISSION = 10_000

  def perform(product_ids)
    key = GlobalConfig.get("INDEXNOW_KEY")
    return if key.blank?

    urls = Link.where(id: Array.wrap(product_ids)).includes(:user).map(&:long_url).uniq
    return if urls.empty?

    urls.each_slice(MAX_URLS_PER_SUBMISSION) do |url_list|
      response = HTTParty.post(
        ENDPOINT,
        body: { host: DOMAIN, key:, keyLocation: "#{UrlService.domain_with_protocol}/#{key}.txt", urlList: url_list }.to_json,
        headers: { "Content-Type" => "application/json; charset=utf-8" },
        timeout: 10
      )
      Rails.logger.info("SubmitToIndexnowJob response=#{response.code} urls=#{url_list.size}")
    end
  end
end
