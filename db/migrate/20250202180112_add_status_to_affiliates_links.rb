class AddStatusToAffiliatesLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :affiliates_links, :status, :string, null: false, default: 'pending'
    add_column :affiliates_links, :status_updated_at, :datetime
    add_index :affiliates_links, :status
    
    # Set status_updated_at to created_at for existing records
    reversible do |dir|
      dir.up do
        execute "UPDATE affiliates_links SET status_updated_at = created_at WHERE status_updated_at IS NULL"
      end
    end
  end
end
