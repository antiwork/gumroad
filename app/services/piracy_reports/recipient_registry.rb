# frozen_string_literal: true

# Where a notice goes is never the agent's call: it reads pages that pirates control, and the
# notice carries the seller's name and email. A report on a host with no entry stays in screening.
class PiracyReports::RecipientRegistry
  PATH = Rails.root.join("config", "piracy_recipients.yml")
  Entry = Data.define(:name, :email, :source_url)

  def self.entries
    @entries ||= (YAML.load_file(PATH) || {}).to_h do |host, attributes|
      [PiracyReport.normalized_host(host), Entry.new(**attributes.to_h.symbolize_keys.slice(:name, :email, :source_url))]
    end.freeze
  end

  def self.for_host(host)
    candidates(PiracyReport.normalized_host(host)).lazy.filter_map { entries[_1] }.first
  end

  # The host itself, then each parent domain above the top level. An IP address matches exactly.
  def self.candidates(host)
    return [host] if host.match?(/\A[\d.]+\z/) || host.include?(":")

    labels = host.split(".")
    (0...[labels.size - 1, 1].max).map { labels[_1..].join(".") }
  end
end
