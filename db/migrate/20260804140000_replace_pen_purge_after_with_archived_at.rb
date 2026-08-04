class ReplacePenPurgeAfterWithArchivedAt < ActiveRecord::Migration[8.1]
  # purge_after was a retention deadline the CLIENT calculated (archive date +
  # 2 years) and sent over the wire — browser date math that silently landed a
  # day early for anyone off UTC. Store the fact instead of the derived
  # deadline: the server records when the pen was archived and derives the
  # deadline itself with ActiveSupport.
  def change
    remove_index :pens, :purge_after
    remove_column :pens, :purge_after, :date
    add_column :pens, :archived_at, :datetime
    add_index :pens, :archived_at
  end
end
