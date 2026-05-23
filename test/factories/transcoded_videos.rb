# frozen_string_literal: true

FactoryBot.define do
  factory :transcoded_video do
    streamable { create(:streamable_video, is_transcoded_for_hls: true) }

    transient do
      key_base_path { "/attachments/#{SecureRandom.hex}" }
    end

    original_video_key { "#{key_base_path}/movie.mp4" }
    transcoded_video_key { "#{key_base_path}/movie/hls/index.m3u8" }
    job_id { "somejobid" }
    state { "completed" }
  end
end
