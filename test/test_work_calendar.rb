require 'helper'

describe "work calendar" do
  # One week of data: Mon 2024-06-03 .. Sun 2024-06-09 (all times UTC).
  #
  # * schedule v1 (from 2024-01-01): Mon-Fri 09:00-12:00 and 13:00-17:00
  #   (lunch break), plus a Friday night shift 20:00-02:00 into Saturday
  # * schedule v2 (from Thu 2024-06-06): Mon-Fri 08:00-12:00 and
  #   12:30-16:30, Friday night shift kept
  # * Saturday 2024-06-08 is a holiday, cutting the Friday night tail
  # * Friday 2024-06-07 gets a temporary opening 19:00-21:00 that overlaps
  #   the night shift
  # * Sunday 2024-06-09 gets a temporary opening 10:00-14:00
  let(:calendar) do
    BusinessTime::WorkCalendar.new(
      time_zone: "UTC",
      schedules: [
        { starts_on: Date.new(2024, 1, 1), hours: {
            mon: [["09:00", "12:00"], ["13:00", "17:00"]],
            tue: [["09:00", "12:00"], ["13:00", "17:00"]],
            wed: [["09:00", "12:00"], ["13:00", "17:00"]],
            thu: [["09:00", "12:00"], ["13:00", "17:00"]],
            fri: [["09:00", "12:00"], ["13:00", "17:00"], ["20:00", "02:00"]] } },
        { starts_on: Date.new(2024, 6, 6), hours: {
            mon: [["08:00", "12:00"], ["12:30", "16:30"]],
            tue: [["08:00", "12:00"], ["12:30", "16:30"]],
            wed: [["08:00", "12:00"], ["12:30", "16:30"]],
            thu: [["08:00", "12:00"], ["12:30", "16:30"]],
            fri: [["08:00", "12:00"], ["12:30", "16:30"], ["20:00", "02:00"]] } }
      ],
      holidays: [Date.new(2024, 6, 8)],
      extra_workdays: [
        { Date.new(2024, 6, 7) => [["19:00", "21:00"]] },
        { Date.new(2024, 6, 9) => [["10:00", "14:00"]] }
      ]
    )
  end

  describe "lunch break" do
    it "does not count the lunch break as business time" do
      from = Time.utc(2024, 6, 3, 11)
      to = Time.utc(2024, 6, 3, 14)
      assert_equal 7200, calendar.business_time_until(from, to)
    end

    it "adds and subtracts across the lunch break boundary" do
      assert_equal Time.utc(2024, 6, 3, 13, 30),
                   calendar.add_business_seconds(Time.utc(2024, 6, 3, 11, 30), 3600)
      assert_equal Time.utc(2024, 6, 3, 11, 30),
                   calendar.subtract_business_seconds(Time.utc(2024, 6, 3, 13, 30), 3600)
    end

    it "rolls out of the lunch break when adding zero seconds" do
      assert_equal Time.utc(2024, 6, 3, 13),
                   calendar.add_business_seconds(Time.utc(2024, 6, 3, 12, 30), 0)
      assert_equal Time.utc(2024, 6, 3, 12),
                   calendar.subtract_business_seconds(Time.utc(2024, 6, 3, 12, 30), 0)
    end
  end

  describe "overnight shifts and holidays" do
    it "extends the Friday night shift past midnight" do
      assert_equal Time.utc(2024, 6, 8, 0, 0),
                   calendar.add_business_seconds(Time.utc(2024, 6, 7, 21), 3 * 3600)
    end

    it "cuts the overnight tail landing on a holiday" do
      from = Time.utc(2024, 6, 7, 21)
      to = Time.utc(2024, 6, 8, 12)
      assert_equal 3 * 3600, calendar.business_time_until(from, to)
    end

    it "counts the overnight tail when the next day is not a holiday" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "UTC",
                                           hours: { fri: [["20:00", "02:00"]] })
      assert_equal 6 * 3600,
                   cal.business_time_until(Time.utc(2024, 6, 7, 20), Time.utc(2024, 6, 8, 2))
    end

    it "removes a whole holiday range from the schedule" do
      cal = BusinessTime::WorkCalendar.new(
        time_zone: "UTC",
        hours: { mon: ["09:00", "17:00"], tue: ["09:00", "17:00"] },
        holidays: [Date.new(2024, 6, 3)..Date.new(2024, 6, 4)]
      )
      assert_equal 0, cal.business_time_until(Time.utc(2024, 6, 3, 0), Time.utc(2024, 6, 5, 0))
    end
  end

  describe "schedule versions" do
    it "switches schedule versions on the effective date" do
      # Wednesday 2024-06-05 still uses v1 (09:00-12:00, 13:00-17:00),
      # Thursday 2024-06-06 uses v2 (08:00-12:00, 12:30-16:30)
      assert_equal Time.utc(2024, 6, 6, 8, 30),
                   calendar.add_business_seconds(Time.utc(2024, 6, 5, 16, 30), 3600)
      assert_equal 15 * 3600,
                   calendar.business_time_until(Time.utc(2024, 6, 5, 9), Time.utc(2024, 6, 6, 17))
    end

    it "applies the earliest version before the first starts_on" do
      # Friday 2023-12-29 is before the first version's starts_on
      assert_equal 7 * 3600,
                   calendar.business_time_until(Time.utc(2023, 12, 29, 9), Time.utc(2023, 12, 29, 17))
    end
  end

  describe "temporary openings" do
    it "merges overlapping segments instead of counting them twice" do
      # the 19:00-21:00 opening overlaps the 20:00-02:00 night shift
      assert_equal 3600,
                   calendar.business_time_until(Time.utc(2024, 6, 7, 19, 30), Time.utc(2024, 6, 7, 20, 30))
      assert_equal 5 * 3600,
                   calendar.business_time_until(Time.utc(2024, 6, 7, 18), Time.utc(2024, 6, 8, 3))
    end

    it "opens a normally closed day with explicit hours" do
      assert_equal 4 * 3600,
                   calendar.business_time_until(Time.utc(2024, 6, 9, 9), Time.utc(2024, 6, 9, 15))
      assert_equal Time.utc(2024, 6, 9, 11),
                   calendar.add_business_seconds(Time.utc(2024, 6, 8, 12), 3600)
    end

    it "opens extra workdays with default hours when none are given" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "UTC",
                                           hours: { mon: ["09:00", "17:00"] },
                                           extra_workdays: [Date.new(2024, 6, 8)])
      assert_equal 8 * 3600,
                   cal.business_time_until(Time.utc(2024, 6, 8, 9), Time.utc(2024, 6, 8, 17))
    end

    it "accepts date ranges for temporary openings" do
      cal = BusinessTime::WorkCalendar.new(
        time_zone: "UTC",
        hours: { mon: ["09:00", "17:00"] },
        extra_workdays: [{ Date.new(2024, 6, 8)..Date.new(2024, 6, 9) => [["10:00", "12:00"]] }]
      )
      assert_equal 4 * 3600,
                   cal.business_time_until(Time.utc(2024, 6, 8, 0), Time.utc(2024, 6, 10, 0))
    end
  end

  describe "round trips" do
    it "returns to the original time after adding and subtracting the same amount" do
      start = Time.utc(2024, 6, 4, 14, 15, 30)
      seconds = 20_000
      later = calendar.add_business_seconds(start, seconds)
      assert_equal seconds, calendar.business_time_until(start, later)
      assert_equal start, calendar.subtract_business_seconds(later, seconds)
      assert_equal start, calendar.add_business_seconds(later, -seconds)
    end

    it "round-trips when landing exactly on an interval boundary" do
      start = Time.utc(2024, 6, 4, 14, 15, 30)
      seconds = 9_870 # exactly until 17:00
      later = calendar.add_business_seconds(start, seconds)
      assert_equal Time.utc(2024, 6, 4, 17), later
      assert_equal start, calendar.subtract_business_seconds(later, seconds)
    end

    it "round-trips across the schedule switch and the holiday weekend" do
      start = Time.utc(2024, 6, 5, 10)
      seconds = 30 * 3600
      later = calendar.add_business_seconds(start, seconds)
      assert_equal seconds, calendar.business_time_until(start, later)
      assert_equal start, calendar.subtract_business_seconds(later, seconds)
    end

    it "reports negative durations for reversed ranges" do
      assert_equal(-7200,
                   calendar.business_time_until(Time.utc(2024, 6, 3, 14), Time.utc(2024, 6, 3, 11)))
    end
  end

  describe "dst policy" do
    it "converts missing local times by shifting forward" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "America/New_York",
                                           hours: { sun: [["00:30", "02:30"]] })
      # 2024-03-10: 02:00-03:00 does not exist, the end shifts to 03:00,
      # so 2 wall hours are 1.5 real hours
      assert_equal 5400,
                   cal.business_time_until(Time.utc(2024, 3, 10, 5, 30), Time.utc(2024, 3, 10, 8, 0))
    end

    it "raises for missing local times with gap: :raise" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "America/New_York",
                                           hours: { sun: [["00:30", "02:30"]] },
                                           dst_policy: { gap: :raise })
      assert_raises(ArgumentError) { cal.intervals_on(Date.new(2024, 3, 10)) }
    end

    it "counts real elapsed seconds across the repeated hour" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "America/New_York",
                                           hours: { sun: [["00:30", "02:30"]] })
      # 2024-11-03: 01:00-02:00 happens twice, 2 wall hours are 3 real hours
      assert_equal 10_800,
                   cal.business_time_until(Time.utc(2024, 11, 3, 4, 30), Time.utc(2024, 11, 3, 7, 30))
    end

    it "resolves repeated local times with the ambiguous policy" do
      first = BusinessTime::WorkCalendar.new(time_zone: "America/New_York",
                                             hours: { sun: [["00:30", "01:30"]] })
      last = BusinessTime::WorkCalendar.new(time_zone: "America/New_York",
                                            hours: { sun: [["00:30", "01:30"]] },
                                            dst_policy: { ambiguous: :last })
      # 01:30 happens twice on 2024-11-03; the policy picks the occurrence
      assert_equal Time.utc(2024, 11, 3, 5, 30), first.intervals_on(Date.new(2024, 11, 3)).first[1]
      assert_equal Time.utc(2024, 11, 3, 6, 30), last.intervals_on(Date.new(2024, 11, 3)).first[1]
      assert_equal 3600, first.business_time_until(Time.utc(2024, 11, 3, 0, 0), Time.utc(2024, 11, 3, 12, 0))
      assert_equal 7200, last.business_time_until(Time.utc(2024, 11, 3, 0, 0), Time.utc(2024, 11, 3, 12, 0))
    end
  end

  describe "integration with the existing api" do
    it "is usable through the :calendar option of business_hours" do
      assert_equal Time.utc(2024, 6, 3, 13, 30),
                   1.business_hours.after(Time.utc(2024, 6, 3, 11, 30), calendar: calendar)
      assert_equal Time.utc(2024, 6, 3, 11, 30),
                   1.business_hours.before(Time.utc(2024, 6, 3, 13, 30), calendar: calendar)
    end

    it "is usable through the :calendar option of business_time_until" do
      from = Time.utc(2024, 6, 3, 11)
      to = Time.utc(2024, 6, 3, 14)
      assert_equal 7200, from.business_time_until(to, calendar: calendar)
    end

    it "applies as the global default for legacy calls when configured" do
      BusinessTime::Config.work_calendar = calendar
      assert_equal Time.utc(2024, 6, 3, 13, 30),
                   1.business_hours.after(Time.utc(2024, 6, 3, 11, 30))
      assert_equal 7200,
                   Time.utc(2024, 6, 3, 11).business_time_until(Time.utc(2024, 6, 3, 14))
    end
  end

  describe "misc" do
    it "knows whether a time is inside working hours" do
      assert calendar.working?(Time.utc(2024, 6, 3, 10))
      refute calendar.working?(Time.utc(2024, 6, 3, 12, 30))
      refute calendar.working?(Time.utc(2024, 6, 8, 10))
    end

    it "accepts the legacy flat pair format for a single segment" do
      cal = BusinessTime::WorkCalendar.new(time_zone: "UTC", hours: { mon: ["09:00", "17:00"] })
      assert_equal 8 * 3600,
                   cal.business_time_until(Time.utc(2024, 6, 3, 0), Time.utc(2024, 6, 3, 23, 59, 59))
    end

    it "rejects conflicting schedule definitions" do
      assert_raises(ArgumentError) do
        BusinessTime::WorkCalendar.new(
          hours: { mon: ["09:00", "17:00"] },
          schedules: [{ starts_on: nil, hours: { mon: ["09:00", "17:00"] } }]
        )
      end
    end

    it "rejects calendars without any working time" do
      assert_raises(ArgumentError) { BusinessTime::WorkCalendar.new(hours: {}) }
    end

    it "rejects invalid day times" do
      assert_raises(ArgumentError) do
        BusinessTime::WorkCalendar.new(hours: { mon: ["nope", "17:00"] })
      end
    end
  end
end
