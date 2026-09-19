class AddLockVersionToTransactionAnalysisRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :transaction_analysis_runs, :lock_version, :integer, null: false, default: 0
  end
end
