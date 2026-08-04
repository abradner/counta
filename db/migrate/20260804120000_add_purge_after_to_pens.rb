class AddPurgeAfterToPens < ActiveRecord::Migration[8.1]
  def change
    # Client-set TTL: archiving a pen sets purge_after = archive date + 2
    # years; the server-side purge job honours it without knowing why (the
    # archive state itself lives inside the encrypted blob). Plaintext with
    # reason — see docs/data-privacy.md data map.
    add_column :pens, :purge_after, :date
    add_index :pens, :purge_after
  end
end
