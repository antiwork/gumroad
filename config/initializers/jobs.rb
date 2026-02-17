# frozen_string_literal: true

JOBS = JSON.load_file("#{Rails.root}/config/jobs.json")["jobs"].map(&:deep_symbolize_keys).freeze
