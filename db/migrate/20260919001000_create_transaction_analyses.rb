class CreateTransactionAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_analyses, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :title, null: false, default: "New analysis"

      t.timestamps
    end

    add_index :transaction_analyses, [ :user_id, :updated_at ]
  end
end
