# frozen_string_literal: true

class Exports::AffiliateExportService
  AFFILIATE_FIELDS = [
    "Affiliate ID", "Name", "Email", "Fee", "Products", "Sales ($)",
    "Referral URL", "Destination URL", "Created At",
  ].freeze
  TOTALS_COLUMN_NAME = "Totals"
  SYNCHRONOUS_EXPORT_THRESHOLD = 500
  attr_reader :filename, :tempfile

  def initialize(seller)
    @seller = seller
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Affiliates-#{@seller.username}_#{timestamp}.csv"
    @totals = Hash.new(0)
  end

  def perform
    @tempfile = Tempfile.new(["Affiliates", ".csv"], "tmp", encoding: "UTF-8")

    CsvSafe.open(@tempfile, "wb") do |csv|
      csv << AFFILIATE_FIELDS
      @seller.direct_affiliates.alive.includes(:affiliate_user, :products).find_each do |affiliate|
        csv << affiliate_row(affiliate)
      end

      totals_row = Array.new(AFFILIATE_FIELDS.size)
      totals_row[0] = TOTALS_COLUMN_NAME
      totals.each do |column_name, amount_cents|
        totals_row[AFFILIATE_FIELDS.index(column_name)] = MoneyFormatter.format(amount_cents, :usd, symbol: false)
      end
      csv << totals_row
    end

    @tempfile.rewind
    self
  end

  def self.export(seller:, recipient: seller)
    if seller.direct_affiliates.alive.count <= SYNCHRONOUS_EXPORT_THRESHOLD
      new(seller).perform
    else
      Exports::AffiliateExportWorker.perform_async(seller.id, recipient.id)
      false
    end
  end

  private
    attr_reader :totals

    def affiliate_row(affiliate)
      sales_cents = affiliate.total_amount_cents
      data = {
        "Affiliate ID" => affiliate.external_id_numeric,
        "Name" => affiliate.affiliate_user.name.presence || affiliate.affiliate_user.username,
        "Email" => affiliate.affiliate_user.email,
        "Fee" => "#{affiliate.affiliate_percentage} %",
        "Sales ($)" => MoneyFormatter.format(sales_cents, :usd, symbol: false),
        "Products" => affiliate.products.map(&:name),
        "Referral URL" => affiliate.referral_url,
        "Destination URL" => affiliate.destination_url,
        "Created At" => affiliate.created_at.in_time_zone(affiliate.affiliate_user.timezone).to_date,
      }

      row = Array.new(AFFILIATE_FIELDS.size)

      # Sum cents, not the rendered cell: MoneyFormatter delimits thousands, and
      # "1,234.56".to_f is 1.0, so every affiliate past $999.99 counted as a dollar.
      @totals["Sales ($)"] += sales_cents

      data.each do |column_name, value|
        row[AFFILIATE_FIELDS.index(column_name)] = value
      end
      row
    end
end
