class Timesheet < ActiveRecord::Base

  unloadable

  require 'will_paginate'
  
  DEFAULT_SORT_COLUMN    = 'year, week_number'
  DEFAULT_SORT_DIRECTION = 'DESC'
  DEFAULT_SORT_ORDER     = "#{ DEFAULT_SORT_COLUMN } #{ DEFAULT_SORT_DIRECTION }"

  # Timesheets describe a week of activity by a particular
  # user. They are made up of TimesheetRows, where each row
  # corresponds to a particular issue. Within that row, each
  # day of activity for that issue is represented by a
  # single TimeEntry. A User can have many Timesheets.

  belongs_to( :user )

  has_many( :timesheet_rows, { :dependent => :destroy, :order => :position           } )
  has_many( :issues,         { :through   => :timesheet_rows                         } )
  has_many( :time_entries,   { :through   => :timesheet_rows, :dependent => :destroy } )

  # I want to use attr_accessible as follows:
  # 
  # attr_accessible(
  #   :week_number,
  #   :year,
  #   :description
  # )
  #
  # Unfortunately, Acts As Audited runs on this model (see below) and
  # uses attr_protected. Rails doesn't allow both, so I have to use
  # the less-secure attr_protected here too.

  attr_protected(
    :user_id,
    :committed_at,
    :timesheet_row_ids,
    :issue_ids,
    :time_entry_ids
  )

  # Return a range of years allowed for a timesheet

  def self.time_range
    ( Date.current.year - 10 )..( Date.current.year + 2 )
  end

  # Make sure the data is sane.

  validates_presence_of( :user_id )
  
  validates_inclusion_of(
    :week_number,
    :in => 1..53,
    :message => 'must lie between 1 and 53'
  )

  validates_inclusion_of(
    :year,
    :in => time_range(),
    :message => "must lie between #{ time_range().first } and #{ time_range().last }"
  )

  validates_inclusion_of(
    :committed,
    :in => [ true, false ],
    :message => "must be set to 'True' or 'False'"
  )

  validate( :column_sums_are_sane )
  
  def column_sums_are_sane
    TimesheetRow::DAY_ORDER.each do | day |
      if ( self.column_sum( day ) > 24 )
        errors.add_to_base( "#{ TimesheetRow::DAY_NAMES[ day ] }: Cannot exceed 24 hours per day" ) 
      end
    end
  end

  # Row validation catches individual rows being added before
  # we reach here. If a restricted user is taken off a issue but
  # has already saved a timesheet including that row, though,
  # they'll get warned. Same thing for inactive issues.
  #
  # Since the only way without hacking that the message can arise
  # (assuming correct functioning of views etc.) is for a issue to
  # have changed state during the lifespan of an uncommitted
  # timesheet, use "no longer..." wording in the error messages.

  validate( :issues_are_active_and_permitted )

  def issues_are_active_and_permitted()
    self.issues.each do | issue |
      errors.add_to_base( "issue '#{ issue.augmented_title }' is no longer active and cannot be included" ) unless issue.status.is_closed

#      if ( !self.user.admin? )
#        errors.add_to_base( "Inclusion of issue '#{ issue.augmented_title }' is no longer permitted" ) unless self.user.issue_ids.include?( issue.id )
#      end
    end
  end

  # Restrict the fields audited by the Acts As Audited plug-in.

  # Create Timesheet Row objects after saving, if not already
  # present. This must be done after because the ID of this
  # object instance is needed for the association.

  after_create :add_default_rows

  # Before an update, see if the 'committed' state is being set
  # to 'true'. If so, update the associated user's last committed
  # date.

  before_update :check_committed_state

  # Is the given user permitted to do anything with this timesheet?

  def is_permitted_for?( user )
    return ( user.admin? or user.id == self.user.id )
  end

  # Is the given user permitted to update this timesheet?

  def can_be_modified_by?( user )
    return true  if     ( user.admin? )
    return false unless ( self.is_permitted_for?( user ) )
    return ( not self.committed )
  end

  # Instance method that returns an array of all timesheets owned
  # by this user. Pass an optional conditions hash (will be sent
  # in as ":conditions => <given value>").

  def find_mine( conditions = {} )
    Timesheet.find_all_by_user_id( self.user_id, :conditions => conditions )
  end

  # Instance method which returns an array of all committed
  # timesheets owned by this user.

  def find_mine_committed( conditions = {} )
    conditions.merge!( :committed => true )
    return find_mine( conditions )
  end

  # Instance method which returns an array of all uncommitted
  # timesheets owned by this user.

  def find_mine_uncommitted( conditions = {} )
    conditions.merge!( :committed => false )
    return find_mine( conditions )
  end

  # Return an array of week numbers which can be assigned to the
  # timesheet. Includes the current timesheet's already allocated
  # week.

  def unused_weeks()
    timesheets = find_mine( :year => self.year )
    used_weeks = timesheets.collect do | hash |
      hash[ :week_number ]
    end

    range        = 1..Timesheet.get_last_week_number( self.year )
    unused_weeks = ( range.to_a - used_weeks )
    unused_weeks.push( self.week_number ) unless ( self.week_number.nil? )

    return unused_weeks.sort()
  end

  # Return the next (pass 'true') or previous (pass 'false') editable
  # week after this one, as a hash with properties 'week_number' and
  # 'timesheet'. The latter will be populated with a timesheet if there
  # is a not committed item in the found week, or nil if the week has no
  # associated timesheet yet. Returns nil altogether if no editable week
  # can be found (e.g. ask for previous from week 1, or all previous
  # weeks have committed timesheets on them).
  #
  # This operation may involve many database queries so is relatively slow.

  def editable_week( nextweek )
    discover_week( nextweek ) do | timesheet |
      ( timesheet.nil? or not timesheet.committed )
    end
  end

  # As editable_week, but returns weeks for 'showable' weeks - that is,
  # only weeks where a timesheet owned by the current user already exists.

  def showable_week( nextweek )
    discover_week( nextweek ) do | timesheet |
      ( not timesheet.nil? )
    end
  end

  # Back-end to editable_week and showable_week. See those functions for
  # details. Call with the next/previous week boolean and pass a block;
  # this is given a timesheet or nil; evaluate 'true' to return details
  # on the item or 'false' to move on to the next week.

  def discover_week( nextweek )
    year  = self.year
    owner = self.user_id

    if ( nextweek )
      inc   = 1
      week  = self.week_number + 1
      limit = Timesheet.get_last_week_number( year ) + 1

      return if ( week >= limit )
    else
      inc   = -1
      week  = self.week_number - 1
      limit = 0

      return if ( week <= limit )
    end

    while ( week != limit )
      timesheet = Timesheet.find_by_user_id_and_year_and_week_number(
        owner, year, week
      )

      if ( yield( timesheet ) )
        return { :week_number => week, :timesheet => timesheet }
      end

      week += inc
    end

    return nil
  end

  # Add a row to the timesheet using the given issue object. Does
  # nothing if a row containing that issue is already present.
  # The updated timesheet is not saved - the caller must do this.

  def add_row( issue )
    unless self.issues.include?( issue )
      timesheet_row      = TimesheetRow.new
      timesheet_row.issue = issue
      self.timesheet_rows.push( timesheet_row )
    end
  end

  # Count the hours across all rows on the given day number; 0 is
  # Sunday, 1-6 Monday to Saturday.

  def column_sum( day_number )
    sum = 0.0

    # [TODO] Slow. Surely there's a better way...?

    self.timesheet_rows.each do | timesheet_row |
      time_entry = TimeEntry.find_by_timesheet_row_id(
        timesheet_row.id,
        :conditions => { :day_number => day_number }
      )

      sum += time_entry.hours if time_entry
    end

    return sum
  end

  # Count the total number of hours in the whole timesheet.

  def total_sum()
    return self.time_entries.sum( :hours )
  end

  # Return the date of the first day for this timesheet as a string.

  def start_day()
    return self.date_for( TimesheetRow::FIRST_DAY )
  end

  # Get the date of the first day of week 1 in the given year.
  # Note that sometimes, this can be in December the previous
  # year. Works on commercial weeks (Mon->Sun). Returns a Date.

  def self.get_first_week_start( year )

    # Is Jan 1st already in week 1?

    date = Date.new( year, 1, 1 )

    if ( date.cweek == 1 )

      # Yes. Check December of the previous year.

      31.downto( 25 ) do | day |
        date = Date.new( year - 1, 12, day )

        # If we encounter a date in the previous year which has a week
        # number > 1, then that's the last week of the previous year. If
        # we're on Dec 31st that means that week 1 started on Jan 1st,
        # else in December on 

        if ( date.cweek > 1 )
          return ( day == 31 ? Date.new( year, 1, 1 ) : Date.new( year - 1, 12, day + 1 ) )
        end
      end

    else

      # No. Walk forward through January until we reach week 1.

      2.upto( 7 ) do | day |
        date = Date.new( year, 1, day )
        return date if ( date.cweek == 1 )
      end
    end
  end

  # Get the date of the last day of the last week in the given year.
  # Note that sometimes, this can be in January in the following
  # year. Works on commercial weeks (Mon->Sun). Returns a Date.

  def self.get_last_week_end( year )

    # Is Dec 31st already in week 1 for the next year?

    date = Date.new( year, 12, 31 )

    if ( date.cweek == 1 )

      # Yes. Check backwards through December to find the last day
      # in the higher week number.

      30.downto( 25 ) do | day |
        date = Date.new( year, 12, day )
        return Date.new( year, 12, day ) if ( date.cweek > 1 )
      end

    else

      # No. Check January of the following year to find the end
      # of the highest numbered week.

      1.upto( 6 ) do | day |
        date = Date.new( year + 1, 1, day )
        if ( date.cweek == 1 )
          return ( day == 1 ? Date.new( year, 12, 31 ) : Date.new( year + 1, 1, day - 1 ) )
        end
      end
    end
  end

  # Get the number of the last commercial week (Mon->Sun) in the
  # given year. This is usually 52, but is 53 for some years.

  def self.get_last_week_number( year )

    # Is Dec 31st already in week 1 for the next year?

    date = Date.new( year, 12, 31 )

    if ( date.cweek == 1 )

      # Yes. Check backwards through December to find the last day
      # in the higher week number.

      30.downto( 25 ) do | day |
        date = Date.new( year, 12, day )
        return date.cweek if ( date.cweek > 1 )
      end

    else

      # No, so we have the highest week already.

      return date.cweek
    end
  end

  # Return a date string representing this timesheet on the given
  # day number. Day numbers are odd - 0 = Sunday at the *end* of this
  # timesheet's week, while 1-6 = Monday at the *start* of the week
  # through to Saturday inclusive (although this may be changed; see
  # the Timesheet Row model). If an optional second parameter is
  # 'true', returns a Date object rather than a string.

  def date_for( day_number, as_date = false )
    Timesheet.date_for( self.year, self.week_number, day_number, as_date )
  end

  # Class method; as date_for, but pass explicitly the year, week number
  # and day number of interest. If an optional fourth parameter is 'true',
  # returns a Date object rather than a string.

  def self.date_for( year, week_number, day_number, as_date = false )

    # Get the date of Monday, week 1 in this timesheet's year.
    # Add as many days as needed to get to Monday of the week
    # for this timesheet.

    date = Timesheet.get_first_week_start( year )
    date = date + ( ( week_number - 1 ) * 7 )

    # Add in the day number offset.

    date += TimesheetRow::DAY_ORDER.index( day_number )

    # Return in DD-Mth-YYYY format, or as a Date object?

    if ( as_date )
      return date
    else
      return date.strftime( '%d-%b-%Y') # Or ISO: '%Y-%m-%d'
    end
  end
  
  def self.overdue(year, week_number)
    
    this_date = Timesheet.date_for(year, week_number, 6, true)
    
    if (Date.today - this_date).to_i > 0
      return true
    end
    
    return false
    
  end
  
  def self.default_issues
    # All visible Activity tracker issues that are expected to be worked during this time period
    # MAYBE: remove issues where total actuals >= estimated or something clever-er
    issues=[]
    
    default_tracker_id = Tracker.find(:first, :conditions => [ "id = ?", Setting.plugin_redmine_planning['tracker']]).id
    
    Issue.visible.each do | issue |
      if ( issue.tracker.id == default_tracker_id ) &&  
        (issue.start_date.nil? || issue.start_date >= Date.today ) && 
        (issue.due_date.nil? || (issue.due_date + 7) >= Date.today )
        issues << issue
      end
    end
    
    return issues
  end

private

  def add_default_rows
    
    # All visible Activity tracker issues that are expected to be worked during this time period
    # MAYBE: remove issues where total actuals >= estimated
    
    Timesheet.default_issues.each do |issue |
      add_row( issue )
    end
  end

  def check_committed_state
    if ( self.committed )
      self.committed_at = self.user.last_committed = Time.new
      self.user.save!
    end
  end
end
