class AddTimesheetRowToTimeEntries < ActiveRecord::Migration
  def self.up
    add_column :time_entries, :timesheet_row_id,  :integer
  end

  def self.down
    remove_column :time_entries, :timesheet_row_id
  end
end
