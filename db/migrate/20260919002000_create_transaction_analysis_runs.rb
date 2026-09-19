class CreateTransactionAnalysisRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_analysis_runs, id: :uuid do |t|
      t.references :transaction_analysis, null: false, type: :uuid,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :rerun_of, type: :uuid,
                   foreign_key: { to_table: :transaction_analysis_runs, on_delete: :nullify }, index: false
      t.string :status, null: false, default: "pending"
      t.text :prompt, null: false
      t.text :clarification_question
      t.text :clarification_response
      t.jsonb :scope, null: false, default: {}
      t.jsonb :deterministic_output, null: false, default: {}
      t.text :result_markdown
      t.jsonb :assumptions, null: false, default: []
      t.jsonb :chart_spec, null: false, default: {}
      t.string :provider_id
      t.string :model
      t.text :error_message
      t.datetime :completed_at

      t.timestamps
    end

    add_check_constraint :transaction_analysis_runs,
                         "status IN ('pending', 'running', 'awaiting_clarification', 'completed', 'failed')",
                         name: "chk_transaction_analysis_runs_status"
    add_index :transaction_analysis_runs, [ :transaction_analysis_id, :created_at ]
    add_index :transaction_analysis_runs, [ :transaction_analysis_id, :status ]
    add_index :transaction_analysis_runs, [ :status, :created_at ]
    add_index :transaction_analysis_runs, :rerun_of_id
  end
end
