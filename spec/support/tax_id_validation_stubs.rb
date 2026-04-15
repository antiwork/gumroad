# frozen_string_literal: true

module TaxIdValidationStubs
  def stub_tax_id_validation_services
    allow_any_instance_of(TaxIdValidationService).to receive(:process) { |service| service.tax_id.present? }
    allow_any_instance_of(AbnValidationService).to receive(:process) { |service| service.abn_id.present? }
    allow_any_instance_of(MvaValidationService).to receive(:process) { |service| service.mva_id.present? }
    allow_any_instance_of(GstValidationService).to receive(:process) { |service| service.gst_id.present? }
    allow_any_instance_of(QstValidationService).to receive(:process) { |service| service.qst_id.present? }
    allow_any_instance_of(VatValidationService).to receive(:process) { |service| service.vat_id.present? }
    allow_any_instance_of(KraPinValidationService).to receive(:process) { |service| service.kra_pin.present? }
    allow_any_instance_of(TrnValidationService).to receive(:process) { |service| service.trn.present? }
    allow_any_instance_of(OmanVatNumberValidationService).to receive(:process) { |service| service.vat_number.present? }
    allow_any_instance_of(FirsTinValidationService).to receive(:process) { |service| service.tin.present? }
    allow_any_instance_of(TraTinValidationService).to receive(:process) { |service| service.tra_tin.present? }
  end
end

RSpec.configure do |config|
  config.include TaxIdValidationStubs
  config.before(:each, :stub_tax_id_validation) do
    stub_tax_id_validation_services
  end
end
