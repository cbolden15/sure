class CreateTransactionAnalysisEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_analysis_evidences, id: :uuid do |t|
      t.references :transaction_analysis_run, null: false, type: :uuid,
                   foreign_key: { on_delete: :cascade }, index: false
      t.references :transaction, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.string :citation_token, null: false
      t.jsonb :snapshot, null: false, default: {}

      t.timestamps
    end

    add_index :transaction_analysis_evidences, [ :transaction_analysis_run_id, :citation_token ],
              unique: true, name: "index_transaction_analysis_evidences_on_run_and_token"
    add_index :transaction_analysis_evidences, :transaction_id
  end
end
