class CreateHermesArchiveAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :hermes_archive_accounts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :source, null: false
      t.string :source_id, null: false
      t.string :name, null: false
      t.string :institution_name
      t.string :institution_url
      t.string :institution_color
      t.string :currency, null: false
      t.string :account_type, null: false
      t.string :subtype
      t.decimal :current_balance, precision: 19, scale: 4, null: false, default: 0
      t.decimal :available_balance, precision: 19, scale: 4
      t.datetime :last_synced_at
      t.jsonb :extra, null: false, default: {}

      t.timestamps
    end

    add_index :hermes_archive_accounts,
              [ :family_id, :source, :source_id ],
              unique: true,
              name: "index_hermes_archive_accounts_on_family_source_id"
  end
end
