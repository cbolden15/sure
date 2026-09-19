class TransactionAnalysis::EvidenceCollector
  MAXIMUM_PER_RUN = 25

  def initialize(run:)
    @run = run
  end

  def collect!(transactions)
    TransactionAnalysis::Evidence.transaction do
      @run.evidences.destroy_all
      Array(transactions).uniq(&:id).select { |transaction| in_run_scope?(transaction) }.first(MAXIMUM_PER_RUN).each_with_index.map do |transaction, index|
        @run.evidences.create!(
          citation_token: "E#{index + 1}",
          source_transaction: transaction,
          snapshot: snapshot_for(transaction)
        )
      end
    end
  end

  def model_payload
    @run.evidences.to_a.sort_by { |evidence| evidence.citation_token.delete_prefix("E").to_i }.map do |evidence|
      { "token" => evidence.citation_token, "transaction" => evidence.snapshot }
    end
  end

  private
    def snapshot_for(transaction)
      entry = transaction.entry
      scope = resolved_scope
      {
        "merchant" => transaction.merchant&.name.presence || entry.name,
        "amount" => entry.amount.to_d.to_s("F"),
        "currency" => entry.currency,
        "date" => entry.date.iso8601,
        "category" => transaction.category&.name.presence || "Uncategorized",
        "account_label" => scope.account_labels.fetch(scope.account_ids.index(entry.account_id))
      }
    end

    def in_run_scope?(transaction)
      scope = resolved_scope
      entry = transaction.entry
      entry && entry.account_id.in?(scope.account_ids) && entry.date.in?(scope.date_range)
    end

    def resolved_scope
      @resolved_scope ||= TransactionAnalysis::Scope.from_snapshot!(user: @run.transaction_analysis.user, snapshot: @run.scope)
    end
end
