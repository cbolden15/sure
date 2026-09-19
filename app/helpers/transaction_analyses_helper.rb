module TransactionAnalysesHelper
  def transaction_analysis_scope_label(scope)
    return t("transaction_analyses.scope.all_history") if scope["all_history"]

    t(
      "transaction_analyses.scope.date_range",
      start_date: format_date(Date.iso8601(scope.fetch("start_date")), :short),
      end_date: format_date(Date.iso8601(scope.fetch("end_date")), :short)
    )
  rescue KeyError, ArgumentError
    t("transaction_analyses.scope.unavailable")
  end

  def transaction_analysis_status_pill(run)
    tone = case run.status
    when "completed" then :success
    when "failed" then :error
    when "awaiting_clarification" then :warning
    else :info
    end

    render DS::Pill.new(
      label: t("transaction_analyses.status.#{run.status}"),
      tone: tone,
      marker: false,
      show_dot: run.pending? || run.running?
    )
  end

  def transaction_analysis_operation_label(operation)
    t("transaction_analyses.calculations.operations.#{operation}", default: operation.to_s.humanize)
  end

  def transaction_analysis_value_label(key)
    t("transaction_analyses.calculations.values.#{key}", default: key.to_s.humanize)
  end

  def transaction_analysis_display_value(value)
    return value.fetch("display") if value.is_a?(Hash) && value["display"].present?
    return value.fetch("raw") if value.is_a?(Hash) && value.key?("raw")
    return value.join(", ") if value.is_a?(Array)

    value.to_s
  end

  def transaction_analysis_scalar_values(values)
    values.each_with_object([]) do |(key, value), result|
      next if key == "rows" || value.is_a?(Array)

      if value.is_a?(Hash) && !value.key?("display") && !value.key?("raw")
        value.each { |nested_key, nested_value| result << [ "#{key}_#{nested_key}", nested_value ] }
      else
        result << [ key, value ]
      end
    end
  end

  def transaction_analysis_chart_data(run)
    spec = run.chart_spec
    return [] unless spec.is_a?(Hash) && spec.fetch("type", nil).in?(%w[line bar])

    Array(spec["series"]).filter_map do |point|
      next unless point.is_a?(Hash) && point["label"].is_a?(String)

      income = Float(point["income"])
      expenses = Float(point["expenses"])
      next unless income.finite? && expenses.finite?

      { label: point["label"].truncate(120), income: income, expenses: expenses }
    rescue ArgumentError, TypeError
      nil
    end
  end

  def transaction_analysis_chart?(run)
    run.chart_spec.is_a?(Hash) && run.chart_spec.fetch("type", nil).in?(%w[line bar]) && transaction_analysis_chart_data(run).any?
  end

  def transaction_analysis_chart_value(value, currency)
    Money.new(value, currency).format
  rescue ArgumentError, TypeError
    value.to_s
  end

  def accessible_evidence_transaction(evidence)
    transaction = evidence.source_transaction
    account_id = transaction&.entry&.account_id
    return unless account_id && Current.user.accessible_accounts.visible.where(id: account_id).exists?

    transaction
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def transaction_analysis_evidence_amount(snapshot)
    amount = snapshot["amount"]
    currency = snapshot["currency"]
    return if amount.blank? || currency.blank?

    Money.new(BigDecimal(amount.to_s), currency).format
  rescue ArgumentError, TypeError, ActiveModel::ValidationError
    "#{amount} #{currency}"
  end

  def transaction_analysis_markdown(markdown)
    sanitize(
      self.markdown(markdown),
      tags: %w[p br h2 h3 ul ol li strong em code pre blockquote table thead tbody tr th td],
      attributes: []
    )
  end
end
