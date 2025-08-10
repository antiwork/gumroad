# Servicio mejorado para prevención de balances duplicados
class BalanceTransactionService
  def self.create_with_duplicate_check!(user:, purchase:, amount:, transaction_type:, description: nil)
    # Verificar duplicados antes de crear
    existing = BalanceTransaction.find_by(
      user: user,
      purchase: purchase,
      transaction_type: transaction_type,
      amount: amount
    )

    if existing && existing.created_at > 1.minute.ago
      Rails.logger.warn("Preventing duplicate balance transaction for user #{user.id}, purchase #{purchase&.id}")
      return existing
    end

    BalanceTransaction.create!(
      user: user,
      purchase: purchase,
      amount: amount,
      transaction_type: transaction_type,
      description: description
    )
  end
